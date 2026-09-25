import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_form_tab.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

// The App Store build hides token swap (Guideline 3.1.5(ii)), and a liquid
// stake is a swap — the same `stake-liquid` builder in both directions. So the
// stake sheet loses its type selector entirely and becomes native-only: not a
// disabled Liquid row, not a Liquid row that errors on tap. Native staking,
// its 1 SOL minimum, its epoch note and the Claim escape hatch are untouched.

class _MockStakingBloc extends MockBloc<StakingEvent, StakingState>
    implements StakingBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class _MockTokenPriceService extends Mock implements TokenPriceService {}

class _MockRemoteConfigService extends Mock implements RemoteConfigService {}

class _MockPriorityFeeService extends Mock implements PriorityFeeService {}

void main() {
  setUpAll(() => registerFallbackValue(Chain.solana));

  late _MockStakingBloc stakingBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  StakingDataResponse data() => StakingDataResponse(
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
        inactiveLamports: 0,
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

  setUp(() {
    stakingBloc = _MockStakingBloc();
    tokenBalanceBloc = _MockTokenBalanceBloc();
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    config = ValueNotifier(RemoteConfig.permissive);
    final remoteConfig = _MockRemoteConfigService();
    when(() => remoteConfig.config).thenReturn(config);
    when(remoteConfig.refreshIfStale).thenAnswer((_) async {});
    register<RemoteConfigService>(remoteConfig);

    final aggregator = _MockSessionPortfolioAggregator();
    when(
      () => aggregator.sendSourcesForMint(
        chain: any(named: 'chain'),
        mint: any(named: 'mint'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async => const []);
    register<SessionPortfolioAggregator>(aggregator);

    final priceService = _MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(null);
    register<TokenPriceService>(priceService);

    final priorityFee = _MockPriorityFeeService();
    when(
      () => priorityFee.ceilingLamports,
    ).thenReturn(kAutoPriorityFeeLamports);
    register<PriorityFeeService>(priorityFee);
  });

  tearDown(() {
    debugShowSwapOverride = null;

    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<RemoteConfigService>();
    drop<SessionPortfolioAggregator>();
    drop<TokenPriceService>();
    drop<PriorityFeeService>();
    config.dispose();
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

  test('the sheet opens Native when swap is hidden, Liquid when it is not', () {
    // The state default is a `const` and cannot read the flag, so the bloc
    // resolves the opening path through this getter instead. Get it wrong and
    // the sheet opens on a path whose selector is not rendered.
    debugShowSwapOverride = true;
    expect(defaultStakeType, StakeType.liquid);
    debugShowSwapOverride = false;
    expect(defaultStakeType, StakeType.native);
  });

  testWidgets('shows the Liquid / Native selector when swap is shown', (
    tester,
  ) async {
    debugShowSwapOverride = true;
    await pumpForm(tester, StakingState(data: data()));

    expect(find.text('Stake type'), findsOneWidget);
    expect(find.text('Liquid'), findsOneWidget);
    expect(find.text('Native'), findsOneWidget);
  });

  testWidgets('drops the whole selector when swap is hidden', (tester) async {
    debugShowSwapOverride = false;
    await pumpForm(
      tester,
      // What `defaultStakeType` produces in this build.
      StakingState(stakeType: StakeType.native, data: data()),
    );

    // Not a disabled row — no row, and no heading over the empty space.
    expect(find.text('Stake type'), findsNothing);
    expect(find.text('Liquid'), findsNothing);
    expect(find.text('Native'), findsNothing);

    // Native staking is entirely unaffected: the amount field, the
    // Half / Max shortcuts, the epoch note and the CTA all stay.
    expect(find.text('Stake amount'), findsOneWidget);
    expect(find.text('Half'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);
    expect(find.textContaining('Native stake is locked until'), findsOneWidget);
  });

  testWidgets('the unstake tab loses it too — a liquid unstake is the same '
      'swap', (tester) async {
    debugShowSwapOverride = false;
    await pumpForm(
      tester,
      StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: data(),
      ),
    );

    expect(find.text('Stake type'), findsNothing);
    expect(find.text('Liquid'), findsNothing);
    // The native unstake form itself is intact.
    expect(find.text('Unstake amount'), findsOneWidget);
  });
}
