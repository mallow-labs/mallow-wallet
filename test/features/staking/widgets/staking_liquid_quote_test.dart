import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_form_tab.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class MockStakingBloc extends MockBloc<StakingEvent, StakingState>
    implements StakingBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class MockTokenPriceService extends Mock implements TokenPriceService {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

/// A liquid stake or unstake is a **Jupiter swap**, and the user signs it from
/// this form. Before this the quote was fetched, spent building the tx and
/// never rendered: no receive amount, no refresh. These
/// tests pin the disclosure and its two honesty rules — a quote priced for a
/// different amount is never shown as this trade's, and the quote on screen is
/// re-fetched rather than left to age.
void main() {
  setUpAll(() => registerFallbackValue(Chain.solana));

  late MockStakingBloc stakingBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    stakingBloc = MockStakingBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    config = ValueNotifier(RemoteConfig.permissive);
    final remoteConfig = MockRemoteConfigService();
    when(() => remoteConfig.config).thenReturn(config);
    when(remoteConfig.refreshIfStale).thenAnswer((_) async {});
    register<RemoteConfigService>(remoteConfig);

    final aggregator = MockSessionPortfolioAggregator();
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async => const []);
    register<SessionPortfolioAggregator>(aggregator);

    final priceService = MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(null);
    register<TokenPriceService>(priceService);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<RemoteConfigService>();
    drop<SessionPortfolioAggregator>();
    drop<TokenPriceService>();
    config.dispose();
  });

  /// 1 SOL in, 0.95 mallowSOL out, quoted at the client's default 50 bps.
  JupiterClassicQuote quote({
    String inAmount = '1000000000',
    String outAmount = '950000000',
  }) => JupiterClassicQuote({
    'inAmount': inAmount,
    'outAmount': outAmount,
    'slippageBps': 50,
  });

  Future<void> pumpForm(WidgetTester tester, StakingState state) async {
    whenListen(
      stakingBloc,
      const Stream<StakingState>.empty(),
      initialState: state,
    );
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<StakingBloc>.value(value: stakingBloc),
              BlocProvider<TokenBalanceBloc>.value(value: tokenBalanceBloc),
            ],
            child: const StakingFormTab(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Disposes the tree so the 30 s quote poll is cancelled with it.
  Future<void> disposeForm(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('a liquid stake discloses what it receives', (tester) async {
    await pumpForm(
      tester,
      StakingState(amount: '1', solLamports: 5000000000, liquidQuote: quote()),
    );

    expect(find.text('Receive'), findsOneWidget);
    expect(find.text('0.95 mallowSOL'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('a liquid unstake discloses the SOL it returns', (tester) async {
    await pumpForm(
      tester,
      StakingState(
        tab: StakeTab.unstake,
        amount: '1',
        mallowSolLamports: 5000000000,
        liquidQuote: quote(outAmount: '1050000000'),
      ),
    );

    // The reverse direction has to name the reverse token, or the disclosure is
    // worse than none.
    expect(find.text('1.05 SOL'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('a quote for a different amount is not shown as this trade', (
    tester,
  ) async {
    // The user typed 2 SOL; the only quote in hand priced 1 SOL. Showing its
    // receive amount would attach a real number to a trade that will not
    // return it.
    await pumpForm(
      tester,
      StakingState(amount: '2', solLamports: 5000000000, liquidQuote: quote()),
    );

    expect(find.text('0.95 mallowSOL'), findsNothing);
    expect(find.text('Fetching…'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('the native path shows no swap disclosure', (tester) async {
    // Native staking is not a swap — there is no quote to disclose, and the
    // poll below must not run for it.
    await pumpForm(
      tester,
      const StakingState(
        stakeType: StakeType.native,
        amount: '1',
        solLamports: 5000000000,
      ),
    );

    expect(find.text('Receive'), findsNothing);

    await tester.pump(const Duration(seconds: 31));
    verifyNever(() => stakingBloc.add(const StakingEvent.refreshLiquidQuote()));
  });

  testWidgets('re-tapping the selected stake type does not re-fetch', (
    tester,
  ) async {
    // The bloc treats a re-tap as a no-op precisely so the quote in hand
    // survives it. Scheduling a refresh from the row regardless would undo
    // that: the receive line blanks and the same quote is fetched again, ~400 ms
    // after a tap that changed nothing.
    await pumpForm(
      tester,
      StakingState(amount: '1', solLamports: 5000000000, liquidQuote: quote()),
    );

    await tester.tap(find.text('Liquid'));
    await tester.pump(const Duration(milliseconds: 500));
    verifyNever(() => stakingBloc.add(const StakingEvent.refreshLiquidQuote()));

    // A real change still has to re-quote — that is what the debounce is for.
    await tester.tap(find.text('Native'));
    await tester.pump(const Duration(milliseconds: 500));
    verify(
      () => stakingBloc.add(const StakingEvent.refreshLiquidQuote()),
    ).called(1);

    await disposeForm(tester);
  });

  testWidgets('the liquid quote is re-fetched every 30 s', (tester) async {
    // Webapp parity (`StakingSection`). The sheet can sit open for
    // minutes; without the poll the number on screen — and the quote that gets
    // signed — is however old the last keystroke left it.
    await pumpForm(
      tester,
      StakingState(amount: '1', solLamports: 5000000000, liquidQuote: quote()),
    );

    await tester.pump(const Duration(seconds: 29));
    verifyNever(() => stakingBloc.add(const StakingEvent.refreshLiquidQuote()));

    await tester.pump(const Duration(seconds: 2));
    verify(
      () => stakingBloc.add(const StakingEvent.refreshLiquidQuote()),
    ).called(1);

    await tester.pump(const Duration(seconds: 30));
    verify(
      () => stakingBloc.add(const StakingEvent.refreshLiquidQuote()),
    ).called(1);

    await disposeForm(tester);
  });

  /// The amount field's leading mark names the token being spent. A liquid
  /// unstake spends mallowSOL, not SOL, so a hardcoded Solana mark told the
  /// user they were about to hand over the wrong asset — the same honesty rule
  /// as the receive line above, applied to the input side.
  testWidgets('the unstake amount field marks the mallowSOL it spends', (
    tester,
  ) async {
    await pumpForm(
      tester,
      const StakingState(
        tab: StakeTab.unstake,
        amount: '1',
        mallowSolLamports: 5000000000,
      ),
    );

    expect(_mallowSolMark, findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('the stake amount field keeps the SOL mark', (tester) async {
    // The reverse direction spends SOL — the mallowSOL logo must not leak onto
    // it when the tab flips back.
    await pumpForm(
      tester,
      const StakingState(amount: '1', solLamports: 5000000000),
    );

    expect(_mallowSolMark, findsNothing);

    await disposeForm(tester);
  });
}

/// The local mallowSOL logo, as `tokenImageWidget` resolves it by mint.
final _mallowSolMark = find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is AssetImage &&
      (w.image as AssetImage).assetName ==
          'assets/images/tokens/mallow-sol.webp',
);
