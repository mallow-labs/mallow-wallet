import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/staking_constants.dart';

/// These tests pin the form's business rules — which balance bounds the input,
/// the Max rent reserve, and what gates the CTA — independently of the bloc's
/// async wiring. They fail if someone changes *what* staking allows, not just
/// how it's plumbed.
void main() {
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

  group('the opening path', () {
    test('a fresh sheet lands on Liquid', () {
      // `StakingBloc` is a DI factory, so every `showStakeSheet` starts from
      // this state — which makes the constructor default the sheet's opening
      // path. Liquid leads: it is the unlocked one (no epoch wait, no 1 SOL
      // minimum), which is also why it is the first row in the selector.
      expect(const StakingState().stakeType, StakeType.liquid);
    });

    test('the opening path survives a tab switch', () {
      // The tab picks the direction, the toggle picks the mechanism — landing
      // on Liquid must not mean re-defaulting every time the user crosses to
      // Unstake and back.
      expect(
        const StakingState().copyWith(tab: StakeTab.unstake).stakeType,
        StakeType.liquid,
      );
    });
  });

  group('input bounds', () {
    test('stake tab spends SOL regardless of stake type', () {
      const state = StakingState(
        solLamports: 5000000000,
        mallowSolLamports: 999,
      );
      expect(state.inputMint, StakingConstants.solMint);
      expect(state.availableLamports, 5000000000);
    });

    test('Max reserves rent/fees on SOL', () {
      const state = StakingState(solLamports: 5000000000);
      expect(
        state.maxLamports,
        5000000000 - StakingConstants.maxReserveLamports,
      );
    });

    test('Max clamps to zero when balance is below the reserve', () {
      const state = StakingState(solLamports: 1000000);
      expect(state.maxLamports, 0);
    });

    test('liquid unstake spends mallowSOL with no reserve', () {
      const state = StakingState(
        tab: StakeTab.unstake,
        mallowSolLamports: 4200000000,
      );
      expect(state.inputMint, StakingConstants.mallowSolMint);
      expect(state.availableLamports, 4200000000);
      expect(state.maxLamports, 4200000000);
    });

    test('native unstake bounds by active + activating stake', () {
      final state = StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: dataWith(active: 3000000000, activating: 1000000000),
      );
      expect(state.availableLamports, 4000000000);
    });
  });

  group('when an unstake lands immediately', () {
    /// Deactivating an account that is still *activating* short-circuits to
    /// `deactivationEpoch == activationEpoch` — Solana treats it as "no stake
    /// at all", so the funds are claimable the moment the tx lands instead of
    /// at the next epoch boundary. Quoting the ~2-day countdown there tells
    /// the user their SOL is locked when it is already back.
    test('only-activating stake deactivates immediately', () {
      final state = StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: dataWith(activating: 1000000000),
      );
      expect(state.deactivatesImmediately, isTrue);
    });

    /// `StakingTxBuilder.buildNativeUnstakeTx` picks accounts largest-first
    /// across active *and* activating, so with both present this sheet cannot
    /// know which kind the tx will touch — and the harm is asymmetric: telling
    /// a user "immediately" about funds that then lock for an epoch is far
    /// worse than quoting a countdown that resolves early.
    test('any active stake falls back to the epoch countdown', () {
      final state = StakingState(
        tab: StakeTab.unstake,
        stakeType: StakeType.native,
        data: dataWith(active: 3000000000, activating: 1000000000),
      );
      expect(state.deactivatesImmediately, isFalse);
    });

    test('staking is never immediate — a fresh delegation always warms up', () {
      final state = StakingState(
        stakeType: StakeType.native,
        data: dataWith(activating: 1000000000),
      );
      expect(state.deactivatesImmediately, isFalse);
    });

    test('liquid unstake is a swap, not a deactivation', () {
      final state = StakingState(
        tab: StakeTab.unstake,
        data: dataWith(activating: 1000000000),
      );
      expect(state.deactivatesImmediately, isFalse);
    });
  });

  group('canSubmit gating', () {
    test('rejects empty / zero amounts', () {
      const empty = StakingState(solLamports: 5000000000);
      expect(empty.canSubmit, isFalse);
      const zero = StakingState(amount: '0', solLamports: 5000000000);
      expect(zero.canSubmit, isFalse);
    });

    test('rejects amounts above the available balance', () {
      const state = StakingState(amount: '2', solLamports: 1000000000);
      expect(state.canSubmit, isFalse);
    });

    test('accepts a valid amount within balance', () {
      const state = StakingState(amount: '1.5', solLamports: 2000000000);
      expect(state.canSubmit, isTrue);
    });

    test('rejects while a tx is in flight', () {
      const state = StakingState(
        amount: '0.5',
        solLamports: 1000000000,
        flow: TxFlowSigning<StakePrep, StakeSuccessData>(),
      );
      expect(state.isBusy, isTrue);
      expect(state.canSubmit, isFalse);
    });
  });
}
