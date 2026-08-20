import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/screens/portfolio_group_screen.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
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

class _MockPortfolioRepository extends Mock implements PortfolioRepository {}

class _MockUserProfileRepository extends Mock
    implements UserProfileRepository {}

class _MockArtworkPermissionService extends Mock
    implements ArtworkPermissionService {}

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

/// Creator gating on the collection drilldown must span the whole session, not
/// the active signer alone: the drilldown aggregates art across every session
/// wallet, so a collection created by a linked-but-inactive wallet is still the
/// viewer's and must keep its creator rows (Sync token / Export holders /
/// Edit / Burn). An unrelated creator must still be gated off.
///
/// The session here is a REAL [SessionManager] over mocked stores — stubbing
/// `ownsAddress` on a mock would assert nothing about the widening itself.
void main() {
  const activeAddress = 'SOL_ACTIVE_A';
  const linkedAddress = 'SOL_LINKED_B';
  const strangerAddress = 'SOL_STRANGER_X';
  const mint = 'COLLECTION_MINT';

  late _MockAuthService authService;
  late _MockPortfolioRepository portfolioRepo;
  late _MockUserProfileRepository profileRepo;
  late _MockArtworkPermissionService permissions;
  late _MockPreferencesService prefs;
  late _MockCastBloc castBloc;

  WalletInfo wallet(String id, String address) => WalletInfo(
    id: id,
    address: address,
    name: id,
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acc-1',
  );

  ArtGroup groupFor(String? creator) => ArtGroup(
    id: 'group-1',
    type: ArtGroupType.collection,
    name: 'A Collection',
    thumbnailUrl: null,
    artworkCount: 0,
    artistAddress: creator,
    collectionMint: mint,
  );

  setUpAll(() {
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  /// A real [SessionManager] spanning the active and the linked wallet, with
  /// [activeAddress] as the active signer.
  Future<SessionManager> buildSession() async {
    final repo = _MockWalletRepository();
    final walletManager = _MockWalletManager();
    final storage = _MockSecureWalletStorage();
    final sessionPrefs = _MockPreferencesService();
    final profileLookup = _MockProfileLookupService();

    when(() => repo.getAccountViews()).thenAnswer(
      (_) async => [
        Account(
          id: 'acc-1',
          name: 'Account 01',
          wallets: [wallet('w-a', activeAddress), wallet('w-b', linkedAddress)],
        ),
      ],
    );
    when(() => storage.storeLoginMode(any())).thenAnswer((_) async {});
    when(() => storage.storeSelectedAccountId(any())).thenAnswer((_) async {});
    when(() => storage.deleteActiveProfileId()).thenAnswer((_) async {});
    when(() => walletManager.switchWalletById(any())).thenAnswer((_) async {});
    when(() => sessionPrefs.lastSolanaWalletId(any())).thenReturn(null);
    when(
      () => sessionPrefs.setLastSolanaWalletId(any(), any()),
    ).thenAnswer((_) async {});

    final session = SessionManager(
      repo,
      walletManager,
      storage,
      sessionPrefs,
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
    portfolioRepo = _MockPortfolioRepository();
    profileRepo = _MockUserProfileRepository();
    permissions = _MockArtworkPermissionService();
    prefs = _MockPreferencesService();
    castBloc = _MockCastBloc();

    // The screen's now-casting bar resolves CastBloc from GetIt; keep the cast
    // session idle so "Add to cast" never joins the sheet's row set.
    whenListen(
      castBloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.idle(),
    );

    when(() => authService.currentAddress).thenReturn(activeAddress);
    when(() => authService.isFollowing(any())).thenReturn(false);
    when(
      () => portfolioRepo.getGroupArtworks(any(), page: any(named: 'page')),
    ).thenAnswer(
      (_) async => const PortfolioArtworksResult(artworks: [], total: 0),
    );
    // Device-wide ownership is empty so the sheet's creator flag is decided by
    // the session predicate alone, not by the `owned.contains(creator)` fallback.
    when(
      () => permissions.ownedAddresses(),
    ).thenAnswer((_) async => <String>{});
    // The screen calls this positionally (no `sessionAddresses`), so the stub
    // must match that shape — mocktail matches named args by exact key set.
    when(
      () => permissions.checkPermissions(any()),
    ).thenAnswer((_) async => ArtworkPermissions.none);
    when(
      () => profileRepo.getCollectionByMint(any()),
    ).thenAnswer((_) async => null);

    register<AuthService>(authService);
    register<PreferencesService>(prefs);
    register<PortfolioRepository>(portfolioRepo);
    register<UserProfileRepository>(profileRepo);
    register<ArtworkPermissionService>(permissions);
    register<CastBloc>(castBloc);
    register<SessionManager>(await buildSession());
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<AuthService>();
    drop<PreferencesService>();
    drop<PortfolioRepository>();
    drop<UserProfileRepository>();
    drop<ArtworkPermissionService>();
    drop<CastBloc>();
    drop<SessionManager>();
  });

  /// Mounts the drilldown for a collection created by [creator] and opens the
  /// kebab menu.
  Future<void> openCollectionMenu(WidgetTester tester, String creator) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: PortfolioGroupScreen(group: groupFor(creator)),
      ),
    );
    await tester.pump();

    final kebab = find.byWidgetPredicate(
      (w) =>
          w is SvgPicture &&
          w.bytesLoader is SvgAssetLoader &&
          (w.bytesLoader as SvgAssetLoader).assetName.contains('dots_vertical'),
    );
    await tester.tap(
      find.ancestor(of: kebab, matching: find.byType(GestureDetector)).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Pops the open sheet while the tree is still mounted so the module-global
  /// `runGuardedSheet` key is released for the next test.
  Future<void> closeSheet(WidgetTester tester) async {
    final nav = tester.firstState<NavigatorState>(find.byType(Navigator));
    if (nav.canPop()) nav.pop();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'collection created by a non-active session wallet keeps the creator rows',
    (tester) async {
      await openCollectionMenu(tester, linkedAddress);

      // Why: the drilldown spans every session wallet, so gating on the active
      // signer alone hid Sync/Export/Edit/Burn from the user's own collection
      // whenever a linked wallet created it.
      expect(find.text('Sync token'), findsOneWidget);
      expect(find.text('Export holders'), findsOneWidget);
      expect(find.text('Edit collection'), findsOneWidget);
      expect(find.text('Burn collection'), findsOneWidget);

      await closeSheet(tester);
    },
  );

  testWidgets('collection created by an unrelated address stays gated off', (
    tester,
  ) async {
    await openCollectionMenu(tester, strangerAddress);

    // Why: widening must not hand creator controls to a viewer who merely
    // holds a piece from the collection — those writes would fail on-chain.
    expect(find.text('Sync token'), findsNothing);
    expect(find.text('Export holders'), findsNothing);
    expect(find.text('Edit collection'), findsNothing);
    expect(find.text('Burn collection'), findsNothing);
    // The non-creator rows still render, proving the sheet actually opened.
    expect(find.text('Share collection'), findsOneWidget);

    await closeSheet(tester);
  });
}
