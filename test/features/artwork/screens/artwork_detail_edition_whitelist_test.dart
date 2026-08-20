import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_account_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/data/offer_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/market/data/whitelist_eligibility_repository.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/raffle/services/raffle_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
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

class MockMarketAccountRepository extends Mock
    implements MarketAccountRepository {}

class MockWhitelistEligibilityRepository extends Mock
    implements WhitelistEligibilityRepository {}

class MockOfferRepository extends Mock implements OfferRepository {}

class MockArtworkEventsRepository extends Mock
    implements ArtworkEventsRepository {}

class MockMarketRealtimeService extends Mock implements MarketRealtimeService {}

class MockUserProfileRepository extends Mock implements UserProfileRepository {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockDio extends Mock implements Dio {}

/// Regression suite for the artwork-detail screen's **on-chain whitelist
/// phase** loaders (`_maybeLoadEditionStats` →
/// `_maybeLoadEditionWhitelistEligibility` in
/// `artwork_detail_screen/loaders.dart`).
///
/// Both verdicts are per-wallet answers with a single consumer,
/// [isWhitelistPhaseBlocked], which decides whether the edition sheet's Buy CTA
/// is live. The two properties pinned here are the ones that decide whether the
/// CTA can be *wrong*:
///
///  1. a verdict may never outlive the wallet it describes, and
///  2. a closed phase must cost no round-trips, since its verdicts can't
///     change any outcome.
void main() {
  const mint = 'mint-1';
  const walletA = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const walletB = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';
  const walletsRoot = 'merkle-root';
  const listingPda = 'listing-pda';

  late MockMarketBloc marketBloc;
  late MockArtworkBloc artworkBloc;
  late MockRaffleBloc raffleBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockArtworkPermissionService permissionService;
  late MockMarketListingRepository listingRepository;
  late MockMarketAccountRepository accountRepository;
  late MockWhitelistEligibilityRepository whitelistRepository;
  late MockOfferRepository offerRepository;
  late MockMarketRealtimeService realtimeService;
  late MockUserProfileRepository userProfileRepository;
  late MockArtworkEventsRepository eventsRepository;
  late MockSessionPortfolioAggregator aggregator;

  /// The live signer. Moved by the test to simulate a wallet switch.
  late String? active;

  /// Drives the rebuild that a wallet switch would produce in the app (nothing
  /// on this screen listens to `AuthService` directly — the next bloc emission
  /// is what re-runs the build-path loaders).
  late StreamController<ArtworkState> artworkStates;

  /// One completer per wallet, so a verdict can be held in flight for exactly
  /// the window this suite is about.
  late Map<String, Completer<bool?>> allowlistCalls;
  late Map<String, Completer<bool?>> holderCalls;

  /// A printable master edition listed buy-now — the only shape that routes to
  /// [ArtworkBuyEditionSheet], the sole consumer of the two verdicts.
  ArtworkDetails edition({String description = 'desc'}) => ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    // Empty so the image widget skips the network (no path_provider here).
    imageUrl: '',
    description: description,
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    listingType: ListingType.buyNow,
    supplyType: SupplyType.limitedEdition,
    isMasterEdition: true,
    price: 1000000000,
    currency: solMint,
    ownerAddress: 'someone-else',
    ownerAddresses: const ['someone-else'],
  );

  EditionPurchaseStats stats({required bool phaseActive}) =>
      EditionPurchaseStats(
        whitelistConfig: EditionWhitelistConfig(
          walletsRoot: walletsRoot,
          isActive: phaseActive,
        ),
      );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(EventMode.all);
    registerFallbackValue(Chain.solana);
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
    // See artwork_detail_funding_switch_test.dart: without an AvatarService the
    // profile strips render an ErrorWidget that pushes the CTAs out of view.
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  setUp(() {
    active = walletA;
    allowlistCalls = {};
    holderCalls = {};

    marketBloc = MockMarketBloc();
    artworkBloc = MockArtworkBloc();
    raffleBloc = MockRaffleBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    permissionService = MockArtworkPermissionService();
    listingRepository = MockMarketListingRepository();
    accountRepository = MockMarketAccountRepository();
    whitelistRepository = MockWhitelistEligibilityRepository();
    offerRepository = MockOfferRepository();
    realtimeService = MockMarketRealtimeService();
    userProfileRepository = MockUserProfileRepository();
    eventsRepository = MockArtworkEventsRepository();
    aggregator = MockSessionPortfolioAggregator();
    artworkStates = StreamController<ArtworkState>.broadcast();

    whenListen(
      artworkBloc,
      artworkStates.stream,
      initialState: ArtworkState.loaded(artwork: edition()),
    );
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
      initialState: TokenBalanceState.loaded(
        tokens: [TokenBalance.nativeSol(lamports: 5000000000)],
        totalUsdValue: 0,
        address: walletA,
      ),
    );

    when(() => authService.currentAddress).thenAnswer((_) => active);
    when(() => sessionManager.sessionAddresses).thenReturn(const {});

    // Build-path loaders that are not under test: inert.
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
    when(
      () => eventsRepository.getEvents(
        mintAccount: any(named: 'mintAccount'),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((_) async => const MarketActivityEventsPage());
    when(
      () => offerRepository.getHighestOffer(
        mintAccount: any(named: 'mintAccount'),
      ),
    ).thenAnswer((_) async => null);
    when(
      () => offerRepository.getUserActiveOffer(
        mintAccount: any(named: 'mintAccount'),
        buyerAddresses: any(named: 'buyerAddresses'),
      ),
    ).thenAnswer((_) async => null);
    // One funding candidate → no "Switch" line; the switch under test is done
    // at the AuthService level, not through the picker.
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async => const []);

    when(
      () => accountRepository.deriveListingPda(any()),
    ).thenAnswer((_) async => listingPda);
    when(
      () => whitelistRepository.isWalletAllowlisted(
        walletsRoot: any(named: 'walletsRoot'),
        address: any(named: 'address'),
      ),
    ).thenAnswer((invocation) {
      final address = invocation.namedArguments[#address] as String;
      return (allowlistCalls[address] ??= Completer<bool?>()).future;
    });
    when(
      () => whitelistRepository.holdsGatingNft(
        listingPda: any(named: 'listingPda'),
        address: any(named: 'address'),
      ),
    ).thenAnswer((invocation) {
      final address = invocation.namedArguments[#address] as String;
      return (holderCalls[address] ??= Completer<bool?>()).future;
    });

    register<MarketBloc>(marketBloc);
    register<ArtworkBloc>(artworkBloc);
    register<RaffleBloc>(raffleBloc);
    register<TokenBalanceBloc>(tokenBalanceBloc);
    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<ArtworkPermissionService>(permissionService);
    register<MarketListingRepository>(listingRepository);
    register<MarketAccountRepository>(accountRepository);
    register<WhitelistEligibilityRepository>(whitelistRepository);
    register<OfferRepository>(offerRepository);
    register<MarketRealtimeService>(realtimeService);
    register<UserProfileRepository>(userProfileRepository);
    register<ArtworkEventsRepository>(eventsRepository);
    register<SessionPortfolioAggregator>(aggregator);
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

  tearDown(() async {
    await artworkStates.close();
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
    drop<MarketAccountRepository>();
    drop<WhitelistEligibilityRepository>();
    drop<OfferRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
    drop<SessionPortfolioAggregator>();
  });

  /// Pumps in fixed steps — never `pumpAndSettle`, the screen keeps shimmer
  /// placeholders animating indefinitely.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const ArtworkDetailScreen(mintAccount: mint),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'a wallet switch drops the previous wallet\'s whitelist verdicts before '
    'the replacement fetches land',
    (tester) async {
      when(
        () => listingRepository.getEditionPurchaseStats(
          mint: any(named: 'mint'),
          buyer: any(named: 'buyer'),
        ),
      ).thenAnswer((_) async => stats(phaseActive: true));

      await pumpScreen(tester);

      // Wallet A is definitively excluded on both paths — the only verdict
      // combination that blocks.
      allowlistCalls[walletA]!.complete(false);
      holderCalls[walletA]!.complete(false);
      await settle(tester);
      expect(find.text('Not allowlisted'), findsOneWidget);

      // Switch to B and rebuild. B's own verdicts are deliberately left in
      // flight: this is the whole window the fix is about.
      active = walletB;
      artworkStates.add(
        ArtworkState.loaded(artwork: edition(description: 'refreshed')),
      );
      await settle(tester);

      // A's exclusion says nothing about B. Carrying it over blocks a wallet
      // that may well be allowlisted (and, in the mirror case, vouches for one
      // that isn't) until B's fetches resolve.
      expect(find.text('Not allowlisted'), findsNothing);
      expect(find.text('Buy edition'), findsOneWidget);
      expect(allowlistCalls.containsKey(walletB), isTrue);

      // B's real answer still governs once it lands.
      allowlistCalls[walletB]!.complete(false);
      holderCalls[walletB]!.complete(false);
      await settle(tester);
      expect(find.text('Not allowlisted'), findsOneWidget);
    },
  );

  testWidgets('an inactive whitelist phase fires no eligibility round-trips', (
    tester,
  ) async {
    when(
      () => listingRepository.getEditionPurchaseStats(
        mint: any(named: 'mint'),
        buyer: any(named: 'buyer'),
      ),
    ).thenAnswer((_) async => stats(phaseActive: false));

    await pumpScreen(tester);

    // `isWhitelistPhaseBlocked` short-circuits on `phaseActive == false`, so
    // neither verdict can change the CTA — fetching them is pure cost on every
    // open of every edition whose allowlist window has closed.
    verifyNever(
      () => whitelistRepository.isWalletAllowlisted(
        walletsRoot: any(named: 'walletsRoot'),
        address: any(named: 'address'),
      ),
    );
    verifyNever(() => accountRepository.deriveListingPda(any()));
    verifyNever(
      () => whitelistRepository.holdsGatingNft(
        listingPda: any(named: 'listingPda'),
        address: any(named: 'address'),
      ),
    );
    expect(find.text('Buy edition'), findsOneWidget);
  });
}
