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
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

class _MockPrefs extends Mock implements PreferencesService {}

/// Dio adapter that stubs `/v0/login` (returning a minimal LoginResult plus a
/// `login-token` Set-Cookie so the auth interceptor is installed) and records
/// the `Cookie` header of every request, so a probe issued after login reveals
/// which wallet-sig cookies the interceptor actually attaches.
class _StubLoginAdapter implements HttpClientAdapter {
  String? lastCookie;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCookie = options.headers['Cookie'] as String?;
    if (options.path.endsWith('/v0/login')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': <String, dynamic>{}},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
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

/// Dio adapter that lets a test hold `/v0/login` open per address, so
/// overlapping [AuthService.switchWallet] calls can be observed mid-flight.
///
/// Every login request is recorded in [startedLogins] **as it arrives** (not
/// when it resolves) and then parks on that address's gate until the test calls
/// [release]. Recording at arrival is what makes the queue-window assertions
/// meaningful: a duplicate switch is visible the moment its `/v0/login` is
/// dispatched, even if the response never comes back.
class _GatedLoginAdapter implements HttpClientAdapter {
  /// Login addresses in dispatch order — one entry per `/v0/login` sent.
  final List<String> startedLogins = [];

  final Map<String, Completer<void>> _gates = {};
  final Set<String> _failing = {};

  Completer<void> _gate(String address) =>
      _gates.putIfAbsent(address, Completer<void>.new);

  /// Let every parked (and future) login for [address] complete.
  void release(String address) {
    final gate = _gate(address);
    if (!gate.isCompleted) gate.complete();
  }

  /// Make [address]'s login respond with an API error envelope.
  void failLogin(String address) => _failing.add(address);

  int loginCount(String address) =>
      startedLogins.where((a) => a == address).length;

  static final _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.endsWith('/v0/login')) {
      return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
    }

    final address = (options.data as Map)['address'] as String;
    startedLogins.add(address);
    await _gate(address).future;

    if (_failing.contains(address)) {
      return ResponseBody.fromString(
        jsonEncode({
          'err': {'message': 'login rejected for $address'},
        }),
        200,
        headers: _jsonHeaders,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'result': {'user': <String, dynamic>{}},
      }),
      200,
      headers: {
        ..._jsonHeaders,
        'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Dio adapter for the cold-start shape: `/v0/login` answers with the PUBLIC
/// user render (no `perks`, no `userDetails` — what the backend returns when the
/// request carries no wallet-sig cookie), while `/v0/authToken/verify` answers
/// with the privileged one plus the `wallet-sig` Set-Cookie.
class _StubVerifyAdapter implements HttpClientAdapter {
  /// Perks the *verify* render reports. Mutable so a test can prove a second,
  /// non-active-wallet verify does not overwrite what the first one adopted.
  List<String> perks = const ['gif-pfp'];

  static final _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/v0/login')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {
            'user': {'addresses': <String>[], 'username': 'artist'},
          },
        }),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
    if (options.path.endsWith('/v0/authToken/verify')) {
      final address = (options.data as Map)['address'] as String;
      return ResponseBody.fromString(
        jsonEncode({
          'result': {
            'user': {
              'addresses': <String>[],
              'username': 'artist',
              'perks': perks,
            },
            'userDetails': {'bio': 'privileged'},
          },
        }),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['wallet-sig-$address=SIGJWT; Path=/'],
        },
      );
    }
    return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
  }

  @override
  void close({bool force = false}) {}
}

/// Dio adapter that mirrors the backend's `hasValidSignedWallet` gate on
/// `/v0/login`: the response is the PRIVILEGED render only when the request
/// already carries a `wallet-sig-<address>` cookie, and the public one
/// otherwise. The public render OMITS `perks`, `showNsfw` and `disabledChains`
/// outright — the shape `renderSingle` produces, and the reason a client cannot
/// tell "the server withheld it" from "the user has it unset": every one of
/// those fields parses to an empty/false default.
class _SignedLoginAdapter implements HttpClientAdapter {
  _SignedLoginAdapter(this._address);

  final String _address;

  /// Set when `/v0/authToken/verify` is reached — the re-sign round trip a
  /// launch that still holds a valid 30-day sig must not have to pay for.
  bool verifyCalled = false;

  static final _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  /// The user really does own the gif-pfp perk, really has turned Tezos off,
  /// and really has opted in to NSFW. None of it is visible publicly.
  static const _privilegedUser = {
    'addresses': <String>[],
    'username': 'artist',
    'perks': ['gif-pfp'],
    'showNsfw': true,
    'disabledChains': ['tezos'],
  };

  static const _publicUser = {'addresses': <String>[], 'username': 'artist'};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/v0/login')) {
      final signed = (options.headers['Cookie'] as String? ?? '').contains(
        'wallet-sig-$_address=',
      );
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': signed ? _privilegedUser : _publicUser},
        }),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
    if (options.path.endsWith('/v0/authToken/verify')) {
      verifyCalled = true;
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': _privilegedUser},
        }),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['wallet-sig-$_address=SIGJWT; Path=/'],
        },
      );
    }
    return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
  }

  @override
  void close({bool force = false}) {}
}

/// Dio adapter for a mid-session signature lapse: `/gated` answers
/// `401 {"error":{"message":"Signature expired"}}` — what the backend returns
/// once it no longer accepts the sig the request carried — until the request
/// arrives with [freshSig], and `/v0/authToken/verify` is the only place that
/// hands [freshSig] out. So the `Cookie` header recorded per `/gated` attempt
/// shows whether the 401 retry actually re-signed.
class _SigLapseAdapter implements HttpClientAdapter {
  _SigLapseAdapter(this._address, this.freshSig);

  final String _address;

  /// The wallet-sig value `/v0/authToken/verify` sets and `/gated` accepts.
  final String freshSig;

  /// The `Cookie` header of every `/gated` attempt, in order.
  final List<String?> gatedCookies = [];

  static final _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/v0/login')) {
      return ResponseBody.fromString(
        jsonEncode({
          'result': {'user': <String, dynamic>{}},
        }),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['login-token=LOGIN_TOK; Path=/'],
        },
      );
    }
    if (options.path.endsWith('/v0/authToken/verify')) {
      return ResponseBody.fromString(
        jsonEncode({'result': <String, dynamic>{}}),
        200,
        headers: {
          ..._jsonHeaders,
          'set-cookie': ['wallet-sig-$_address=$freshSig; Path=/'],
        },
      );
    }

    final cookie = options.headers['Cookie'] as String?;
    gatedCookies.add(cookie);
    if (cookie == null || !cookie.contains('wallet-sig-$_address=$freshSig')) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Signature expired'},
        }),
        401,
        headers: _jsonHeaders,
      );
    }
    return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
  }

  @override
  void close({bool force = false}) {}
}

/// Build a syntactically-valid JWT whose payload carries [exp] (seconds since
/// epoch). Only the payload is meaningful to [AuthService]'s expiry check.
String _jwt(int expEpochSeconds) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m)));
  return '${seg({'alg': 'HS256'})}.${seg({'exp': expEpochSeconds})}.sig';
}

void main() {
  tearDown(Config.debugOverrides.clear);

  late _MockApi api;
  late _MockWalletManager walletManager;
  late _MockStorage storage;
  late AuthService auth;

  const address = 'SoLAddr123';

  final futureExp =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000;
  final pastExp =
      DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000;

  setUp(() {
    api = _MockApi();
    walletManager = _MockWalletManager();
    storage = _MockStorage();
    auth = AuthService(api, walletManager, storage, Dio());
  });

  group('hasValidWalletSigForAny disk-hit hydration', () {
    // Regression: a wallet-sig that lives only on disk (e.g. right after an app
    // restart, before any re-login hydrates it) must be pulled into the
    // in-memory cache the Dio interceptor sends. Otherwise the gate passes while
    // the very next request goes out cookieless. hasAnyVerifiedSession reads
    // exactly that in-memory map, so it becoming true proves the hydration.
    test('valid disk-only sig is hydrated into the in-memory cache', () async {
      when(
        () => storage.loadWalletSigCookie(address),
      ).thenAnswer((_) async => _jwt(futureExp));

      // Nothing in memory yet.
      expect(auth.hasAnyVerifiedSession([address]), isFalse);

      expect(await auth.hasValidWalletSigForAny([address]), isTrue);

      // The disk value is now in the map the interceptor attaches.
      expect(auth.hasAnyVerifiedSession([address]), isTrue);
    });

    test('expired disk sig is not counted and not hydrated', () async {
      when(
        () => storage.loadWalletSigCookie(address),
      ).thenAnswer((_) async => _jwt(pastExp));

      expect(await auth.hasValidWalletSigForAny([address]), isFalse);
      expect(auth.hasAnyVerifiedSession([address]), isFalse);
    });

    test('no sig on disk → false', () async {
      when(
        () => storage.loadWalletSigCookie(address),
      ).thenAnswer((_) async => null);

      expect(await auth.hasValidWalletSigForAny([address]), isFalse);
      expect(auth.hasAnyVerifiedSession([address]), isFalse);
    });
  });

  // `/v0/login` renders the user PUBLICLY unless the request already carries a
  // valid wallet-sig cookie, and on a cold start it cannot: the login POST goes
  // out before the signature handshake has run. So the privileged fields —
  // perks, the full roles, showNsfw, disabledChains — are absent from the login
  // response every first login. `/v0/authToken/verify` is where ownership is
  // proven and it repeats the user privileged; adopting that render is what
  // stops an owned perk from reading as unowned. The GIF-pfp gate in the edit
  // profile flow denies on `perks` NOT containing the perk, so without this a
  // paying user is told "Animated PFP is locked" on every cold start.
  group('privileged user adoption from /v0/authToken/verify', () {
    const activeAddr = 'WALLET_A';
    const otherAddr = 'WALLET_B';
    const gifPerk = 'gif-pfp';

    late _StubVerifyAdapter adapter;
    late _MockSession session;

    setUpAll(() {
      registerFallbackValue(const AuthTokenRequest(address: activeAddr));
    });

    setUp(() {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

      adapter = _StubVerifyAdapter();
      auth = AuthService(
        api,
        walletManager,
        storage,
        Dio()..httpClientAdapter = adapter,
      );

      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn({activeAddr});
      when(() => session.settingsScopeId()).thenAnswer((_) async => null);
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);

      when(
        () => walletManager.getAddress(),
      ).thenAnswer((_) async => activeAddr);
      // Nothing cached, so login runs the full sign + verify handshake rather
      // than short-circuiting on a disk hit — the cold-start shape.
      when(
        () => storage.loadWalletSigCookie(any()),
      ).thenAnswer((_) async => null);
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
      when(
        () => storage.storeWalletSigCookie(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => walletManager.isLedgerWallet(any()),
      ).thenAnswer((_) async => false);
      when(
        () => walletManager.needsSocialKeyRecovery(any()),
      ).thenAnswer((_) async => false);
      when(
        () => api.getAuthToken(any()),
      ).thenAnswer((_) async => const ApiResponse<String>(result: 'TOKEN'));
      when(
        () => walletManager.signLoginChallengeForAddress(
          any(),
          message: any(named: 'message'),
          token: any(named: 'token'),
        ),
      ).thenAnswer(
        (_) async => const LoginChallengeSignature(
          chain: Chain.solana,
          signature: 'SIG',
        ),
      );
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
    });

    test(
      'a perk absent from the login render is picked up from verify',
      () async {
        await auth.initializeSession();

        // Login alone would have left this empty — the gate would then deny a
        // user who actually owns the perk.
        expect(auth.currentUser?.perks, contains(gifPerk));
        expect(auth.currentUserDetails?.bio, 'privileged');
      },
    );

    test(
      'a non-active wallet\'s verify does not replace the cached user',
      () async {
        await auth.initializeSession();
        adapter.perks = const ['some-other-perk'];

        // verifySessionWallet runs the same handshake for a session wallet that
        // is NOT the active signer. In an Account session that address resolves
        // to a different user server-side, so adopting its render would swap the
        // logged-in identity out from under the app.
        await auth.verifySessionWallet(otherAddr);

        expect(auth.currentUser?.perks, contains(gifPerk));
      },
    );
  });

  // Regression, and the case the group above never reached: the SECOND and
  // every later cold start. `/v0/login` went out before any wallet-sig was in
  // memory, so the backend answered with the public render — and the signature
  // handshake that follows it short-circuits on the still-valid 30-day sig
  // sitting on disk, so `/v0/authToken/verify` never ran and nothing upgraded
  // that render. Two things broke for the whole session:
  //
  //   1. `currentUser.perks` stayed empty, so the edit-profile gate told a user
  //      who owns gif-pfp that "Animated PFP is locked" on every launch.
  //   2. The two settings hydrations mirrored the public render's MISSING
  //      fields — which parse to "no chains disabled" and "NSFW off" — over the
  //      user's real server-side settings, silently re-enabling a chain they had
  //      turned off and re-blurring content they had opted in to.
  //
  // Priming the sig from disk BEFORE the login POST is what fixes both at once:
  // the login is signed, so its own response is the privileged render. The
  // cached sig is still reused — no re-sign, no verify round trip.
  group('privileged render on a returning launch', () {
    const activeAddr = 'WALLET_A';
    const scopeId = 'profile-1';
    const gifPerk = 'gif-pfp';

    late _SignedLoginAdapter adapter;
    late _MockSession session;
    late _MockPrefs prefs;

    setUpAll(() {
      registerFallbackValue(Chain.solana);
      registerFallbackValue(const AuthTokenRequest(address: activeAddr));
    });

    setUp(() {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

      adapter = _SignedLoginAdapter(activeAddr);
      auth = AuthService(
        api,
        walletManager,
        storage,
        Dio()..httpClientAdapter = adapter,
      );

      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn({activeAddr});
      // A Profile session — the only mode that mirrors server settings onto the
      // device at all. An Account session's null scope skips both hydrations.
      when(() => session.settingsScopeId()).thenAnswer((_) async => scopeId);
      prefs = _MockPrefs();
      when(() => prefs.setShowNsfw(any())).thenAnswer((_) async {});

      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);
      if (GetIt.instance.isRegistered<PreferencesService>()) {
        GetIt.instance.unregister<PreferencesService>();
      }
      GetIt.instance.registerSingleton<PreferencesService>(prefs);

      when(
        () => walletManager.getAddress(),
      ).thenAnswer((_) async => activeAddr);
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
      when(
        () => storage.storeWalletSigCookie(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => storage.storeNetworkEnabled(any(), any(), scope: scopeId),
      ).thenAnswer((_) async {});
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      if (GetIt.instance.isRegistered<PreferencesService>()) {
        GetIt.instance.unregister<PreferencesService>();
      }
    });

    /// The returning-launch shape: the 30-day sig from a previous session is
    /// still on disk and still valid, so nothing needs re-signing.
    void withCachedSig() {
      when(
        () => storage.loadWalletSigCookie(activeAddr),
      ).thenAnswer((_) async => _jwt(futureExp));
    }

    test('an owned perk survives a launch that never re-signs', () async {
      withCachedSig();

      await auth.initializeSession();

      // The perk is only in the privileged render, so this passing means the
      // login POST carried the cached sig. Before the fix it read as unowned.
      expect(auth.currentUser?.perks, contains(gifPerk));
      // ...and it cost nothing: re-signing on every launch would defeat the
      // reason the cached sig short-circuits the handshake in the first place.
      expect(
        adapter.verifyCalled,
        isFalse,
        reason: 'a valid cached sig must still skip the re-sign round trip',
      );
    });

    test('a server-disabled chain is not re-enabled by the launch', () async {
      withCachedSig();

      await auth.initializeSession();

      // The user turned Tezos off server-side. The public render omits
      // disabledChains entirely, so the old flow read "[]" and wrote `true`
      // here — turning the chain back on behind the user's back on every launch.
      verify(
        () => storage.storeNetworkEnabled(Chain.tezos, false, scope: scopeId),
      ).called(1);
      verifyNever(
        () => storage.storeNetworkEnabled(Chain.tezos, true, scope: scopeId),
      );
      // Ethereum is genuinely enabled, so mirroring it as enabled is correct —
      // proof the gate suppresses only the values we never received.
      verify(
        () => storage.storeNetworkEnabled(Chain.ethereum, true, scope: scopeId),
      ).called(1);
    });

    test('an opted-in showNsfw is not reset by the launch', () async {
      withCachedSig();

      await auth.initializeSession();

      // Same failure mode as the chain toggle: absent parses as false, so the
      // old flow re-blurred everything for a user who had opted in.
      verify(() => prefs.setShowNsfw(true)).called(1);
      verifyNever(() => prefs.setShowNsfw(false));
    });

    test('the first-ever login mirrors settings only once verify upgrades '
        'the render', () async {
      // No sig anywhere yet — the one path that legitimately has to sign.
      when(
        () => storage.loadWalletSigCookie(any()),
      ).thenAnswer((_) async => null);
      when(
        () => walletManager.isLedgerWallet(any()),
      ).thenAnswer((_) async => false);
      when(
        () => walletManager.needsSocialKeyRecovery(any()),
      ).thenAnswer((_) async => false);
      when(
        () => api.getAuthToken(any()),
      ).thenAnswer((_) async => const ApiResponse<String>(result: 'TOKEN'));
      when(
        () => walletManager.signLoginChallengeForAddress(
          any(),
          message: any(named: 'message'),
          token: any(named: 'token'),
        ),
      ).thenAnswer(
        (_) async => const LoginChallengeSignature(
          chain: Chain.solana,
          signature: 'SIG',
        ),
      );

      await auth.initializeSession();

      expect(adapter.verifyCalled, isTrue, reason: 'nothing to reuse yet');
      expect(auth.currentUser?.perks, contains(gifPerk));
      // `called(1)` is the assertion that matters: the login render was public,
      // so a flow that hydrated from it and then corrected itself would write
      // Tezos twice — `true` first, `false` after. The user's setting must never
      // be written wrong, not even transiently.
      verify(
        () => storage.storeNetworkEnabled(Chain.tezos, false, scope: scopeId),
      ).called(1);
      verifyNever(
        () => storage.storeNetworkEnabled(Chain.tezos, true, scope: scopeId),
      );
      verify(() => prefs.setShowNsfw(true)).called(1);
      verifyNever(() => prefs.setShowNsfw(false));
    });

    test('a wallet that cannot sign never mirrors the public render', () async {
      // A social wallet whose stored key is gone defers its background
      // wallet-sig handshake (recovering the key would force an interactive
      // re-login), so the render stays public for the whole session — there is
      // no privileged render coming to correct a bad write. Withholding the
      // mirror entirely is the only safe answer: the device settings keep
      // whatever the user last chose.
      when(
        () => storage.loadWalletSigCookie(any()),
      ).thenAnswer((_) async => null);
      when(
        () => walletManager.isLedgerWallet(any()),
      ).thenAnswer((_) async => false);
      when(
        () => walletManager.needsSocialKeyRecovery(any()),
      ).thenAnswer((_) async => true);

      await auth.initializeSession();

      expect(adapter.verifyCalled, isFalse);
      verifyNever(
        () => storage.storeNetworkEnabled(Chain.tezos, any(), scope: scopeId),
      );
      verifyNever(() => prefs.setShowNsfw(any()));
    });
  });

  // Regression, post-Web3Auth-migration: social signing became LOCAL and silent
  // (the key is stored on device at sign-in), but the background handshake kept
  // the blanket "social wallets cannot sign" skip from the era when signing a
  // social wallet meant a remote, interactive round trip. A social wallet then
  // had no automatic route to a wallet-sig at all — the 401 retry re-enters this
  // same method, so its skip fired a second time and the retry refreshed
  // nothing. Every ownership-gated read (private curations, hide/download,
  // `disabledChains`) stayed 401 for the whole session until the user happened
  // to tap something that routes through signAndVerifyForWallet.
  //
  // The gate has to stay for a social row whose key is NOT on the device:
  // recovering it opens an OAuth browser tab, and these callers are background
  // paths (post-login warm-up, wallet switch, the 401 interceptor) that must
  // never go interactive.
  group('social wallet background signature verification', () {
    const socialAddr = 'SOCIAL_A';

    late _MockSession session;

    setUpAll(() {
      registerFallbackValue(const AuthTokenRequest(address: socialAddr));
    });

    void registerSession() {
      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn({socialAddr});
      when(() => session.settingsScopeId()).thenAnswer((_) async => null);
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);
    }

    setUp(() {
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
      registerSession();

      when(
        () => walletManager.getAddress(),
      ).thenAnswer((_) async => socialAddr);
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
      when(
        () => storage.storeWalletSigCookie(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => walletManager.isLedgerWallet(any()),
      ).thenAnswer((_) async => false);
      when(
        () => api.getAuthToken(any()),
      ).thenAnswer((_) async => const ApiResponse<String>(result: 'TOKEN'));
      when(
        () => walletManager.signLoginChallengeForAddress(
          any(),
          message: any(named: 'message'),
          token: any(named: 'token'),
        ),
      ).thenAnswer(
        (_) async => const LoginChallengeSignature(
          chain: Chain.solana,
          signature: 'SIG',
        ),
      );
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
    });

    /// The fresh-install / lapsed-sig shape: nothing cached anywhere, so login
    /// has to run the sign + verify handshake or the session never gets a sig.
    void withNoCachedSig() {
      when(
        () => storage.loadWalletSigCookie(any()),
      ).thenAnswer((_) async => null);
    }

    test('a social wallet holding its key signs at login', () async {
      final adapter = _StubVerifyAdapter();
      auth = AuthService(
        api,
        walletManager,
        storage,
        Dio()..httpClientAdapter = adapter,
      );
      withNoCachedSig();
      // Key on device — signing is local and silent, so there is nothing to
      // defer and no reason to make the user tap for it.
      when(
        () => walletManager.needsSocialKeyRecovery(any()),
      ).thenAnswer((_) async => false);

      await auth.initializeSession();

      verify(
        () => walletManager.signLoginChallengeForAddress(
          socialAddr,
          message: any(named: 'message'),
          token: 'TOKEN',
        ),
      ).called(1);
      verify(
        () => storage.storeWalletSigCookie(socialAddr, 'SIGJWT'),
      ).called(1);
    });

    test(
      'a social wallet whose key is gone never signs in the background',
      () async {
        final adapter = _StubVerifyAdapter();
        auth = AuthService(
          api,
          walletManager,
          storage,
          Dio()..httpClientAdapter = adapter,
        );
        withNoCachedSig();
        // No key on device: the signer would recover it by opening an OAuth
        // browser tab. Login must not reach the signer at all — the prompt has to
        // come from a user action (signAndVerifyForWallet), not from a launch.
        when(
          () => walletManager.needsSocialKeyRecovery(any()),
        ).thenAnswer((_) async => true);

        await auth.initializeSession();

        verifyNever(
          () => walletManager.signLoginChallengeForAddress(
            any(),
            message: any(named: 'message'),
            token: any(named: 'token'),
          ),
        );
        verifyNever(() => api.getAuthToken(any()));
        verifyNever(() => storage.storeWalletSigCookie(any(), any()));
        expect(auth.hasAnyVerifiedSession([socialAddr]), isFalse);
      },
    );

    // The half the blanket skip made unreachable: a wallet-sig the backend has
    // stopped accepting (the ~30-day lapse) is repaired by the 401 retry, which
    // re-enters _verifySignatureIfPossible with forceRefresh. forceRefresh only
    // skips the CACHE check, so a skip on the wallet type made the retry a
    // no-op and the second 401 terminal.
    group('401 signature retry', () {
      late _SigLapseAdapter adapter;
      late Dio dio;
      late String freshSig;

      setUp(() {
        // Two distinct-but-unexpired JWTs: the client cannot tell the cached
        // one has gone stale (its own `exp` is still in the future), only the
        // backend can — which is why this lapse surfaces as a 401 rather than
        // as the local expiry check.
        freshSig = _jwt(futureExp + 60);
        adapter = _SigLapseAdapter(socialAddr, freshSig);
        dio = Dio()..httpClientAdapter = adapter;
        auth = AuthService(api, walletManager, storage, dio);
        when(
          () => storage.loadWalletSigCookie(any()),
        ).thenAnswer((_) async => _jwt(futureExp));
      });

      test('re-signs and the retried request carries the new sig', () async {
        when(
          () => walletManager.needsSocialKeyRecovery(any()),
        ).thenAnswer((_) async => false);

        await auth.initializeSession();
        final response = await dio.get<dynamic>('https://api.test/gated');

        expect(response.statusCode, 200);
        expect(adapter.gatedCookies, hasLength(2));
        // The first attempt carried the stale sig and was rejected; the retry
        // carries the one /v0/authToken/verify just issued. Same request, now
        // authorized — which is the whole point of the interceptor.
        expect(
          adapter.gatedCookies.first,
          isNot(contains('wallet-sig-$socialAddr=$freshSig')),
        );
        expect(
          adapter.gatedCookies.last,
          contains('wallet-sig-$socialAddr=$freshSig'),
        );
      });

      test(
        'a key-less social wallet fails the request instead of prompting',
        () async {
          when(
            () => walletManager.needsSocialKeyRecovery(any()),
          ).thenAnswer((_) async => true);

          await auth.initializeSession();

          // Nothing can repair the sig without an interactive re-login, so the
          // 401 surfaces to the caller. That is the correct outcome for a
          // background interceptor: the caller shows an error, and the user's
          // next deliberate action is what opens the login.
          await expectLater(
            dio.get<dynamic>('https://api.test/gated'),
            throwsA(isA<DioException>()),
          );
          verifyNever(
            () => walletManager.signLoginChallengeForAddress(
              any(),
              message: any(named: 'message'),
              token: any(named: 'token'),
            ),
          );
        },
      );
    });
  });

  // Regression: login used to hydrate only the ACTIVE wallet's sig from disk, so
  // after a cold start a NON-active session wallet's sig-gated reads (hidden
  // state, etc.) went out cookieless even though its valid sig sat on disk. A
  // single hydration pass over every session wallet at login must attach them.
  group('session wallet-sig hydration on login', () {
    const activeAddr = 'WALLET_A';
    const otherAddr = 'WALLET_B';

    late _StubLoginAdapter adapter;
    late Dio dio;
    late _MockSession session;

    setUp(() {
      // Point login at a host the stub adapter intercepts, rather than the
      // environment default.
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

      adapter = _StubLoginAdapter();
      dio = Dio()..httpClientAdapter = adapter;
      auth = AuthService(api, walletManager, storage, dio);

      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn({activeAddr, otherAddr});
      when(() => session.settingsScopeId()).thenAnswer((_) async => null);
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);

      when(
        () => walletManager.getAddress(),
      ).thenAnswer((_) async => activeAddr);
      // The active wallet's own sig is already cached on disk, so login's
      // _verifySignatureIfPossible short-circuits (no signing, no network).
      when(
        () => storage.loadWalletSigCookie(activeAddr),
      ).thenAnswer((_) async => _jwt(futureExp));
      // The OTHER session wallet's valid sig also lives only on disk — the
      // cold-start pass must pull it into the in-memory snapshot.
      when(
        () => storage.loadWalletSigCookie(otherAddr),
      ).thenAnswer((_) async => _jwt(futureExp));
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
    });

    test('B\'s valid disk sig is attached to requests after login', () async {
      await auth.initializeSession();

      // A request issued after login must carry B's wallet-sig cookie — proof
      // the hydration pulled it off disk into the in-memory snapshot the Dio
      // interceptor sends. Before this fix only A's cookie rode along.
      await dio.get<dynamic>('https://api.test/probe');

      expect(adapter.lastCookie, isNotNull);
      expect(
        adapter.lastCookie,
        contains('wallet-sig-$otherAddr=${_jwt(futureExp)}'),
      );
    });

    test('every session wallet hydrates on a single post-login request', () async {
      await auth.initializeSession();

      // The hydration pass runs the per-address disk lookups in parallel and
      // refreshes the interceptor once at the end. A single request after login
      // must therefore carry BOTH session wallets' cookies — proof the pass
      // doesn't stop at the first hit and the one final refresh reflects all of
      // them (a per-hit refresh would still land here, but a short-circuit that
      // hydrated only the first wallet would drop one of these cookies).
      await dio.get<dynamic>('https://api.test/probe');

      expect(adapter.lastCookie, isNotNull);
      expect(
        adapter.lastCookie,
        contains('wallet-sig-$activeAddr=${_jwt(futureExp)}'),
      );
      expect(
        adapter.lastCookie,
        contains('wallet-sig-$otherAddr=${_jwt(futureExp)}'),
      );
    });
  });

  // The Dio AuthService installs its interceptor on is the app's ONE shared
  // client: Jupiter's public token search and the rewards-store CDN read
  // through the same instance. `login-token` is the bearer of the logged-in
  // account and each `wallet-sig-<addr>` is a signed proof of wallet
  // ownership, so an unguarded interceptor handed the user's live session to
  // third parties on every one of those reads — a credential disclosure the
  // user cannot see and cannot revoke.
  group('session cookie host guard', () {
    const activeAddr = 'WALLET_A';

    late _StubLoginAdapter adapter;
    late Dio dio;
    late _MockSession session;

    setUp(() {
      // Makes `api.test` the first-party host; every other host below is
      // therefore outside the guard.
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

      adapter = _StubLoginAdapter();
      dio = Dio()..httpClientAdapter = adapter;
      auth = AuthService(api, walletManager, storage, dio);

      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn({activeAddr});
      when(() => session.settingsScopeId()).thenAnswer((_) async => null);
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);

      when(
        () => walletManager.getAddress(),
      ).thenAnswer((_) async => activeAddr);
      when(
        () => storage.loadWalletSigCookie(activeAddr),
      ).thenAnswer((_) async => _jwt(futureExp));
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
    });

    test('the API host receives both session cookies', () async {
      await auth.initializeSession();

      await dio.get<dynamic>('https://api.test/v1/user/profile');

      expect(adapter.lastCookie, contains('login-token=LOGIN_TOK'));
      expect(
        adapter.lastCookie,
        contains('wallet-sig-$activeAddr=${_jwt(futureExp)}'),
      );
    });

    test('no session cookie reaches a non-mallow host', () async {
      await auth.initializeSession();

      // Prove the interceptor is installed and sending, so the two absences
      // below cannot pass because the session simply never came up.
      await dio.get<dynamic>('https://api.test/v1/user/profile');
      expect(adapter.lastCookie, contains('login-token=LOGIN_TOK'));

      // Token search — a public third-party API with no mallow session.
      await dio.get<dynamic>('https://api.jup.ag/tokens/v2/search?query=sol');
      expect(adapter.lastCookie, isNull);

      // Rewards-store metadata — static JSON on a public CDN. Same origin
      // suffix as the API, different host: the guard matches hosts, not
      // domains.
      await dio.get<dynamic>(
        'https://cdn.example.com/store/dev/merch.shirt.foo.json',
      );
      expect(adapter.lastCookie, isNull);
    });

    test('no session cookie reaches a FIRST_PARTY_HOSTS proxy', () async {
      // The session gate is `Config.sessionHosts` (the API hosts), NOT
      // `Config.firstPartyHosts` (those plus `FIRST_PARTY_HOSTS`). The two
      // were briefly the same set, and while they were, declaring a proxy
      // first-party silently started sending it the user's live session.
      //
      // This asserts the wiring, not the getter: pointing
      // `_setupAuthInterceptor` back at `firstPartyHosts` still satisfies
      // every set-level test in client_id_headers_test.dart, and fails here.
      Config.debugOverrides['FIRST_PARTY_HOSTS'] = 'rpc.test,pin.test';
      // Both platform values, so the precondition holds whichever one the
      // test host reads.
      Config.debugOverrides['CLIENT_ID_HEADER'] = 'X-Client';
      Config.debugOverrides['CLIENT_ID_IOS'] = 'example.client';
      Config.debugOverrides['CLIENT_ID_ANDROID'] = 'example.client';

      await auth.initializeSession();

      // The proxy is first-party enough for the client-id header...
      expect(
        Config.clientIdHeadersFor(Uri.parse('https://rpc.test')),
        isNot(isEmpty),
        reason: 'precondition: the host must be inside the client-id gate',
      );

      // ...and still gets no session.
      await dio.get<dynamic>('https://rpc.test/');
      expect(adapter.lastCookie, isNull);

      await dio.get<dynamic>('https://pin.test/upload');
      expect(adapter.lastCookie, isNull);

      // The API host is unaffected — pinning must not break login.
      await dio.get<dynamic>('https://api.test/v1/user/profile');
      expect(adapter.lastCookie, contains('login-token=LOGIN_TOK'));
    });
  });

  // T0.5 of the wallet-switching contract. Since T0.2,
  // `SessionManager.selectSourceWallet` AWAITS `switchWallet`, so a wallet
  // switch is no longer fire-and-forget: whatever the caller dispatches next
  // (burn authority, accept-offer seller, …) reads `currentAddress` the instant
  // the switch resolves. Every test here exists to protect that one instant.
  group('switchWallet concurrency', () {
    const b = 'WALLET_B';
    const c = 'WALLET_C';

    late _GatedLoginAdapter adapter;
    late _MockSession session;

    setUp(() {
      // Point login at a host the stub adapter intercepts, rather than the
      // environment default.
      Config.debugOverrides['API_BASE_URL'] = 'https://api.test';

      adapter = _GatedLoginAdapter();
      auth = AuthService(
        api,
        walletManager,
        storage,
        Dio()..httpClientAdapter = adapter,
      );

      session = _MockSession();
      when(() => session.sessionAddresses).thenReturn(const {});
      when(() => session.settingsScopeId()).thenAnswer((_) async => null);
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(session);

      // A valid cached wallet-sig short-circuits _verifySignatureIfPossible, so
      // login stays a single observable network call per switch.
      when(
        () => storage.loadWalletSigCookie(any()),
      ).thenAnswer((_) async => _jwt(futureExp));
      when(() => storage.storeLoginToken(any())).thenAnswer((_) async {});
      when(() => storage.deleteLoginToken()).thenAnswer((_) async {});
      when(() => storage.deleteSessionExpiry()).thenAnswer((_) async {});
      when(() => storage.deleteAuthToken()).thenAnswer((_) async {});
    });

    tearDown(() {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
    });

    // WHY: two switches to different wallets used to run concurrently —
    // last-login-wins — so the logged-in identity could end up diverging from
    // the persisted wallet selection. A queued switch must not start its
    // own _clearSession()/login until the in-flight one has finished, and the
    // wallet left logged in must be the one requested LAST.
    test(
      'a switch to a different address queues behind the in-flight one',
      () async {
        final switchToB = auth.switchWallet(b);
        await pumpEventQueue();
        expect(adapter.startedLogins, [b], reason: 'B\'s login is in flight');

        final switchToC = auth.switchWallet(c);
        await pumpEventQueue();
        // The whole point: C waits. If it interleaved, its _clearSession() would
        // wipe the session B is mid-way through establishing.
        expect(
          adapter.startedLogins,
          [b],
          reason: 'C must not log in while B is still in flight',
        );

        adapter.release(b);
        await switchToB;
        await pumpEventQueue();
        expect(adapter.startedLogins, [b, c], reason: 'C starts only after B');

        adapter.release(c);
        await switchToC;
        expect(auth.currentAddress, c);
      },
    );

    // WHY (the T0.2 item-3 regression): the null-`currentAddress`-at-dispatch
    // bug. A naive serialization that awaits the in-flight switch BEFORE
    // publishing its own pending address still passes the test above, because
    // during that wait the dedup guard reads the OLD pending address — so a
    // second caller for C sails past dedup and opens its own _clearSession() +
    // login. The first caller then resolves while a duplicate clear/login for C
    // is in flight behind it, and the flow that just awaited the switch reads
    // `currentAddress == null` when it builds its authority field.
    //
    // Publishing the pending address synchronously is what collapses the second
    // caller onto the first. Both assertions below are sampled AT THE MOMENT the
    // first caller resolves — the exact instant a real caller dispatches.
    //
    // Which assertion does the discriminating: the login-dispatch one. Replayed
    // against the naive implementation this sequence dispatches [B, C, C]; the
    // duplicate is visible at the sampling point even though its response never
    // arrives. `currentAddress` is only the *symptom*, and whether it reads null
    // at that instant depends on how the duplicate's _clearSession() interleaves
    // — so it is asserted as the invariant callers actually depend on, not as
    // the detector. Do not drop the login-dispatch assertion for it.
    test(
      'two callers for the same queued address produce exactly one login',
      () async {
        final switchToB = auth.switchWallet(b);
        await pumpEventQueue();
        expect(adapter.startedLogins, [b]);

        String? addressWhenFirstResolved;
        List<String> loginsWhenFirstResolved = const [];

        // Both callers arrive while B is still in flight — the window the naive
        // implementation leaves open (e.g. selectSourceWallet and the app.dart
        // onWalletChanged listener both switching to C).
        final firstC = auth.switchWallet(c).then((result) {
          addressWhenFirstResolved = auth.currentAddress;
          loginsWhenFirstResolved = List.of(adapter.startedLogins);
          return result;
        });
        final secondC = auth.switchWallet(c);
        await pumpEventQueue();

        adapter.release(b);
        await switchToB;
        await pumpEventQueue();
        adapter.release(c);
        await Future.wait([firstC, secondC]);

        expect(
          loginsWhenFirstResolved,
          [b, c],
          reason:
              'a second _clearSession()/login for C must never have been opened',
        );
        expect(
          addressWhenFirstResolved,
          c,
          reason:
              'the caller dispatches here — currentAddress must be C, not null',
        );
        expect(adapter.loginCount(c), 1);
      },
    );

    // WHY: the original per-address dedup (BLoC + app-level listener both
    // calling switchWallet for the same wallet) must survive the queueing
    // change — two logins for one wallet is a wasted round trip and a second
    // session teardown for no reason.
    test(
      'concurrent switches to the same address dedup to one login',
      () async {
        final first = auth.switchWallet(b);
        final second = auth.switchWallet(b);
        await pumpEventQueue();
        expect(adapter.loginCount(b), 1);

        adapter.release(b);
        await Future.wait([first, second]);

        expect(adapter.loginCount(b), 1);
        expect(auth.currentAddress, b);
      },
    );

    // WHY: the guard is cleared in a `finally`, so a failed login must leave no
    // orphaned completer behind. If it did, the next switch would await a
    // completer nobody ever completes and the caller — now a blocking
    // `selectSourceWallet` — would hang forever with no wallet logged in.
    // The error must also reach the caller: T0.2's rollback depends on it.
    test(
      'a failed switch surfaces the error and does not wedge the guard',
      () async {
        adapter
          ..failLogin(b)
          ..release(b)
          ..release(c);

        await expectLater(
          auth.switchWallet(b),
          throwsA(isA<AuthException>()),
          reason: 'the caller must be able to roll back its own selection',
        );
        expect(auth.currentAddress, isNull);

        // The next switch still runs to completion rather than hanging.
        await auth.switchWallet(c);
        expect(auth.currentAddress, c);
        expect(adapter.loginCount(c), 1);
      },
    );

    // WHY: logging out must actually log the user out. A login already on the
    // wire would otherwise land afterwards and re-populate the very session
    // logout just tore down — the user taps Log out, sees the logged-out UI,
    // and is silently signed back in a moment later.
    test(
      'a logout during an in-flight login tears the session back down',
      () async {
        final switching = auth.switchWallet(b);
        await pumpEventQueue();
        expect(adapter.loginCount(b), 1, reason: 'login is on the wire');

        await auth.logout();
        adapter.release(b);

        await expectLater(switching, throwsA(isA<AuthException>()));
        expect(auth.currentAddress, isNull);
      },
    );

    // WHY: the queued switch holds a *local* reference to the in-flight
    // completer, so clearing `_pendingSwitch*` on logout does not stop it — it
    // still falls through to its own _clearSession() + login. Only the
    // generation check does. Without it, logging out while a second wallet is
    // queued logs the user back in as that wallet.
    test('a logout cancels a queued switch instead of logging it in', () async {
      final first = auth.switchWallet(b);
      await pumpEventQueue();
      final queued = auth.switchWallet(c);
      await pumpEventQueue();
      expect(adapter.loginCount(c), 0, reason: 'C is still queued behind B');

      await auth.logout();

      adapter
        ..release(b)
        ..release(c);
      await first.then((_) {}, onError: (_, _) {});
      await expectLater(queued, throwsA(isA<AuthException>()));
      await pumpEventQueue();

      expect(
        adapter.loginCount(c),
        0,
        reason: 'no login for C may be dispatched after logout',
      );
      expect(auth.currentAddress, isNull);
    });

    // WHY: the generation guard must not wedge the service — an explicit
    // sign-in after a logout is a normal flow and has to work.
    test('a switch started after a logout still completes', () async {
      await auth.logout();

      adapter.release(c);
      await auth.switchWallet(c);

      expect(auth.currentAddress, c);
      expect(adapter.loginCount(c), 1);
    });
  });
}
