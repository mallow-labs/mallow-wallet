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
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

/// The two requests of a login, each of which a test can hold open.
///
/// `/v2/session` for an address sets `login-token=TOK_<address>`, and
/// `/v0/currentUser` answers for whichever token the request carried — so the
/// user a login reads is the user of the token that was installed when it
/// asked, as on the real backend.
class _HeldLoginAdapter implements HttpClientAdapter {
  /// Requests in the order they were sent: `session:<address>` and
  /// `user:<address>`.
  final List<String> sent = [];

  final Map<String, Completer<void>> _held = {};
  final Set<String> _failing = {};

  /// Hold the next [step] (`session:<address>` or `user:<address>`) until
  /// [release] is called for it.
  void hold(String step) => _held[step] = Completer<void>();

  void release(String step) => _held.remove(step)!.complete();

  /// Make [step] fail with a `500` once it is let through.
  void fail(String step) => _failing.add(step);

  static final _json = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final cookie = options.headers['Cookie'] as String? ?? '';
    final String step;
    if (path.endsWith('/v2/session')) {
      step = 'session:${(options.data as Map)['address']}';
    } else if (path.endsWith('/v0/currentUser')) {
      final token = RegExp(r'login-token=TOK_(\w+)').firstMatch(cookie);
      step = 'user:${token?.group(1)}';
    } else {
      return ResponseBody.fromString(
        jsonEncode({'cookie': cookie}),
        200,
        headers: _json,
      );
    }

    sent.add(step);
    await _held[step]?.future;
    if (_failing.remove(step)) {
      return ResponseBody.fromString('{}', 500, headers: _json);
    }

    final address = step.substring(step.indexOf(':') + 1);
    if (step.startsWith('session:')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'address': address},
        }),
        200,
        headers: {
          ..._json,
          'set-cookie': ['login-token=TOK_$address; Path=/'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'result': {
          'user': {'username': 'user-of-$address'},
        },
      }),
      200,
      headers: _json,
    );
  }

  @override
  void close({bool force = false}) {}
}

String _jwt() {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m)));
  final exp =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000;
  return '${seg({'alg': 'HS256'})}.${seg({'exp': exp})}.sig';
}

// A login is two requests — start the session, then read its user — and the
// session state is assigned after the second. A resume refresh for wallet A
// that was still on the wire when the user switched to wallet B used to finish
// last: the UI showed A while requests carried B's login token (or A's token
// went back over B's), until the next switch.
void main() {
  const a = 'WALLETA';
  const b = 'WALLETB';

  late _MockWalletManager walletManager;
  late _MockStorage storage;
  late _HeldLoginAdapter adapter;
  late Dio dio;
  late AuthService auth;

  setUp(() async {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

    walletManager = _MockWalletManager();
    storage = _MockStorage();
    adapter = _HeldLoginAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    auth = AuthService(_MockApi(), walletManager, storage, dio);

    final session = _MockSession();
    when(() => session.sessionAddresses).thenReturn(const {});
    when(() => session.settingsScopeId()).thenAnswer((_) async => null);
    GetIt.instance.registerSingleton<SessionManager>(session);

    when(() => walletManager.getAddress()).thenAnswer((_) async => a);
    // A proof on disk for every wallet: the login never has to sign.
    when(
      () => storage.loadWalletSigCookie(any()),
    ).thenAnswer((_) async => _jwt());
    when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
    when(() => storage.deleteLoginToken()).thenAnswer((_) async {});
    when(() => storage.deleteSessionExpiry()).thenAnswer((_) async {});
    when(() => storage.deleteAuthToken()).thenAnswer((_) async {});

    // The app is running, logged in as A.
    await auth.initializeSession();
    adapter.sent.clear();
  });

  tearDown(() {
    Config.debugOverrides.clear();
    GetIt.instance.unregister<SessionManager>();
  });

  /// The login token a request made now would carry.
  Future<String?> installedToken() async {
    final response = await dio.get<Map<String, dynamic>>(
      'https://api.test/v1/probe',
    );
    final cookie = response.data!['cookie'] as String;
    return RegExp(r'login-token=(\w+)').firstMatch(cookie)?.group(1);
  }

  Future<void> expectLoggedInAsB() async {
    expect(auth.currentAddress, b);
    expect(auth.currentUser?.username, 'user-of-$b');
    expect(auth.sessionState, SessionState.authenticated);
    expect(await installedToken(), 'TOK_$b');
  }

  test('a refresh overtaken before its session answers assigns '
      'nothing', () async {
    adapter.hold('session:$a');
    final refresh = auth.refresh();
    await pumpEventQueue();
    expect(adapter.sent, ['session:$a'], reason: 'A\'s refresh is on the wire');

    // The user switches wallets; B's login runs start to finish.
    final switched = await auth.switchWallet(b);
    await expectLoggedInAsB();

    // Only now does A's session request answer, with A's login token.
    adapter.release('session:$a');
    // The refresh asked for a fresh session and there is one: B's.
    expect(await refresh, same(switched));
    await pumpEventQueue();

    await expectLoggedInAsB();
    expect(
      adapter.sent,
      isNot(contains('user:$a')),
      reason: 'a superseded login must not go on to read its user',
    );
  });

  test(
    'a refresh overtaken between its two requests assigns nothing',
    () async {
      adapter.hold('user:$a');
      final refresh = auth.refresh();
      await pumpEventQueue();
      expect(
        adapter.sent,
        ['session:$a', 'user:$a'],
        reason: 'A\'s token is installed and its user read is on the wire',
      );

      final switched = await auth.switchWallet(b);
      await expectLoggedInAsB();

      adapter.release('user:$a');
      expect(await refresh, same(switched));
      await pumpEventQueue();

      await expectLoggedInAsB();
    },
  );

  test('a superseded refresh that fails does not mark the new session '
      'failed', () async {
    adapter
      ..hold('session:$a')
      ..fail('session:$a');
    final refresh = auth.refresh();
    await pumpEventQueue();

    final switched = await auth.switchWallet(b);
    adapter.release('session:$a');
    // Its own failure is nobody's news: the session it wanted is up.
    expect(await refresh, same(switched));
    await pumpEventQueue();

    await expectLoggedInAsB();
  });

  // The startup screen awaits this login and offers "retry" when it fails. A
  // switch that lands during it must not turn a logged-in app into that
  // screen.
  test('a startup login overtaken by a switch still in flight answers with '
      'the switch\'s login', () async {
    await auth.logout();
    adapter.sent.clear();
    adapter
      ..hold('session:$a')
      ..hold('session:$b');
    final startup = auth.initializeSession();
    await pumpEventQueue();
    final switching = auth.switchWallet(b);
    await pumpEventQueue();
    expect(adapter.sent, ['session:$a', 'session:$b']);

    adapter.release('session:$a');
    await pumpEventQueue();
    expect(auth.currentAddress, isNull, reason: 'A assigned nothing');

    adapter.release('session:$b');
    expect(await startup, same(await switching));
    await expectLoggedInAsB();
  });

  test('a refresh during a switch joins it instead of logging in '
      'beside it', () async {
    adapter.hold('session:$b');
    final switching = auth.switchWallet(b);
    await pumpEventQueue();
    expect(adapter.sent, ['session:$b']);

    // The app resumes mid-switch. The session is cleared, so a login of its
    // own would be for whatever wallet is selected — here still A.
    final refresh = auth.refresh();
    await pumpEventQueue();
    expect(adapter.sent, ['session:$b'], reason: 'no second login started');

    adapter.release('session:$b');
    final results = await Future.wait([switching, refresh]);

    expect(results[1], same(results[0]));
    await expectLoggedInAsB();
    verify(() => walletManager.getAddress()).called(1); // the setUp login
  });

  test('a logout during a login is not undone by it', () async {
    adapter.hold('user:$a');
    final refresh = auth.refresh();
    final refreshOutcome = expectLater(refresh, throwsA(isA<AuthException>()));
    await pumpEventQueue();

    await auth.logout();
    adapter.release('user:$a');
    await refreshOutcome;
    await pumpEventQueue();

    expect(auth.currentAddress, isNull);
    expect(auth.currentUser, isNull);
    expect(auth.sessionState, SessionState.initial);
    expect(await installedToken(), isNull);
  });

  test('a login nobody overtook still completes', () async {
    final result = await auth.refresh();

    expect(result.user.username, 'user-of-$a');
    expect(auth.currentAddress, a);
    expect(auth.sessionState, SessionState.authenticated);
    expect(await installedToken(), 'TOK_$a');
  });

  // The "Please log in" retry starts a session for the address it read when
  // the 401 arrived. If the user switched meanwhile, its token is the previous
  // wallet's.
  test('a login-token retry overtaken by a switch installs nothing', () async {
    // Drop A's token as an expired one would be refused, then let a request
    // 401 with the message the retry reacts to.
    final expired = _ExpiredOnce(adapter);
    dio.httpClientAdapter = expired;
    adapter.hold('session:$a');

    final request = dio.get<dynamic>('https://api.test/v1/needs-login');
    final requestOutcome = request.then((_) {}, onError: (_) {});
    await pumpEventQueue();
    expect(adapter.sent, [
      'session:$a',
    ], reason: 'the retry is re-logging A in');

    await auth.switchWallet(b);
    await expectLoggedInAsB();

    adapter.release('session:$a');
    await requestOutcome;
    await pumpEventQueue();

    await expectLoggedInAsB();
  });
}

/// Answers the first request to `/v1/needs-login` with the backend's
/// expired-login `401`, and hands everything else to [inner].
class _ExpiredOnce implements HttpClientAdapter {
  _ExpiredOnce(this.inner);

  final HttpClientAdapter inner;
  bool _refused = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!_refused && options.uri.path.endsWith('/v1/needs-login')) {
      _refused = true;
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Please log in'},
        }),
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
