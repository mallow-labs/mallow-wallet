// Client for the mock backend's `/__test__` control surface.
//
// The driver test runs ON THE DEVICE, in the same process as the app, and the
// app already reaches the mock at `http://10.0.2.2:8091`. So a scenario is
// selected from inside the test over plain HTTP, and CI needs no new
// `--dart-define` — the define list lives in `test/e2e/dart_defines.sh`, which
// `test/e2e/lib.sh` and the CI e2e pipeline both source, and this client adds
// nothing to it.
//
// The base URL is DERIVED from the existing `API_BASE_URL` define
// (`Config.apiBaseUrl`) rather than hardcoded, so a run on a different port,
// or a future move off 10.0.2.2, needs no change here.
//
// Every call throws [MockControlException] on a non-2xx reply. That is
// deliberate: an unknown scenario name answered with a silent fallthrough to
// the default fixtures is the false-confidence failure mode this whole suite
// exists to avoid — the test would pass while asserting nothing.
//
// The control surface lives ONLY in `test/e2e/mock_backend.py`. Nothing in
// `lib/` knows it exists.

import 'dart:convert';
import 'dart:io';

import 'package:mallow_wallet/core/config/environment.dart';

/// Thrown when the mock's control surface rejects a call or is unreachable.
class MockControlException implements Exception {
  MockControlException(this.message);
  final String message;
  @override
  String toString() => 'MockControlException: $message';
}

/// One entry of the mock's request log, as returned by [MockControl.requests].
class MockRequest {
  const MockRequest({
    required this.method,
    required this.path,
    this.rpc,
    this.body,
  });

  factory MockRequest.fromJson(Map<String, dynamic> json) => MockRequest(
    method: json['method'] as String? ?? '',
    path: json['path'] as String? ?? '',
    rpc: json['rpc'] as String?,
    body: json['body'],
  );

  /// HTTP verb, e.g. `POST`.
  final String method;

  /// Request path, e.g. `/v2/tx/list`.
  final String path;

  /// JSON-RPC `method` field when the request was a Solana RPC POST, else
  /// null. Every Solana verb posts to the same proxy root, so `path` alone
  /// cannot tell `getLatestBlockhash` from `sendTransaction`.
  final String? rpc;

  /// Decoded JSON request body, or null when there was none / it was not JSON.
  final dynamic body;

  @override
  String toString() =>
      'MockRequest($method $path${rpc == null ? '' : ' rpc=$rpc'})';
}

/// Static client for the mock backend's control surface.
///
/// Typical use inside a flow file:
///
/// ```dart
/// setUp(() async {
///   await MockControl.reset();               // default scenario, no faults
/// });
///
/// testWidgets('offers inbox renders', (tester) async {
///   await MockControl.scenario('offers_inbox');
///   await restartApp(tester);
///   ...
/// });
/// ```
class MockControl {
  MockControl._();

  /// `http://10.0.2.2:8091` under the E2E defines. Trailing slashes trimmed so
  /// `$base/__test__/...` never doubles up.
  static String get baseUrl {
    var url = Config.apiBaseUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Resets the mock to a clean slate: all faults cleared, request log
  /// emptied, transaction state forgotten, and the scenario set to [scenario]
  /// (`default` when omitted).
  ///
  /// Call this in `setUp`, not just once per file — a fault left armed by a
  /// failing case is the classic cross-case contaminant.
  ///
  /// PASS [scenario] RATHER THAN CALLING [MockControl.scenario] AFTERWARDS.
  /// A bare reset puts the mock back on `default` for as long as the second
  /// round trip takes, and the previous case's app is still running: any
  /// request it lands in that window is answered from the WRONG fixture set,
  /// which shows up later as a screen that rendered from data no test chose.
  /// One call closes the window.
  static Future<void> reset({String? scenario}) => _post(
    '/__test__/reset',
    scenario == null ? null : {'scenario': scenario},
  );

  /// Selects the named fixture set.
  ///
  /// Throws [MockControlException] when the mock does not know [name] (it
  /// answers HTTP 400). Never swallow that: a typo silently serving default
  /// fixtures produces a green test that asserts nothing.
  ///
  /// Prefer `reset(scenario: name)` when you are doing both.
  static Future<void> scenario(String name) async {
    await _post('/__test__/scenario', {'name': name});
  }

  /// Arms a fault for requests matching [path] (a regex, matched against the
  /// request path).
  ///
  /// * [method] — restrict to one HTTP verb, e.g. `'POST'`. Null matches any.
  /// * [rpc] — restrict to one JSON-RPC method, e.g. `'sendTransaction'`.
  ///   Null matches any.
  /// * [status] — HTTP status to answer with. **Null (the default) means "do
  ///   not break it": the request is answered normally, from the fixture or
  ///   built-in that would have served it.** State a status explicitly to
  ///   fail a request.
  /// * [delayMs] — sleep before answering; models a slow network. Combined
  ///   with the null [status] default this is a pure "slow, but working"
  ///   fault, which is what a loading-state case actually needs. (This
  ///   parameter used to inherit a `status: 500` default, so every "slow"
  ///   case was silently also a "broken" case.)
  /// * [refuse] — drop the connection instead of answering; models RPC down.
  /// * [times] — fire for the first N matches only, then behave normally.
  ///   Null means "until cleared", which is what you want for a hard outage
  ///   and NOT what you want for a retry test.
  /// * [body] — JSON body to answer with instead of the fixture. Served with
  ///   HTTP 200 when no [status] is given, so `fault(path: ..., body: ...)`
  ///   is also the way to serve a one-off *successful* body.
  static Future<void> fault({
    required String path,
    String? method,
    String? rpc,
    int? status,
    int delayMs = 0,
    bool refuse = false,
    int? times,
    Object? body,
  }) async {
    await _post('/__test__/fault', {
      'path': path,
      'method': method,
      'rpc': rpc,
      'status': status,
      'delay_ms': delayMs,
      'refuse': refuse,
      'times': times,
      'body': body,
    });
  }

  /// Disarms every fault. Leaves the scenario and the request log alone.
  static Future<void> clearFaults() => _post('/__test__/faults/clear', null);

  /// Everything the app has asked the mock for since the last [reset], oldest
  /// first.
  ///
  /// This is the assertion of record for "did the app actually broadcast
  /// something" — a screen showing a success state proves the UI, the request
  /// log proves the wire.
  ///
  /// 🛑 An entry records a request's ARRIVAL, not its completion. The mock
  /// appends to the log before it applies faults, delays or `refuse`, so a
  /// count of 1 proves the app sent the request and proves nothing about
  /// whether it got an answer. "It finished" needs a second signal — the
  /// screen that the answer drives, or a fixed wait past the fault's delay.
  static Future<List<MockRequest>> requests() async {
    final decoded = await _get('/__test__/requests');
    if (decoded is! List) {
      throw MockControlException(
        'GET /__test__/requests returned ${decoded.runtimeType}, expected a list',
      );
    }
    return decoded
        .cast<Map<String, dynamic>>()
        .map(MockRequest.fromJson)
        .toList();
  }

  /// Merges [values] into the mock's tunable state.
  ///
  /// The key set is CLOSED and validated server-side: it is exactly the mock's
  /// `INITIAL_STATE`, listed below, and an unknown key answers HTTP 400 with
  /// NOTHING applied (so this call throws [MockControlException] and no
  /// partial merge lands). That is deliberate — a typo'd key merging silently
  /// while the real tunable kept its default would turn a failure-path case
  /// into a green happy-path pass.
  ///
  /// Every key is optional; each keeps its default until set.
  /// * `fee_payer` (String) — fee payer baked into generated `/v2/tx/*`
  ///   fixtures; set it to the deterministic test wallet's Solana address.
  /// * `tx_version` (String) — `legacy` or `v0`, the version of those
  ///   generated transactions.
  /// * `tx_presigned` (bool) — whether they arrive carrying a signature.
  /// * `blockhash` (String) — what `getLatestBlockhash` answers.
  /// * `blockhash_valid` (bool) — what `isBlockhashValid` answers. Setting it
  ///   false is what makes an expired-blockhash case finish in seconds instead
  ///   of eating the client's full 90 s `maxWait`.
  /// * `confirm_after_polls` (int) — how many `getSignatureStatuses` polls to
  ///   answer "not confirmed" before confirming.
  /// * `tx_error` (Map|null) — a JSON-RPC transaction error OBJECT, not a
  ///   string, e.g. `{'InstructionError': [1, 'Custom']}`. Non-null puts it in
  ///   the confirmation status and in `getTransaction`.
  /// * `sim_error` (Map|null) — same shape, returned from
  ///   `simulateTransaction`.
  /// * `balance_lamports` (int) — what `getBalance` answers.
  /// * `sim_cost_lamports` (int) — the simulated cost, which drives the
  ///   net-SOL delta the confirmation sheets show.
  /// * `units_consumed` (int) — `unitsConsumed` in the simulation result.
  /// * `slot` (int) — the current slot; RPC verbs advance it from here.
  static Future<void> state(Map<String, Object?> values) =>
      _post('/__test__/state', values);

  // -------------------------------------------------------------------------

  static Future<dynamic> _post(String path, Object? body) =>
      _send('POST', path, body);

  static Future<dynamic> _get(String path) => _send('GET', path, null);

  static Future<dynamic> _send(String method, String path, Object? body) async {
    final uri = Uri.parse('$baseUrl$path');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, uri);
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = encoded.length;
        request.add(encoded);
      } else {
        request.headers.contentLength = 0;
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MockControlException(
          '$method $uri -> HTTP ${response.statusCode}: $text',
        );
      }
      if (text.isEmpty) return null;
      return jsonDecode(text);
    } on SocketException catch (e) {
      throw MockControlException(
        '$method $uri failed: $e. Is test/e2e/mock_backend.py running, and '
        'does it expose the /__test__ control surface?',
      );
    } finally {
      client.close(force: true);
    }
  }
}
