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
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

/// Answers `/v2/session` with a login token and everything else with `{}`,
/// except the paths in [unauthorized], which get a `401` carrying the message
/// the signature retry reacts to. Records every request.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final Set<String> unauthorized = {};

  String? get lastCookie => requests.last.headers['Cookie'] as String?;

  static final _json = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (unauthorized.contains(path)) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Signature required'},
        }),
        401,
        headers: _json,
      );
    }
    if (path.endsWith('/v2/session')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'address': (options.data as Map)['address']},
        }),
        200,
        headers: {
          ..._json,
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
    if (path.endsWith('/v0/currentUser')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': <String, dynamic>{}},
        }),
        200,
        headers: _json,
      );
    }
    return ResponseBody.fromString('{}', 200, headers: _json);
  }

  @override
  void close({bool force = false}) {}
}

/// When every proof in this file expires. Read once: [_proof] is called both
/// to store a proof and, later, to say which proof a header should carry, and
/// a clock read at each call gives two different proofs whenever a second
/// ticks over in between.
final int _proofExpiry =
    DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;

/// A proof the size the backend issues: about 300 bytes with its cookie name.
String _proof(String address) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = _proofExpiry;
  final payload = seg({'address': address, 'iat': exp - 2592000, 'exp': exp});
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.$payload.${'s' * 43}';
}

/// A Solana-length address, so a proof's cookie name is as long as a real one.
String _address(String name) => name.padRight(44, 'x');

List<String> _proofAddresses(String? cookie) => [
  for (final part in (cookie ?? '').split('; '))
    if (part.startsWith('wallet-sig-'))
      part.substring('wallet-sig-'.length, part.indexOf('=')),
];

void main() {
  late _MockApi api;
  late _MockWalletManager walletManager;
  late _MockStorage storage;
  late _MockSession session;
  late _RecordingAdapter adapter;
  late Dio dio;
  late AuthService auth;

  /// A common server limit for one header.
  const headerLimit = 8 * 1024;

  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

    api = _MockApi();
    walletManager = _MockWalletManager();
    storage = _MockStorage();
    session = _MockSession();
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    auth = AuthService(api, walletManager, storage, dio);

    when(() => session.settingsScopeId()).thenAnswer((_) async => null);
    GetIt.instance.registerSingleton<SessionManager>(session);

    // Every wallet has a proof on disk — what push sync leaves behind once it
    // has signed for each wallet the app holds a key for.
    when(() => storage.loadWalletSigCookie(any())).thenAnswer(
      (inv) async => _proof(inv.positionalArguments.first as String),
    );
    when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
    when(() => storage.deleteLoginToken()).thenAnswer((_) async {});
    when(() => storage.deleteSessionExpiry()).thenAnswer((_) async {});
    when(() => storage.deleteAuthToken()).thenAnswer((_) async {});
  });

  tearDown(() {
    Config.debugOverrides.clear();
    GetIt.instance.unregister<SessionManager>();
  });

  Future<String?> probeCookie({String? ownCookie}) async {
    await dio.get<dynamic>(
      'https://api.test/v1/probe',
      options: Options(headers: {'Cookie': ?ownCookie}),
    );
    return adapter.lastCookie;
  }

  // Servers refuse a request whose Cookie header grows too large, and the
  // interceptor puts its whole proof map into that one header. Loading every
  // proof on disk into it would break every API request on a device with a
  // few dozen wallets — after one login, with no way back short of a restart.
  group('the shared proofs are bounded', () {
    final wallets = [for (var i = 0; i < 40; i++) _address('W$i')];
    // The logged-in wallet is the LAST of the session, so a cap that keeps
    // "the first few" would drop the one proof every signed read needs.
    final active = wallets.last;

    setUp(() {
      when(() => session.sessionAddresses).thenReturn(wallets.toSet());
      when(() => walletManager.getAddress()).thenAnswer((_) async => active);
    });

    test('40 stored proofs: the header stays under the limit and carries the '
        'logged-in wallet\'s', () async {
      await auth.initializeSession();

      final cookie = await probeCookie();

      expect(cookie, contains('login-token=LOGIN_TOK'));
      expect(cookie, contains('wallet-sig-$active=${_proof(active)}'));
      expect(
        _proofAddresses(cookie),
        hasLength(AuthService.maxSharedWalletProofs),
      );
      expect(cookie!.length, lessThan(headerLimit ~/ 2));
    });

    test(
      'which proofs ride along is the session\'s order, not chance',
      () async {
        await auth.initializeSession();

        expect(_proofAddresses(await probeCookie()).toSet(), {
          active,
          ...wallets.take(AuthService.maxSharedWalletProofs - 1),
        });
      },
    );

    test('a request with eight proofs of its own still fits', () async {
      // A push sync adds up to eight proofs for the wallets it is proving, on
      // top of what the interceptor sends.
      await auth.initializeSession();
      final own = [
        for (final w in wallets.skip(20).take(8)) 'wallet-sig-$w=${_proof(w)}',
      ].join('; ');

      final cookie = await probeCookie(ownCookie: own);

      expect(cookie, startsWith(own));
      expect(cookie!.length, lessThan(headerLimit));
    });

    test(
      'asking for every wallet\'s proof in turn never outgrows it',
      () async {
        await auth.initializeSession();

        for (final wallet in wallets) {
          expect(await auth.hasValidWalletSigForAny([wallet]), isTrue);
          final cookie = await probeCookie();
          // The proof the gate just accepted is on the very next request...
          expect(cookie, contains('wallet-sig-$wallet='));
          // ...the logged-in wallet's is never the one given up for it...
          expect(cookie, contains('wallet-sig-$active='));
          // ...and the header is no bigger for it.
          expect(
            _proofAddresses(cookie).length,
            lessThanOrEqualTo(AuthService.maxSharedWalletProofs),
          );
          expect(cookie!.length, lessThan(headerLimit ~/ 2));
        }
      },
    );

    test('a proof a caller asked for outlasts the ones merely found', () async {
      await auth.initializeSession();
      final asked = wallets[30];

      await auth.hasValidWalletSigForAny([asked]);
      await auth.hasValidWalletSigForAny([wallets[31]]);

      // Two found proofs made room, the session's last ones first.
      expect(_proofAddresses(await probeCookie()).toSet(), {
        active,
        asked,
        wallets[31],
        ...wallets.take(AuthService.maxSharedWalletProofs - 3),
      });
    });

    test('the byte cap holds when proofs are larger than expected', () async {
      // Ten times the usual size: three of these already fill the budget.
      when(() => storage.loadWalletSigCookie(any())).thenAnswer((inv) async {
        final address = inv.positionalArguments.first as String;
        final parts = _proof(address).split('.');
        return '${parts[0]}.${parts[1]}.${'s' * 900}';
      });

      await auth.initializeSession();
      final cookie = await probeCookie();

      expect(cookie, contains('wallet-sig-$active='));
      expect(
        _proofAddresses(cookie).length,
        lessThan(AuthService.maxSharedWalletProofs),
      );
      expect(
        cookie!.length,
        lessThan(AuthService.maxSharedWalletProofBytes + 512),
      );
    });
  });

  // The proofs widen reads across the wallets of one session. Before the
  // prune they survived every switch, so a run that visited several accounts
  // sent each request the proofs of all of them.
  group('a wallet or account switch', () {
    final first = [_address('A1'), _address('A2'), _address('A3')];
    final second = [_address('B1'), _address('B2')];

    test('drops the previous account\'s proofs', () async {
      when(() => session.sessionAddresses).thenReturn(first.toSet());
      when(() => walletManager.getAddress()).thenAnswer((_) async => first[0]);
      await auth.initializeSession();
      expect(_proofAddresses(await probeCookie()).toSet(), first.toSet());

      // The session manager describes the new account before the login runs.
      when(() => session.sessionAddresses).thenReturn(second.toSet());
      await auth.switchWallet(second[0]);

      final cookie = await probeCookie();
      expect(_proofAddresses(cookie).toSet(), second.toSet());
      for (final wallet in first) {
        expect(auth.hasAnyVerifiedSession([wallet]), isFalse);
      }
    });

    test('keeps the proofs of a session that did not change', () async {
      // Picking another wallet of the same account: its siblings' proofs are
      // exactly what the multi-wallet reads still need.
      when(() => session.sessionAddresses).thenReturn(first.toSet());
      when(() => walletManager.getAddress()).thenAnswer((_) async => first[0]);
      await auth.initializeSession();

      await auth.switchWallet(first[1]);

      expect(_proofAddresses(await probeCookie()).toSet(), first.toSet());
    });

    test('the request that logs the new wallet in carries none of the old '
        'account\'s', () async {
      when(() => session.sessionAddresses).thenReturn(first.toSet());
      when(() => walletManager.getAddress()).thenAnswer((_) async => first[0]);
      await auth.initializeSession();
      adapter.requests.clear();

      when(() => session.sessionAddresses).thenReturn(second.toSet());
      await auth.switchWallet(second[0]);

      for (final request in adapter.requests) {
        final cookie = request.headers['Cookie'] as String?;
        expect(_proofAddresses(cookie), everyElement(isIn(second)));
      }
    });
  });

  // The vault routes authenticate by an identity token or a vault-key
  // signature. Sending them the wallet session as well told the server which
  // wallets were logged in on the device that opened which vault.
  group('the social-vault routes', () {
    final active = _address('ACTIVE');

    setUp(() async {
      when(() => session.sessionAddresses).thenReturn({active});
      when(() => walletManager.getAddress()).thenAnswer((_) async => active);
      await auth.initializeSession();
    });

    for (final path in [
      '/v2/social-vault/open',
      '/v2/social-vault/create',
      '/v2/social-vault/slots/add',
      '/v2/social-vault/status',
    ]) {
      test('$path carries no session cookie', () async {
        await dio.post<dynamic>(
          'https://api.test$path',
          data: {'idToken': 'x'},
          options: Options(headers: {'x-vault-signature': 'sig'}),
        );

        expect(adapter.lastCookie, isNull);
        // What the route does authenticate by is untouched.
        expect(adapter.requests.last.headers['x-vault-signature'], 'sig');
      });
    }

    test('an ordinary path on the same host still carries it', () async {
      await dio.post<dynamic>('https://api.test/v2/social-vault/open');
      expect(adapter.lastCookie, isNull);

      await dio.get<dynamic>('https://api.test/v2/portfolio/artworks');

      expect(adapter.lastCookie, contains('login-token=LOGIN_TOK'));
      expect(adapter.lastCookie, contains('wallet-sig-$active='));
    });

    test('the path is matched under any base path', () {
      expect(
        isSessionlessRoute(Uri.parse('https://api.test/social-vault/open')),
        isTrue,
      );
      expect(
        isSessionlessRoute(Uri.parse('https://api.test/api/v2/social-vault/x')),
        isTrue,
      );
      expect(
        isSessionlessRoute(Uri.parse('https://api.test/v2/social-vaults')),
        isFalse,
      );
      expect(
        isSessionlessRoute(Uri.parse('https://api.test/v2/session')),
        isFalse,
      );
    });

    test('a 401 from a vault route is not answered with a wallet '
        'signature', () async {
      // The message is the one the session's signature retry reacts to. On a
      // hardware wallet that retry opens a verify sheet.
      adapter.unauthorized.add('/v2/social-vault/status');

      await expectLater(
        dio.post<dynamic>('https://api.test/v2/social-vault/status'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );

      verifyNever(() => walletManager.isHardwareWallet(any()));
      expect(
        adapter.requests.where((r) => r.uri.path.contains('social-vault')),
        hasLength(1),
        reason: 'the request must not be replayed',
      );
    });
  });
}
