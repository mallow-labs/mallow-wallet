import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

// The session is started with `POST /v2/session`, which proves nothing and
// returns only `{address, expiresAt}`, and the user is read from
// `GET /v0/currentUser`, which carries the personal fields (following, likes,
// gumball invites) only for a caller holding the address's wallet proof.

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

const _address = 'WALLET_A';
const _followed = 'FOLLOWED_ADDR';
const _liked = 'LIKED_MINT';

String _jwt() {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m)));
  final exp =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000;
  return '${seg({'alg': 'HS256'})}.${seg({'exp': exp})}.sig';
}

/// What the backend answers. `/v0/currentUser` is the privileged render, with
/// the personal fields, only when the request carries `wallet-sig-<address>`.
class _Backend implements HttpClientAdapter {
  final List<String> paths = [];
  final List<Object?> sessionBodies = [];
  final List<bool> currentUserSigned = [];

  /// Set by `/v0/authToken/verify`.
  String? issuedSig;

  /// The first session start answers "Please log in" for the next read.
  bool expireNextRead = false;

  /// When set, `/v0/currentUser` waits on it before answering.
  Completer<void>? holdCurrentUser;

  /// `/gated` answers 401 "Signature expired" until a request carries
  /// [issuedSig] — what the backend does once it stops accepting a proof.
  bool gatedNeedsFreshSig = false;

  static final _json = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  ResponseBody _ok(Object body, {List<String>? setCookie}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {..._json, 'set-cookie': ?setCookie},
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    paths.add(path);
    if (path.endsWith('/v2/session')) {
      sessionBodies.add(options.data);
      return _ok(
        {
          'result': {
            'address': (options.data as Map)['address'],
            'expiresAt': '2026-11-25T00:00:00.000Z',
          },
        },
        setCookie: ['login-token=LOGIN_TOK; Path=/'],
      );
    }
    if (path.endsWith('/v0/currentUser')) {
      await holdCurrentUser?.future;
      final signed = (options.headers['Cookie'] as String? ?? '').contains(
        'wallet-sig-$_address=',
      );
      currentUserSigned.add(signed);
      return _ok({
        'result': signed
            ? {
                'user': {
                  'addresses': [_address],
                  'username': 'artist',
                  'showNsfw': false,
                  'disabledChains': <String>[],
                },
                'userDetails': {'bio': 'mine'},
                'following': [_followed],
                'likesByContentType': {
                  'nft': [_liked],
                },
                'subscriptions': <String>[],
                'invitedGumballCount': 2,
              }
            : {
                'user': {
                  'addresses': [_address],
                  'username': 'artist',
                },
                'userDetails': {'bio': 'public'},
              },
      });
    }
    if (path.endsWith('/v0/authToken/verify')) {
      final sig = issuedSig = _jwt();
      return _ok(
        {'result': <String, dynamic>{}},
        setCookie: ['wallet-sig-$_address=$sig; Path=/'],
      );
    }
    if (path.endsWith('/gated') && gatedNeedsFreshSig) {
      final cookie = options.headers['Cookie'] as String? ?? '';
      final sig = issuedSig;
      if (sig == null || !cookie.contains('wallet-sig-$_address=$sig')) {
        return ResponseBody.fromString(
          jsonEncode({
            'error': {'message': 'Signature expired'},
          }),
          401,
          headers: _json,
        );
      }
    }
    if (expireNextRead) {
      expireNextRead = false;
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Please log in'},
        }),
        401,
        headers: _json,
      );
    }
    return _ok(<String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _MockApi api;
  late _MockWalletManager walletManager;
  late _MockStorage storage;
  late _Backend backend;
  late Dio dio;
  late AuthService auth;
  late String? diskSig;

  setUpAll(() {
    registerFallbackValue(const AuthTokenRequest(address: _address));
  });

  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
    api = _MockApi();
    walletManager = _MockWalletManager();
    storage = _MockStorage();
    backend = _Backend();
    diskSig = null;

    final session = _MockSession();
    when(() => session.sessionAddresses).thenReturn({_address});
    when(() => session.settingsScopeId()).thenAnswer((_) async => null);
    if (GetIt.instance.isRegistered<SessionManager>()) {
      GetIt.instance.unregister<SessionManager>();
    }
    GetIt.instance.registerSingleton<SessionManager>(session);

    when(() => walletManager.getAddress()).thenAnswer((_) async => _address);
    when(
      () => walletManager.isHardwareWallet(any()),
    ).thenAnswer((_) async => false);
    when(
      () => walletManager.needsSocialKeyRecovery(any()),
    ).thenAnswer((_) async => false);
    when(
      () => walletManager.signLoginChallengeForAddress(
        any(),
        message: any(named: 'message'),
        token: any(named: 'token'),
      ),
    ).thenAnswer(
      (_) async =>
          const LoginChallengeSignature(chain: Chain.solana, signature: 'SIG'),
    );
    when(
      () => api.getAuthToken(any()),
    ).thenAnswer((_) async => const ApiResponse<String>(result: 'TOKEN'));
    when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
    when(() => storage.storeSessionExpiry(any())).thenAnswer((_) async {});
    when(
      () => storage.loadWalletSigCookie(any()),
    ).thenAnswer((_) async => diskSig);
    when(() => storage.storeWalletSigCookie(any(), any())).thenAnswer((
      i,
    ) async {
      diskSig = i.positionalArguments[1] as String;
    });

    dio = Dio()..httpClientAdapter = backend;
    auth = AuthService(api, walletManager, storage, dio);
  });

  tearDown(() {
    Config.debugOverrides.clear();
    if (GetIt.instance.isRegistered<SessionManager>()) {
      GetIt.instance.unregister<SessionManager>();
    }
  });

  test('starts the session on /v2/session and reads the user from '
      '/v0/currentUser, never /v0/login', () async {
    diskSig = _jwt();

    await auth.initializeSession();

    expect(backend.paths, isNot(contains(endsWith('/v0/login'))));
    expect(backend.paths.first, '/v2/session');
    expect(backend.sessionBodies.single, {'address': _address});
    expect(backend.paths, contains('/v0/currentUser'));
    expect(auth.currentAddress, _address);
    expect(auth.currentUser?.username, 'artist');
    verify(
      () => storage.storeSessionExpiry('2026-11-25T00:00:00.000Z'),
    ).called(1);
  });

  // With a stored proof the read is signed: the personal fields arrive with
  // the user, and nothing has to be signed for them.
  test('a stored proof gives the personal fields on the first read', () async {
    diskSig = _jwt();

    await auth.initializeSession();

    expect(backend.currentUserSigned.first, isTrue);
    expect(auth.isFollowing(_followed), isTrue);
    expect(auth.isLiked(_liked, ContentType.nft), isTrue);
    expect(auth.invitedGumballCount, 2);
    expect(auth.currentUserDetails?.bio, 'mine');
    verifyNever(() => api.getAuthToken(any()));
  });

  // A wallet that cannot sign silently, with no proof: the anonymous view.
  // Loading follows or likes is never a reason to ask for a signature.
  test(
    'no proof and no silent signer: the anonymous view, no prompt',
    () async {
      when(
        () => walletManager.needsSocialKeyRecovery(any()),
      ).thenAnswer((_) async => true);

      await auth.initializeSession();

      expect(backend.currentUserSigned, [false]);
      expect(auth.following, isEmpty);
      expect(auth.likesByContentType, isEmpty);
      expect(auth.invitedGumballCount, 0);
      expect(auth.currentUser?.username, 'artist');
      verifyNever(() => api.getAuthToken(any()));
      expect(backend.paths, isNot(contains('/v0/authToken/verify')));
    },
  );

  // A first login: the read before the signature is public, so once the
  // silent signature lands the signed render is read for the personal fields.
  test(
    'after the login signature, the personal fields are read signed',
    () async {
      await auth.initializeSession();
      // The signed re-read runs after the signature, without blocking it.
      await pumpEventQueue();

      expect(backend.currentUserSigned, [false, true]);
      expect(auth.isFollowing(_followed), isTrue);
      expect(auth.isLiked(_liked, ContentType.nft), isTrue);
      expect(auth.invitedGumballCount, 2);
    },
  );

  // The re-read for the personal fields follows a re-sign inside the 401
  // retry. The original request's replay must not wait for it.
  test('a 401 re-sign replays the request without waiting for the '
      'personal-data read', () async {
    diskSig = _jwt();
    await auth.initializeSession();
    backend.gatedNeedsFreshSig = true;
    backend.holdCurrentUser = Completer<void>();

    final response = await dio
        .get<dynamic>('https://api.test/gated')
        .timeout(const Duration(seconds: 5));

    expect(response.statusCode, 200);
    expect(backend.paths, contains('/v0/authToken/verify'));
    expect(
      backend.paths.where((p) => p == '/v0/currentUser').length,
      2,
      reason: 'the re-read went out and is still held',
    );
    backend.holdCurrentUser!.complete();
    await pumpEventQueue();
  });

  test('the "Please log in" refresh starts a new session', () async {
    diskSig = _jwt();
    await auth.initializeSession();
    final before = backend.sessionBodies.length;

    backend.expireNextRead = true;
    await dio.get<dynamic>('https://api.test/v1/anything');

    expect(backend.sessionBodies.length, before + 1);
    expect(backend.sessionBodies.last, {'address': _address});
    expect(backend.paths, isNot(contains(endsWith('/v0/login'))));
  });

  test('the link flow swaps tokens through /v2/session', () async {
    diskSig = _jwt();
    await auth.initializeSession();
    final before = backend.sessionBodies.length;

    await auth.loginForLinkFlow('WALLET_B');

    expect(backend.sessionBodies.length, before + 1);
    expect(backend.sessionBodies.last, {'address': 'WALLET_B'});
  });
}
