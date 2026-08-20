import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_season_banner.dart';
import 'package:mallow_wallet/features/staking/widgets/staking_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockStakingBloc extends MockBloc<StakingEvent, StakingState>
    implements StakingBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockSessionPortfolioAggregator extends Mock
    implements SessionPortfolioAggregator {}

class MockTokenPriceService extends Mock implements TokenPriceService {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

class MockTokenRepository extends Mock implements TokenRepository {}

/// Closing the season banner used to flip a plain `bool` on the sheet's own
/// [State], so it came back on the next `showStakeSheet` — the widget is
/// rebuilt from scratch every time the sheet opens. Dismissal is now persisted,
/// and scoped to the season number so a *new* season still gets to announce
/// itself.
void main() {
  setUpAll(() => registerFallbackValue(Chain.solana));

  late MockStakingBloc stakingBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<PreferencesService> registerPrefs([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await PreferencesService.create();
    register<PreferencesService>(prefs);
    return prefs;
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

    final tokenRepo = MockTokenRepository();
    when(() => tokenRepo.getCachedBalances(any())).thenAnswer((_) async => []);
    when(() => tokenRepo.getTokenBalances(any())).thenAnswer((_) async => []);
    register<TokenRepository>(tokenRepo);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<RemoteConfigService>();
    drop<SessionPortfolioAggregator>();
    drop<TokenPriceService>();
    drop<TokenRepository>();
    drop<PreferencesService>();
    config.dispose();
  });

  StakingDataResponse stakingData({int season = 3}) =>
      StakingDataResponse.fromJson({
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
            'active': 0,
            'inactive': 0,
            'activating': 0,
            'deactivating': 0,
          },
        },
        'currentSeason': {
          'season': season,
          'label': 'Season $season',
          'rewardPool': 1000.0,
        },
        'leaderboard': <Map<String, dynamic>>[],
      });

  /// Mounts the sheet the way `showStakeSheet` does — a fresh [StakingSheet],
  /// so each call is a new open of the sheet.
  Future<void> openSheet(WidgetTester tester, StakingState state) async {
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
            child: const StakingSheet(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> closeSheet(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('closing the banner keeps it closed on the next sheet open', (
    tester,
  ) async {
    final prefs = await registerPrefs();
    await openSheet(tester, StakingState(data: stakingData()));
    expect(find.byType(StakingSeasonBanner), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(StakingSeasonBanner),
        matching: find.byType(GestureDetector),
      ),
    );
    await tester.pump();
    expect(find.byType(StakingSeasonBanner), findsNothing);

    // The dismissal has to outlive this State object, not just this build.
    expect(prefs.dismissedStakingSeason, 3);

    await closeSheet(tester);
    await openSheet(tester, StakingState(data: stakingData()));
    expect(find.byType(StakingSeasonBanner), findsNothing);
  });

  testWidgets('a previously dismissed season stays hidden on a cold start', (
    tester,
  ) async {
    await registerPrefs({'pref_dismissed_staking_season': 3});
    await openSheet(tester, StakingState(data: stakingData()));

    expect(find.byType(StakingSeasonBanner), findsNothing);
  });

  testWidgets('a new season re-shows the banner', (tester) async {
    // Scoping to the season number is the whole reason this is not a bool:
    // dismissing Season 3 must not silently swallow Season 4's announcement.
    await registerPrefs({'pref_dismissed_staking_season': 3});
    await openSheet(tester, StakingState(data: stakingData(season: 4)));

    expect(find.byType(StakingSeasonBanner), findsOneWidget);
    expect(find.text('Season 4'), findsOneWidget);
  });
}
