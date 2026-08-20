import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/curations/data/curation_repository.dart';
import 'package:mallow_wallet/features/curations/services/curation_attribution_store.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/all_art_masonry.dart';
import 'package:mallow_wallet/features/profile/screens/curation_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockAuthService extends Mock implements AuthService {}

class MockSessionManager extends Mock implements SessionManager {}

class MockCastBloc extends MockBloc<CastEvent, CastState> implements CastBloc {}

class MockCurationRepository extends Mock implements CurationRepository {}

class MockCurationAttributionStore extends Mock
    implements CurationAttributionStore {}

/// Tap-through from a curation is the ONLY moment the client learns that a
/// purchase should credit a curator — nothing later in the buy flow can
/// reconstruct it. But this screen also renders the home "recommended" rails
/// and exhibitions, which are not curations anyone may be paid for, and the
/// share slug it credits is public on-chain in the resulting memo. So the
/// record must fire on the real path and stay silent on every other.
void main() {
  const owner = 'wallet-owner-A';
  const mint = 'ArtMint11111111111111111111111111111111111';

  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockCastBloc castBloc;
  late MockCurationRepository curationRepository;
  late MockCurationAttributionStore attribution;

  const curationGroup = ArtGroup(
    id: 'curation-1',
    type: ArtGroupType.curation,
    name: 'My Curation',
    thumbnailUrl: null,
    artworkCount: 1,
  );

  final artwork = PortfolioArtwork(
    mintAccount: mint,
    title: 'Sunset',
    imageUrl: '',
    artistName: 'artist',
  );

  api.CurationDetail detail({String? shareSlug}) => api.CurationDetail(
    id: curationGroup.id,
    name: curationGroup.name,
    slug: 'my-curation',
    shareSlug: shareSlug,
    visibility: 'public',
    owner: const api.CurationOwner(address: owner),
  );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(
          Dio(),
          sl<PreferencesService>(),
          const FlutterSecureStorage(),
        ),
      );
    }
  });

  setUp(() {
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    castBloc = MockCastBloc();
    curationRepository = MockCurationRepository();
    attribution = MockCurationAttributionStore();

    when(() => authService.isFollowing(any())).thenReturn(false);
    when(() => authService.currentAddress).thenReturn(owner);
    when(() => sessionManager.sessionAddresses).thenReturn(const {owner});
    whenListen(
      castBloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.idle(),
    );
    when(
      () => attribution.record(
        mintAccount: any(named: 'mintAccount'),
        shareSlug: any(named: 'shareSlug'),
      ),
    ).thenReturn(null);

    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<CastBloc>(castBloc);
    register<CurationRepository>(curationRepository);
    register<CurationAttributionStore>(attribution);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<AuthService>();
    drop<SessionManager>();
    drop<CastBloc>();
    drop<CurationRepository>();
    drop<CurationAttributionStore>();
  });

  /// Mounts the curation screen behind a router (opening an artwork pushes the
  /// detail route) and fires the artwork-tap callback the grid, masonry and
  /// detail view modes all share.
  Future<void> tapArtwork(
    WidgetTester tester, {
    required bool isEphemeral,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => CurationScreen(
            group: curationGroup,
            ownerAddress: owner,
            isEphemeral: isEphemeral,
          ),
        ),
        GoRoute(path: '/artwork/:mint', builder: (_, _) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pump();
    await tester.pump();

    tester.widget<AllArtMasonry>(find.byType(AllArtMasonry)).onTap!(artwork);
    await tester.pumpAndSettle();
  }

  testWidgets('opening an artwork from a real curation records the slug', (
    tester,
  ) async {
    when(() => curationRepository.getCurationById(curationGroup.id)).thenAnswer(
      (_) async => CurationDetailResult(
        detail: detail(shareSlug: 'ABCDEFGH'),
        artworks: [artwork],
      ),
    );

    await tapArtwork(tester, isEphemeral: false);

    verify(
      () => attribution.record(mintAccount: mint, shareSlug: 'ABCDEFGH'),
    ).called(1);
  });

  testWidgets('an ephemeral curation records nothing even with a slug loaded', (
    tester,
  ) async {
    // Recommended rails and exhibitions reuse this screen with a synthetic /
    // borrowed id, and a pull-to-refresh on one still hits `getCurationById`
    // — so a slug can be in hand. `isEphemeral` has to suppress the record on
    // its own, because crediting a curator for a rail nobody curated pays out
    // on a view that never happened.
    when(() => curationRepository.getCurationById(curationGroup.id)).thenAnswer(
      (_) async => CurationDetailResult(
        detail: detail(shareSlug: 'ABCDEFGH'),
        artworks: [artwork],
      ),
    );

    await tapArtwork(tester, isEphemeral: true);

    verifyNever(
      () => attribution.record(
        mintAccount: any(named: 'mintAccount'),
        shareSlug: any(named: 'shareSlug'),
      ),
    );
  });

  testWidgets('a curation with no share slug yet records nothing', (
    tester,
  ) async {
    // Rows created before the backend's share-slug backfill return null. Fail
    // soft — there is no token to put in the memo, and inventing one would
    // credit whichever curation happened to own it.
    when(() => curationRepository.getCurationById(curationGroup.id)).thenAnswer(
      (_) async => CurationDetailResult(detail: detail(), artworks: [artwork]),
    );

    await tapArtwork(tester, isEphemeral: false);

    verifyNever(
      () => attribution.record(
        mintAccount: any(named: 'mintAccount'),
        shareSlug: any(named: 'shareSlug'),
      ),
    );
  });
}
