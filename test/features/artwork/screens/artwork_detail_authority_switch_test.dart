import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
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
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/data/offer_repository.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
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

class MockArtworkEventsRepository extends Mock
    implements ArtworkEventsRepository {}

class MockMarketRealtimeService extends Mock implements MarketRealtimeService {}

class MockUserProfileRepository extends Mock implements UserProfileRepository {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockDio extends Mock implements Dio {}

/// Track A regression suite for the artwork detail screen's authority
/// actions.
///
/// Every assertion here is about **the address the tx will be built with**, so
/// the tests record `AuthService.currentAddress` at the moment the bloc event
/// is dispatched. Asserting only that `selectSourceWallet` was called would
/// pass while the flow is still broken: the switch used to be fire-and-forget,
/// leaving `currentAddress` null (or stale) for the whole dispatch — the wallet-switch
/// race in the wallet-switching contract.
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
  // Active signing wallet: watch-only, so it also exercises A1d — the
  // view-only guard must not block an action whose authority is a *signable*
  // session wallet.
  const activeAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  // The session wallet that actually holds the piece / placed the offer.
  const holderAddress = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';
  // Auction winner — a third party, not in the session.
  const winnerAddress = '4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T';

  const activeWallet = WalletInfo(
    id: 'active-wallet',
    address: activeAddress,
    name: 'active',
    walletType: WalletType.viewOnly,
    chain: 'solana',
    accountId: 'acct',
  );
  const holderWallet = WalletInfo(
    id: 'holder-wallet',
    address: holderAddress,
    name: 'holder',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );

  late MockMarketBloc marketBloc;
  late MockArtworkBloc artworkBloc;
  late MockRaffleBloc raffleBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockWalletRepository walletRepository;
  late MockOfferRepository offerRepository;
  late MockArtworkPermissionService permissionService;
  late MockMarketListingRepository listingRepository;
  late MockMarketRealtimeService realtimeService;
  late MockUserProfileRepository userProfileRepository;
  late MockArtworkEventsRepository eventsRepository;

  /// The live active signer. `selectSourceWallet` moves it *atomically* —
  /// the Phase-0 contract: the awaited `/v0/login` has landed by the time it
  /// resolves, so `currentAddress` is the target when the caller continues.
  late String? active;

  /// `(event, currentAddress-at-dispatch)` for every bloc event the screen
  /// dispatched, in order.
  late List<(Object, String?)> dispatched;

  /// Wallets `selectSourceWallet` was pointed at, in order.
  late List<String> switches;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(EventMode.all);
    registerFallbackValue(const MarketEvent.reset());
    registerFallbackValue(const RaffleEvent.reset());
    registerFallbackValue(const ArtworkEvent.refresh());
    registerFallbackValue(holderWallet);
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
    // The auction panel's bidder strip renders an AccountAvatar, which
    // resolves AvatarService out of GetIt in `initState`. Without it the
    // avatar throws and Flutter substitutes an ErrorWidget — which, inside
    // the bottom-pinned sheet's unbounded-height slot, expands to 100 000 px
    // and pushes every CTA outside the render view, so no tap ever lands. An
    // unstubbed mock Dio makes the fetch fail, so it renders the anon
    // fallback.
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

  setUp(() {
    active = activeAddress;
    dispatched = [];
    switches = [];

    marketBloc = MockMarketBloc();
    artworkBloc = MockArtworkBloc();
    raffleBloc = MockRaffleBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    walletRepository = MockWalletRepository();
    offerRepository = MockOfferRepository();
    permissionService = MockArtworkPermissionService();
    listingRepository = MockMarketListingRepository();
    realtimeService = MockMarketRealtimeService();
    userProfileRepository = MockUserProfileRepository();
    eventsRepository = MockArtworkEventsRepository();

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
    // Record the active address AT DISPATCH TIME — the whole point of Track A.
    when(() => marketBloc.add(any())).thenAnswer((invocation) {
      dispatched.add((invocation.positionalArguments.single as Object, active));
    });
    when(() => raffleBloc.add(any())).thenAnswer((invocation) {
      dispatched.add((invocation.positionalArguments.single as Object, active));
    });

    when(() => authService.currentAddress).thenAnswer((_) => active);
    when(
      () => sessionManager.sessionAddresses,
    ).thenReturn(const {activeAddress, holderAddress});
    when(
      () => sessionManager.sessionWalletForAddress(holderAddress),
    ).thenReturn(holderWallet);
    when(
      () => sessionManager.sessionWalletForAddress(activeAddress),
    ).thenReturn(activeWallet);
    when(() => sessionManager.resolveWalletForAddress(any())).thenReturn(null);
    when(
      () => sessionManager.resolveWalletForAddress(holderAddress),
    ).thenReturn(holderWallet);
    when(
      () => sessionManager.resolveWalletForAddress(activeAddress),
    ).thenReturn(activeWallet);
    when(
      () => sessionManager.sessionWalletForAddressCaseInsensitive(any()),
    ).thenReturn(null);
    when(
      () =>
          sessionManager.sessionWalletForAddressCaseInsensitive(holderAddress),
    ).thenReturn(holderWallet);
    when(
      () =>
          sessionManager.sessionWalletForAddressCaseInsensitive(activeAddress),
    ).thenReturn(activeWallet);
    // Reproduces the live switch: `AuthService.switchWallet` clears the
    // session synchronously — nulling `currentAddress` and dropping the auth
    // interceptor — and only re-authenticates as the target once `/v0/login`
    // returns an async gap later. Phase 0 (T0.2) makes `selectSourceWallet`
    // await that login, so the address is the target by the time it RESOLVES —
    // but it is null for anyone who dispatches without awaiting. That is what
    // makes "assert `currentAddress` at dispatch time" a real test: a
    // fire-and-forget caller records `null` here, while a caller that merely
    // *called* `selectSourceWallet` would still satisfy a `verify()`.
    when(() => sessionManager.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      final wallet = invocation.positionalArguments.single as WalletInfo;
      switches.add(wallet.address);
      active = null;
      await Future<void>.delayed(Duration.zero);
      active = wallet.address;
    });
    // `guardViewOnly` reads the DB's active wallet — watch-only until the
    // signer is re-pointed to the holder.
    when(() => walletRepository.getActiveWallet()).thenAnswer(
      (_) async => active == holderAddress ? holderWallet : activeWallet,
    );

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
    drop<SessionManager>();
    drop<WalletRepository>();
    drop<OfferRepository>();
    drop<ArtworkPermissionService>();
    drop<MarketListingRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
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
    // The bottom-pinned action sheet slides in via `AnimatedSheetReveal`
    // (`MallowTheme.sheetDuration`), so its CTAs sit *below* the render view
    // until the reveal finishes — tapping earlier misses every time. Pump the
    // reveal out in fixed steps rather than settling: the screen keeps
    // repeating animations (shimmer placeholders) alive indefinitely.
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Pumps past a tapped handler's async gaps in fixed steps.
  ///
  /// Never `pumpAndSettle` here: the market flow sheet this screen opens on
  /// every authority action animates indefinitely (shimmering cost lines while
  /// the tx builds), so settling never terminates. The handler chain is
  /// `selectSourceWallet` (a zero-delay timer standing in for the login round
  /// trip) → `guardViewOnly`'s DB read → dispatch → sheet route, so a handful
  /// of small pumps is enough to drive it to the dispatch.
  Future<void> pumpAction(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  ArtworkDetails endedAuction() => ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    listingType: ListingType.auction,
    ownerAddress: holderAddress,
    ownerAddresses: const [holderAddress],
    auctionMetadata: AuctionMetadata(
      seller: holderAddress,
      currentBidder: winnerAddress,
      currentBidAmount: 1000000000,
      bidCount: 1,
      endsAt: DateTime.now().subtract(const Duration(hours: 1)),
    ),
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

  // Settle-auction is the strictest case: the sheet's proceeds breakdown and
  // the optimistic ownership bookkeeping are BOTH derived from
  // `currentAddress`, so the signer has to be re-pointed before any of it is
  // computed (A1a) — not just before the tx is built.
  testWidgets(
    'settle-auction from a non-active seller dispatches as the seller and '
    'still carries the winning-bid proceeds',
    (tester) async {
      arrange(endedAuction());
      await pumpScreen(tester);

      await tester.tap(find.text('Settle auction'));
      await pumpAction(tester);

      expect(switches, [holderAddress]);
      final settle = dispatched.singleWhere((d) => d.$1 is MarketSettleAuction);
      // The authority `SettleAuctionTxRequest.caller` resolves from — asserted
      // at dispatch time, not merely "a switch happened".
      expect(settle.$2, holderAddress);
      // A1a: `me` is re-read after the switch, so the seller still gets the
      // proceeds line instead of a gas-only sheet.
      expect((settle.$1 as MarketSettleAuction).winningBid?.rawAmount, 1e9);
    },
  );

  // A1d: `guardViewOnly` runs AFTER the signer moves, so a watch-only *active*
  // wallet no longer blocks an action whose authority is a signable session
  // wallet. (`activeWallet` above is watch-only for every test in this file.)
  testWidgets(
    'a watch-only active wallet does not block an action whose authority is a '
    'signable session wallet',
    (tester) async {
      arrange(endedAuction());
      await pumpScreen(tester);

      await tester.tap(find.text('Settle auction'));
      await pumpAction(tester);

      // Run guard-first and this is what you get instead: the active wallet is
      // still the watch-only one when `guardViewOnly` reads it, so the sheet
      // goes up and the action never dispatches.
      expect(find.text('View-only wallet'), findsNothing);
      expect(dispatched.map((d) => d.$1).whereType<MarketSettleAuction>(), [
        isA<MarketSettleAuction>(),
      ]);
    },
  );

  // A1b end-to-end: the own-offer lookup spans the session, so an offer placed
  // by a non-active wallet surfaces "Cancel offer" — and cancelling it signs as
  // the maker, since `CancelOfferTxRequest.buyer` IS the signer.
  testWidgets(
    'cancel-offer resolves an offer placed by another session wallet and '
    'dispatches as that wallet',
    (tester) async {
      when(
        () => offerRepository.getUserActiveOffer(
          mintAccount: any(named: 'mintAccount'),
          buyerAddresses: any(named: 'buyerAddresses'),
        ),
      ).thenAnswer(
        (_) async => const OfferRender(
          offerType: OfferType.nft,
          buyerAddress: holderAddress,
          asset: mint,
          currencyMint: 'So11111111111111111111111111111111111111112',
          price: 500000000,
        ),
      );
      arrange(unlistedViewer());
      await pumpScreen(tester);
      // Let the widened own-offer lookup resolve and flip the CTA. The offer
      // was placed by a wallet that is NOT the active signer, so the CTA
      // appearing at all is the A1b widening (`buyerAddresses` = the whole
      // session, not `[currentAddress]`).
      await tester.pump();
      await tester.pump();
      expect(find.text('Cancel offer'), findsOneWidget);

      await tester.tap(find.text('Cancel offer'));
      await pumpAction(tester);

      expect(switches, [holderAddress]);
      final cancel = dispatched.singleWhere((d) => d.$1 is MarketCancelOffer);
      expect(cancel.$2, holderAddress);
    },
  );

  // The same A1b widening turns "Make offer" into "Update offer", and the
  // backend builder only emits an `updateOffer` re-bid for the buyer that
  // already has one — i.e. the SIGNER. Without re-pointing to the maker first,
  // "Update offer" escrows a second, independent full-price offer for the
  // active wallet and the user ends up holding two.
  testWidgets(
    'update-offer on an offer placed by another session wallet dispatches as '
    'that maker',
    (tester) async {
      when(
        () => offerRepository.getUserActiveOffer(
          mintAccount: any(named: 'mintAccount'),
          buyerAddresses: any(named: 'buyerAddresses'),
        ),
      ).thenAnswer(
        (_) async => const OfferRender(
          offerType: OfferType.nft,
          buyerAddress: holderAddress,
          asset: mint,
          currencyMint: 'So11111111111111111111111111111111111111112',
          price: 500000000,
        ),
      );
      arrange(unlistedViewer());
      await pumpScreen(tester);
      await tester.pump();
      await tester.pump();
      expect(find.text('Update offer'), findsOneWidget);

      await tester.tap(find.text('Update offer'));
      await pumpAction(tester);
      // The re-point lands before the amount sheet opens, so the escrow credit
      // the confirm step is handed is read for the wallet that will sign.
      expect(switches, [holderAddress]);
      expect(active, holderAddress);

      await tester.enterText(find.byType(TextField).last, '1');
      await pumpAction(tester);
      await tester.tap(find.text('Next'));
      await pumpAction(tester);

      final offer = dispatched.singleWhere((d) => d.$1 is MarketMakeOfferV2);
      // `CreateOfferTxRequest.buyer` resolves from this — the maker, so the
      // program updates the existing Offer PDA instead of opening a second one.
      expect(offer.$2, holderAddress);
    },
  );

  // The abandon counterpart: make-offer's entry step runs BEFORE anything is
  // dispatched, so the bloc is still idle and the flow host's own restore never
  // fires. Backing out of the amount sheet must still put the wallet back.
  testWidgets(
    'abandoning the update-offer amount sheet restores the previous signer',
    (tester) async {
      when(
        () => offerRepository.getUserActiveOffer(
          mintAccount: any(named: 'mintAccount'),
          buyerAddresses: any(named: 'buyerAddresses'),
        ),
      ).thenAnswer(
        (_) async => const OfferRender(
          offerType: OfferType.nft,
          buyerAddress: holderAddress,
          asset: mint,
          currencyMint: 'So11111111111111111111111111111111111111112',
          price: 500000000,
        ),
      );
      arrange(unlistedViewer());
      await pumpScreen(tester);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Update offer'));
      await pumpAction(tester);
      expect(switches, [holderAddress]);

      // Dismiss the amount sheet without submitting a price.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await pumpAction(tester);

      expect(switches, [holderAddress, activeAddress]);
      expect(active, activeAddress);
      expect(
        dispatched.map((d) => d.$1).whereType<MarketMakeOfferV2>(),
        isEmpty,
      );
    },
  );

  // Opening a confirm sheet and walking away must not move the user's
  // app-wide wallet.
  testWidgets(
    'abandoning the cancel-offer confirm sheet restores the previous signer',
    (tester) async {
      when(
        () => offerRepository.getUserActiveOffer(
          mintAccount: any(named: 'mintAccount'),
          buyerAddresses: any(named: 'buyerAddresses'),
        ),
      ).thenAnswer(
        (_) async => const OfferRender(
          offerType: OfferType.nft,
          buyerAddress: holderAddress,
          asset: mint,
          currencyMint: 'So11111111111111111111111111111111111111112',
          price: 500000000,
        ),
      );
      arrange(unlistedViewer());
      await pumpScreen(tester);
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Cancel offer'));
      await pumpAction(tester);
      expect(switches, [holderAddress]);

      // Still preparing when the user walks away — nothing was signed, so the
      // re-point must be undone. Stubbed only now: a `TxFlowPreparing` state at
      // build time renders the CTA as a disabled spinner, so the tap above
      // would never have landed.
      when(
        () => marketBloc.state,
      ).thenReturn(const TxFlowPreparing<MarketPrepData, MarketSuccessData>());

      // Dismiss the confirm sheet.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await pumpAction(tester);

      expect(switches, [holderAddress, activeAddress]);
      expect(active, activeAddress);
    },
  );
}
