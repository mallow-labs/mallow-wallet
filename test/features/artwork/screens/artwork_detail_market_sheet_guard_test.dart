import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/market/widgets/market_confirmation_sheet.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/raffle/services/raffle_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/no_verified_list_database.dart';

class MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class MockArtworkBloc extends MockBloc<ArtworkEvent, ArtworkState>
    implements ArtworkBloc {
  // The detail screen subscribes to this in initState to surface like
  // failures; MockBloc only fakes the state stream.
  @override
  Stream<String> get transientErrors => const Stream<String>.empty();
}

class MockRaffleBloc extends MockBloc<RaffleEvent, RaffleState>
    implements RaffleBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockAuthService extends Mock implements AuthService {}

class MockSessionManager extends Mock implements SessionManager {}

class MockArtworkPermissionService extends Mock
    implements ArtworkPermissionService {}

class MockMarketListingRepository extends Mock
    implements MarketListingRepository {}

class MockArtworkEventsRepository extends Mock
    implements ArtworkEventsRepository {}

class MockMarketRealtimeService extends Mock implements MarketRealtimeService {}

class MockUserProfileRepository extends Mock implements UserProfileRepository {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

/// Minimal `TxFlowReady` payload for the artwork buy flow. `estimatedFee`
/// is the only field that varies between emissions so the second emit looks
/// like a simulation refresh (a *changed* `TxFlowReady` payload) — exactly
/// the within-`TxFlowReady` re-emit that once turned into a duplicate sheet.
MarketState _ready({int estimatedFeeLamports = 5000}) {
  return TxFlowReady<MarketPrepData, MarketSuccessData>(
    MarketPrepData(
      transactionsBase64: const ['tx'],
      mintAccount: 'mint-1',
      actionType: 'buy',
      flow: AppFlow.fixedPriceBuy,
      totalCost: const MarketPrice(rawAmount: 1e9),
      estimatedFeeLamports: estimatedFeeLamports,
    ),
  );
}

void main() {
  const mint = 'mint-1';

  late MockMarketBloc marketBloc;
  late MockArtworkBloc artworkBloc;
  late MockRaffleBloc raffleBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockArtworkPermissionService permissionService;
  late MockMarketListingRepository listingRepository;
  late MockMarketRealtimeService realtimeService;
  late MockUserProfileRepository userProfileRepository;
  late MockArtworkEventsRepository eventsRepository;

  const artwork = ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    // Empty so `_ArtworkImage` skips CachedNetworkImage (no network / no
    // path_provider in the widget-test harness).
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
  );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    // `any(named: 'mode')` on getEvents needs a registered fallback for the
    // EventMode enum.
    registerFallbackValue(EventMode.all);
    // The MarketConfirmationSheet's cost breakdown renders FeeDetailsDisclosure,
    // which reads the "fee details expanded" preference from GetIt, so the
    // sheet can't mount without a registered PreferencesService.
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
    // The screen fires analytics on mount / market-flow terminal states. Register
    // an uninitialized AnalyticsService — its track() no-ops (never calls init),
    // so it needs no network/config, just satisfies the sl<AnalyticsService>()
    // lookup.
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
    marketBloc = MockMarketBloc();
    artworkBloc = MockArtworkBloc();
    raffleBloc = MockRaffleBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    permissionService = MockArtworkPermissionService();
    listingRepository = MockMarketListingRepository();
    realtimeService = MockMarketRealtimeService();
    userProfileRepository = MockUserProfileRepository();
    eventsRepository = MockArtworkEventsRepository();

    // ArtworkBloc holds the loaded artwork so the screen's MarketBloc
    // listener reaches the `_showConfirmationSheet` branch.
    whenListen(
      artworkBloc,
      const Stream<ArtworkState>.empty(),
      initialState: const ArtworkState.loaded(artwork: artwork),
    );
    whenListen(
      raffleBloc,
      const Stream<RaffleState>.empty(),
      initialState: const RaffleState.initial(),
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    // No connected wallet — short-circuits the edition-stats / user-offer
    // loaders so we don't need to stub those repositories.
    when(() => authService.currentAddress).thenReturn(null);
    // Empty session — the action-state resolver reads this synchronously in
    // build to widen ownership across the session's wallets.
    when(() => sessionManager.sessionAddresses).thenReturn(const {});

    // Build-path side-effect loaders: keep them inert (never resolve / empty)
    // so they don't drive extra rebuilds during the test.
    when(
      () => permissionService.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenAnswer((_) => Completer<ArtworkPermissions>().future);
    when(
      () => listingRepository.getEditionState(any()),
    ).thenAnswer((_) async => null);
    when(
      () => realtimeService.watchMint(any()),
    ).thenAnswer((_) => const Stream<MarketInvalidation>.empty());
    when(
      () => userProfileRepository.getUserProfiles(any()),
    ).thenAnswer((_) async => <String, UserProfile?>{});
    // The History tab fetches activity on mount — keep it empty so the
    // section renders its empty state without driving extra rebuilds.
    when(
      () => eventsRepository.getEvents(
        mintAccount: any(named: 'mintAccount'),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((_) async => const MarketActivityEventsPage());

    register<MarketBloc>(marketBloc);
    register<ArtworkBloc>(artworkBloc);
    register<RaffleBloc>(raffleBloc);
    register<TokenBalanceBloc>(tokenBalanceBloc);
    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<ArtworkPermissionService>(permissionService);
    register<MarketListingRepository>(listingRepository);
    register<MarketRealtimeService>(realtimeService);
    register<UserProfileRepository>(userProfileRepository);
    register<ArtworkEventsRepository>(eventsRepository);
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
    // Every price row on these sheets resolves its currency through this
    // service. The fixtures are all registry-priced, so it short-circuits on
    // the static table and never issues a DAS request — it only has to exist.
    if (!sl.isRegistered<TokenMetadataService>()) {
      sl.registerLazySingleton<TokenMetadataService>(
        () => TokenMetadataService(
          DasApiService(),
          sl<PreferencesService>(),
          NoVerifiedListDatabase(),
        ),
      );
    }
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<MarketBloc>();
    drop<ArtworkBloc>();
    drop<RaffleBloc>();
    drop<TokenBalanceBloc>();
    drop<AuthService>();
    drop<ArtworkPermissionService>();
    drop<MarketListingRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
  });

  testWidgets(
    'repeated TxFlowReady re-emits open the market confirmation sheet only once',
    (tester) async {
      // Generous surface so the full artwork-detail scaffold lays out
      // without overflow assertions.
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Idle → Ready(initial) → Ready(simulation refresh). The second emit
      // is a *changed* TxFlowReady payload, so `marketArtworkListenWhen`
      // fires the listener again — the regression scenario.
      whenListen(
        marketBloc,
        Stream<MarketState>.fromIterable([
          _ready(),
          _ready(estimatedFeeLamports: 7500),
        ]),
        initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: const ArtworkDetailScreen(mintAccount: mint),
        ),
      );
      // Let both stream emissions flush and the sheet route build/settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Without the `_marketSheetActive` guard the second re-emit stacks a
      // second confirmation sheet; the guard keeps it at one.
      expect(find.byType(MarketConfirmationSheet), findsOneWidget);
    },
  );
}
