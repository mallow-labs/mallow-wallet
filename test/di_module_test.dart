import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/api_key_interceptor.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/di_module.dart';
import 'package:mocktail/mocktail.dart';

class _Module extends RegisterModule {}

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

/// Captures the outgoing request so the test can assert on the headers the
/// chain attached, without hitting the network.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    requests.add(options);
    if (options.uri.path.endsWith('/v2/session')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'address': 'WALLET_A'},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
    if (options.uri.path.endsWith('/v0/currentUser')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': <String, dynamic>{}},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
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

  // AuthService starts the session and reads the user with raw Dio (the token
  // comes off Set-Cookie), but on this same module-built Dio, so both requests
  // carry what the retrofit clients' calls carry: the client-id header the
  // backend's /v2 gate takes in place of an API key, and the API key.
  test('the session start and the user read carry the client-id and the '
      'key', () async {
    Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
    Config.debugOverrides['CLIENT_ID_IOS'] = 'example.client';
    Config.debugOverrides['CLIENT_ID_ANDROID'] = 'example.client';
    final walletManager = _MockWalletManager();
    final storage = _MockStorage();
    when(() => walletManager.getAddress()).thenAnswer((_) async => 'WALLET_A');
    when(
      () => walletManager.isHardwareWallet(any()),
    ).thenAnswer((_) async => false);
    when(
      () => walletManager.needsSocialKeyRecovery(any()),
    ).thenAnswer((_) async => true);
    when(
      () => storage.loadWalletSigCookie(any()),
    ).thenAnswer((_) async => null);
    when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});

    final auth = AuthService(_MockApi(), walletManager, storage, dio);
    await auth.initializeSession();

    final session = adapter.requests.singleWhere(
      (r) => r.uri.path.endsWith('/v2/session'),
    );
    final user = adapter.requests.singleWhere(
      (r) => r.uri.path.endsWith('/v0/currentUser'),
    );
    for (final sent in [session, user]) {
      expect(sent.uri.host, 'api.test');
      expect(sent.headers['X-Client'], 'example.client');
      expect(sent.headers['x-api-key'], 'KEY123');
    }
    expect(session.uri.toString(), 'https://api.test/v2/session');
  });
}
