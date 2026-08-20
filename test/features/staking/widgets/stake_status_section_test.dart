import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/data/epoch_progress.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/widgets/stake_status_cards.dart';
import 'package:mallow_wallet/features/staking/widgets/stake_status_section.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class MockStakingBloc extends MockBloc<StakingEvent, StakingState>
    implements StakingBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

/// The tokens portfolio shows the native-stake status cells above the sort row,
/// but it has no staking data of its own — the staking banner beside them is a
/// static CTA. These pin the three decisions that makes:
///
///  1. the section is invisible *and weightless* without stake, so the
///     portfolio's 26 px rhythm doesn't gain a hole for every user who has
///     never staked (the majority);
///  2. it re-reads when balances settle, because the stake sheet closes with
///     its own bloc and would otherwise leave these cells describing the
///     pre-stake world;
///  3. Claim leaves for the sheet instead of claiming in place, where the
///     biometric gate and the withdraw-stake kill switch live.
void main() {
  late MockStakingBloc stakingBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;

  StakingState stateWith({
    int activating = 0,
    int deactivating = 0,
    int inactive = 0,
  }) => StakingState(
    isLoading: false,
    epochProgress: const EpochProgress(
      epoch: 700,
      // 180k slots left of a 432k-slot epoch × 400 ms = exactly 20 h.
      slotIndex: 252000,
      slotsInEpoch: 432000,
    ),
    data: StakingDataResponse(
      nativeApy: 0.0574,
      liquidApy: 0.0559,
      solPerMallowSol: 1.0,
      totalSolStakedLamports: '0',
      totalStakers: 0,
      totalSeasonPoints: 0,
      userData: StakingUserData(
        spPerDay: 0,
        nativeStake: NativeStakeBreakdown(
          activeLamports: 0,
          inactiveLamports: inactive,
          activatingLamports: activating,
          deactivatingLamports: deactivating,
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
    ),
  );

  TokenBalanceState balances({bool isRefreshing = false}) =>
      TokenBalanceState.loaded(
        tokens: const [],
        totalUsdValue: 0,
        isRefreshing: isRefreshing,
      );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    stakingBloc = MockStakingBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    register<StakingBloc>(stakingBloc);
  });

  tearDown(() {
    if (sl.isRegistered<StakingBloc>()) sl.unregister<StakingBloc>();
  });

  Future<void> pump(
    WidgetTester tester, {
    required StakingState state,
    Stream<TokenBalanceState>? balanceStream,
  }) async {
    whenListen(
      stakingBloc,
      const Stream<StakingState>.empty(),
      initialState: state,
    );
    whenListen(
      tokenBalanceBloc,
      balanceStream ?? const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: BlocProvider<TokenBalanceBloc>.value(
          value: tokenBalanceBloc,
          child: const Scaffold(body: Column(children: [StakeStatusSection()])),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('takes no space at all when there is nothing staked', (
    tester,
  ) async {
    await pump(tester, state: stateWith());

    // Not just "no cards" — no trailing 26 either. The section owns its own
    // gap precisely so a non-staker's portfolio doesn't grow one.
    expect(tester.getSize(find.byType(StakeStatusSection)).height, 0);
  });

  testWidgets('shows each kind of stake it finds, with its countdown', (
    tester,
  ) async {
    await pump(
      tester,
      state: stateWith(
        activating: 2000000000,
        deactivating: 1000000000,
        inactive: 500000000,
      ),
    );

    expect(find.text('Stake Activating'), findsOneWidget);
    expect(find.text('2 SOL'), findsOneWidget);
    // Activation and deactivation both land on the epoch boundary, so the two
    // countdowns are the same clock read through different verbs.
    expect(find.text('Staked in 20h 0m'), findsOneWidget);
    expect(find.text('Claim in 20h 0m'), findsOneWidget);
    expect(find.text('Unstaked'), findsNWidgets(2));
    expect(find.text('Claim'), findsOneWidget);

    // Below the section sits the trailing gap that separates it from the sort
    // row — present only now that there are cells to separate.
    expect(tester.getSize(find.byType(StakeStatusSection)).height, isNonZero);
  });

  testWidgets('re-reads staking data once a balance refresh settles', (
    tester,
  ) async {
    await pump(
      tester,
      state: stateWith(activating: 2000000000),
      balanceStream: Stream.fromIterable([
        balances(isRefreshing: true),
        balances(),
      ]),
    );
    await tester.pump();

    // Once on mount, once when the refresh lands — and *not* a third time for
    // the isRefreshing:true half of the same refresh.
    verify(() => stakingBloc.add(const StakingEvent.loadData())).called(2);
  });

  testWidgets('Claim hands off instead of claiming in place', (tester) async {
    // Asserted at the callback seam rather than through the section: in the
    // portfolio that callback is `showStakeSheet`, because claiming needs the
    // biometric gate, the withdraw-stake kill switch and a progress sheet, all
    // of which already live in the sheet. What must hold everywhere is that the
    // card *delegates* the action rather than owning one.
    var claims = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: StakeClaimableCard(
            lamports: 500000000,
            onClaim: () => claims++,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Claim'));
    expect(claims, 1);

    // Mid-claim the button goes inert — a second tap would build and sign a
    // second withdraw for funds the first one is already taking.
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: StakeClaimableCard(
            lamports: 500000000,
            onClaim: () => claims++,
            isClaiming: true,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(StakeClaimableCard));

    expect(claims, 1);
  });
}
