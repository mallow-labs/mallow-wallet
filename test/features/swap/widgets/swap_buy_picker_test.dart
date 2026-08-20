import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart' as mallow_tokens;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_verified_token_list_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/swap/services/swap_bloc.dart';
import 'package:mallow_wallet/features/swap/widgets/swap_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class MockSwapBloc extends MockBloc<SwapEvent, SwapState> implements SwapBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class MockWalletManager extends Mock implements WalletManager {}

class MockSessionManager extends Mock implements SessionManager {}

class MockTokenPriceService extends Mock implements TokenPriceService {}

class MockJupiterVerifiedTokenListService extends Mock
    implements JupiterVerifiedTokenListService {}

/// The swap buy picker's browse tabs.
///
/// The buy list used to be one flat set of held + registry rows. Splitting it
/// into Owned / Popular is only an improvement if each tab answers its own
/// question honestly, so these pin the two that a plain volume ranking gets
/// wrong on its own: Owned has to mean the *session's* holdings — the ones the
/// portfolio shows — not just the wallet that happens to be signing, and
/// mallowSOL has to be reachable even though the market ranks it nowhere near
/// the top.
void main() {
  const address = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  const bonkMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

  const wallet = WalletInfo(
    id: 'wallet-a',
    address: address,
    name: 'A',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );

  const signerSol = TokenBalance(
    mint: mallow_tokens.solMint,
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1,
    isNative: true,
    isVerified: true,
  );

  /// Held only by a sibling wallet — invisible to the signer's own balances.
  const siblingBonk = TokenBalance(
    mint: bonkMint,
    symbol: 'BONK',
    name: 'Bonk',
    decimals: 5,
    rawBalance: 10000000,
    uiBalance: 100,
    isVerified: true,
  );

  const usdc = TokenBalance(
    mint: usdcMint,
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 0,
    uiBalance: 0,
    isVerified: true,
  );

  const catalogUsdc = (
    mint: usdcMint,
    symbol: 'USDC',
    name: 'USD Coin',
    iconUrl: null,
    decimals: 6,
    dailyVolume: 1000000.0,
  );

  late MockSwapBloc swapBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockSessionPortfolioAggregator aggregator;
  late MockJupiterVerifiedTokenListService verifiedTokens;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() {
    registerFallbackValue(wallet);
    registerFallbackValue(Chain.solana);
    registerFallbackValue(const SwapEvent.getQuote());
  });

  setUp(() {
    swapBloc = MockSwapBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    aggregator = MockSessionPortfolioAggregator();
    verifiedTokens = MockJupiterVerifiedTokenListService();

    whenListen(
      swapBloc,
      const Stream<SwapState>.empty(),
      initialState: const SwapState(sellToken: signerSol, buyToken: usdc),
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      // Only the signing wallet's holdings — the sheet's own bloc is
      // per-signer, which is exactly what the Owned tab must not be limited to.
      initialState: const TokenBalanceState.loaded(
        tokens: [signerSol],
        totalUsdValue: 0,
        address: address,
      ),
    );

    final walletManager = MockWalletManager();
    when(() => walletManager.getAddress()).thenAnswer((_) async => address);
    final sessionManager = MockSessionManager();
    when(
      () => sessionManager.selectSourceWallet(any()),
    ).thenAnswer((_) async {});
    when(
      () => aggregator.signableSolanaBalances(refresh: any(named: 'refresh')),
    ).thenAnswer((_) async => const [signerSol, siblingBonk]);
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer(
      (_) async => [
        const SendSourceCandidate(
          wallet: wallet,
          rawBalance: 1000000000,
          uiBalance: 1,
        ),
      ],
    );
    final priceService = MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(null);

    when(() => verifiedTokens.ensureCached()).thenAnswer((_) async {});
    when(() => verifiedTokens.search(any())).thenAnswer((_) async => const []);
    // The catalog ranks purely on traded volume, and mallowSOL is nowhere in
    // it — the whole point of the pin.
    when(
      () => verifiedTokens.popular(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const [catalogUsdc]);

    register<SessionPortfolioAggregator>(aggregator);
    register<WalletManager>(walletManager);
    register<SessionManager>(sessionManager);
    register<TokenPriceService>(priceService);
    register<JupiterVerifiedTokenListService>(verifiedTokens);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<SessionPortfolioAggregator>();
    drop<WalletManager>();
    drop<SessionManager>();
    drop<TokenPriceService>();
    drop<JupiterVerifiedTokenListService>();
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<TokenBalanceBloc>.value(value: tokenBalanceBloc),
              BlocProvider<SwapBloc>.value(value: swapBloc),
            ],
            child: const SwapSheet(),
          ),
        ),
      ),
    );
    // Post-frame callback → balance push, session read, source candidates.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Opens the buy picker and settles the sheet animation. The
  /// "ink splashes may be invisible" assertion is a pre-existing cosmetic trip
  /// of `TokenSelectorModal`'s own background; same filter as
  /// `swap_token_chain_test.dart`.
  Future<void> openBuyPicker(WidgetTester tester) async {
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);

    await tester.tap(find.text('USDC'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// One neutral drag inside the picker's list. `SheetOverscrollDismiss` builds
  /// its `AnimationController` lazily, and disposing a sheet that was never
  /// touched constructs a ticker from `dispose()`.
  Future<void> settlePickerForTeardown(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -5));
    await tester.pump();
  }

  testWidgets('Owned lists the whole session\'s holdings', (tester) async {
    await pumpSheet(tester);
    await openBuyPicker(tester);

    expect(find.text('Select token to buy'), findsOneWidget);
    // BONK is held by a sibling wallet, so it is absent from this sheet's
    // per-signer balance bloc. Scoping Owned to the signer would hide a token
    // the portfolio the user just came from lists plainly.
    expect(find.textContaining('Bonk'), findsOneWidget);
    expect(find.text('Solana'), findsOneWidget);
    await settlePickerForTeardown(tester);
  });

  testWidgets('Popular pins mallowSOL above the volume ranking', (
    tester,
  ) async {
    await pumpSheet(tester);
    await openBuyPicker(tester);

    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();

    // mallowSOL is mallow's own token and the sheet's default buy side, but it
    // trades ~1500th by volume — the ranking alone drops it off the tab, so
    // the tab would omit the one token this wallet most wants to surface.
    //
    // Rows are located by their subtitle (`name • mint`): a token with no image
    // renders its symbol inside the avatar too, and the sheet behind the modal
    // still shows the buy chip, so the symbol alone matches several widgets.
    // USDC reads `USDC •` rather than `USD Coin •` because the picker's own
    // registry row wins the by-mint substitution over the catalog's.
    final mallowSol = tester.getTopLeft(find.textContaining('mallowSOL •')).dy;
    expect(
      mallowSol,
      lessThan(tester.getTopLeft(find.textContaining('USDC •')).dy),
    );
    await settlePickerForTeardown(tester);
  });

  testWidgets('Popular keeps the catalog\'s verified tag on a held row', (
    tester,
  ) async {
    // A held row carries `isVerified` from market-data enrichment, which may
    // not have landed (or may have failed). Every row on this tab comes from
    // the verified catalog by definition, so substituting the held balance in
    // must not demote a top-volume token below the "Unverified" header — the
    // tab would be calling a Jupiter-verified token unverified.
    when(
      () => aggregator.signableSolanaBalances(refresh: any(named: 'refresh')),
    ).thenAnswer(
      (_) async => [signerSol, siblingBonk.copyWith(isVerified: false)],
    );
    when(() => verifiedTokens.popular(limit: any(named: 'limit'))).thenAnswer(
      (_) async => const [
        (
          mint: bonkMint,
          symbol: 'BONK',
          name: 'Bonk',
          iconUrl: null,
          decimals: 5,
          dailyVolume: 5000000.0,
        ),
        catalogUsdc,
      ],
    );

    await pumpSheet(tester);
    await openBuyPicker(tester);

    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Bonk •'), findsOneWidget);
    expect(find.text('Unverified tokens'), findsNothing);
    await settlePickerForTeardown(tester);
  });

  testWidgets('mallowSOL is pinned once, not duplicated', (tester) async {
    when(() => verifiedTokens.popular(limit: any(named: 'limit'))).thenAnswer(
      (_) async => const [
        catalogUsdc,
        (
          mint: mallow_tokens.mallowSolMint,
          symbol: 'mallowSOL',
          name: 'mallowSOL',
          iconUrl: null,
          decimals: 9,
          dailyVolume: 28.0,
        ),
      ],
    );

    await pumpSheet(tester);
    await openBuyPicker(tester);

    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();

    // The catalog does carry mallowSOL — it is simply ranked far down. Pinning
    // without dropping the ranked copy renders the row twice.
    expect(find.textContaining('mallowSOL •'), findsOneWidget);
    await settlePickerForTeardown(tester);
  });
}
