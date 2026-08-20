import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/swap/services/swap_bloc.dart';
import 'package:mallow_wallet/features/swap/widgets/swap_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class MockSwapBloc extends MockBloc<SwapEvent, SwapState> implements SwapBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class MockWalletManager extends Mock implements WalletManager {}

class MockSessionManager extends Mock implements SessionManager {}

class MockTokenPriceService extends Mock implements TokenPriceService {}

/// The swap sheet's source-wallet affordance.
///
/// The affordance is only correct if a switch also **re-derives everything
/// quoted for the outgoing wallet**: a Jupiter order is compiled around its
/// taker, so a quote from wallet A signed by wallet B is a loss-of-funds path.
/// These tests therefore assert
/// on the events the sheet dispatches after a switch, not merely that the
/// picker opened.
void main() {
  const addressA = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const addressB = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';
  const addressC = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

  const walletA = WalletInfo(
    id: 'wallet-a',
    address: addressA,
    name: 'A',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );
  const walletB = WalletInfo(
    id: 'wallet-b',
    address: addressB,
    name: 'B',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct',
  );
  const walletC = WalletInfo(
    id: 'wallet-c',
    address: addressC,
    name: 'C',
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
    rawBalance: 0,
    uiBalance: 0,
  );

  const readyQuote = SwapState(
    sellToken: solToken,
    buyToken: usdcToken,
    amount: '1.0',
    flow: TxFlowReady(
      SwapQuoteData(
        order: UltraOrderResponseDto(
          inputMint: 'So11111111111111111111111111111111111111112',
          outputMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
          inAmount: '1000000000',
          outAmount: '200000000',
          otherAmountThreshold: '198000000',
          requestId: 'req-1',
          transaction: 'dHg=',
        ),
        outputAmount: 200.0,
        rate: 200.0,
        taker: addressA,
      ),
    ),
  );

  SendSourceCandidate candidate(WalletInfo wallet, double balance) =>
      SendSourceCandidate(
        wallet: wallet,
        rawBalance: (balance * 1000000000).round(),
        uiBalance: balance,
      );

  late MockSwapBloc swapBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockSessionPortfolioAggregator aggregator;
  late MockWalletManager walletManager;
  late MockSessionManager sessionManager;

  /// Addresses `selectSourceWallet` was pointed at, in order.
  late List<String> switches;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() {
    registerFallbackValue(walletA);
    registerFallbackValue(Chain.solana);
  });

  setUp(() {
    switches = [];
    swapBloc = MockSwapBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    aggregator = MockSessionPortfolioAggregator();
    walletManager = MockWalletManager();
    sessionManager = MockSessionManager();

    whenListen(
      swapBloc,
      const Stream<SwapState>.empty(),
      initialState: readyQuote,
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    when(() => walletManager.getAddress()).thenAnswer((_) async => addressA);
    // The sell picker's session-wide rows — not what these tests assert on, but
    // the sheet reads them on open (see swap_sell_picker_test.dart).
    when(
      () => aggregator.signableSolanaBalances(refresh: any(named: 'refresh')),
    ).thenAnswer((_) async => const [solToken]);
    when(() => sessionManager.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      switches.add(
        (invocation.positionalArguments.single as WalletInfo).address,
      );
    });

    final priceService = MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(null);

    register<SessionPortfolioAggregator>(aggregator);
    register<WalletManager>(walletManager);
    register<SessionManager>(sessionManager);
    register<TokenPriceService>(priceService);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<SessionPortfolioAggregator>();
    drop<WalletManager>();
    drop<SessionManager>();
    drop<TokenPriceService>();
  });

  void stubCandidates(List<SendSourceCandidate> candidates) {
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async => candidates);
  }

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
    // Post-frame callback → source address + candidate load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Advances past the picker sheet's entrance animation and its tap guard.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('no Switch affordance for a single funding candidate', (
    tester,
  ) async {
    stubCandidates([candidate(walletA, 1)]);
    await pumpSheet(tester);

    expect(find.textContaining('Your wallet'), findsOneWidget);
    expect(find.text('Switch'), findsNothing);
  });

  testWidgets('no Switch affordance when the session has no candidates', (
    tester,
  ) async {
    stubCandidates(const []);
    await pumpSheet(tester);

    expect(find.text('Switch'), findsNothing);
  });

  testWidgets(
    'two funded session wallets: the picker lists both, and choosing the '
    'non-active one switches and re-derives the quote and balances',
    (tester) async {
      stubCandidates([candidate(walletA, 1), candidate(walletB, 5)]);
      await pumpSheet(tester);

      expect(find.text('Switch'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await settleSheet(tester);

      // Both wallets offered, each with its balance of the sell token.
      expect(find.text('Select Solana wallet'), findsOneWidget);
      expect(find.text(truncateAddress(addressA)), findsOneWidget);
      expect(find.text(truncateAddress(addressB)), findsOneWidget);
      expect(find.text('Bal: 1 SOL'), findsOneWidget);
      expect(find.text('Bal: 5 SOL'), findsOneWidget);

      await tester.tap(find.text(truncateAddress(addressB)));
      await settleSheet(tester);

      expect(switches, [addressB]);
      // Everything derived for wallet A is invalidated and re-derived: the
      // quote (bloc-side, see swap_bloc_test) and the balances the sell-side
      // row and Half/Max read from.
      verify(
        () => swapBloc.add(const SwapEvent.sourceWalletChanged()),
      ).called(1);
      verify(
        () => tokenBalanceBloc.add(const TokenBalanceEvent.refresh()),
      ).called(1);
      // The source line now names the new funding wallet.
      expect(
        find.text('Your wallet: ${truncateAddress(addressB)}'),
        findsOneWidget,
      );
      // Candidates are re-read for the new wallet (initial load + reload).
      verify(
        () => aggregator.sendSourcesForMint(
          chain: Chain.solana,
          mint: solToken.mint,
        ),
      ).called(2);
    },
  );

  testWidgets(
    'the active wallet holds none of the sell token: the sheet adopts the '
    'wallet that does and re-derives against it',
    (tester) async {
      // Entry is the portfolio, which aggregates every session wallet — so the
      // seeded sell token can be one the active signer (A) has none of. Signing
      // stays single-wallet, so without this the swap could only fail.
      stubCandidates([candidate(walletA, 0), candidate(walletB, 5)]);
      await pumpSheet(tester);
      await settleSheet(tester);

      expect(switches, [addressB]);
      verify(
        () => swapBloc.add(const SwapEvent.sourceWalletChanged()),
      ).called(1);
      verify(
        () => tokenBalanceBloc.add(const TokenBalanceEvent.refresh()),
      ).called(1);
      expect(
        find.text('Your wallet: ${truncateAddress(addressB)}'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'no session wallet holds the sell token: nothing is switched, and the '
    'cache-only candidate read is confirmed against the network first',
    (tester) async {
      stubCandidates([candidate(walletA, 0), candidate(walletB, 0)]);
      await pumpSheet(tester);
      await settleSheet(tester);

      // Nowhere better to go — the swap stays on the active wallet and blocks
      // at the balance check rather than switching the user somewhere just as
      // empty.
      expect(switches, isEmpty);
      verifyNever(() => swapBloc.add(const SwapEvent.sourceWalletChanged()));
      expect(
        find.text('Your wallet: ${truncateAddress(addressA)}'),
        findsOneWidget,
      );
      // A cold per-wallet cache reports an unread sibling at zero, so "nobody
      // holds it" is only true once the balances have been re-read live.
      verify(
        () => aggregator.sendSourcesForMint(
          chain: any(named: 'chain'),
          mint: any(named: 'mint'),
          refresh: true,
        ),
      ).called(1);
    },
  );

  testWidgets('auto-switch picks the largest holder of the sell token', (
    tester,
  ) async {
    // The amount is entered *after* the switch, so the wallet most likely to
    // cover it wins — a dust-holding wallet would strand the user right back at
    // an insufficient balance.
    stubCandidates([
      candidate(walletA, 0),
      candidate(walletB, 0.5),
      candidate(walletC, 5),
    ]);
    await pumpSheet(tester);
    await settleSheet(tester);

    expect(switches, [addressC]);
  });

  testWidgets(
    'a failed switch surfaces the error and leaves the flow on the previous '
    'wallet',
    (tester) async {
      stubCandidates([candidate(walletA, 1), candidate(walletB, 5)]);
      // `selectSourceWallet` is async, so a failed switch arrives as a
      // rejected future (the T0.2 rollback has already re-pointed the DB).
      when(
        () => sessionManager.selectSourceWallet(any()),
      ).thenAnswer((_) => Future<void>.error(Exception('offline')));
      await pumpSheet(tester);

      await tester.tap(find.text('Switch'));
      await settleSheet(tester);
      await tester.tap(find.text(truncateAddress(addressB)));
      await settleSheet(tester);

      expect(
        find.text("Couldn't switch wallet. Please try again."),
        findsOneWidget,
      );
      // Nothing downstream moved: no re-quote, no balance reload, and the
      // sheet is still funded by — and would still sign with — wallet A.
      verifyNever(() => swapBloc.add(const SwapEvent.sourceWalletChanged()));
      verifyNever(
        () => tokenBalanceBloc.add(const TokenBalanceEvent.refresh()),
      );
      verifyNever(() => swapBloc.add(const SwapEvent.execute()));
      expect(
        find.text('Your wallet: ${truncateAddress(addressA)}'),
        findsOneWidget,
      );
    },
  );
}
