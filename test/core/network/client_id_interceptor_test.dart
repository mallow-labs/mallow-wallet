import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/client_id_interceptor.dart';

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

Dio _dioWith(_CapturingAdapter adapter) => Dio()
  ..httpClientAdapter = adapter
  ..interceptors.add(
    ClientIdInterceptor(mallowHosts: const {'api.example.com'}),
  );

void main() {
  // `clientIdValue` reads a different define per platform, so configure
  // whichever one the host running the test will actually consult.
  final valueKey = Platform.isIOS ? 'CLIENT_ID_IOS' : 'CLIENT_ID_ANDROID';

  late _CapturingAdapter adapter;
  late Dio dio;

  setUp(() {
    adapter = _CapturingAdapter();
    dio = _dioWith(adapter);
  });

  tearDown(Config.debugOverrides.clear);

  void configure() {
    Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
    Config.debugOverrides[valueKey] = 'example.client';
  }

  test('sends the configured client-id header to a mallow host', () async {
    configure();

    await dio.get<dynamic>('https://api.example.com/v2/portfolio');

    expect(adapter.lastRequest!.headers['X-Client'], 'example.client');
  });

  test('does not send the client-id header to a third-party host', () async {
    // This header authorizes the caller on the backend's open /v2 routes, so
    // it is a credential. The shared Dio it rides on also serves third-party
    // traffic — Jupiter's public API backs token search — and sending it there
    // hands our credential to a host that has no business holding it.
    configure();

    await dio.get<dynamic>('https://api.jup.ag/tokens/v2/search?query=sol');

    expect(adapter.lastRequest!.headers.containsKey('X-Client'), isFalse);
  });

  test('sends no header at all when the build is unconfigured', () async {
    // Blank means omitted, not empty: an empty header value is a different
    // request on the wire, and a gateway may reject it as malformed instead of
    // treating it as an anonymous caller. An OSS clone configures neither half.
    await dio.get<dynamic>('https://api.example.com/v2/portfolio');

    expect(adapter.lastRequest!.headers.containsKey('X-Client'), isFalse);
  });
}
