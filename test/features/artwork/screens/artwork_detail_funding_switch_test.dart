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
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/data/offer_repository.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/raffle/data/raffle_repository.dart';
import 'package:mallow_wallet/features/raffle/services/raffle_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

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

class MockWalletRepository extends Mock implements WalletRepository {}

class MockOfferRepository extends Mock implements OfferRepository {}

class MockArtworkPermissionService extends Mock
    implements ArtworkPermissionService {}

class MockMarketListingRepository extends Mock
    implements MarketListingRepository {}

class MockRaffleRepository extends Mock implements RaffleRepository {}

class MockArtworkEventsRepository extends Mock
    implements ArtworkEventsRepository {}

class MockMarketRealtimeService extends Mock implements MarketRealtimeService {}

class MockUserProfileRepository extends Mock implements UserProfileRepository {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockDio extends Mock implements Dio {}

/// Regression suite for the source-wallet affordance on the artwork
/// **funding** flows (buy / make offer / place bid / raffle tickets).
///
/// These are the only wallet-switching flows on the
/// `AuthService.currentAddress` side of the fault line (the wallet-switching
/// race) — their dispatches reach `MarketplaceActionFlow.prepare`, which reads
/// the address of the last `/v0/login`, not the DB selection. So every dispatch
/// assertion here records `currentAddress` **at the moment the bloc event is
/// dispatched**. Asserting merely that `selectSourceWallet` was called passes
/// while the flow is broken: the switch nulls `currentAddress` for the whole
/// `/v0/login` round trip, and only the awaited login closes that window.
/// Permissive kill-switch config. The entry gates added in Phase 4c read
/// [RemoteConfigService] before dispatching, so it must be in GetIt; nothing
/// is killed here, which keeps behaviour identical to the pre-kill-switch
/// baseline these tests were written against.
class _PermissiveRemoteConfigService extends Fake
    implements RemoteConfigService {
  final ValueNotifier<RemoteConfig> _config = ValueNotifier(
    RemoteConfig.permissive,
  );

  // Narrower than the interface's `ValueListenable` on purpose: that type is
  // not in `material.dart`'s re-export of foundation, and a covariant override
  // avoids an import that exists only to name a return type.
  @override
  ValueNotifier<RemoteConfig> get config => _config;

  @override
  Future<void> refreshIfStale() async {}
}

void main() {
  const mint = 'mint-1';
  // Both wallets are signable — this is a funding flow, not an authority one.
  const activeAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const otherAddress = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';

  const activeWallet = WalletInfo(
    id: 'active-wallet',
    address: activeAddress,
    name: 'active',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );
  const otherWallet = WalletInfo(
    id: 'other-wallet',
    address: otherAddress,
    name: 'other',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );

  final otherRowLabel = truncateAddress(otherAddress);

  late MockMarketBloc marketBloc;
  late MockArtworkBloc artworkBloc;
  late MockRaffleBloc raffleBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late StreamController<TokenBalanceState> balances;
  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockWalletRepository walletRepository;
  late MockOfferRepository offerRepository;
  late MockArtworkPermissionService permissionService;
  late MockMarketListingRepository listingRepository;
  late MockRaffleRepository raffleRepository;
  late MockMarketRealtimeService realtimeService;
  late MockUserProfileRepository userProfileRepository;
  late MockArtworkEventsRepository eventsRepository;
  late MockSessionPortfolioAggregator aggregator;

  /// The live active signer, moved only by `selectSourceWallet`.
  late String? active;

  /// `(event, currentAddress-at-dispatch)` for every market/raffle event the
  /// screen dispatched, in order.
  late List<(Object, String?)> dispatched;

  /// Wallets `selectSourceWallet` was pointed at, in order.
  late List<String> switches;

  /// When true the next switch fails its `/v0/login` and rethrows — Phase 0's
  /// contract for an unreachable backend.
  late bool switchFails;

  /// When set, the switch parks mid-flight (session cleared, login pending)
  /// until it is completed — the wallet-switch window, held open on demand.
  late Completer<void>? switchGate;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(EventMode.all);
    registerFallbackValue(Chain.solana);
    registerFallbackValue(const MarketEvent.reset());
    registerFallbackValue(const RaffleEvent.reset());
    registerFallbackValue(const ArtworkEvent.refresh());
    registerFallbackValue(const TokenBalanceEvent.load());
    registerFallbackValue(otherWallet);
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
    // See the note in artwork_detail_authority_switch_test.dart: without an
    // AvatarService the auction panel's bidder strip renders an ErrorWidget
    // that expands to 100 000 px and pushes every CTA out of the render view.
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
    if (!sl.isRegistered<RemoteConfigService>()) {
      sl.registerSingleton<RemoteConfigService>(
        _PermissiveRemoteConfigService(),
      );
    }
  });

  void arrange(ArtworkDetails artwork) {
    whenListen(
      artworkBloc,
      const Stream<ArtworkState>.empty(),
      initialState: ArtworkState.loaded(artwork: artwork),
    );
  }

  /// Balance snapshot for the *currently active* wallet.
  TokenBalanceState loadedSol(int lamports) => TokenBalanceState.loaded(
    tokens: [TokenBalance.nativeSol(lamports: lamports)],
    totalUsdValue: 0,
    address: active,
  );

  /// Candidate set the funding affordance scans: the active wallet plus
  /// [others]. One candidate → no affordance at all.
  void arrangeCandidates(List<SendSourceCandidate> candidates) {
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async => candidates);
  }

  setUp(() {
    active = activeAddress;
    dispatched = [];
    switches = [];
    switchFails = false;
    switchGate = null;

    marketBloc = MockMarketBloc();
    artworkBloc = MockArtworkBloc();
    raffleBloc = MockRaffleBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    balances = StreamController<TokenBalanceState>.broadcast();
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    walletRepository = MockWalletRepository();
    offerRepository = MockOfferRepository();
    permissionService = MockArtworkPermissionService();
    listingRepository = MockMarketListingRepository();
    raffleRepository = MockRaffleRepository();
    // The detail screen fetches the live raffle PDA snapshot to resolve
    // sold / winner authoritatively; null keeps the indexed metadata.
    when(() => raffleRepository.getState(any())).thenAnswer((_) async => null);
    realtimeService = MockMarketRealtimeService();
    userProfileRepository = MockUserProfileRepository();
    eventsRepository = MockArtworkEventsRepository();
    aggregator = MockSessionPortfolioAggregator();

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
    // 5 SOL on the active wallet by default — enough for every CTA's
    // affordability gate; the re-derive test overrides it with an empty one.
    whenListen(
      tokenBalanceBloc,
      balances.stream,
      initialState: TokenBalanceState.loaded(
        tokens: [TokenBalance.nativeSol(lamports: 5000000000)],
        totalUsdValue: 0,
        address: activeAddress,
      ),
    );
    // Record the active address AT DISPATCH TIME — the whole point here.
    when(() => marketBloc.add(any())).thenAnswer((invocation) {
      dispatched.add((invocation.positionalArguments.single as Object, active));
    });
    when(() => raffleBloc.add(any())).thenAnswer((invocation) {
      dispatched.add((invocation.positionalArguments.single as Object, active));
    });

    when(() => authService.currentAddress).thenAnswer((_) => active);
    when(
      () => sessionManager.sessionAddresses,
    ).thenReturn(const {activeAddress, otherAddress});
    when(() => sessionManager.sessionWalletForAddress(any())).thenReturn(null);
    when(
      () => sessionManager.sessionWalletForAddressCaseInsensitive(any()),
    ).thenReturn(null);
    // Reproduces the live switch: the session is cleared synchronously —
    // nulling `currentAddress` — and only re-authenticates as the target once
    // `/v0/login` returns an async gap later. Phase 0 makes `selectSourceWallet`
    // await that login, so the address is the target when it RESOLVES. A
    // fire-and-forget caller would record `null` at dispatch.
    when(() => sessionManager.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      final wallet = invocation.positionalArguments.single as WalletInfo;
      switches.add(wallet.address);
      active = null;
      final gate = switchGate;
      if (gate != null) await gate.future;
      await Future<void>.delayed(Duration.zero);
      if (switchFails) {
        // T0.2 item 2: the selection is rolled back, so the previous wallet is
        // still the signer when the error reaches the caller.
        active = activeAddress;
        throw Exception('login failed');
      }
      active = wallet.address;
    });
    when(() => walletRepository.getActiveWallet()).thenAnswer(
      (_) async => active == otherAddress ? otherWallet : activeWallet,
    );

    arrangeCandidates(const [
      SendSourceCandidate(wallet: activeWallet, rawBalance: 0, uiBalance: 0),
      SendSourceCandidate(
        wallet: otherWallet,
        rawBalance: 5000000000,
        uiBalance: 5,
      ),
    ]);

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

    register<MarketBloc>(marketBloc);
    register<ArtworkBloc>(artworkBloc);
    register<RaffleBloc>(raffleBloc);
    register<TokenBalanceBloc>(tokenBalanceBloc);
    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<WalletRepository>(walletRepository);
    register<OfferRepository>(offerRepository);
    register<ArtworkPermissionService>(permissionService);
    register<MarketListingRepository>(listingRepository);
    register<RaffleRepository>(raffleRepository);
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
    await balances.close();
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<MarketBloc>();
    drop<ArtworkBloc>();
    drop<RaffleBloc>();
    drop<TokenBalanceBloc>();
    drop<AuthService>();
    drop<SessionManager>();
    drop<WalletRepository>();
    drop<OfferRepository>();
    drop<ArtworkPermissionService>();
    drop<MarketListingRepository>();
    drop<RaffleRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
    drop<SessionPortfolioAggregator>();
  });

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
    // The pinned action sheet slides in via `AnimatedSheetReveal`; its CTAs sit
    // below the render view until the reveal finishes. Never `pumpAndSettle` —
    // the screen keeps shimmer placeholders animating indefinitely.
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Pumps past a handler's async gaps in fixed steps (see the note above).
  Future<void> pumpAction(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Opens the source picker and taps the non-active wallet's row.
  Future<void> switchToOther(WidgetTester tester) async {
    await tester.tap(find.text('Switch'));
    // The picker is a modal route: taps sent while its transition is still
    // running are swallowed, so pump the sheet fully in before selecting.
    await pumpAction(tester);
    await tester.tap(find.text(otherRowLabel));
    await pumpAction(tester);
  }

  ArtworkDetails listedOneOfOne() => const ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    listingType: ListingType.buyNow,
    price: 1000000000,
    currency: solMint,
    ownerAddress: 'someone-else',
    ownerAddresses: ['someone-else'],
  );

  ArtworkDetails unlistedViewer() => const ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    ownerAddress: 'someone-else',
    ownerAddresses: ['someone-else'],
  );

  ArtworkDetails liveAuction() => ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    listingType: ListingType.auction,
    ownerAddress: 'someone-else',
    ownerAddresses: const ['someone-else'],
    auctionMetadata: AuctionMetadata(
      seller: 'someone-else',
      bidMint: solMint,
      reservePrice: 100000000,
      endsAt: DateTime.now().add(const Duration(hours: 1)),
    ),
  );

  ArtworkDetails sellingRaffle() => ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    listingType: ListingType.raffle,
    ownerAddress: 'someone-else',
    ownerAddresses: const ['someone-else'],
    raffleMetadata: RaffleMetadata(
      mintAccount: mint,
      raffleAccount: 'raffle-1',
      entrantsAccount: 'entrants-1',
      creator: 'someone-else',
      // Base units — 0.1 SOL. `priceRaw` is the wire `price` column, a
      // lamport-denominated BigInt.
      priceRaw: 100000000,
      currencyMint: solMint,
      supply: 50,
      sold: 0,
      endsAt: DateTime.now().add(const Duration(hours: 1)),
    ),
  );

  // ── The affordance itself ─────────────────────────────────────────────────

  testWidgets('no Switch affordance when the session has one funding source', (
    tester,
  ) async {
    arrangeCandidates(const [
      SendSourceCandidate(
        wallet: activeWallet,
        rawBalance: 5000000000,
        uiBalance: 5,
      ),
    ]);
    arrange(listedOneOfOne());
    await pumpScreen(tester);

    expect(find.text('Switch'), findsNothing);
    expect(find.text('Buy'), findsOneWidget);
  });

  testWidgets('the Switch affordance appears with two funding sources', (
    tester,
  ) async {
    arrange(listedOneOfOne());
    await pumpScreen(tester);

    expect(find.text('Switch'), findsOneWidget);
    // The line names the wallet that will actually fund the buy.
    expect(
      find.text('Your wallet: ${truncateAddress(activeAddress)}'),
      findsOneWidget,
    );
  });

  // ── Re-derive on switch + dispatch-time authority (buy) ───────────────────
  //
  // The strictest case: the CTA's affordability gate is computed from the
  // *previous* wallet's balance, so a switch that doesn't reload it would leave
  // a stale "insufficient" verdict blocking a buy the new wallet can afford.
  testWidgets(
    'switching re-derives the sheet balance and affordability, and the buy '
    'dispatches as the chosen wallet',
    (tester) async {
      arrange(listedOneOfOne());
      // Active wallet holds nothing — the 1 SOL listing is unaffordable.
      whenListen(
        tokenBalanceBloc,
        balances.stream,
        initialState: const TokenBalanceState.loaded(
          tokens: [],
          totalUsdValue: 0,
          address: activeAddress,
        ),
      );
      await pumpScreen(tester);

      await tester.tap(find.text('Buy'));
      await pumpAction(tester);
      expect(find.textContaining('Insufficient SOL'), findsOneWidget);
      expect(dispatched.whereType<MarketBuy>(), isEmpty);

      await switchToOther(tester);
      expect(switches, [otherAddress]);
      // Every figure computed for the old wallet is re-derived.
      verify(
        () => tokenBalanceBloc.add(const TokenBalanceEvent.refresh()),
      ).called(1);

      // …and the reloaded balance replaces the stale one.
      balances.add(loadedSol(5000000000));
      await pumpAction(tester);

      await tester.tap(find.text('Buy'));
      await pumpAction(tester);

      final buy = dispatched.singleWhere((d) => d.$1 is MarketBuy);
      // `MarketplaceActionFlow.prepare` builds the tx from
      // `AuthService.currentAddress` — asserted at dispatch time, not merely
      // "a switch happened".
      expect(buy.$2, otherAddress);
    },
  );

  // ── A failed switch never signs ───────────────────────────────────────────

  testWidgets(
    'a failed switch surfaces the error, keeps the previous wallet and never '
    'dispatches',
    (tester) async {
      switchFails = true;
      arrange(listedOneOfOne());
      await pumpScreen(tester);

      await switchToOther(tester);

      expect(find.textContaining("Couldn't switch wallet"), findsOneWidget);
      // Rolled back to the previous signer, and nothing was armed behind it.
      expect(active, activeAddress);
      expect(dispatched, isEmpty);
      verifyNever(
        () => tokenBalanceBloc.add(const TokenBalanceEvent.refresh()),
      );
    },
  );

  // ── The wallet-switch window, held open ───────────────────────────────────────────
  //
  // Dismissing the picker cannot cancel the durable switch, so this is the one
  // moment a funding CTA can be tapped while `AuthService.currentAddress` is
  // null. Dispatching there builds the tx with no authority at all ("No wallet
  // connected"), which is why the CTA is disabled for the whole round trip.
  testWidgets(
    'a CTA tapped while the switch is still in flight never dispatches, and '
    'buys as the chosen wallet once it settles',
    (tester) async {
      final gate = Completer<void>();
      switchGate = gate;
      arrange(listedOneOfOne());
      await pumpScreen(tester);

      await tester.tap(find.text('Switch'));
      await pumpAction(tester);
      await tester.tap(find.text(otherRowLabel));
      await pumpAction(tester);
      expect(switches, [otherAddress]);
      // Session cleared, login still pending.
      expect(active, isNull);

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await pumpAction(tester);
      await tester.tap(find.text('Buy'));
      await pumpAction(tester);
      expect(dispatched, isEmpty);

      gate.complete();
      await pumpAction(tester);
      expect(active, otherAddress);

      await tester.tap(find.text('Buy'));
      await pumpAction(tester);
      final buy = dispatched.singleWhere((d) => d.$1 is MarketBuy);
      expect(buy.$2, otherAddress);
    },
  );

  // ── Dispatch-time authority for the remaining funding flows ───────────────

  testWidgets('make-offer dispatches as the chosen wallet', (tester) async {
    arrange(unlistedViewer());
    await pumpScreen(tester);

    await switchToOther(tester);
    expect(switches, [otherAddress]);

    await tester.tap(find.text('Make offer'));
    await pumpAction(tester);
    await tester.enterText(find.byType(TextField).last, '1');
    await pumpAction(tester);
    await tester.tap(find.text('Next'));
    await pumpAction(tester);

    final offer = dispatched.singleWhere((d) => d.$1 is MarketMakeOfferV2);
    expect(offer.$2, otherAddress);
  });

  testWidgets('place-bid dispatches as the chosen wallet', (tester) async {
    arrange(liveAuction());
    await pumpScreen(tester);

    await switchToOther(tester);
    expect(switches, [otherAddress]);

    await tester.tap(find.text('Place bid'));
    await pumpAction(tester);
    await tester.enterText(find.byType(TextField).last, '1');
    await pumpAction(tester);
    await tester.tap(find.text('Next'));
    await pumpAction(tester);

    final bid = dispatched.singleWhere((d) => d.$1 is MarketPlaceBid);
    expect(bid.$2, otherAddress);
  });

  testWidgets('raffle-ticket purchase dispatches as the chosen wallet', (
    tester,
  ) async {
    arrange(sellingRaffle());
    await pumpScreen(tester);

    await switchToOther(tester);
    expect(switches, [otherAddress]);

    await tester.tap(find.text('Buy tickets'));
    await pumpAction(tester);
    await tester.tap(find.text('Buy'));
    await pumpAction(tester);

    final tickets = dispatched.singleWhere((d) => d.$1 is RaffleBuyTickets);
    expect(tickets.$2, otherAddress);
  });
}
