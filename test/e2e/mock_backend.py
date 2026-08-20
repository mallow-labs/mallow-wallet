#!/usr/bin/env python3
"""Sandboxed mock backend for mallow wallet E2E tests.

A single dependency-free HTTP server (stdlib only) that stands in for the real
mallow backend (v1 + v2 REST) and the Solana RPC proxy during automated device
tests. Flows become deterministic: the pass/fail of a regression test reflects
the app, not devnet latency or backend state.

The app reaches this server (running on the host) from inside the Android
emulator via the host-loopback alias 10.0.2.2. The authoritative dart-define
list that points the app here (API, v2, RPC proxy, ETH/Tezos RPC) lives in
test/e2e/dart_defines.sh, sourced by test/e2e/lib.sh.

Resolution order for a request, most specific first:

    1. fault rules        (POST /__test__/fault)
    2. active scenario    test/e2e/fixtures/<scenario>/routes.json, file order
    3. default scenario   test/e2e/fixtures/default/routes.json
    4. built-in handlers  JSON-RPC verbs, POST /v2/tx/*
    5. DEFAULTS           empty list/object keyed by HTTP method

So a scenario file only states its diffs from `default`. Every request logs one
stderr line naming the rule that answered it; a `DEFAULT` tag is how a missing
fixture gets found.

Solana verbs all POST to the same proxy-root path, so JSON-RPC requests are
dispatched on the body's `method` field, not on the path. Batch bodies (a JSON
array) are supported and answered with an array of envelopes.

!! The `/__test__/*` control surface exists ONLY in this file. It is never
!! compiled into the app and cannot be reached in any release build - there is
!! no client, define, or route for it outside this mock.
"""

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from txfixture import (  # noqa: E402  (path shim must run first)
    DEFAULT_BLOCKHASH,
    PLACEHOLDER_FEE_PAYER,
    build_unsigned_tx,
    signature_for,
)

PORT = int(os.environ.get("MOCK_PORT", "8091"))
FIXTURES_DIR = os.path.join(_HERE, "fixtures")
DEFAULT_SCENARIO = "default"

# Fallback bodies by method when nothing else matches. Lists for
# collection-ish GETs, objects otherwise.
DEFAULTS = {
    "GET": [],
    "POST": {},
    "PATCH": {},
    "PUT": {},
    "DELETE": {},
    "HEAD": {},
}

SYSTEM_PROGRAM_ID = "11111111111111111111111111111111"

# Tunables merged by POST /__test__/state. Reset restores exactly this dict.
INITIAL_STATE = {
    # Fee payer baked into generated /v2/tx/* fixtures. Set it to the
    # deterministic test wallet's address before any signing flow.
    "fee_payer": PLACEHOLDER_FEE_PAYER,
    "tx_version": "legacy",
    "tx_presigned": False,
    "blockhash": DEFAULT_BLOCKHASH,
    # isBlockhashValid answer. False makes awaitConfirmationOrThrow give up at
    # its ~15 s expiry probe instead of burning the full 90 s maxWait.
    "blockhash_valid": True,
    # getSignatureStatuses polls before the tx is reported landed.
    "confirm_after_polls": 1,
    # Non-null puts an error into the confirmation status (and getTransaction).
    "tx_error": None,
    # Non-null puts an error into simulateTransaction.
    "sim_error": None,
    "balance_lamports": 2000000000,
    # getBalance - simulated post-balance. Drives the net-SOL delta the
    # confirmation sheets show (simulateWithDelta).
    "sim_cost_lamports": 5000,
    "units_consumed": 5000,
    "slot": 300000000,
}


class MockState:
    """All mutable server state. Guarded by [lock]."""

    def __init__(self):
        self.lock = threading.RLock()
        self.scenarios = {}
        self.reset()

    def reset(self):
        self.scenario = DEFAULT_SCENARIO
        self.faults = []
        self.requests = []
        self.sent = {}
        self.values = dict(INITIAL_STATE)
        self.scenarios = load_scenarios()

    def next_slot(self):
        self.values["slot"] += 1
        return self.values["slot"]


# --- fixture loading ------------------------------------------------------


def load_scenarios():
    """Read every `fixtures/<scenario>/routes.json` off disk.

    Called at startup and again on every scenario switch, so an agent adding a
    fixture directory never needs to restart the server. A malformed or
    missing file raises - a silently skipped fixture is worse than a crash.
    """
    scenarios = {}
    if not os.path.isdir(FIXTURES_DIR):
        return scenarios
    for name in sorted(os.listdir(FIXTURES_DIR)):
        routes_path = os.path.join(FIXTURES_DIR, name, "routes.json")
        if not os.path.isfile(routes_path):
            continue
        with open(routes_path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
        routes = document.get("routes", [])
        for route in routes:
            body_file = route.get("bodyFile")
            if body_file:
                sibling = os.path.join(FIXTURES_DIR, name, body_file)
                with open(sibling, "r", encoding="utf-8") as handle:
                    route["body"] = json.load(handle)
        scenarios[name] = routes
    return scenarios


STATE = MockState()


def match_route(routes, method, path, rpc):
    """Index + route of the first entry matching this request, else (None, None).

    A JSON-RPC request only ever matches a route that declares `rpc`; a plain
    HTTP request only ever matches one that does not. That keeps a broad path
    regex (e.g. the default scenario's `^/?$`) from swallowing every RPC verb.
    """
    for index, route in enumerate(routes):
        if route.get("method") and route["method"] != method:
            continue
        route_rpc = route.get("rpc")
        if rpc is None:
            if route_rpc:
                continue
        else:
            if route_rpc != rpc:
                continue
        pattern = route.get("path")
        if pattern and not re.search(pattern, path):
            continue
        return index, route
    return None, None


# --- fault injection ------------------------------------------------------


def match_fault(method, path, rpc):
    """First fault rule matching this request; decrements its `times` budget."""
    for fault in list(STATE.faults):
        if fault.get("method") and fault["method"] != method:
            continue
        if fault.get("rpc"):
            if isinstance(rpc, list):
                if fault["rpc"] not in rpc:
                    continue
            elif fault["rpc"] != rpc:
                continue
        pattern = fault.get("path")
        if pattern and not re.search(pattern, path):
            continue
        times = fault.get("times")
        if times is not None:
            fault["times"] = times - 1
            if fault["times"] <= 0:
                STATE.faults.remove(fault)
        return fault
    return None


# --- built-in JSON-RPC verbs ----------------------------------------------


def _context():
    return {"apiVersion": "2.1.0", "slot": STATE.values["slot"]}


def _param(params, index, default=None):
    if isinstance(params, list) and len(params) > index:
        return params[index]
    return default


def _sim_account():
    values = STATE.values
    return {
        "lamports": values["balance_lamports"] - values["sim_cost_lamports"],
        "owner": SYSTEM_PROGRAM_ID,
        "data": ["", "base64"],
        "executable": False,
        "rentEpoch": 0,
    }


def _rpc_get_latest_blockhash(params):
    return {
        "context": _context(),
        "value": {
            "blockhash": STATE.values["blockhash"],
            "lastValidBlockHeight": STATE.values["slot"] + 150,
        },
    }


def _rpc_is_blockhash_valid(params):
    return {"context": _context(), "value": bool(STATE.values["blockhash_valid"])}


def _rpc_get_account_info(params):
    return {"context": _context(), "value": None}


def _rpc_get_multiple_accounts(params):
    addresses = _param(params, 0, [])
    count = len(addresses) if isinstance(addresses, list) else 0
    return {"context": _context(), "value": [None] * count}


def _rpc_get_balance(params):
    return {"context": _context(), "value": STATE.values["balance_lamports"]}


def _rpc_get_token_accounts_by_owner(params):
    return {"context": _context(), "value": []}


def _rpc_simulate_transaction(params):
    config = _param(params, 1, {}) or {}
    addresses = (config.get("accounts") or {}).get("addresses")
    accounts = None
    if isinstance(addresses, list):
        accounts = [_sim_account() for _ in addresses]
    error = STATE.values["sim_error"]
    return {
        "context": _context(),
        "value": {
            "err": error,
            "logs": [
                "Program %s invoke [1]" % SYSTEM_PROGRAM_ID,
                "Program %s success" % SYSTEM_PROGRAM_ID,
            ],
            "accounts": accounts,
            "unitsConsumed": STATE.values["units_consumed"],
            "returnData": None,
        },
    }


def _rpc_send_transaction(params):
    encoded = _param(params, 0, "")
    signature = signature_for(encoded if isinstance(encoded, str) else "")
    record = STATE.sent.setdefault(
        signature, {"polls": 0, "slot": STATE.next_slot(), "tx": encoded}
    )
    record.setdefault("polls", 0)
    return signature


def _rpc_get_signature_statuses(params):
    signatures = _param(params, 0, [])
    if not isinstance(signatures, list):
        signatures = []
    values = []
    for signature in signatures:
        record = STATE.sent.get(signature)
        if record is None:
            values.append(None)
            continue
        record["polls"] += 1
        polls = record["polls"]
        threshold = STATE.values["confirm_after_polls"]
        if polls < threshold:
            values.append(None)
            continue
        error = STATE.values["tx_error"]
        status = "confirmed" if polls == threshold else "finalized"
        values.append(
            {
                "slot": record["slot"],
                "confirmations": 0 if status == "confirmed" else None,
                "err": error,
                "confirmationStatus": status,
            }
        )
    return {"context": _context(), "value": values}


def _rpc_get_transaction(params):
    signature = _param(params, 0)
    record = STATE.sent.get(signature)
    if record is None:
        return None
    values = STATE.values
    pre = values["balance_lamports"]
    post = pre - values["sim_cost_lamports"]
    return {
        "slot": record["slot"],
        "blockTime": 1750000000,
        "version": 0,
        "meta": {
            "err": values["tx_error"],
            "fee": values["sim_cost_lamports"],
            "preBalances": [pre],
            "postBalances": [post],
            "preTokenBalances": [],
            "postTokenBalances": [],
            "innerInstructions": [],
            "logMessages": [],
            "rewards": [],
            "loadedAddresses": {"readonly": [], "writable": []},
        },
        "transaction": {
            "signatures": [signature],
            "message": {
                "accountKeys": [
                    {
                        "pubkey": values["fee_payer"],
                        "signer": True,
                        "writable": True,
                        "source": "transaction",
                    }
                ],
                "instructions": [],
                "recentBlockhash": values["blockhash"],
            },
        },
    }


def _rpc_get_minimum_balance_for_rent_exemption(params):
    size = _param(params, 0, 0)
    size = size if isinstance(size, int) else 0
    # The real rent-exempt minimum: (128 + dataSize) * 6960 lamports.
    return (128 + size) * 6960


def _rpc_get_fee_for_message(params):
    return {"context": _context(), "value": 5000}


def _rpc_get_epoch_info(params):
    slot = STATE.values["slot"]
    return {
        "absoluteSlot": slot,
        "blockHeight": slot - 1000,
        "epoch": slot // 432000,
        "slotIndex": slot % 432000,
        "slotsInEpoch": 432000,
        "transactionCount": 123456789,
    }


def _rpc_get_slot(params):
    return STATE.values["slot"]


def _rpc_get_health(params):
    return "ok"


def _rpc_get_recent_prioritization_fees(params):
    slot = STATE.values["slot"]
    return [
        {"slot": slot - 2, "prioritizationFee": 0},
        {"slot": slot - 1, "prioritizationFee": 1000},
        {"slot": slot, "prioritizationFee": 5000},
    ]


def _rpc_get_signatures_for_address(params):
    entries = []
    for signature, record in STATE.sent.items():
        entries.append(
            {
                "signature": signature,
                "slot": record["slot"],
                "err": STATE.values["tx_error"],
                "memo": None,
                "blockTime": 1750000000,
                "confirmationStatus": "finalized",
            }
        )
    entries.sort(key=lambda entry: entry["slot"], reverse=True)
    return entries


def _rpc_get_priority_fee_estimate(params):
    # Helius extension. The app calls it on every non-devnet RPC URL, and the
    # sandbox URL has no `devnet` in it, so the mock must answer.
    return {"priorityFeeEstimate": 10000}


RPC_BUILTINS = {
    "getLatestBlockhash": _rpc_get_latest_blockhash,
    "isBlockhashValid": _rpc_is_blockhash_valid,
    "getAccountInfo": _rpc_get_account_info,
    "getMultipleAccounts": _rpc_get_multiple_accounts,
    "getBalance": _rpc_get_balance,
    "getTokenAccountsByOwner": _rpc_get_token_accounts_by_owner,
    "simulateTransaction": _rpc_simulate_transaction,
    "sendTransaction": _rpc_send_transaction,
    "getSignatureStatuses": _rpc_get_signature_statuses,
    "getTransaction": _rpc_get_transaction,
    "getMinimumBalanceForRentExemption": _rpc_get_minimum_balance_for_rent_exemption,
    "getFeeForMessage": _rpc_get_fee_for_message,
    "getEpochInfo": _rpc_get_epoch_info,
    "getSlot": _rpc_get_slot,
    "getHealth": _rpc_get_health,
    "getRecentPrioritizationFees": _rpc_get_recent_prioritization_fees,
    "getSignaturesForAddress": _rpc_get_signatures_for_address,
    "getPriorityFeeEstimate": _rpc_get_priority_fee_estimate,
}


# --- built-in REST handlers -----------------------------------------------


def builtin_rest(method, path):
    """Non-RPC built-ins. Returns (body, tag) or (None, None)."""
    if method == "POST" and re.search(r"^/v2/tx/", path):
        values = STATE.values
        tx = build_unsigned_tx(
            values["fee_payer"],
            values["tx_version"],
            bool(values["tx_presigned"]),
            values["blockhash"],
        )
        return {"result": {"tx": tx}}, "builtin:v2tx"
    return None, None


# --- request parsing ------------------------------------------------------


def parse_rpc(raw):
    """(parsed_body, rpc) where rpc is a str, a list of str (batch), or None."""
    if not raw:
        return None, None
    try:
        body = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None, None
    if isinstance(body, list) and body:
        methods = [
            entry.get("method")
            for entry in body
            if isinstance(entry, dict) and entry.get("method")
        ]
        if len(methods) == len(body):
            return body, methods
        return body, None
    if isinstance(body, dict) and body.get("method") and "jsonrpc" in body:
        return body, body["method"]
    return body, None


def lookup(method, path, rpc):
    """Scenario-then-default route lookup. Returns (route, tag) or (None, None)."""
    index, route = match_route(STATE.scenarios.get(STATE.scenario, []), method, path, rpc)
    if route is not None:
        return route, "scenario:%s#%d" % (STATE.scenario, index)
    if STATE.scenario != DEFAULT_SCENARIO:
        index, route = match_route(
            STATE.scenarios.get(DEFAULT_SCENARIO, []), method, path, rpc
        )
        if route is not None:
            return route, "fallback:%s#%d" % (DEFAULT_SCENARIO, index)
    return None, None


def rpc_envelope(entry, path):
    """Answer one JSON-RPC call. Returns (envelope, tag)."""
    method = entry.get("method")
    params = entry.get("params")
    identifier = entry.get("id", 1)

    route, tag = lookup("POST", path, method)
    if route is not None:
        if "error" in route:
            return {"jsonrpc": "2.0", "id": identifier, "error": route["error"]}, tag
        return {"jsonrpc": "2.0", "id": identifier, "result": route.get("body")}, tag

    handler = RPC_BUILTINS.get(method)
    if handler is not None:
        return (
            {"jsonrpc": "2.0", "id": identifier, "result": handler(params)},
            "builtin:%s" % method,
        )
    return {"jsonrpc": "2.0", "id": identifier, "result": None}, "DEFAULT"


def resolve(method, path, raw):
    """(status, body, tag, delay_ms, refuse, rpc) for one request.

    A fault that names neither `status` nor `body` is a DELAY/REFUSE-ONLY
    fault: the request still gets its normal answer, just late (or not at
    all). That is what a "slow network" case wants, and making it the default
    is deliberate - a `delay_ms` fault that also silently returned 500 turned
    every loading-state case into an error-state case.
    """
    body, rpc = parse_rpc(raw)
    # The recorded `rpc` is always a string or null - a batch is joined with
    # commas, never emitted as a list, because the Dart-side client reads it as
    # `json['rpc'] as String?` and a list would throw at the cast.
    STATE.requests.append(
        {
            "method": method,
            "path": path,
            "rpc": ",".join(rpc) if isinstance(rpc, list) else rpc,
            "body": body,
        }
    )

    delay_ms = 0
    refuse = False
    prefix = ""
    fault = match_fault(method, path, rpc)
    if fault is not None:
        delay_ms = fault.get("delay_ms", 0)
        refuse = bool(fault.get("refuse"))
        status = fault.get("status")
        payload = fault.get("body")
        if status is not None or payload is not None or refuse:
            if status is None:
                status = 200 if payload is not None else 500
            if payload is None:
                payload = {"error": "injected fault", "status": status}
            return status, payload, "fault", delay_ms, refuse, rpc
        # Delay-only: fall through to the normal answer, served late.
        prefix = "fault:delay+"

    if rpc is not None:
        STATE.next_slot()
        if isinstance(rpc, list):
            envelopes = []
            tags = []
            for entry in body:
                envelope, tag = rpc_envelope(entry, path)
                envelopes.append(envelope)
                tags.append(tag)
            tag = "%sbatch[%s]" % (prefix, ",".join(tags))
            return 200, envelopes, tag, delay_ms, refuse, rpc
        envelope, tag = rpc_envelope(body, path)
        return 200, envelope, prefix + tag, delay_ms, refuse, rpc

    route, tag = lookup(method, path, None)
    if route is not None:
        status = route.get("status", 200)
        return status, route.get("body"), prefix + tag, delay_ms, refuse, rpc

    rest_body, rest_tag = builtin_rest(method, path)
    if rest_tag is not None:
        return 200, rest_body, prefix + rest_tag, delay_ms, refuse, rpc

    return 200, DEFAULTS.get(method, {}), prefix + "DEFAULT", delay_ms, refuse, rpc


# --- control surface (mock-only; see the module docstring) ----------------


def control(method, path, raw):
    """(status, body) for a /__test__/* request, or (None, None)."""
    try:
        payload = json.loads(raw.decode("utf-8")) if raw else {}
    except (ValueError, UnicodeDecodeError):
        return 400, {"ok": False, "error": "body is not JSON"}
    if not isinstance(payload, dict):
        return 400, {"ok": False, "error": "body must be a JSON object"}

    if path == "/__test__/reset" and method == "POST":
        # `{"scenario": name}` resets AND selects in one round trip. Doing it
        # in two leaves a window where the mock is back on `default` while the
        # previous case's app is still making requests.
        name = payload.get("scenario")
        STATE.reset()
        if name is not None:
            if name not in STATE.scenarios:
                return 400, {"ok": False, "error": "unknown scenario: %s" % name}
            STATE.scenario = name
        return 200, {"ok": True, "name": STATE.scenario}

    if path == "/__test__/scenario" and method == "POST":
        name = payload.get("name")
        STATE.scenarios = load_scenarios()
        if name not in STATE.scenarios:
            return 400, {"ok": False, "error": "unknown scenario: %s" % name}
        STATE.scenario = name
        return 200, {"ok": True, "name": name}

    if path == "/__test__/fault" and method == "POST":
        STATE.faults.append(dict(payload))
        return 200, {"ok": True, "count": len(STATE.faults)}

    if path == "/__test__/faults/clear" and method == "POST":
        STATE.faults = []
        return 200, {"ok": True}

    if path == "/__test__/requests" and method == "GET":
        return 200, list(STATE.requests)

    if path == "/__test__/state" and method == "POST":
        # A typo'd key (`blockhashValid`, `tx_eror`) would otherwise merge
        # silently while the real tunable keeps its default - which turns a
        # failure-path case into a green happy-path pass, or eats a 90 s
        # confirmation timeout. Reject the whole payload; never apply part.
        unknown = sorted(key for key in payload if key not in INITIAL_STATE)
        if unknown:
            return 400, {
                "ok": False,
                "error": "unknown state key(s): %s; valid keys: %s"
                % (", ".join(unknown), ", ".join(sorted(INITIAL_STATE))),
            }
        STATE.values.update(payload)
        return 200, {"ok": True, "state": dict(STATE.values)}

    return 404, {"ok": False, "error": "unknown control endpoint: %s %s" % (method, path)}


# --- server ---------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path

        if path.startswith("/__test__"):
            with STATE.lock:
                status, payload = control(self.command, path, raw)
            self._write(status, payload)
            _log(self.command, path, None, status, "control")
            return

        with STATE.lock:
            status, payload, tag, delay_ms, refuse, rpc = resolve(
                self.command, path, raw
            )

        if delay_ms:
            time.sleep(delay_ms / 1000.0)
        if refuse:
            self.close_connection = True
            _log(self.command, path, rpc, "refused", tag)
            return

        self._write(status, payload)
        _log(self.command, path, rpc, status, tag)

    def _write(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = _handle
    do_POST = _handle
    do_PATCH = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_HEAD = _handle

    # Silence the default noisy stderr logging (we log our own line).
    def log_message(self, *args):
        pass


def _log(method, path, rpc, status, tag):
    if isinstance(rpc, list):
        rpc = ",".join(rpc)
    sys.stderr.write(
        "[mock] %s %s rpc=%s -> %s (%s)\n" % (method, path, rpc or "-", status, tag)
    )
    sys.stderr.flush()


def make_server(port=PORT):
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


def main():
    STATE.reset()
    server = make_server()
    sys.stderr.write(
        "[mock] listening on 0.0.0.0:%d, scenarios: %s\n"
        % (PORT, ", ".join(sorted(STATE.scenarios)) or "(none)")
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
