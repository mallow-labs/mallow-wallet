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
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';
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

/// The status cards are the sheet's only account of money the user cannot see
/// in their wallet balance: stake mid-warmup, stake mid-cooldown, stake ready
/// to reclaim, and season rewards still sitting ZK-compressed. Each one is the
/// difference between "my SOL vanished" and "my SOL is doing something".
///
/// These pin the three cases where an amount existed with nowhere on screen to
/// account for it — the unstake tab's Max spending activating stake it never
/// mentioned, the balance line understating that same stake, and SMORES a
/// finished season paid out that the app offered no way to claim.
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
    int activeLamports = 2500000000,
    int activatingLamports = 0,
    int deactivatingLamports = 0,
    int inactiveLamports = 0,
  }) => StakingDataResponse.fromJson({
    'nativeApy': 0.07,
    'liquidApy': 0.05,
    'solPerMallowSol': 1.0,
    'totalSolStaked': '1000000000000',
    'totalStakers': 1234,
    'totalSeasonPoints': 100.0,
    'userData': {
      'spPerDay': 24.0,
      'liquidStake': 0,
      'nativeStake': {
        'active': activeLamports,
        'inactive': inactiveLamports,
        'activating': activatingLamports,
        'deactivating': deactivatingLamports,
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

  group('season rewards', () {
    testWidgets('claimable SMORES get a cell and a working Claim', (
      tester,
    ) async {
      // Season prizes are airdropped ZK-compressed, so they show up in no
      // balance the app reads — before this cell existed the only way to get
      // them was the webapp.
      await pumpForm(
        tester,
        StakingState(
          data: stakingData(),
          // 1,250 SMORES at 6 decimals.
          smoresClaimableRaw: 1250000000,
        ),
      );

      expect(find.text('Your Rewards'), findsOneWidget);
      expect(find.text('1,250 SMORES'), findsOneWidget);

      await tester.tap(find.text('Claim'));
      await tester.pumpAndSettle();
      verify(
        () => stakingBloc.add(const StakingEvent.claimRewards()),
      ).called(1);

      await disposeForm(tester);
    });

    testWidgets('nothing compressed means no cell', (tester) async {
      // The balance is the claim: once the decompress lands it reads 0 and the
      // cell must disappear rather than offer a claim that would now fail.
      await pumpForm(tester, StakingState(data: stakingData()));

      expect(find.text('Your Rewards'), findsNothing);

      await disposeForm(tester);
    });

    testWidgets('the rewards cell is on the unstake tab too', (tester) async {
      await pumpForm(
        tester,
        StakingState(
          data: stakingData(),
          tab: StakeTab.unstake,
          // Explicit: the form defaults to liquid, and the unstake tab's cards
          // are native-only.
          stakeType: StakeType.native,
          smoresClaimableRaw: 1000000,
        ),
      );

      expect(find.text('Your Rewards'), findsOneWidget);
      expect(find.text('1 SMORES'), findsOneWidget);

      await disposeForm(tester);
    });
  });

  group('activating stake on the unstake tab', () {
    testWidgets('is accounted for by a card', (tester) async {
      // This tab's Max spends active + activating and the builder does
      // deactivate activating accounts, so leaving the card off the unstake tab
      // left the extra spendable SOL unexplained.
      await pumpForm(
        tester,
        StakingState(
          data: stakingData(
            activeLamports: 1000000000,
            activatingLamports: 3000000000,
          ),
          tab: StakeTab.unstake,
          // Explicit: the form defaults to liquid, and the unstake tab's cards
          // are native-only.
          stakeType: StakeType.native,
        ),
      );

      expect(find.text('Stake Activating'), findsOneWidget);
      expect(find.text('3 SOL'), findsOneWidget);

      await disposeForm(tester);
    });

    testWidgets('carries the accent outline here too', (tester) async {
      // The unstake tab used to render this one card unbordered — it was the
      // only cell in the column without an outline, which read as a disabled
      // or secondary notice rather than as the same class of fact as the
      // Unstaked cells beside it.
      await pumpForm(
        tester,
        StakingState(
          data: stakingData(
            activeLamports: 1000000000,
            activatingLamports: 3000000000,
          ),
          tab: StakeTab.unstake,
          stakeType: StakeType.native,
        ),
      );

      final card = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Stake Activating'),
              matching: find.byType(Container),
            )
            .last,
      );
      final border = (card.decoration! as BoxDecoration).border! as Border;
      expect(
        border.top.color,
        MallowTheme.lightTheme.extension<MallowColors>()!.accent,
      );

      await disposeForm(tester);
    });

    testWidgets('is counted in the Native balance line', (tester) async {
      // The line is read as the cap on what can be unstaked; active-only
      // understated it, so Max filled more than the balance it sat under.
      await pumpForm(
        tester,
        StakingState(
          data: stakingData(
            activeLamports: 1000000000,
            activatingLamports: 3000000000,
          ),
          tab: StakeTab.unstake,
        ),
      );

      expect(find.text('Bal: 4 SOL'), findsOneWidget);
      expect(find.text('Bal: 1 SOL'), findsNothing);

      await disposeForm(tester);
    });
  });
}
