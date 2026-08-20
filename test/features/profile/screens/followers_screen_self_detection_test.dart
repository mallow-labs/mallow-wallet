import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/profile/screens/followers_screen.dart';
import 'package:mallow_wallet/features/profile/services/followers_bloc.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _MockAuthService extends Mock implements AuthService {}

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSecureWalletStorage extends Mock implements SecureWalletStorage {}

class _MockPreferencesService extends Mock implements PreferencesService {}

class _MockProfileLookupService extends Mock implements ProfileLookupService {}

class _MockFollowersBloc extends MockBloc<FollowersEvent, FollowersState>
    implements FollowersBloc {}

/// Self-detection in the follower list must span the whole session, not the
/// active signing wallet alone: a session's linked-but-inactive wallet is still
/// the viewer, and offering it a Follow button lets the user follow themselves
/// (a write the backend rejects). Widened via [SessionManager.ownsAddress],
/// which also normalises the owner key so the API's lowercased EVM address
/// matches a checksummed session wallet.
///
/// The session here is a REAL [SessionManager] over mocked stores — stubbing
/// `ownsAddress` on a mock would assert nothing about the widening or the
/// EIP-55 normalisation these tests exist to pin.
void main() {
  const activeAddress = 'SOL_ACTIVE_A';
  const linkedAddress = 'SOL_LINKED_B';
  // Session holds the EIP-55 checksummed form; the API echoes it lowercased.
  const evmChecksummed = '0xAbC0000000000000000000000000000000000001';
  const evmLowercased = '0xabc0000000000000000000000000000000000001';
  const strangerAddress = 'SOL_STRANGER_X';

  late _MockAuthService authService;
  late _MockFollowersBloc bloc;

  WalletInfo wallet(String id, String address, String chain) => WalletInfo(
    id: id,
    address: address,
    name: id,
    walletType: WalletType.hd,
    chain: chain,
    accountId: 'acc-1',
  );

  // The rows' missing-image avatar is a generated identicon (AccountAvatar),
  // which resolves AvatarService via GetIt. An unstubbed mock Dio makes every
  // fetch fail, so rows render the anon fallback.
  setUpAll(() {
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  /// A real [SessionManager] whose session spans the three wallets above, with
  /// [activeAddress] as the active signer.
  Future<SessionManager> buildSession() async {
    final repo = _MockWalletRepository();
    final walletManager = _MockWalletManager();
    final storage = _MockSecureWalletStorage();
    final prefs = _MockPreferencesService();
    final profileLookup = _MockProfileLookupService();

    final wallets = [
      wallet('w-a', activeAddress, 'solana'),
      wallet('w-b', linkedAddress, 'solana'),
      wallet('w-eth', evmChecksummed, 'ethereum'),
    ];
    when(() => repo.getAccountViews()).thenAnswer(
      (_) async => [Account(id: 'acc-1', name: 'Account 01', wallets: wallets)],
    );
    when(() => storage.storeLoginMode(any())).thenAnswer((_) async {});
    when(() => storage.storeSelectedAccountId(any())).thenAnswer((_) async {});
    when(() => storage.deleteActiveProfileId()).thenAnswer((_) async {});
    when(() => walletManager.switchWalletById(any())).thenAnswer((_) async {});
    when(() => prefs.lastSolanaWalletId(any())).thenReturn(null);
    when(
      () => prefs.setLastSolanaWalletId(any(), any()),
    ).thenAnswer((_) async {});

    final session = SessionManager(
      repo,
      walletManager,
      storage,
      prefs,
      profileLookup,
    );
    await session.switchToAccount('acc-1');
    return session;
  }

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() async {
    authService = _MockAuthService();
    bloc = _MockFollowersBloc();
    when(() => authService.currentAddress).thenReturn(activeAddress);

    register<AuthService>(authService);
    register<SessionManager>(await buildSession());
    register<FollowersBloc>(bloc);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<AuthService>();
    drop<SessionManager>();
    drop<FollowersBloc>();
  });

  Future<void> pumpList(
    WidgetTester tester,
    List<api.FollowUser> users, {
    FollowersTab initialTab = FollowersTab.all,
  }) async {
    whenListen(
      bloc,
      const Stream<FollowersState>.empty(),
      initialState: FollowersState.loaded(
        followers: users,
        following: const [],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: FollowersScreen(
          addresses: const [activeAddress],
          initialTab: initialTab,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'a follower held by a non-active session wallet is self — no Follow button',
    (tester) async {
      await pumpList(tester, const [
        api.FollowUser(addresses: [linkedAddress], username: 'linked'),
      ]);

      // Why: the row is the viewer's own linked wallet. Before widening, the
      // active-address-only compare missed it and offered follow-self.
      expect(find.text('@linked'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Unfollow'), findsNothing);
      // Nothing followable left → the bulk affordance is gone too.
      expect(find.text('Follow All'), findsNothing);
    },
  );

  testWidgets('an unrelated address is not self — Follow button still shown', (
    tester,
  ) async {
    await pumpList(tester, const [
      api.FollowUser(addresses: [strangerAddress], username: 'stranger'),
    ]);

    // Why: widening must not swallow real follow targets.
    expect(find.text('@stranger'), findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
    expect(find.text('Follow All'), findsOneWidget);
  });

  testWidgets(
    'an EVM session wallet matches the API\'s lowercased address — self',
    (tester) async {
      await pumpList(tester, const [
        api.FollowUser(addresses: [evmLowercased], username: 'evm-self'),
      ]);

      // Why: the session stores the EIP-55 checksummed form while the API
      // echoes it lowercased — a raw string compare treats the viewer's own
      // EVM wallet as a stranger and offers follow-self. This is the exact bug
      // class `apiOwnerAddress` normalisation inside `ownsAddress` prevents.
      expect(find.text('@evm-self'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(find.text('Follow All'), findsNothing);
    },
  );

  // The profile header's Following count has to land on the Following list,
  // the way the webapp's follower-manager modal opens on its `initialTab` —
  // otherwise both numbers open the same (All) list and the second one is a
  // lie about where it goes.
  testWidgets('an explicit initial tab is selected once the lists resolve', (
    tester,
  ) async {
    await pumpList(tester, const [
      api.FollowUser(addresses: [strangerAddress], username: 'stranger'),
    ], initialTab: FollowersTab.following);

    verify(
      () =>
          bloc.add(const FollowersEvent.changeTab(tab: FollowersTab.following)),
    ).called(1);
  });

  testWidgets('the default entry point leaves the All tab alone', (
    tester,
  ) async {
    await pumpList(tester, const [
      api.FollowUser(addresses: [strangerAddress], username: 'stranger'),
    ]);

    verifyNever(
      () =>
          bloc.add(const FollowersEvent.changeTab(tab: FollowersTab.following)),
    );
    verifyNever(
      () =>
          bloc.add(const FollowersEvent.changeTab(tab: FollowersTab.followers)),
    );
  });
}
