import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
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

/// `GET /v1/staking` carries the mallowSOL exchange rate and both APYs, and
/// the stake form parsed all of it and rendered none of it: no rate to check a
/// liquid quote against, no view of the position you already hold, and no
/// number attached to the yield the sheet is selling. These tests pin the
/// three stats the webapp shows in the same place (`MainContent`,
/// `StakingSection`).
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

  StakingDataResponse stakingData({
    double solPerMallowSol = 1.234567,
    int activeLamports = 2500000000,
  }) => StakingDataResponse.fromJson({
    'nativeApy': 0.07,
    'liquidApy': 0.05,
    'solPerMallowSol': solPerMallowSol,
    'totalSolStaked': '1000000000000',
    'totalStakers': 1234,
    'totalSeasonPoints': 100.0,
    'userData': {
      'spPerDay': 24.0,
      'liquidStake': 3000000000,
      'nativeStake': {
        'active': activeLamports,
        'inactive': 0,
        'activating': 0,
        'deactivating': 0,
      },
    },
    'currentSeason': {'season': 3, 'label': 'Season 3', 'rewardPool': 1000.0},
    'leaderboard': <Map<String, dynamic>>[],
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

  Future<void> disposeForm(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('the mallowSOL exchange rate is on the stake tab', (
    tester,
  ) async {
    await pumpForm(tester, StakingState(data: stakingData()));

    // Without this, "Receive 0.95 mallowSOL" on the liquid path is a number
    // the user has nothing to compare against.
    expect(find.text('1 mallowSOL ='), findsOneWidget);
    expect(find.text('1.23457 SOL'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('an em dash stands in for an unpriced mallowSOL', (tester) async {
    // A zero rate is "the backend could not price it", not "1 mallowSOL is
    // worth nothing" — showing `0 SOL` would read as the latter.
    // Native, so the liquid path's own "Receive —" placeholder can't be what
    // satisfies the em-dash assertion below.
    await pumpForm(
      tester,
      StakingState(
        stakeType: StakeType.native,
        data: stakingData(solPerMallowSol: 0),
      ),
    );

    expect(find.text('0 SOL'), findsNothing);
    expect(find.text('—'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('a signed-in staker sees the position they already hold', (
    tester,
  ) async {
    await pumpForm(
      tester,
      StakingState(
        data: stakingData(),
        myAddress: 'STAKER',
        mallowSolLamports: 3000000000,
      ),
    );

    expect(find.text('Your native stake'), findsOneWidget);
    expect(find.text('2.5 SOL'), findsOneWidget);
    // The liquid position is the mallowSOL balance itself, in mallowSOL —
    // the same number the unstake tab will let them redeem.
    expect(find.text('Your liquid stake'), findsOneWidget);
    expect(find.text('3 mallowSOL'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('the position cards stay hidden with no wallet resolved', (
    tester,
  ) async {
    await pumpForm(tester, StakingState(data: stakingData()));

    expect(find.text('Your native stake'), findsNothing);
    expect(find.text('Your liquid stake'), findsNothing);

    await disposeForm(tester);
  });

  testWidgets('the yield estimate follows the selected staking path', (
    tester,
  ) async {
    await pumpForm(
      tester,
      StakingState(
        stakeType: StakeType.native,
        data: stakingData(),
        amount: '10',
        solLamports: 20000000000,
      ),
    );

    // 10 SOL at the 7% native APY.
    expect(find.text('Estimated yield'), findsOneWidget);
    expect(find.text('~0.7 SOL / year'), findsOneWidget);

    await disposeForm(tester);

    await pumpForm(
      tester,
      StakingState(data: stakingData(), amount: '10', solLamports: 20000000000),
    );

    // The two paths pay differently; quoting the native APY on the liquid
    // path would overstate the return by 40%.
    expect(find.text('~0.5 SOL / year'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('an empty amount quotes no yield', (tester) async {
    // `submitLamports` floors a native stake at the rent-adjusted minimum, so
    // reading the estimate off it would promise yield on an untouched field.
    await pumpForm(tester, StakingState(data: stakingData()));

    expect(find.text('Estimated yield'), findsOneWidget);
    expect(find.text('~0 SOL / year'), findsOneWidget);

    await disposeForm(tester);
  });

  testWidgets('the unstake tab shows neither stats nor a yield estimate', (
    tester,
  ) async {
    await pumpForm(
      tester,
      StakingState(
        data: stakingData(),
        tab: StakeTab.unstake,
        myAddress: 'STAKER',
      ),
    );

    expect(find.text('1 mallowSOL ='), findsNothing);
    expect(find.text('Estimated yield'), findsNothing);

    await disposeForm(tester);
  });
}
