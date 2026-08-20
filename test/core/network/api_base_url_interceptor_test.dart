import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/api_base_url_interceptor.dart';

/// `Config.missingApiBaseUrl` existed with zero call sites: three documents
/// called `API_BASE_URL` fail-loud while an unset value produced an empty
/// string and a `debugPrint`. These tests pin the behaviour that closes that
/// gap — and, just as importantly, the two cases that must NOT be broken by
/// closing it.
void main() {
  tearDown(Config.debugOverrides.clear);

  /// Runs one request through a Dio carrying only the guard, with a terminating
  /// adapter that reports whether the request survived the chain.
  Future<({bool reached, Object? error})> send({
    required String baseUrl,
    required String path,
  }) async {
    var reached = false;
    final dio = Dio(BaseOptions(baseUrl: baseUrl))
      ..interceptors.add(const ApiBaseUrlInterceptor())
      ..httpClientAdapter = _StubAdapter(() => reached = true);
    try {
      await dio.request<dynamic>(path);
      return (reached: reached, error: null);
    } on DioException catch (e) {
      return (reached: reached, error: e.error);
    }
  }

  test(
    'a relative path with no base URL is rejected, naming the variable',
    () async {
      final r = await send(baseUrl: '', path: '/v1/notifications');
      expect(
        r.reached,
        isFalse,
        reason: 'the request must not reach the network',
      );
      expect(r.error, isA<StateError>());
      expect((r.error! as StateError).message, contains('API_BASE_URL'));
    },
  );

  test('a configured base URL passes through untouched', () async {
    final r = await send(
      baseUrl: 'https://api.example.com',
      path: '/v1/notifications',
    );
    expect(r.reached, isTrue);
    expect(r.error, isNull);
  });

  // 🛑 The shared Dio also carries third-party traffic (Jupiter, the rewards
  // CDN). Those URLs are absolute and never consult the base, so an
  // unset API_BASE_URL is none of their business — a guard that blocked them
  // would break unrelated features in a build that is merely unconfigured.
  test('an absolute URL is unaffected by a missing base URL', () async {
    final r = await send(
      baseUrl: '',
      path: 'https://quote-api.example.com/price',
    );
    expect(r.reached, isTrue);
    expect(r.error, isNull);
  });
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.onReach);
  final void Function() onReach;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onReach();
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
