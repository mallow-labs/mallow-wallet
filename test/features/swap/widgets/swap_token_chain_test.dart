import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
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

/// Swap is Jupiter-backed and no swap provider is wired for Ethereum or Tezos
/// yet, so an ETH/XTZ row anywhere in the sheet is a dead end — it can only
/// quote an error. The sheet's own `TokenBalanceBloc` merges all three chains
/// (that is what the portfolio tab renders), so the chain filter is the only
/// thing keeping those rows out of the pickers and out of the default seeding.
/// These tests fail the moment that filter is dropped.
void main() {
  const address = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

  const wallet = WalletInfo(
    id: 'wallet-a',
    address: address,
    name: 'A',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );

  const solToken = TokenBalance(
    mint: 'So11111111111111111111111111111111111111112',
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    isNative: true,
  );
  const usdcToken = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 5000000,
    uiBalance: 5.0,
  );
  final ethToken = TokenBalance.nativeEth(
    wei: BigInt.from(2000000000000000000),
  );
  const usdtToken = TokenBalance(
    mint: '0xdac17f958d2ee523a2206206994597c13d831ec7',
    symbol: 'USDT',
    name: 'Tether USD',
    decimals: 6,
    rawBalance: 7000000,
    uiBalance: 7.0,
    chain: Chain.ethereum,
  );
  final xtzToken = TokenBalance.nativeTezos(mutez: 3000000);

  late MockSwapBloc swapBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockSessionPortfolioAggregator aggregator;

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

    whenListen(
      swapBloc,
      const Stream<SwapState>.empty(),
      initialState: const SwapState(sellToken: solToken, buyToken: usdcToken),
    );
    // Every chain the portfolio reads, in the order the repository's sort
    // produces: natives first (all three of them), then the rest by USD value.
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: TokenBalanceState.loaded(
        tokens: [solToken, ethToken, xtzToken, usdcToken, usdtToken],
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

    // The buy picker warms and searches the Jupiter verified catalog; stubbed
    // out so these chain-filter assertions see only the local rows.
    final verifiedTokens = MockJupiterVerifiedTokenListService();
    when(() => verifiedTokens.ensureCached()).thenAnswer((_) async {});
    when(() => verifiedTokens.search(any())).thenAnswer((_) async => const []);

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
    // Post-frame callback → balance push + source-candidate load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Opens a picker via its token chip and settles the sheet animation.
  ///
  /// `TokenSelectorModal` paints its own background behind Material's
  /// `ListTile`s, which trips a debug-only "ink splashes may be invisible"
  /// assertion. It predates this test and is cosmetic, so it is filtered rather
  /// than fixed here; anything else still fails the test.
  Future<void> openPicker(WidgetTester tester, String chipSymbol) async {
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

    await tester.tap(find.text(chipSymbol));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// One neutral pointer-down inside the picker's list. `SheetOverscrollDismiss`
  /// creates its `AnimationController` lazily, and disposing a sheet that was
  /// never touched constructs a ticker from `dispose()` — which trips a
  /// framework assertion when the test's widget tree is finalised. Same
  /// workaround as `test/features/activity/screens/activity_sheet_test.dart`;
  /// a drag rather than a tap so no token is selected.
  Future<void> settlePickerForTeardown(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -5));
    await tester.pump();
  }

  // Rows are asserted on the subtitle (`name`), not the symbol: a token with
  // no image renders its symbol inside the avatar too, which would match twice.
  // Matched as a substring because a non-base token's subtitle also carries its
  // truncated mint — an exact match would pass vacuously if a row *were* there.
  void expectNoOtherChains() {
    expect(find.textContaining('Ethereum'), findsNothing);
    expect(find.textContaining('Tether USD'), findsNothing);
    expect(find.textContaining('Tezos'), findsNothing);
  }

  testWidgets('the sell picker lists only Solana holdings', (tester) async {
    await pumpSheet(tester);
    await openPicker(tester, 'SOL');

    expect(find.text('Select token to sell'), findsOneWidget);
    expect(find.text('Solana'), findsOneWidget);
    expect(find.textContaining('USD Coin'), findsOneWidget);
    expectNoOtherChains();
    await settlePickerForTeardown(tester);
  });

  testWidgets('the buy picker lists only Solana holdings and registry tokens', (
    tester,
  ) async {
    await pumpSheet(tester);
    await openPicker(tester, 'USDC');

    expect(find.text('Select token to buy'), findsOneWidget);
    expect(find.text('Solana'), findsOneWidget);
    // The registry side of this list is already Solana-only (`disableSwap` on
    // ETH/XTZ/oXTZ); this guards the held tokens spliced in ahead of it.
    expectNoOtherChains();
    await settlePickerForTeardown(tester);
  });

  testWidgets('only Solana balances reach the bloc, so the default sell side '
      'can never seed to another chain\'s native coin', (tester) async {
    await pumpSheet(tester);

    final pushed = verify(
      () => swapBloc.add(captureAny(that: isA<SwapBalancesUpdated>())),
    ).captured.cast<SwapBalancesUpdated>().single;

    expect(pushed.tokens, [solToken, usdcToken]);
    expect(pushed.tokens.where((t) => t.isNative).single.symbol, 'SOL');
  });
}
