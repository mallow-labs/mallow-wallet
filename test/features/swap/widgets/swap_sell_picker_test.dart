import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
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

/// The swap sell picker.
///
/// The sheet signs with one wallet but is opened from a portfolio that
/// aggregates the whole session, so the picker has to offer every session
/// wallet's holdings — otherwise a token the user can plainly see in their
/// portfolio is unsellable, with nothing on screen explaining why. Widening it
/// is only safe if a pick then (a) re-points the swap at a wallet that actually
/// holds the token and (b) shows the *signer's* balance rather than the summed
/// one: Half/Max read that number, and offering another wallet's funds produces
/// a quote that can only fail.
void main() {
  const addressA = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const addressB = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';

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

  const solMint = 'So11111111111111111111111111111111111111112';
  const bonkMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';
  const airdropMint = '4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R';

  /// Wallet A's own SOL — 1 of the session's 6.
  const signerSol = TokenBalance(
    mint: solMint,
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1,
    isNative: true,
    isVerified: true,
  );

  /// The same mint as the portfolio shows it: summed across the session.
  const sessionSol = TokenBalance(
    mint: solMint,
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 6000000000,
    uiBalance: 6,
    isNative: true,
    isVerified: true,
  );

  /// Held only by wallet B — invisible to the active signer's balances.
  const siblingBonk = TokenBalance(
    mint: bonkMint,
    symbol: 'BONK',
    name: 'Bonk',
    decimals: 5,
    rawBalance: 10000000,
    uiBalance: 100,
    isVerified: true,
  );

  const unverifiedAirdrop = TokenBalance(
    mint: airdropMint,
    symbol: 'MYSTERY',
    name: 'Mystery Token',
    decimals: 6,
    rawBalance: 5000000,
    uiBalance: 5,
  );

  const usdc = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 0,
    uiBalance: 0,
    isVerified: true,
  );

  const idle = SwapState(sellToken: signerSol, buyToken: usdc);

  SendSourceCandidate candidate(WalletInfo wallet, int raw, double ui) =>
      SendSourceCandidate(wallet: wallet, rawBalance: raw, uiBalance: ui);

  late MockSwapBloc swapBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockSessionPortfolioAggregator aggregator;
  late MockWalletManager walletManager;
  late MockSessionManager sessionManager;
  late StreamController<SwapState> swapStates;
  late List<String> switches;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() {
    registerFallbackValue(walletA);
    registerFallbackValue(Chain.solana);
    registerFallbackValue(const SwapEvent.getQuote());
  });

  setUp(() {
    switches = [];
    swapBloc = MockSwapBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    aggregator = MockSessionPortfolioAggregator();
    walletManager = MockWalletManager();
    sessionManager = MockSessionManager();
    swapStates = StreamController<SwapState>.broadcast();

    whenListen(swapBloc, swapStates.stream, initialState: idle);
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      // Only wallet A's holdings — the sheet's own bloc is per-signer.
      initialState: const TokenBalanceState.loaded(
        tokens: [signerSol],
        totalUsdValue: 0,
      ),
    );
    when(() => walletManager.getAddress()).thenAnswer((_) async => addressA);
    when(() => sessionManager.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      switches.add(
        (invocation.positionalArguments.single as WalletInfo).address,
      );
    });
    when(
      () => aggregator.signableSolanaBalances(refresh: any(named: 'refresh')),
    ).thenAnswer(
      (_) async => const [sessionSol, siblingBonk, unverifiedAirdrop],
    );

    final priceService = MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(null);

    register<SessionPortfolioAggregator>(aggregator);
    register<WalletManager>(walletManager);
    register<SessionManager>(sessionManager);
    register<TokenPriceService>(priceService);
  });

  tearDown(() async {
    await swapStates.close();
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<SessionPortfolioAggregator>();
    drop<WalletManager>();
    drop<SessionManager>();
    drop<TokenPriceService>();
  });

  /// Candidate funding wallets, keyed by mint: A holds the SOL, B holds the
  /// BONK — the split the whole feature exists for.
  void stubCandidates() {
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((invocation) async {
      final mint = invocation.namedArguments[#mint] as String;
      return switch (mint) {
        solMint => [
          candidate(walletA, signerSol.rawBalance, signerSol.uiBalance),
          candidate(walletB, 5000000000, 5),
        ],
        bonkMint => [
          candidate(walletA, 0, 0),
          candidate(walletB, siblingBonk.rawBalance, siblingBonk.uiBalance),
        ],
        _ => <SendSourceCandidate>[],
      };
    });
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
    // Post-frame callback → source address, session tokens, candidate load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Advances past a sheet's entrance animation and its tap guard.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('SOL'));
    await settleSheet(tester);
  }

  /// The sell token the sheet handed the bloc.
  TokenBalance capturedSellToken() {
    final event =
        verify(
              () => swapBloc.add(captureAny(that: isA<SwapSetSellToken>())),
            ).captured.last
            as SwapSetSellToken;
    return event.token;
  }

  testWidgets('lists every session wallet\'s holdings, not just the signer\'s', (
    tester,
  ) async {
    stubCandidates();
    await pumpSheet(tester);
    await openPicker(tester);

    // BONK sits on wallet B and MYSTERY on neither — both are absent from the
    // per-signer balances the sheet gates on, but both are sellable: the sheet
    // switches funding wallets on the way.
    expect(find.widgetWithText(ListTile, 'BONK'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'MYSTERY'), findsOneWidget);
    // …and the unverified one is quarantined under its own header rather than
    // sitting next to the tokens the user recognises.
    expect(find.text('Unverified tokens'), findsOneWidget);
  });

  testWidgets(
    'picking a token only a sibling wallet holds re-points the swap at that '
    'wallet',
    (tester) async {
      stubCandidates();
      await pumpSheet(tester);
      await settleSheet(tester);
      // Wallet A holds the seeded SOL, so nothing has switched yet.
      expect(switches, isEmpty);

      await openPicker(tester);
      await tester.tap(find.widgetWithText(ListTile, 'BONK'));
      await settleSheet(tester);

      // The signer holds none of it, so the row's session-wide 100 BONK must
      // not survive the pick — Half/Max read this number.
      final picked = capturedSellToken();
      expect(picked.mint, bonkMint);
      expect(picked.rawBalance, 0);
      expect(picked.uiBalance, 0);

      // The bloc's reduction of that pick is what re-reads the funding
      // candidates, and the funding latch set by the initial SOL load must not
      // block the adoption.
      swapStates.add(idle.copyWith(sellToken: picked));
      await settleSheet(tester);

      expect(switches, [addressB]);
      verify(
        () => swapBloc.add(const SwapEvent.sourceWalletChanged()),
      ).called(1);
    },
  );

  testWidgets('a token the signer shares is narrowed to the signer\'s share', (
    tester,
  ) async {
    stubCandidates();
    await pumpSheet(tester);
    await openPicker(tester);

    await tester.tap(find.widgetWithText(ListTile, 'SOL'));
    await settleSheet(tester);

    // The picker row is the portfolio's 6 SOL (A's 1 + B's 5). Max on the
    // aggregate would build a quote for five wallets' worth of SOL that the
    // signer cannot pay.
    final picked = capturedSellToken();
    expect(picked.mint, solMint);
    expect(picked.uiBalance, 1);
  });

  testWidgets('falls back to the signer\'s own balances when the session read '
      'fails', (tester) async {
    stubCandidates();
    when(
      () => aggregator.signableSolanaBalances(refresh: any(named: 'refresh')),
    ).thenAnswer((_) async => throw Exception('offline'));

    await pumpSheet(tester);
    await openPicker(tester);

    // Losing the aggregate must not empty the picker: the signer's own
    // holdings are still perfectly sellable.
    expect(find.widgetWithText(ListTile, 'SOL'), findsOneWidget);
    expect(find.text('No tokens found'), findsNothing);
  });
}
