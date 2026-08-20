import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/offers/screens/offers_screen.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mallow_wallet/features/offers/widgets/offers_artwork_group.dart';
import 'package:mallow_wallet/features/offers/widgets/offers_auction_bid_card.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';

class _MockDio extends Mock implements Dio {}

class _MockAuthService extends Mock implements AuthService {}

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockOffersInboxBloc extends MockBloc<OffersInboxEvent, OffersInboxState>
    implements OffersInboxBloc {}

class _MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

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
  const solMint = 'So11111111111111111111111111111111111111112';

  // The rows' missing-image avatar is a generated identicon (AccountAvatar),
  // which resolves AvatarService via GetIt. An unstubbed mock Dio makes every
  // fetch fail, so rows render the anon fallback.
  setUpAll(() {
    registerFallbackValue(const MarketEvent.reset());
    registerFallbackValue(
      const WalletInfo(
        id: 'fallback',
        address: 'FALLBACK',
        name: 'Fallback',
        walletType: WalletType.hd,
        chain: 'solana',
      ),
    );
    sl.registerLazySingleton<AvatarService>(
      () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
    );
    if (!sl.isRegistered<RemoteConfigService>()) {
      sl.registerSingleton<RemoteConfigService>(
        _PermissiveRemoteConfigService(),
      );
    }
  });
  tearDownAll(() => sl.unregister<AvatarService>());

  // Two artworks so the tab split is observable by header title: one received
  // (an offer on the viewer's art), one placed (the viewer's own offer).
  api.OffersInboxItem itemFor(
    api.OffersInboxDirection direction,
    String title,
  ) => api.OffersInboxItem(
    kind: api.OffersInboxKind.offer,
    direction: direction,
    asset: title,
    artworkTitle: title,
    actorAddress: 'ACTOR',
    viewerAddress: 'W1',
    rawAmount: 1000000000,
    currencyMint: solMint,
  );

  /// Taps a row's action pill and pumps past the signer switch's async gap.
  /// Never `pumpAndSettle`: the switch raises a blocking progress overlay whose
  /// branded loader animates indefinitely, as does the market flow sheet that
  /// opens once the action dispatches.
  Future<void> tapAction(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  late _MockOffersInboxBloc offersBloc;
  late _MockMarketBloc marketBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;

  setUp(() {
    offersBloc = _MockOffersInboxBloc();
    marketBloc = _MockMarketBloc();
    tokenBalanceBloc = _MockTokenBalanceBloc();

    whenListen(
      offersBloc,
      const Stream<OffersInboxState>.empty(),
      initialState: OffersInboxState.loaded(
        items: [
          itemFor(api.OffersInboxDirection.received, 'RecvArt'),
          itemFor(api.OffersInboxDirection.placed, 'SentArt'),
        ],
      ),
    );
    whenListen(
      marketBloc,
      const Stream<MarketState>.empty(),
      initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    if (sl.isRegistered<OffersInboxBloc>()) sl.unregister<OffersInboxBloc>();
    if (sl.isRegistered<MarketBloc>()) sl.unregister<MarketBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
    sl.registerFactory<OffersInboxBloc>(() => offersBloc);
    sl.registerFactory<MarketBloc>(() => marketBloc);
    sl.registerFactory<TokenBalanceBloc>(() => tokenBalanceBloc);
  });

  tearDown(() {
    if (sl.isRegistered<OffersInboxBloc>()) sl.unregister<OffersInboxBloc>();
    if (sl.isRegistered<MarketBloc>()) sl.unregister<MarketBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
  });

  testWidgets(
    'Received tab shows only received items; Sent tab shows only placed — the '
    'merged feed is split by direction so each side is actionable on its own',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();

      // Received is the default tab.
      expect(find.text('RecvArt'), findsOneWidget);
      expect(find.text('SentArt'), findsNothing);

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();

      expect(find.text('SentArt'), findsOneWidget);
      expect(find.text('RecvArt'), findsNothing);
    },
  );

  testWidgets(
    'auction bids render as standalone self-contained cards, not inside the '
    'artwork group — the card carries its own artwork header, so nesting '
    'it under a group header would double it',
    (tester) async {
      const auctionItem = api.OffersInboxItem(
        kind: api.OffersInboxKind.bid,
        direction: api.OffersInboxDirection.received,
        asset: 'AuctionArt',
        artworkTitle: 'AuctionArt',
        actorAddress: 'ACTOR',
        viewerAddress: 'W1',
        rawAmount: 1000000000,
        currencyMint: solMint,
        auction: api.AuctionInfo(status: api.AuctionStatus.live),
      );
      offersBloc = _MockOffersInboxBloc();
      whenListen(
        offersBloc,
        const Stream<OffersInboxState>.empty(),
        initialState: OffersInboxState.loaded(
          items: [
            auctionItem,
            itemFor(api.OffersInboxDirection.received, 'RecvArt'),
          ],
        ),
      );
      sl.unregister<OffersInboxBloc>();
      sl.registerFactory<OffersInboxBloc>(() => offersBloc);

      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      // Not pumpAndSettle: the live-auction card's ping animation repeats
      // forever, so the tree never settles.
      await tester.pump();
      await tester.pump();

      expect(find.byType(OffersAuctionBidCard), findsOneWidget);
      // The plain offer still renders under its group header…
      expect(find.byType(OffersArtworkGroup), findsOneWidget);
      // …but the auction card is never nested inside a group.
      expect(
        find.descendant(
          of: find.byType(OffersArtworkGroup),
          matching: find.byType(OffersAuctionBidCard),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'tapping the sort control opens the sort sheet with the active option '
    'accent-highlighted, and picking another option dispatches setSort',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Latest'));
      await tester.pumpAndSettle();

      expect(find.text('Sort by'), findsOneWidget);
      expect(find.text('Oldest'), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget);
      // The sheet shows both the control label and the selected row; the
      // selected row is the accent-colored one.
      final accentLatest = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data == 'Latest' &&
            w.style?.color == MallowColors.light.accent,
      );
      expect(accentLatest, findsOneWidget);

      // Sheets swallow taps for sheetTapGuardMinimum after opening — wait it
      // out before selecting.
      await tester.pump(MallowTheme.sheetTapGuardMinimum * 2);
      await tester.tap(find.text('Oldest'));
      await tester.pumpAndSettle();

      verify(
        () => offersBloc.add(
          const OffersInboxEvent.setSort(sort: api.OffersInboxSort.oldest),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'an Ethereum row resolves its holder despite EIP-55 casing: the API echoes '
    '`viewerAddress` lowercased while wallets are stored checksummed, so a '
    "case-sensitive lookup would read the user's own watch-only ETH wallet as "
    'a third-party delegate and wave a doomed action through instead of '
    'prompting to import it',
    (tester) async {
      // Same wallet, two spellings: what the backend stores vs. what the
      // device derives (see `apiOwnerAddress`).
      const lowercased = '0xab5801a7d398351b8be11c439e05c5b3259aec9b';
      const checksummed = '0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B';
      const ethWallet = WalletInfo(
        id: 'eth-1',
        address: checksummed,
        name: 'ETH',
        // Watch-only: the import prompt is only reachable once the lowercased
        // API address has been matched to this session wallet, so it is the
        // observable proof of the case-insensitive resolution.
        walletType: WalletType.viewOnly,
        chain: 'ethereum',
      );

      final authService = _MockAuthService();
      final walletRepo = _MockWalletRepository();
      final sessionManager = _MockSessionManager();
      // Active signer is a different (Solana) wallet.
      when(() => authService.currentAddress).thenReturn('SolanaSigner');
      when(() => walletRepo.getActiveWallet()).thenAnswer((_) async => null);
      when(
        () => sessionManager.sessionWalletForAddressCaseInsensitive(lowercased),
      ).thenReturn(ethWallet);
      when(
        () => sessionManager.sessionWalletForAddress(any()),
      ).thenReturn(null);
      when(
        () => sessionManager.selectSourceWallet(any()),
      ).thenAnswer((_) async {});
      sl.registerSingleton<AuthService>(authService);
      sl.registerSingleton<WalletRepository>(walletRepo);
      sl.registerSingleton<SessionManager>(sessionManager);
      addTearDown(() {
        sl.unregister<AuthService>();
        sl.unregister<WalletRepository>();
        sl.unregister<SessionManager>();
      });

      offersBloc = _MockOffersInboxBloc();
      whenListen(
        offersBloc,
        const Stream<OffersInboxState>.empty(),
        initialState: OffersInboxState.loaded(
          items: [
            itemFor(
              api.OffersInboxDirection.received,
              'EthArt',
            ).copyWith(viewerAddress: lowercased),
          ],
        ),
      );
      sl.unregister<OffersInboxBloc>();
      sl.registerFactory<OffersInboxBloc>(() => offersBloc);

      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();

      await tapAction(tester, 'View');

      expect(find.text('Watch-only wallet'), findsOneWidget);
      // A watch-only holder is never adopted as the signer.
      verifyNever(() => sessionManager.selectSourceWallet(any()));
      // The market pipeline must not have been armed behind the prompt.
      verifyNever(() => marketBloc.add(any()));
    },
  );

  // ── Signer settles before dispatch (switch-window regression) ──────────────────────
  //
  // `MarketBloc` reads its authority off `AuthService.currentAddress` when it
  // builds the tx (`MarketplaceActionFlow.prepare`), and the wallet switch
  // synchronously nulls that address while its `/v0/login` is in flight. So the
  // only assertion that observes the bug is `currentAddress` **at the moment
  // the event is dispatched** — asserting merely that `selectSourceWallet` was
  // called passes even while the flow is broken.
  group('dispatch happens only after the signer switch has fully settled', () {
    const activeAddress = 'ActiveSolanaWallet';
    const holderAddress = 'HolderSolanaWallet';
    const activeWallet = WalletInfo(
      id: 'sol-active',
      address: activeAddress,
      name: 'Active',
      walletType: WalletType.hd,
      chain: 'solana',
    );
    const holderWallet = WalletInfo(
      id: 'sol-holder',
      address: holderAddress,
      name: 'Holder',
      walletType: WalletType.hd,
      chain: 'solana',
    );

    /// Wires GetIt so the item's `viewerAddress` is a *non-active* signable
    /// session wallet, and `selectSourceWallet` reproduces the live async
    /// switch: `currentAddress` is nulled first (as `_clearSession` does) and
    /// only becomes the target once the login round trip lands.
    ///
    /// Returns a getter for the address that was live when `MarketBloc.add`
    /// fired.
    String? Function() wireNonActiveHolder() {
      final authService = _MockAuthService();
      final walletRepo = _MockWalletRepository();
      final sessionManager = _MockSessionManager();

      String? current = activeAddress;
      when(() => authService.currentAddress).thenAnswer((_) => current);
      when(
        () => sessionManager.sessionWalletForAddress(activeAddress),
      ).thenReturn(activeWallet);
      when(
        () => sessionManager.sessionWalletForAddress(holderAddress),
      ).thenReturn(holderWallet);
      when(() => sessionManager.selectSourceWallet(any())).thenAnswer((
        invocation,
      ) async {
        final target = invocation.positionalArguments.first as WalletInfo;
        // The gap the plan exists to close: authenticated as nobody until the
        // login lands.
        current = null;
        await Future<void>.delayed(Duration.zero);
        current = target.address;
      });
      // Signable active wallet → `guardViewOnly` lets the action through.
      when(
        () => walletRepo.getActiveWallet(),
      ).thenAnswer((_) async => holderWallet);

      String? addressAtDispatch;
      var dispatched = false;
      when(() => marketBloc.add(any())).thenAnswer((invocation) {
        final event = invocation.positionalArguments.first;
        if (event is MarketReset || dispatched) return;
        dispatched = true;
        addressAtDispatch = authService.currentAddress;
      });

      sl.registerSingleton<AuthService>(authService);
      sl.registerSingleton<WalletRepository>(walletRepo);
      sl.registerSingleton<SessionManager>(sessionManager);
      addTearDown(() {
        sl.unregister<AuthService>();
        sl.unregister<WalletRepository>();
        sl.unregister<SessionManager>();
      });
      return () => addressAtDispatch;
    }

    void loadOnly(api.OffersInboxItem item) {
      offersBloc = _MockOffersInboxBloc();
      whenListen(
        offersBloc,
        const Stream<OffersInboxState>.empty(),
        initialState: OffersInboxState.loaded(items: [item]),
      );
      sl.unregister<OffersInboxBloc>();
      sl.registerFactory<OffersInboxBloc>(() => offersBloc);
    }

    testWidgets('accept-offer signs as the wallet that holds the art', (
      tester,
    ) async {
      final addressAtDispatch = wireNonActiveHolder();
      loadOnly(
        itemFor(
          api.OffersInboxDirection.received,
          'HeldByOther',
        ).copyWith(viewerAddress: holderAddress),
      );

      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();
      await tapAction(tester, 'View');

      expect(addressAtDispatch(), holderAddress);
    });

    testWidgets('cancel-offer signs as the wallet that placed the offer', (
      tester,
    ) async {
      final addressAtDispatch = wireNonActiveHolder();
      loadOnly(
        itemFor(
          api.OffersInboxDirection.placed,
          'PlacedByOther',
        ).copyWith(viewerAddress: holderAddress),
      );

      await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
      await tester.pumpAndSettle();
      // Offers the viewer placed live on the Sent tab, where the pill reads
      // "Cancel".
      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();
      await tapAction(tester, 'Cancel');

      expect(addressAtDispatch(), holderAddress);
    });
  });
}
