import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_form_tab.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

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

/// Phase 4b — staking's four kill-switch cells.
///
/// `showStakeSheet` is a single entry hosting four distinct tx builders, so a
/// gate at the sheet would be one switch for all four. The point of these
/// tests is the *separation*: killing the stake path must leave the ways back
/// out — `unstake-native` and `withdraw-stake` — reachable, because a kill
/// that strands deactivated SOL is worse than the bug it was pulled for.
void main() {
  StakingDataResponse dataWith({int inactive = 0}) => StakingDataResponse(
    nativeApy: 0.0574,
    liquidApy: 0.0559,
    solPerMallowSol: 1.0,
    totalSolStakedLamports: '0',
    totalStakers: 0,
    totalSeasonPoints: 0,
    userData: StakingUserData(
      spPerDay: 0,
      nativeStake: NativeStakeBreakdown(
        activeLamports: 5000000000,
        inactiveLamports: inactive,
        activatingLamports: 0,
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

    // A live CTA now opens the confirm sheet, which quotes the network fee
    // from the user's priority-fee ceiling.
    final priorityFee = MockPriorityFeeService();
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

  /// Run the confirm sheet's entrance to completion.
  ///
  /// Deliberately not `pumpAndSettle`: the sheet renders a `ShimmerBox` for any
  /// value still in flight (the epoch read, a liquid quote), and a shimmer
  /// never stops animating — settling would time out rather than fail on
  /// anything meaningful.
  Future<void> presentSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Seeds the kill switch with `'<chain>:<flow>' -> message` cells.
  void kill(Map<String, String> cells) =>
      config.value = RemoteConfig(disabledMessages: cells);

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

  testWidgets('killing stake-native leaves withdraw-stake reachable', (
    tester,
  ) async {
    // The escape hatch. Deactivated SOL only gets back to the wallet through
    // Claim, so a kill of the *stake* builder must not touch it — that would
    // strand funds for the length of the incident.
    kill({'solana:stake-native': 'Native staking is paused.'});
    await pumpForm(
      tester,
      StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: dataWith(inactive: 2000000000),
      ),
    );

    await tester.tap(find.text('Claim'));
    await tester.pump();

    verify(() => stakingBloc.add(const StakingEvent.claim())).called(1);
    expect(find.text('Native staking is paused.'), findsNothing);
  });

  testWidgets('killing stake-native does not disable the Unstake CTA', (
    tester,
  ) async {
    // `unstake-native` is the other escape hatch and a distinct builder. The
    // shared `stakingSubmitFlow` derivation is what keeps the CTA on the
    // unstake tab reading `unstake-native` rather than the tab-agnostic cell.
    kill({'solana:stake-native': 'Native staking is paused.'});
    await pumpForm(
      tester,
      StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        amount: '1',
        solLamports: 5000000000,
        data: dataWith(),
      ),
    );

    await tester.tap(find.text('Unstake'));
    await presentSheet(tester);

    // A live CTA reaches the confirm sheet, not the wire — the submit itself
    // is one deliberate tap further on (`stake_confirm_sheet_test.dart`). What
    // this asserts is that the kill did not reach this cell.
    expect(find.text('Confirm Unstake'), findsOneWidget);
  });

  testWidgets('a killed stake cell disables the CTA and explains verbatim', (
    tester,
  ) async {
    // Explained *before* the form is filled in — the whole reason this phase
    // exists — and in the operator's words, not client copy that would drift
    // from whatever the incident actually is.
    const message =
        'Native staking is paused while we rotate the validator. '
        'Your existing stake is untouched.';
    kill({'solana:stake-native': message});
    await pumpForm(
      tester,
      StakingState(
        stakeType: StakeType.native,
        amount: '2',
        solLamports: 5000000000,
        data: dataWith(),
      ),
    );

    expect(find.text(message), findsOneWidget);

    await tester.tap(find.text('Stake'));
    await presentSheet(tester);

    // The confirm sheet must not open either. `verifyNever(submit)` alone no
    // longer proves the kill holds — no CTA dispatches submit directly any
    // more, so that assertion would pass just as happily on a live cell.
    expect(find.text('Confirm Stake'), findsNothing);
    verifyNever(() => stakingBloc.add(const StakingEvent.submit()));
  });

  testWidgets('a killed withdraw-stake explains on tap instead of claiming', (
    tester,
  ) async {
    // Killing an escape hatch is allowed — it just has to be deliberate, and
    // the user staring at claimable SOL deserves to be told why the button
    // did nothing.
    const message = 'Stake withdrawals are paused. Your SOL is safe.';
    kill({'solana:withdraw-stake': message});
    await pumpForm(
      tester,
      StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: dataWith(inactive: 2000000000),
      ),
    );

    await tester.tap(find.text('Claim'));
    await tester.pumpAndSettle();

    verifyNever(() => stakingBloc.add(const StakingEvent.claim()));
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('killing stake-native leaves liquid staking submittable', (
    tester,
  ) async {
    // Native and liquid stake are different builders (client-side stake
    // program vs a Jupiter swap) and so different cells.
    kill({'solana:stake-native': 'Native staking is paused.'});
    await pumpForm(
      tester,
      StakingState(amount: '2', solLamports: 5000000000, data: dataWith()),
    );

    await tester.tap(find.text('Stake'));
    await presentSheet(tester);

    // As above: reaching the confirm sheet is what "still submittable" looks
    // like from the form now.
    expect(find.text('Confirm Stake'), findsOneWidget);
  });
}
