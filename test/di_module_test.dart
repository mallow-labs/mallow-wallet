import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/api_key_interceptor.dart';
import 'package:mallow_wallet/di_module.dart';

class _Module extends RegisterModule {}

/// Captures the outgoing request so the test can assert on the headers the
/// chain attached, without hitting the network.
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

/// `test/core/network/api_key_interceptor_test.dart` proves the interceptor's
/// own behaviour on a `Dio` the test constructs — so deleting the
/// `ApiKeyInterceptor()` registration in `RegisterModule.dio` fails none of it,
/// and the app would quietly stop authenticating while every test stays green.
/// This file closes that gap: it exercises the `Dio` the module actually
/// builds, the one every API call site is injected with.
void main() {
  late _CapturingAdapter adapter;
  late Dio dio;

  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
    Config.debugOverrides['MALLOW_API_KEY'] = 'KEY123';

    adapter = _CapturingAdapter();
    dio = _Module().dio..httpClientAdapter = adapter;
  });

  tearDown(Config.debugOverrides.clear);

  test('the module-built Dio carries the API-key interceptor', () {
    expect(dio.interceptors.whereType<ApiKeyInterceptor>(), hasLength(1));
  });

  test('a request through the module-built chain reaches the API host with '
      'the key', () async {
    await dio.get<dynamic>('/v1/user/profile');

    final sent = adapter.lastRequest!;
    expect(sent.uri.host, 'api.test');
    expect(sent.headers['x-api-key'], 'KEY123');
  });

  test('the same chain sends no key to a third-party host', () async {
    await dio.get<dynamic>('https://api.jup.ag/tokens/v2/search?query=sol');

    expect(adapter.lastRequest!.headers.containsKey('x-api-key'), isFalse);
  });
}
