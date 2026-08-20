import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/api_key_interceptor.dart';

/// Captures the outgoing request so the test can assert on the headers the
/// interceptor attached, without hitting the network.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// `MALLOW_API_KEY` is a credential a mallow deployment issues to one holder,
/// and the `Dio` it rides on is the app's ONE shared client: Jupiter's public
/// token search and the rewards CDN both read through the same
/// instance. An unguarded interceptor would hand the key to every one of them
/// on every request — a disclosure the key-holder cannot see and cannot undo
/// short of a revocation.
///
/// These tests assert the **wiring**, not the getter. `test/core/config/`
/// already pins `Config.apiKeyHeadersFor` at the set level; what this file adds
/// is that the interceptor actually consults it, and consults the narrow set.
void main() {
  late _CapturingAdapter adapter;
  late Dio dio;

  setUp(() {
    // Makes `api.test` the API host; every other host below is outside it.
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
    Config.debugOverrides['MALLOW_API_KEY'] = 'KEY123';

    adapter = _CapturingAdapter();
    dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(ApiKeyInterceptor());
  });

  tearDown(Config.debugOverrides.clear);

  String? sentKey() => adapter.lastRequest!.headers['x-api-key'] as String?;

  test('the API host receives the key', () async {
    await dio.get<dynamic>('https://api.test/v1/user/profile');

    expect(sentKey(), 'KEY123');
  });

  test('the derived v2 API host receives the key', () async {
    await dio.get<dynamic>('${Config.apiV2BaseUrl}/portfolio');

    expect(sentKey(), 'KEY123');
  });

  test('no x-api-key reaches a third-party host', () async {
    // Prove the interceptor is installed and sending, so the absence below
    // cannot pass because the key was simply never configured.
    await dio.get<dynamic>('https://api.test/v1/user/profile');
    expect(sentKey(), 'KEY123');

    await dio.get<dynamic>('https://api.jup.ag/tokens/v2/search?query=sol');
    expect(sentKey(), isNull);

    // Same origin suffix as the API, different host: the guard matches hosts,
    // not domains.
    await dio.get<dynamic>('https://cdn.example.com/store/merch.shirt.json');
    expect(sentKey(), isNull);
  });

  test('no x-api-key reaches a FIRST_PARTY_HOSTS proxy', () async {
    // 🛑 The gate is `Config.sessionHosts` (the derived API hosts), NOT
    // `Config.firstPartyHosts` (those plus whatever `FIRST_PARTY_HOSTS`
    // declares). The wider set is build configuration: a deployment lists its
    // RPC, gas and IPFS proxies there so they receive the client-id header,
    // which tells them only which build is calling. This key is spendable
    // against one backend, so gating it on a set that build config can widen
    // would mean a line in `.env` could hand a third-party proxy a working
    // credential.
    //
    // This asserts the wiring, not the getter: re-pointing the interceptor
    // (or `Config.apiKeyHeadersFor`) at `firstPartyHosts` leaves every other
    // test in this file and in `test/core/config/` green, and fails here.
    Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.test,pin.test';
    // Both platform values, so the precondition holds whichever one the test
    // host reads.
    Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
    Config.debugOverrides['CLIENT_ID_IOS'] = 'example.client';
    Config.debugOverrides['CLIENT_ID_ANDROID'] = 'example.client';

    // The proxy is first-party enough for the client-id header...
    expect(
      Config.clientIdHeadersFor(Uri.parse('https://rpc.test')),
      isNot(isEmpty),
      reason: 'precondition: the host must be inside the client-id gate',
    );

    // ...and still gets no key.
    await dio.get<dynamic>('https://rpc.test/');
    expect(sentKey(), isNull);

    await dio.get<dynamic>('https://pin.test/upload');
    expect(sentKey(), isNull);

    // The API host is unaffected — widening must not break the backend call.
    await dio.get<dynamic>('https://api.test/v1/user/profile');
    expect(sentKey(), 'KEY123');
  });

  test('an unconfigured build sends no header at all', () async {
    // The OSS default: no key, so no header — not an empty one, which is a
    // different request on the wire and which a gateway may reject as
    // malformed rather than treat as an anonymous caller.
    Config.debugOverrides.remove('MALLOW_API_KEY');

    await dio.get<dynamic>('https://api.test/v1/user/profile');

    expect(adapter.lastRequest!.headers.containsKey('x-api-key'), isFalse);
  });
}
