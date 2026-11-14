import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/hardware_verify_controller.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/moderation/data/moderation_repository.dart';
import 'package:mallow_wallet/features/moderation/screens/blocked_accounts_screen.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/notifications/data/notifications_repository.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

// The background block-list and unread-badge reads, driven by a REAL
// AuthService over a fake backend: login order, the link flow's token swap,
// and the Blocked accounts screen's 401 → sign → list.

class _MockApi extends Mock implements MallowApiClient {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSession extends Mock implements SessionManager {}

class _MockWalletRepo extends Mock implements WalletRepository {}

class _MockAvatars extends Mock implements AvatarService {}

const _walletA = 'WALLET_A';
const _walletB = 'WALLET_B';

/// A JWT whose payload carries an expiry a day out — all [AuthService] reads.
String _jwt(String tag) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m)));
  final exp =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
      1000;
  return '${seg({'alg': 'HS256'})}.${seg({'exp': exp, 'tag': tag})}.sig';
}

/// One signed read the fake backend received.
class _Read {
  _Read(this.path, this.loginAddress, this.requireProof);

  final String path;
  final String? loginAddress;
  final String? requireProof;
}

/// The backend, as far as these reads go. `/v2/session` sets a login token
/// naming the address and `/v0/currentUser` answers for it; `/v2/blocks` and the unread count answer only when the request
/// carries a wallet-sig for that address which the backend accepts (and, like
/// the real routes with `requireProof=true`, a 401 "Signature required"
/// otherwise). Each wallet blocks a different account, so a list shows whose it
/// is.
class _FakeBackend implements HttpClientAdapter {
  /// Wallet-sig values the backend accepts, per address.
  final Map<String, String> acceptedSigs = {};

  /// What `/v0/authToken/verify` issues, per address.
  final Map<String, String> issuedSigs = {};

  final List<_Read> reads = [];
  final List<String> verifies = [];

  /// The address of every `/v2/session`, in order.
  final List<String> logins = [];

  /// Addresses whose login token the backend now treats as expired.
  final Set<String> expiredLogins = {};

  /// The `Cookie` header of the last signed read.
  String? lastCookie;

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
    if (path.endsWith('/v0/currentUser')) {
      return _ok({
        'result': {'user': <String, dynamic>{}},
      });
    }
    if (path.endsWith('/v2/session')) {
      final address = (options.data as Map)['address'] as String;
      logins.add(address);
      return _ok(
        {
          'result': {'address': address},
        },
        setCookie: ['login-token=LOGIN_$address; Path=/'],
      );
    }
    if (path.endsWith('/v0/authToken/verify')) {
      final address = (options.data as Map)['address'] as String;
      verifies.add(address);
      final sig = issuedSigs[address] ?? _jwt('issued-$address');
      acceptedSigs[address] = sig;
      return _ok(
        {'result': <String, dynamic>{}},
        setCookie: ['wallet-sig-$address=$sig; Path=/'],
      );
    }

    final cookie = options.headers['Cookie'] as String? ?? '';
    lastCookie = cookie;
    final login = RegExp(r'login-token=LOGIN_([A-Z_]+)').firstMatch(cookie);
    final address = login?.group(1);
    reads.add(
      _Read(path, address, options.uri.queryParameters['requireProof']),
    );
    if (address == null || expiredLogins.remove(address)) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Please log in'},
        }),
        401,
        headers: _json,
      );
    }
    final accepted = acceptedSigs[address];
    if (accepted == null || !cookie.contains('wallet-sig-$address=$accepted')) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Signature required'},
        }),
        401,
        headers: _json,
      );
    }
    if (path.endsWith('/v2/blocks')) {
      return _ok({
        'result': [
          {'address': 'BLOCKED_BY_$address', 'createdAt': 'now'},
        ],
      });
    }
    if (path.endsWith('/v1/notifications/unread-count')) {
      return _ok({
        'result': {'unreadCount': 1, 'hasUnreadMessages': true},
      });
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
  late _MockSession session;
  late _MockWalletRepo wallets;
  late HardwareVerifyController controller;
  late _FakeBackend backend;
  late Dio dio;
  late AuthService auth;
  late BlockStore blocks;
  late NotificationsRepository notifications;
  late Map<String, String> diskSigs;
  late int sheetRequests;

  setUpAll(() {
    registerFallbackValue(const AuthTokenRequest(address: _walletA));
  });

  void register<T extends Object>(T instance) {
    if (GetIt.instance.isRegistered<T>()) GetIt.instance.unregister<T>();
    GetIt.instance.registerSingleton<T>(instance);
  }

  /// Every wallet is [type]; [diskSigs] is what the device has stored.
  void wire(WalletType type) {
    when(
      () => walletManager.isHardwareWallet(any()),
    ).thenAnswer((_) async => type.isHardware);
    when(() => wallets.getWalletByAddress(any())).thenAnswer(
      (i) async => WalletInfo(
        id: 'id-${i.positionalArguments.first}',
        address: i.positionalArguments.first as String,
        name: 'wallet',
        walletType: type,
        chain: 'solana',
      ),
    );
  }

  setUp(() {
    Config.debugOverrides['API_BASE_URL'] = 'https://api.test';
    api = _MockApi();
    walletManager = _MockWalletManager();
    storage = _MockStorage();
    session = _MockSession();
    wallets = _MockWalletRepo();
    controller = HardwareVerifyController();
    backend = _FakeBackend();
    diskSigs = {};
    sheetRequests = 0;
    controller.requests.listen((r) {
      sheetRequests++;
      r.completer.complete(false);
    });

    when(() => session.sessionAddresses).thenReturn({_walletA});
    when(() => session.settingsScopeId()).thenAnswer((_) async => null);
    register<SessionManager>(session);
    register<WalletRepository>(wallets);
    register<HardwareVerifyController>(controller);

    when(() => walletManager.getAddress()).thenAnswer((_) async => _walletA);
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
    when(() => storage.deleteLoginToken()).thenAnswer((_) async {});
    when(() => storage.deleteSessionExpiry()).thenAnswer((_) async {});
    when(() => storage.deleteAuthToken()).thenAnswer((_) async {});
    when(() => storage.storeSessionExpiry(any())).thenAnswer((_) async {});
    when(
      () => storage.loadWalletSigCookie(any()),
    ).thenAnswer((i) async => diskSigs[i.positionalArguments.first]);
    when(() => storage.storeWalletSigCookie(any(), any())).thenAnswer((
      i,
    ) async {
      diskSigs[i.positionalArguments[0] as String] =
          i.positionalArguments[1] as String;
    });
    when(() => storage.deleteWalletSigCookie(any())).thenAnswer((i) async {
      diskSigs.remove(i.positionalArguments.first);
    });

    dio = Dio()..httpClientAdapter = backend;
    auth = AuthService(api, walletManager, storage, dio);
    blocks = BlockStore(
      ModerationRepository(
        MallowApiV2Client(dio, baseUrl: Config.apiV2BaseUrl),
      ),
      auth,
    );
    notifications = NotificationsRepository(
      MallowApiClient(dio, baseUrl: Config.apiBaseUrl),
      auth,
    );
  });

  tearDown(() {
    blocks.dispose();
    controller.dispose();
    Config.debugOverrides.clear();
    for (final unregister in [
      () => GetIt.instance.unregister<SessionManager>(),
      () => GetIt.instance.unregister<WalletRepository>(),
      () => GetIt.instance.unregister<HardwareVerifyController>(),
    ]) {
      unregister();
    }
  });

  /// A proof both the device and the backend hold for [address].
  void provenOnDisk(String address) {
    final sig = _jwt('disk-$address');
    diskSigs[address] = sig;
    backend.acceptedSigs[address] = sig;
  }

  Iterable<_Read> readsOf(String suffix) =>
      backend.reads.where((r) => r.path.endsWith(suffix));

  group('launch and wallet switch', () {
    // A profile view (block list) and the drawer (badge) can both ask before
    // the launch login lands. The login with a stored proof is what lets them
    // go, and they must go as the logged-in wallet, without any prompt.
    test('a Seed Vault launch with a stored proof loads both reads, '
        'unprompted', () async {
      wire(WalletType.seedVault);
      provenOnDisk(_walletA);

      await blocks.ensureLoaded();
      await notifications.refreshUnreadCount();
      expect(backend.reads, isEmpty, reason: 'no session yet');

      await auth.initializeSession();
      await pumpEventQueue();

      expect(blocks.isBlocked('BLOCKED_BY_$_walletA'), isTrue);
      expect(notifications.hasUnread.value, isTrue);
      expect(readsOf('/v2/blocks').single.loginAddress, _walletA);
      expect(readsOf('/v2/blocks').single.requireProof, 'true');
      expect(readsOf('/unread-count').single.requireProof, 'true');
      expect(sheetRequests, 0);
      expect(backend.verifies, isEmpty, reason: 'nothing was signed');
    });

    test(
      'a Seed Vault launch with no stored proof sends neither read',
      () async {
        wire(WalletType.seedVault);

        await blocks.ensureLoaded();
        await notifications.refreshUnreadCount();
        await auth.initializeSession();
        await pumpEventQueue();

        expect(backend.reads, isEmpty);
        expect(sheetRequests, 0);
      },
    );

    test('a wallet switch reloads both for the new wallet', () async {
      wire(WalletType.seedVault);
      provenOnDisk(_walletA);
      provenOnDisk(_walletB);
      await blocks.ensureLoaded();
      await notifications.refreshUnreadCount();
      await auth.initializeSession();
      await pumpEventQueue();
      expect(blocks.isBlocked('BLOCKED_BY_$_walletA'), isTrue);

      await auth.switchWallet(_walletB);
      await pumpEventQueue();

      expect(blocks.isBlocked('BLOCKED_BY_$_walletA'), isFalse);
      expect(blocks.isBlocked('BLOCKED_BY_$_walletB'), isTrue);
      expect(readsOf('/v2/blocks').last.loginAddress, _walletB);
      expect(readsOf('/unread-count').last.loginAddress, _walletB);
      expect(sheetRequests, 0);
    });
  });

  // The link flow installs the login token of the profile being linked into,
  // without changing the active wallet. A background read sent then would run
  // as that other profile, and its list would be adopted as this one's.
  group('the link flow', () {
    test('no background read goes out while the swapped token is in, and '
        'they run after it is restored', () async {
      wire(WalletType.hd);
      provenOnDisk(_walletA);
      provenOnDisk(_walletB);
      await auth.initializeSession();
      await pumpEventQueue();
      expect(backend.reads, isEmpty, reason: 'nothing asked yet');

      await auth.loginForLinkFlow(_walletB);
      expect(await auth.canSendBackgroundSignedRead(), isFalse);
      await blocks.ensureLoaded();
      await notifications.refreshUnreadCount();
      await pumpEventQueue();
      expect(backend.reads, isEmpty);

      await auth.loginForLinkFlow(_walletA);
      await pumpEventQueue();

      expect(backend.reads, isNotEmpty);
      expect(backend.reads.map((r) => r.loginAddress), everyElement(_walletA));
      expect(blocks.isBlocked('BLOCKED_BY_$_walletA'), isTrue);
      expect(blocks.isBlocked('BLOCKED_BY_$_walletB'), isFalse);
    });
  });

  // The swapped token is still what requests carry until the restore has
  // installed the active wallet's own, so the flag may only drop after that.
  group('the link flow flag comes down only with the own token back', () {
    late bool restoring;
    late List<bool> gateWhileInstalling;

    setUp(() {
      restoring = false;
      gateWhileInstalling = [];
      when(() => storage.storeLoginToken('LOGIN_$_walletA')).thenAnswer((
        _,
      ) async {
        if (restoring) {
          gateWhileInstalling.add(await auth.canSendBackgroundSignedRead());
        }
      });
    });

    Future<void> swapToB() async {
      wire(WalletType.hd);
      provenOnDisk(_walletA);
      provenOnDisk(_walletB);
      await auth.initializeSession();
      await auth.loginForLinkFlow(_walletB);
      await blocks.ensureLoaded();
      await pumpEventQueue();
      expect(backend.reads, isEmpty);
    }

    test('the restore call', () async {
      await swapToB();

      restoring = true;
      await auth.loginForLinkFlow(_walletA);
      await pumpEventQueue();

      expect(gateWhileInstalling, [false]);
      expect(await auth.canSendBackgroundSignedRead(), isTrue);
      expect(readsOf('/v2/blocks').single.loginAddress, _walletA);
    });

    // The link flow signs on hardware, and a Seed Vault approval backgrounds
    // the app: the resume refresh lands mid-flow. Logging the active wallet in
    // there would put its token on approveLinkRequestV2 and link the new
    // wallet to the wrong profile, so the refresh stands down.
    test('a resume refresh() mid-flow keeps the profile token', () async {
      await swapToB();
      final loginsBefore = backend.logins.length;

      await auth.refresh();
      await dio.get<dynamic>('https://api.test/v1/anything');

      expect(backend.logins, hasLength(loginsBefore), reason: 'no re-login');
      expect(backend.reads.last.loginAddress, _walletB);
      expect(await auth.canSendBackgroundSignedRead(), isFalse);

      await auth.loginForLinkFlow(_walletA);
      await pumpEventQueue();
      expect(readsOf('/v2/blocks').single.loginAddress, _walletA);
    });

    // Same hazard on the "Please log in" refresh: mid-flow it re-logs the
    // linked profile in, so the retried request still runs as that profile.
    test(
      'the "Please log in" refresh mid-flow re-logs the linked profile',
      () async {
        await swapToB();
        backend.expiredLogins.add(_walletB);

        await dio.get<dynamic>('https://api.test/v1/anything');

        expect(backend.logins.last, _walletB);
        expect(backend.reads.last.loginAddress, _walletB);
        expect(await auth.canSendBackgroundSignedRead(), isFalse);
        expect(readsOf('/v2/blocks'), isEmpty);
      },
    );
  });

  // When the flow cannot put the active wallet's token back, it drops the
  // swapped one. The session and the proofs stay, the waiting reads run, and
  // the next request logs the ACTIVE wallet in through "Please log in".
  test(
    'abandonLinkFlowToken hands the session back to the active wallet',
    () async {
      wire(WalletType.hd);
      provenOnDisk(_walletA);
      provenOnDisk(_walletB);
      await auth.initializeSession();
      await auth.loginForLinkFlow(_walletB);
      await blocks.ensureLoaded();
      await pumpEventQueue();
      expect(backend.reads, isEmpty);

      await auth.abandonLinkFlowToken();
      // The read, its "Please log in", the re-login and the retry take a few
      // round trips.
      for (
        var i = 0;
        i < 200 && !blocks.isBlocked('BLOCKED_BY_$_walletA');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(auth.linkFlowActive, isFalse);
      expect(auth.loginTokenIsFor(_walletA), isTrue);
      expect(backend.logins.last, _walletA, reason: 'retried as the active');
      expect(readsOf('/v2/blocks').last.loginAddress, _walletA);
      expect(blocks.isBlocked('BLOCKED_BY_$_walletA'), isTrue);
      verify(() => storage.deleteLoginToken()).called(1);
      verifyNever(() => storage.deleteWalletSigCookie(any()));
    },
  );

  // On a launch the listeners cannot hinge on the cached-proof branch's
  // `_refreshAuthInterceptor()`: the login primes the stored proof into memory
  // first, and their own gate reads the disk again, so the authenticated
  // notify already lets them run. Where that call IS the only thing that makes
  // a stored proof count is a wallet whose proof is on disk only, verified
  // after the interceptor is up — a non-active session wallet.
  test('verifySessionWallet puts a disk-only proof on the next request and '
      'announces it', () async {
    wire(WalletType.hd);
    provenOnDisk(_walletA);
    await auth.initializeSession();
    diskSigs[_walletB] = _jwt('disk-$_walletB');
    var changes = 0;
    void onChange() => changes++;
    auth.walletSigChanges.addListener(onChange);

    await auth.verifySessionWallet(_walletB);
    auth.walletSigChanges.removeListener(onChange);
    await dio.get<dynamic>('https://api.test/v1/anything');

    expect(changes, greaterThan(0));
    expect(backend.lastCookie, contains('wallet-sig-$_walletB='));
    expect(backend.verifies, isEmpty, reason: 'the stored proof was used');
  });

  // The screen is opened on purpose, so a refused proof is repaired by the
  // ordinary 401 re-sign and the list is shown — not an empty "You haven't
  // blocked anyone", which is what the backend's no-proof answer looked like
  // before requireProof.
  testWidgets(
    'the Blocked accounts screen re-signs on a 401 and shows the list',
    (tester) async {
      wire(WalletType.hd);
      // The device trusts a proof the backend no longer accepts.
      diskSigs[_walletA] = _jwt('stale');
      final avatars = _MockAvatars();
      when(() => avatars.cachedFile(any())).thenReturn(null);
      when(() => avatars.avatarFile(any())).thenAnswer((_) async => null);
      if (sl.isRegistered<AvatarService>()) sl.unregister<AvatarService>();
      sl.registerSingleton<AvatarService>(avatars);
      if (sl.isRegistered<BlockStore>()) sl.unregister<BlockStore>();
      sl.registerSingleton<BlockStore>(blocks);
      addTearDown(() {
        sl.unregister<AvatarService>();
        sl.unregister<BlockStore>();
      });

      await tester.runAsync(auth.initializeSession);
      // The screen's read runs over real Dio futures, so mount it in the real
      // zone and give them time, then build the result. Wait for the store to
      // publish the retried read's rows rather than for a fixed delay: on a
      // loaded machine the second response can take longer than any short
      // sleep to be parsed and handed back to the screen.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: BlockedAccountsScreen()),
        );
        for (var i = 0; i < 1000 && blocks.blocked.value.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        // The screen's own continuation (its setState) runs after the store's.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      final reads = readsOf('/v2/blocks').toList();
      expect(reads, hasLength(2), reason: 'refused, then retried once signed');
      expect(reads.every((r) => r.requireProof == 'true'), isTrue);
      expect(backend.verifies, [_walletA]);
      expect(find.text('BLOCKED_BY_$_walletA'), findsWidgets);
      expect(find.text('You haven’t blocked anyone'), findsNothing);
    },
  );
}
