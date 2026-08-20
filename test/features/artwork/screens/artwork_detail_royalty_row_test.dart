import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/data/offer_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
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

class MockOfferRepository extends Mock implements OfferRepository {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

/// The Details tab's Royalties row is a trust surface: it must never state an
/// affirmative `0%` for a royalty the app has not actually resolved. Indexed
/// `sellerFeeBasisPoints` of 0/absent is common for Core / pNFT artworks whose
/// royalty lives only in an on-chain plugin, so the row falls back to the
/// [ArtworkPermissionService] read — and has to render each of that read's
/// outcomes differently. These four tests pin exactly that mapping; if any of
/// them starts rendering `0%`, the app is understating a real royalty to a
/// buyer.
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
  late MockOfferRepository offerRepository;

  /// [royaltyPercent] null models "the index reports no seller fee" — the
  /// state that hands the decision to the on-chain read.
  ArtworkDetails artworkWith({String? royaltyPercent}) => ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    // Empty so `_ArtworkImage` skips CachedNetworkImage (no network / no
    // path_provider in the widget-test harness).
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    royaltyPercent: royaltyPercent,
  );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(EventMode.all);
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
    offerRepository = MockOfferRepository();

    whenListen(
      marketBloc,
      const Stream<MarketState>.empty(),
      initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
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

    when(() => authService.currentAddress).thenReturn(null);
    when(() => sessionManager.sessionAddresses).thenReturn(const {});
    when(
      () => listingRepository.getEditionState(any()),
    ).thenAnswer((_) async => null);
    when(
      () => realtimeService.watchMint(any()),
    ).thenAnswer((_) => const Stream<MarketInvalidation>.empty());
    when(
      () => userProfileRepository.getUserProfiles(any()),
    ).thenAnswer((_) async => <String, UserProfile?>{});
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
    register<OfferRepository>(offerRepository);
    when(
      () => offerRepository.getUserActiveOffer(
        mintAccount: any(named: 'mintAccount'),
        buyerAddresses: any(named: 'buyerAddresses'),
      ),
    ).thenAnswer((_) async => null);
    if (!sl.isRegistered<TxLandedSlots>()) {
      sl.registerLazySingleton<TxLandedSlots>(TxLandedSlots.new);
    }
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
    drop<SessionManager>();
    drop<ArtworkPermissionService>();
    drop<MarketListingRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
    drop<OfferRepository>();
  });

  /// Mount the detail screen and open the Details tab (the info-tabs widget
  /// only builds its active tab, and Description is index 0).
  Future<void> openDetailsTab(
    WidgetTester tester, {
    required ArtworkDetails artwork,
    required Future<ArtworkPermissions> Function() permissions,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    whenListen(
      artworkBloc,
      const Stream<ArtworkState>.empty(),
      initialState: ArtworkState.loaded(artwork: artwork),
    );
    when(
      () => permissionService.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenAnswer((_) => permissions());

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const ArtworkDetailScreen(mintAccount: mint),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.ensureVisible(find.text('Details'));
    await tester.tap(find.text('Details'));
    // The cross-fade swaps the visible index only after its reverse leg
    // completes, so this needs several frames, not one long one.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// A resolved read that carries [bps] as the on-chain royalty.
  ArtworkPermissions resolved(int? bps) => ArtworkPermissions(
    canTransfer: false,
    canEdit: false,
    canBurn: false,
    canList: false,
    onChainRoyaltyBps: bps,
  );

  testWidgets('indexed seller fee renders immediately, without waiting on the '
      'on-chain read', (tester) async {
    // The on-chain read never resolves: an indexed royalty must not be
    // gated behind it.
    await openDetailsTab(
      tester,
      artwork: artworkWith(royaltyPercent: '10'),
      permissions: () => Completer<ArtworkPermissions>().future,
    );

    expect(find.text('Royalties'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets(
    'no indexed fee + on-chain read in flight renders a placeholder',
    (tester) async {
      await openDetailsTab(
        tester,
        artwork: artworkWith(),
        permissions: () => Completer<ArtworkPermissions>().future,
      );

      // The row is present (so it doesn't pop in later) but claims nothing —
      // pre-fix this rendered "Royalties 0%".
      expect(find.text('Royalties'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    },
  );

  testWidgets('a resolved on-chain read of zero renders a confirmed 0%', (
    tester,
  ) async {
    await openDetailsTab(
      tester,
      artwork: artworkWith(),
      permissions: () async => resolved(0),
    );

    expect(find.text('Royalties'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('a resolved on-chain plugin royalty renders that value', (
    tester,
  ) async {
    // The whole point of the fallback: the index says nothing, the Core /
    // pNFT plugin says 5%.
    await openDetailsTab(
      tester,
      artwork: artworkWith(),
      permissions: () async => resolved(500),
    );

    expect(find.text('5%'), findsOneWidget);
  });

  testWidgets('the optimistic post-buy owner flip keeps the resolved on-chain '
      'royalty', (tester) async {
    // The buy-success listener replaces `_permissions` with an optimistic
    // owner-can-list value so the buyer gets "List artwork" without waiting on
    // the indexer. That value is a RESOLVED read as far as this row is
    // concerned, so it must carry the on-chain royalty forward — built as a
    // `const ArtworkPermissions(...)` it dropped the bps and flipped a real 5%
    // Core/pNFT plugin royalty to a confident "0%" the instant the buy landed.
    final marketStates = StreamController<MarketState>();
    addTearDown(marketStates.close);
    whenListen(
      marketBloc,
      marketStates.stream,
      initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
    );
    // The 1/1 buy branch only runs for a connected wallet.
    when(() => authService.currentAddress).thenReturn('buyer-addr');

    await openDetailsTab(
      tester,
      artwork: artworkWith(),
      permissions: () async => resolved(500),
    );
    expect(find.text('5%'), findsOneWidget);

    marketStates.add(
      const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'sig-1',
        result: MarketSuccessData(
          explorerUrl: 'https://explorer/tx/sig-1',
          actionType: 'buy',
          mintAccount: mint,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('5%'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('a failed on-chain read hides the Royalties row entirely', (
    tester,
  ) async {
    await openDetailsTab(
      tester,
      artwork: artworkWith(),
      permissions: () async => const UnresolvedArtworkPermissions(),
    );

    // Details tab is open (other rows render) but Royalties is gone — better
    // no answer than a wrong one.
    expect(find.text('Mint address'), findsOneWidget);
    expect(find.text('Royalties'), findsNothing);
    expect(find.text('—'), findsNothing);
  });
}
