#!/usr/bin/env python3
"""Self-test for the E2E mock backend and the tx fixture builder.

Stdlib only. Run from the repo root:

    python3 -m unittest discover -s test/e2e -p 'test_*.py' -v

These tests guard the contract the Dart-side E2E helpers depend on. They boot a
real server on an ephemeral port and talk to it over HTTP, so a regression in
routing, faults, or RPC coherence fails here rather than as a mystery timeout
on the emulator.
"""

import base64
import json
import os
import shutil
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import mock_backend  # noqa: E402
import txfixture  # noqa: E402

SCENARIO_DIR = os.path.join(mock_backend.FIXTURES_DIR, "selftest_scenario")


def _write_scenario():
    os.makedirs(SCENARIO_DIR, exist_ok=True)
    with open(os.path.join(SCENARIO_DIR, "portfolio.json"), "w", encoding="utf-8") as f:
        json.dump({"groups": ["from-file"], "tokens": [], "nfts": []}, f)
    with open(os.path.join(SCENARIO_DIR, "routes.json"), "w", encoding="utf-8") as f:
        json.dump(
            {
                "routes": [
                    {"method": "POST", "path": "/v2/.*portfolio", "bodyFile": "portfolio.json"},
                    {"method": "POST", "rpc": "getBalance",
                     "body": {"context": {"slot": 1}, "value": 777}},
                    {"method": "GET", "path": "/v2/gone", "status": 404, "body": {"e": 1}},
                ]
            },
            f,
        )


class MockBackendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _write_scenario()
        mock_backend.STATE.reset()
        cls.server = mock_backend.make_server(port=0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(SCENARIO_DIR, ignore_errors=True)

    def setUp(self):
        self.post("/__test__/reset", {})

    # --- helpers ---------------------------------------------------------

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def request(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.url(path), data=data, method=method)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, json.loads(response.read().decode())
        except urllib.error.HTTPError as err:
            with err:
                return err.code, json.loads(err.read().decode())

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, payload):
        return self.request("POST", path, payload)

    def rpc(self, method, params=None, identifier=1):
        status, body = self.post(
            "/",
            {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params},
        )
        self.assertEqual(200, status)
        return body

    # --- default routes stay byte-compatible -----------------------------

    def test_default_routes_serve_the_wire_shapes(self):
        # Each of these is bound to a type - see the `_note` on the route in
        # fixtures/default/routes.json. An "empty" body of the wrong shape is
        # worse than no fixture: the screen renders its ERROR view and a
        # careless test reads that as empty.
        self.assertEqual(
            (200, {"result": {"user": {}}}), self.post("/v0/login", {})
        )
        self.assertEqual((200, {"result": []}), self.get("/v2/evm/balances"))
        self.assertEqual(
            (200, {"result": [], "total": 0}),
            self.post("/v2/portfolio/artworks", {}),
        )
        self.assertEqual(
            (200, {"result": {"groups": [], "total": 0}}),
            self.post("/v2/portfolio/groups", {}),
        )
        self.assertEqual(
            (
                200,
                {
                    "result": [],
                    "pagination": {"page": 0, "limit": 50, "hasMore": False},
                },
            ),
            self.get("/v2/activity?addresses=x"),
        )
        self.assertEqual(
            (200, {"result": {"users": [], "unlinkedAddresses": []}}),
            self.post("/v1/user/bulk", {}),
        )
        self.assertEqual(
            (200, {"result": {"unreadCount": 0, "hasUnreadMessages": False}}),
            self.get("/v1/notifications/unread-count"),
        )
        self.assertEqual((200, {"result": []}), self.get("/v1/curations"))
        self.assertEqual((200, {"result": {}}), self.get("/v0/getTokenPrices"))
        self.assertEqual(
            (200, {"result": {"updateRequired": False, "disabledFlows": []}}),
            self.get("/v2/config/mobile"),
        )

    def test_searchAssets_answers_an_empty_portfolio_not_a_null_result(self):
        # Not a built-in verb: without the default route it answers
        # `result: null`, which TokenRepository degrades to zero tokens
        # WITHOUT erroring - a silent false-empty.
        body = self.rpc("searchAssets", [{"ownerAddress": "x"}])
        self.assertEqual(0, body["result"]["total"])
        self.assertEqual([], body["result"]["items"])

    def test_home_feed_is_deliberately_unfixtured(self):
        # A correct `{"result": {}}` makes HomeBloc cache the feed from a
        # handler that outlives the test, and drift throws when restartApp
        # closes the connection under the insert. See the `_comment` block in
        # fixtures/default/routes.json.
        self.assertEqual((200, []), self.get("/home"))

    def test_unmatched_paths_fall_through_to_method_defaults(self):
        self.assertEqual((200, []), self.get("/v2/anything"))
        self.assertEqual((200, {}), self.post("/v2/anything", {"a": 1}))

    # --- scenarios -------------------------------------------------------

    def test_scenario_switch_overrides_only_its_own_routes(self):
        status, body = self.post("/__test__/scenario", {"name": "selftest_scenario"})
        self.assertEqual((200, {"ok": True, "name": "selftest_scenario"}), (status, body))
        # bodyFile is loaded from the sibling file.
        self.assertEqual(
            (200, {"groups": ["from-file"], "tokens": [], "nfts": []}),
            self.post("/v2/wallet/portfolio", {}),
        )
        # Untouched routes still fall back to the default scenario.
        self.assertEqual((200, {"result": {"user": {}}}), self.post("/v0/login", {}))
        # rpc-keyed route wins over the built-in verb.
        self.assertEqual(777, self.rpc("getBalance", ["addr"])["result"]["value"])
        # Route-level status override.
        self.assertEqual(404, self.get("/v2/gone")[0])

    def test_reset_can_select_a_scenario_in_the_same_round_trip(self):
        # Two calls leave a window in which the mock is back on `default`
        # while the previous case's app is still making requests, and those
        # get answered from the wrong fixture set.
        status, body = self.post(
            "/__test__/reset", {"scenario": "selftest_scenario"}
        )
        self.assertEqual((200, {"ok": True, "name": "selftest_scenario"}), (status, body))
        self.assertEqual(777, self.rpc("getBalance", ["addr"])["result"]["value"])

    def test_reset_with_an_unknown_scenario_fails_loud(self):
        status, body = self.post("/__test__/reset", {"scenario": "nope"})
        self.assertEqual(400, status)
        self.assertIn("unknown scenario: nope", body["error"])

    def test_unknown_scenario_fails_loud(self):
        status, body = self.post("/__test__/scenario", {"name": "nope"})
        self.assertEqual(400, status)
        self.assertFalse(body["ok"])
        self.assertIn("unknown scenario: nope", body["error"])
        # And the previous scenario is untouched.
        self.assertEqual((200, {"result": {"user": {}}}), self.post("/v0/login", {}))

    def test_scenarios_are_rediscovered_without_a_restart(self):
        late = os.path.join(mock_backend.FIXTURES_DIR, "selftest_late")
        os.makedirs(late, exist_ok=True)
        try:
            with open(os.path.join(late, "routes.json"), "w", encoding="utf-8") as f:
                json.dump({"routes": [{"method": "GET", "path": "/late", "body": {"ok": 1}}]}, f)
            self.assertEqual(
                200, self.post("/__test__/scenario", {"name": "selftest_late"})[0]
            )
            self.assertEqual((200, {"ok": 1}), self.get("/late"))
        finally:
            shutil.rmtree(late, ignore_errors=True)

    # --- faults ----------------------------------------------------------

    def test_fault_applies_status_and_times_budget(self):
        self.post(
            "/__test__/fault",
            {"path": "/v2/config/mobile", "method": "GET", "status": 503, "times": 2},
        )
        self.assertEqual(503, self.get("/v2/config/mobile")[0])
        self.assertEqual(503, self.get("/v2/config/mobile")[0])
        self.assertEqual(200, self.get("/v2/config/mobile")[0])

    def test_fault_applies_delay_and_custom_body(self):
        self.post(
            "/__test__/fault",
            {"path": "/v2/slow", "delay_ms": 250, "status": 500, "body": {"boom": True}},
        )
        started = time.monotonic()
        status, body = self.get("/v2/slow")
        self.assertGreaterEqual(time.monotonic() - started, 0.2)
        self.assertEqual((500, {"boom": True}), (status, body))

    def test_fault_without_a_status_is_slow_but_not_broken(self):
        # The whole point of the nullable status: `delay_ms` on its own must
        # model a slow network, not a slow 500. A fault that answered 500 by
        # default turned every loading-state case into an error-state case.
        self.post(
            "/__test__/fault", {"path": "/v2/config/mobile", "delay_ms": 250}
        )
        started = time.monotonic()
        status, body = self.get("/v2/config/mobile")
        self.assertGreaterEqual(time.monotonic() - started, 0.2)
        self.assertEqual(200, status)
        self.assertEqual(
            {"result": {"updateRequired": False, "disabledFlows": []}}, body
        )

    def test_fault_with_a_body_but_no_status_serves_that_body_with_200(self):
        self.post("/__test__/fault", {"path": "/v2/config/mobile", "body": {"a": 1}})
        self.assertEqual((200, {"a": 1}), self.get("/v2/config/mobile"))

    def test_fault_can_target_an_rpc_method(self):
        self.post("/__test__/fault", {"rpc": "getHealth", "status": 502})
        req = urllib.request.Request(
            self.url("/"),
            data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "getHealth", "params": []}
            ).encode(),
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(req, timeout=10)
        caught.exception.close()
        # A different verb is untouched.
        self.assertEqual(502, caught.exception.code)
        self.assertGreater(self.rpc("getSlot")["result"], 300000000)

    def test_refuse_closes_the_connection(self):
        self.post("/__test__/fault", {"path": "/v2/dead", "refuse": True})
        with self.assertRaises(Exception):
            urllib.request.urlopen(self.url("/v2/dead"), timeout=10)

    def test_faults_clear(self):
        self.post("/__test__/fault", {"path": "/v2/config/mobile", "status": 503})
        self.assertEqual(503, self.get("/v2/config/mobile")[0])
        self.assertEqual((200, {"ok": True}), self.post("/__test__/faults/clear", {}))
        self.assertEqual(200, self.get("/v2/config/mobile")[0])

    # --- recorded requests ----------------------------------------------

    def test_requests_are_recorded_and_reset_clears_them(self):
        self.post("/v0/login", {"hello": "world"})
        self.rpc("getHealth")
        status, recorded = self.get("/__test__/requests")
        self.assertEqual(200, status)
        paths = [entry["path"] for entry in recorded]
        self.assertIn("/v0/login", paths)
        login = next(e for e in recorded if e["path"] == "/v0/login")
        self.assertEqual({"hello": "world"}, login["body"])
        self.assertIsNone(login["rpc"])
        self.assertIn("getHealth", [entry["rpc"] for entry in recorded])
        # Control endpoints are not recorded.
        self.assertNotIn("/__test__/requests", paths)
        self.post("/__test__/reset", {})
        self.assertEqual([], self.get("/__test__/requests")[1])

    # --- JSON-RPC dispatch ------------------------------------------------

    def test_rpc_dispatch_by_method_not_by_path(self):
        self.assertEqual("ok", self.rpc("getHealth")["result"])
        blockhash = self.rpc("getLatestBlockhash")["result"]["value"]["blockhash"]
        self.assertEqual(txfixture.DEFAULT_BLOCKHASH, blockhash)
        self.assertEqual(32, len(txfixture.b58decode(blockhash)))
        self.assertEqual(
            2000000000, self.rpc("getBalance", ["addr"])["result"]["value"]
        )
        self.assertEqual(
            [None, None],
            self.rpc("getMultipleAccounts", [["a", "b"]])["result"]["value"],
        )
        self.assertEqual(
            2039280,
            self.rpc("getMinimumBalanceForRentExemption", [165])["result"],
        )

    def test_rpc_batch_dispatch_echoes_ids(self):
        payload = [
            {"jsonrpc": "2.0", "id": "a", "method": "getHealth", "params": []},
            {"jsonrpc": "2.0", "id": "b", "method": "getSlot", "params": []},
        ]
        status, body = self.post("/", payload)
        self.assertEqual(200, status)
        self.assertEqual(["a", "b"], [entry["id"] for entry in body])
        self.assertEqual("ok", body[0]["result"])
        self.assertIsInstance(body[1]["result"], int)
        # A batch is recorded as a joined string, never a list: the Dart client
        # reads `json['rpc'] as String?`.
        recorded = self.get("/__test__/requests")[1]
        self.assertEqual("getHealth,getSlot", recorded[0]["rpc"])

    def test_unknown_rpc_verb_returns_a_null_result(self):
        self.assertIsNone(self.rpc("getNoSuchThing")["result"])

    def test_blockhash_validity_is_switchable(self):
        self.assertTrue(self.rpc("isBlockhashValid", ["x"])["result"]["value"])
        self.post("/__test__/state", {"blockhash_valid": False})
        self.assertFalse(self.rpc("isBlockhashValid", ["x"])["result"]["value"])

    # --- state tunables --------------------------------------------------

    def test_unknown_state_key_fails_loud(self):
        # A silently-merged typo leaves the real tunable at its default, so a
        # failure-path case quietly passes on the happy path instead.
        status, body = self.post("/__test__/state", {"blockhashValid": False})
        self.assertEqual(400, status)
        self.assertFalse(body["ok"])
        self.assertIn("blockhashValid", body["error"])
        # The correctly-spelled tunable is untouched.
        self.assertTrue(self.rpc("isBlockhashValid", ["x"])["result"]["value"])

    def test_a_mixed_state_payload_applies_nothing(self):
        status, body = self.post(
            "/__test__/state", {"confirm_after_polls": 3, "tx_eror": "boom"}
        )
        self.assertEqual(400, status)
        self.assertIn("tx_eror", body["error"])
        # The valid half of the rejected payload did NOT land: the tx still
        # confirms on the first poll.
        tx = txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER)
        signature = self.rpc("sendTransaction", [tx, {}])["result"]
        landed = self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
        self.assertEqual("confirmed", landed["confirmationStatus"])

    def test_known_state_keys_still_apply(self):
        status, body = self.post(
            "/__test__/state", {"blockhash_valid": False, "units_consumed": 1234}
        )
        self.assertEqual(200, status)
        self.assertTrue(body["ok"])
        self.assertFalse(body["state"]["blockhash_valid"])
        self.assertFalse(self.rpc("isBlockhashValid", ["x"])["result"]["value"])
        value = self.rpc("simulateTransaction", ["dGVzdA==", {}])["result"]["value"]
        self.assertEqual(1234, value["unitsConsumed"])

    def test_simulate_returns_units_and_a_coherent_accounts_array(self):
        params = [
            "dGVzdA==",
            {
                "encoding": "base64",
                "replaceRecentBlockhash": True,
                "accounts": {"encoding": "base64", "addresses": ["payer"]},
            },
        ]
        value = self.rpc("simulateTransaction", params)["result"]["value"]
        self.assertIsNone(value["err"])
        self.assertEqual(5000, value["unitsConsumed"])
        self.assertEqual(1, len(value["accounts"]))
        balance = self.rpc("getBalance", ["payer"])["result"]["value"]
        # post - pre must be a small, negative net SOL delta (a cost).
        self.assertEqual(-5000, value["accounts"][0]["lamports"] - balance)
        # Without an accounts request, the array is null - as the real RPC does.
        bare = self.rpc("simulateTransaction", ["dGVzdA==", {}])["result"]["value"]
        self.assertIsNone(bare["accounts"])

    # --- broadcast -> confirm -> read coherence --------------------------

    def test_send_status_and_transaction_are_coherent(self):
        tx = txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER)
        signature = self.rpc("sendTransaction", [tx, {}])["result"]
        # A real Solana signature is 64 bytes -> 87-88 base58 chars.
        self.assertIn(len(signature), (87, 88))
        self.assertEqual(64, len(txfixture.b58decode(signature)))
        # An unknown signature is "never seen".
        self.assertIsNone(
            self.rpc("getSignatureStatuses", [["nope"]])["result"]["value"][0]
        )
        self.assertIsNone(self.rpc("getTransaction", ["nope"])["result"])
        # The sent one confirms on the first poll, then finalizes.
        first = self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
        self.assertEqual("confirmed", first["confirmationStatus"])
        self.assertIsNone(first["err"])
        second = self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
        self.assertEqual("finalized", second["confirmationStatus"])
        details = self.rpc("getTransaction", [signature])["result"]
        self.assertIsNotNone(details)
        self.assertEqual(signature, details["transaction"]["signatures"][0])
        self.assertIsNone(details["meta"]["err"])
        # And the broadcast is visible in the recorded log.
        recorded = self.get("/__test__/requests")[1]
        self.assertIn("sendTransaction", [entry["rpc"] for entry in recorded])

    def test_confirm_after_polls_delays_the_landing(self):
        self.post("/__test__/state", {"confirm_after_polls": 3})
        tx = txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER)
        signature = self.rpc("sendTransaction", [tx, {}])["result"]
        for _ in range(2):
            self.assertIsNone(
                self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
            )
        landed = self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
        self.assertEqual("confirmed", landed["confirmationStatus"])

    def test_tx_error_surfaces_in_the_confirmation_status(self):
        self.post("/__test__/state", {"tx_error": {"InstructionError": [1, "Custom"]}})
        tx = txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER)
        signature = self.rpc("sendTransaction", [tx, {}])["result"]
        status = self.rpc("getSignatureStatuses", [[signature]])["result"]["value"][0]
        self.assertEqual({"InstructionError": [1, "Custom"]}, status["err"])

    # --- /v2/tx/* builder -------------------------------------------------

    def test_v2_tx_routes_are_generated_for_the_configured_fee_payer(self):
        payer = txfixture.b58encode(bytes([9]) * 32)
        self.post("/__test__/state", {"fee_payer": payer, "tx_presigned": True})
        status, body = self.post("/v2/tx/assets/burn", {"asset": "x"})
        self.assertEqual(200, status)
        raw = base64.b64decode(body["result"]["tx"])
        # 2 signature slots, and slot 1 carries the dummy server signature.
        self.assertEqual(2, raw[0])
        self.assertEqual(bytes(64), raw[1:65])
        self.assertNotEqual(bytes(64), raw[65:129])
        # accountKeys[0] is the fee payer.
        self.assertEqual(txfixture.b58decode(payer), raw[133:165])


class TxFixtureTest(unittest.TestCase):
    def test_base58_round_trips(self):
        for data in (bytes(32), bytes(range(32)), b"\x00\x00" + bytes([255]) * 30):
            self.assertEqual(data, txfixture.b58decode(txfixture.b58encode(data)))

    def test_legacy_unsigned_layout(self):
        payer = txfixture.b58encode(bytes([3]) * 32)
        raw = base64.b64decode(txfixture.build_unsigned_tx(payer))
        self.assertEqual(1, raw[0])  # one signature slot
        self.assertEqual(bytes(64), raw[1:65])  # all-zero placeholder
        message = raw[65:]
        self.assertEqual([1, 0, 1], list(message[0:3]))  # header
        self.assertEqual(2, message[3])  # two account keys
        self.assertEqual(txfixture.b58decode(payer), message[4:36])
        blockhash = message[68:100]
        self.assertEqual(txfixture.b58decode(txfixture.DEFAULT_BLOCKHASH), blockhash)
        self.assertEqual(1, message[100])  # one instruction
        self.assertEqual(1, message[101])  # programIdIndex -> the memo program
        self.assertEqual(0, message[102])  # no account indexes
        self.assertEqual(len(b"mallow-e2e"), message[103])
        self.assertEqual(len(message), 104 + len(b"mallow-e2e"))

    def test_v0_carries_the_version_prefix_and_an_empty_lookup_list(self):
        payer = txfixture.b58encode(bytes([3]) * 32)
        raw = base64.b64decode(txfixture.build_unsigned_tx(payer, "v0"))
        message = raw[65:]
        self.assertEqual(0x80, message[0])
        self.assertEqual(0, message[-1])  # zero address table lookups

    def test_presigned_variant_puts_the_dummy_in_a_non_wallet_slot(self):
        payer = txfixture.b58encode(bytes([3]) * 32)
        raw = base64.b64decode(txfixture.build_unsigned_tx(payer, "legacy", True))
        self.assertEqual(2, raw[0])
        self.assertEqual(bytes(64), raw[1:65])
        self.assertTrue(any(byte != 0 for byte in raw[65:129]))
        message = raw[129:]
        self.assertEqual([2, 1, 1], list(message[0:3]))
        self.assertEqual(3, message[3])
        self.assertEqual(txfixture.b58decode(payer), message[4:36])
        self.assertNotEqual(txfixture.b58decode(payer), message[36:68])

    def test_all_four_variants_build(self):
        variants = txfixture.build_tx_variants(txfixture.PLACEHOLDER_FEE_PAYER)
        self.assertEqual(
            {"legacy_unsigned", "legacy_presigned", "v0_unsigned", "v0_presigned"},
            set(variants),
        )
        for name, encoded in variants.items():
            decoded = base64.b64decode(encoded)
            self.assertGreater(len(decoded), 100, name)

    def test_bad_fee_payer_fails_loud(self):
        with self.assertRaises(ValueError):
            txfixture.build_unsigned_tx("tooshort")
        with self.assertRaises(ValueError):
            txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER, "v9")

    def test_signature_is_deterministic(self):
        tx = txfixture.build_unsigned_tx(txfixture.PLACEHOLDER_FEE_PAYER)
        self.assertEqual(txfixture.signature_for(tx), txfixture.signature_for(tx))
        self.assertEqual(64, len(txfixture.b58decode(txfixture.signature_for(tx))))


if __name__ == "__main__":
    unittest.main()
