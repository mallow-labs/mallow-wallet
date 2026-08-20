import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/data/epoch_progress.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/stake_confirm_sheet.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_form_tab.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
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

class MockPriorityFeeService extends Mock implements PriorityFeeService {}

/// Stake and Unstake move real funds and the stake sheet's CTA sat one stray
/// tap away from signing. These tests pin the interstitial that now stands
/// between them: that the form does **not** submit until it returns, and that
/// what it reports is the transaction that is actually about to be signed —
/// the right amount in the right token, the right epoch/swap consequence for
/// the mechanism chosen, and a fee that follows the user's own priority
/// setting rather than a hardcoded guess.
void main() {
  setUpAll(() => registerFallbackValue(Chain.solana));

  late MockStakingBloc stakingBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockPriorityFeeService priorityFee;
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

    priorityFee = MockPriorityFeeService();
    // Auto — the ceiling every unset wallet resolves to.
    when(
      () => priorityFee.ceilingLamports,
    ).thenReturn(kAutoPriorityFeeLamports);
    register<PriorityFeeService>(priorityFee);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<RemoteConfigService>();
    drop<SessionPortfolioAggregator>();
    drop<TokenPriceService>();
    drop<PriorityFeeService>();
    config.dispose();
  });

  /// 1 SOL in, 0.95 mallowSOL out — the client's default 50 bps quote.
  JupiterClassicQuote quote({
    String inAmount = '1000000000',
    String outAmount = '950000000',
  }) => JupiterClassicQuote({
    'inAmount': inAmount,
    'outAmount': outAmount,
    'slippageBps': 50,
  });

  /// Let `showMallowSheet`'s entrance tap-guard release. It arms a bare
  /// `Timer` once the route animation finishes, and a timer that schedules no
  /// frame is not advanced by `pumpAndSettle` — without this every tap on a
  /// freshly-presented sheet is swallowed exactly as a too-eager real one is.
  Future<void> settleSheetTapGuard(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  /// A `/v1/staking` payload carrying only the native-stake breakdown the
  /// deactivation line reads — every other field is inert here.
  StakingDataResponse dataWith({int active = 0, int activating = 0}) =>
      StakingDataResponse(
        nativeApy: 0.0574,
        liquidApy: 0.0559,
        solPerMallowSol: 1.0,
        totalSolStakedLamports: '0',
        totalStakers: 0,
        totalSeasonPoints: 0,
        userData: StakingUserData(
          spPerDay: 0,
          nativeStake: NativeStakeBreakdown(
            activeLamports: active,
            inactiveLamports: 0,
            activatingLamports: activating,
            deactivatingLamports: 0,
          ),
          liquidStakeLamports: 0,
        ),
        currentSeason: const StakingSeason(
          season: 3,
          label: 'Season 3',
          endsAt: null,
          rewardPool: 0,
          rewardsSentAt: null,
        ),
        leaderboard: const [],
      );

  /// An epoch with 1d 5h of slots left to run (29 h / 400 ms per slot).
  const epoch = EpochProgress(
    epoch: 800,
    slotIndex: 432000 - 261000,
    slotsInEpoch: 432000,
  );

  /// Hold the bloc at one fixed [state]. It never emits, so what each test
  /// asserts is a pure function of the form state the user left behind.
  void seed(StakingState state) => whenListen(
    stakingBloc,
    const Stream<StakingState>.empty(),
    initialState: state,
  );

  /// Pump [home] on a viewport tall enough for the sheet to lay out unclipped —
  /// the default 800 px is shorter than the confirm column, and an overflow
  /// there would fail tests for a reason none of them are about.
  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: MallowTheme.lightTheme, home: home),
    );
    await tester.pump();
  }

  Future<void> pumpSheet(WidgetTester tester, StakingState state) async {
    seed(state);
    await pumpApp(
      tester,
      Scaffold(
        body: BlocProvider<StakingBloc>.value(
          value: stakingBloc,
          child: const StakeConfirmSheet(),
        ),
      ),
    );
  }

  group('what the sheet reports', () {
    testWidgets('a native stake names its amount and when it activates', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        const StakingState(
          stakeType: StakeType.native,
          amount: '1.5',
          solLamports: 5000000000,
          epochProgress: epoch,
        ),
      );

      expect(find.text('Confirm Stake'), findsOneWidget);
      expect(find.text('1.5 SOL'), findsOneWidget);
      // The mechanism is picked on the form and decides whether these funds
      // lock for an epoch or swap instantly, so the review step has to name it
      // back rather than leave the user to infer it from the sections below.
      expect(find.text('Native stake'), findsOneWidget);
      expect(find.text('Liquid stake'), findsNothing);
      // Native stake is epoch-bound: when the funds start earning is the one
      // consequence a user cannot infer from the form.
      expect(find.text('Activates in'), findsOneWidget);
      expect(find.text('1d 5h'), findsOneWidget);
      // There is no swap on this path, so nothing may claim one.
      expect(find.text("You'll receive"), findsNothing);
    });

    testWidgets('a native unstake names when it deactivates', (tester) async {
      await pumpSheet(
        tester,
        const StakingState(
          tab: StakeTab.unstake,
          stakeType: StakeType.native,
          amount: '2',
          epochProgress: epoch,
        ),
      );

      expect(find.text('Confirm Unstake'), findsOneWidget);
      // The reverse direction has to name the reverse consequence — the same
      // countdown means something different here.
      expect(find.text('Deactivates in'), findsOneWidget);
      expect(find.text('Activates in'), findsNothing);
    });

    testWidgets('unstaking stake that is still activating lands immediately', (
      tester,
    ) async {
      // Deactivating an account that never finished activating short-circuits
      // to inactive on the spot, so the funds are claimable the moment the tx
      // lands. Quoting the epoch countdown here would tell a user their SOL is
      // locked for two days when it is already back in the wallet.
      await pumpSheet(
        tester,
        StakingState(
          tab: StakeTab.unstake,
          stakeType: StakeType.native,
          amount: '2',
          data: dataWith(activating: 3000000000),
          epochProgress: epoch,
        ),
      );

      expect(find.text('Deactivates'), findsOneWidget);
      expect(find.text('Immediately'), findsOneWidget);
      expect(find.text('Deactivates in'), findsNothing);
      expect(find.text('1d 5h'), findsNothing);
    });

    testWidgets('unstaking with active stake in hand keeps the countdown', (
      tester,
    ) async {
      // The builder takes accounts largest-first across active *and*
      // activating, so a mixed position gives this sheet no way to know which
      // it will touch — it must not promise the instant path.
      await pumpSheet(
        tester,
        StakingState(
          tab: StakeTab.unstake,
          stakeType: StakeType.native,
          amount: '2',
          data: dataWith(active: 5000000000, activating: 3000000000),
          epochProgress: epoch,
        ),
      );

      expect(find.text('Deactivates in'), findsOneWidget);
      expect(find.text('1d 5h'), findsOneWidget);
      expect(find.text('Immediately'), findsNothing);
    });

    testWidgets('a liquid stake reports the swap output, not an epoch', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        StakingState(
          amount: '1',
          solLamports: 5000000000,
          liquidQuote: quote(),
          epochProgress: epoch,
        ),
      );

      expect(find.text('Liquid stake'), findsOneWidget);
      expect(find.text('Native stake'), findsNothing);
      // Liquid staking is a swap that settles instantly — an epoch countdown
      // here would describe a lock that does not exist.
      expect(find.text('Activates in'), findsNothing);
      expect(find.text("You'll receive"), findsOneWidget);
      expect(find.text('0.95 mallowSOL'), findsOneWidget);
    });

    testWidgets('a liquid unstake spends mallowSOL and returns SOL', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        StakingState(
          tab: StakeTab.unstake,
          amount: '1',
          mallowSolLamports: 5000000000,
          liquidQuote: quote(outAmount: '1050000000'),
        ),
      );

      // The token spent is mallowSOL, not SOL — naming the wrong one is the
      // whole reason this direction gets its own assertion.
      expect(find.text('1 mallowSOL'), findsOneWidget);
      expect(find.text('1.05 SOL'), findsOneWidget);
    });

    testWidgets('a quote for a different amount is not shown as this trade', (
      tester,
    ) async {
      // 2 SOL typed, only a 1 SOL quote in hand. Attaching its output to this
      // trade would put a number on screen the swap will not return.
      await pumpSheet(
        tester,
        StakingState(
          amount: '2',
          solLamports: 5000000000,
          liquidQuote: quote(),
        ),
      );

      expect(find.text('0.95 mallowSOL'), findsNothing);
      expect(find.byType(ShimmerBox), findsOneWidget);
      // The bloc fetches a quote at submit when it holds none, so a pending
      // one is not a reason to strand the user on a dead button.
      final cta = tester.widget<MallowButton>(
        find.widgetWithText(MallowButton, 'Stake'),
      );
      expect(cta.enabled, isTrue);
    });
  });

  group('the network fee', () {
    testWidgets('follows the wallet default when the setting is Auto', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        const StakingState(
          stakeType: StakeType.native,
          amount: '1',
          solLamports: 5000000000,
        ),
      );

      // 5 000 base + 50 000 Auto ceiling.
      expect(find.text('~0.000055 SOL'), findsOneWidget);
    });

    testWidgets('follows the user\'s own priority-fee ceiling', (tester) async {
      // A user who raised their ceiling to High is quoted that ceiling — a
      // hardcoded default would under-report their fee by 20×.
      when(() => priorityFee.ceilingLamports).thenReturn(1000000);

      await pumpSheet(
        tester,
        const StakingState(
          stakeType: StakeType.native,
          amount: '1',
          solLamports: 5000000000,
        ),
      );

      expect(find.text('~0.001005 SOL'), findsOneWidget);
    });
  });

  group('what the sheet returns', () {
    Future<bool?> openAndTap(WidgetTester tester, String label) async {
      seed(
        const StakingState(
          stakeType: StakeType.native,
          amount: '1',
          solLamports: 5000000000,
          epochProgress: epoch,
        ),
      );

      bool? result;
      await pumpApp(
        tester,
        BlocProvider<StakingBloc>.value(
          value: stakingBloc,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showStakeConfirmSheet(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await settleSheetTapGuard(tester);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('confirming resolves true', (tester) async {
      expect(await openAndTap(tester, 'Stake'), isTrue);
    });

    testWidgets('cancelling resolves false', (tester) async {
      // Not null: the caller distinguishes "declined" from "dismissed" only
      // insofar as neither may submit, and both must stay off the wire.
      expect(await openAndTap(tester, 'Cancel'), isFalse);
    });
  });

  group('the form gate', () {
    testWidgets('tapping Stake submits nothing until the sheet confirms', (
      tester,
    ) async {
      // The entire point of the interstitial: before it, this tap signed.
      seed(
        const StakingState(
          stakeType: StakeType.native,
          amount: '1',
          solLamports: 5000000000,
          myAddress: 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH',
          epochProgress: epoch,
        ),
      );

      await pumpApp(
        tester,
        Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<StakingBloc>.value(value: stakingBloc),
              BlocProvider<TokenBalanceBloc>.value(value: tokenBalanceBloc),
            ],
            child: const StakingFormTab(),
          ),
        ),
      );

      await tester.tap(find.text('Stake'));
      await tester.pumpAndSettle();

      verifyNever(() => stakingBloc.add(const StakingEvent.submit()));
      expect(find.text('Confirm Stake'), findsOneWidget);
      await settleSheetTapGuard(tester);

      // ...and confirming from the sheet is what releases it. Targeted inside
      // the sheet: the form's own CTA carries the same label underneath it.
      await tester.tap(
        find.descendant(
          of: find.byType(StakeConfirmSheet),
          matching: find.widgetWithText(MallowButton, 'Stake'),
        ),
      );
      await tester.pumpAndSettle();
      verify(() => stakingBloc.add(const StakingEvent.submit())).called(1);
    });
  });
}
