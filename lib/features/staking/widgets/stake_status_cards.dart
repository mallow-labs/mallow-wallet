import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../data/epoch_progress.dart';
import '../staking_constants.dart';
import '../staking_format.dart';

/// The native-stake status trio, in the order a user meets them: what they just
/// staked, what is on its way back, what is waiting to be taken.
///
/// Public because three surfaces render the same cards — the stake sheet's
/// Stake and Unstake tabs and the tokens portfolio, which shows them above the
/// sort row. They were private to `StakingFormTab` until the portfolio needed
/// them; duplicating the chrome there would have re-introduced exactly the
/// two-visual-languages-for-one-fact problem unifying the tabs removed.
///
/// Activation and deactivation both complete at the epoch boundary, so every
/// countdown here reads the same [EpochProgress.timeRemaining].
///
/// Renders nothing when [native] has none of the three — callers that need to
/// reserve space (a sliver gap, say) must key that off [hasAny] rather than
/// assuming a non-zero height.
class StakeStatusCards extends StatelessWidget {
  const StakeStatusCards({
    required this.native,
    required this.epoch,
    required this.onClaim,
    this.isClaiming = false,
    super.key,
  });

  final NativeStakeBreakdown native;
  final EpochProgress? epoch;

  /// Tapping Claim. [isClaiming] is what makes the button inert mid-claim.
  final VoidCallback onClaim;
  final bool isClaiming;

  /// Whether [native] has anything to show. Lets a caller decide on its own
  /// surrounding spacing before this widget builds.
  static bool hasAny(NativeStakeBreakdown native) =>
      native.activatingLamports > 0 ||
      native.deactivatingLamports > 0 ||
      native.inactiveLamports > 0;

  @override
  Widget build(BuildContext context) {
    if (!hasAny(native)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: MallowTheme.spacingSm,
      children: [
        if (native.activatingLamports > 0)
          StakeActivatingCard(
            lamports: native.activatingLamports,
            epoch: epoch,
          ),
        if (native.deactivatingLamports > 0)
          StakeDeactivatingCard(
            lamports: native.deactivatingLamports,
            epoch: epoch,
          ),
        if (native.inactiveLamports > 0)
          StakeClaimableCard(
            lamports: native.inactiveLamports,
            onClaim: onClaim,
            isClaiming: isClaiming,
          ),
      ],
    );
  }
}

/// Funds still activating (warming up). Native stake goes active at the same
/// epoch boundary deactivating stake becomes claimable at, so it counts down
/// off the same [EpochProgress.timeRemaining].
///
/// Accent-outlined on every surface, unstake tab included: it is the one cell
/// that reports stake still on its way *in*, and it reads as an afterthought
/// next to the outlined cells when it is the only unbordered one.
class StakeActivatingCard extends StatelessWidget {
  const StakeActivatingCard({
    required this.lamports,
    required this.epoch,
    super.key,
  });

  final int lamports;
  final EpochProgress? epoch;

  @override
  Widget build(BuildContext context) {
    return _StakeStatusCard(
      title: 'Stake Activating',
      value: '${StakingFormat.lamportsSol(lamports)} SOL',
      outlined: true,
      trailing: _StakeStatusPill(
        label: epoch == null
            ? 'Staked at epoch end'
            : 'Staked in ${StakingFormat.countdown(epoch!.timeRemaining)}',
      ),
    );
  }
}

/// Funds still deactivating (locked) — the amount and a non-actionable claim
/// countdown.
class StakeDeactivatingCard extends StatelessWidget {
  const StakeDeactivatingCard({
    required this.lamports,
    required this.epoch,
    super.key,
  });

  final int lamports;
  final EpochProgress? epoch;

  @override
  Widget build(BuildContext context) {
    return _StakeStatusCard(
      title: 'Unstaked',
      value: '${StakingFormat.lamportsSol(lamports)} SOL',
      trailing: _StakeStatusPill(
        label: epoch == null
            ? 'Claim at epoch end'
            : 'Claim in ${StakingFormat.countdown(epoch!.timeRemaining)}',
      ),
    );
  }
}

/// Funds fully deactivated (claimable) — the amount and a Claim button.
class StakeClaimableCard extends StatelessWidget {
  const StakeClaimableCard({
    required this.lamports,
    required this.onClaim,
    this.isClaiming = false,
    super.key,
  });

  final int lamports;
  final VoidCallback onClaim;

  /// A claim already in flight. Makes the button inert and swaps the label for
  /// a spinner — a second tap would build and sign a second withdraw for funds
  /// the first one is already taking.
  final bool isClaiming;

  @override
  Widget build(BuildContext context) {
    return _StakeStatusCard(
      title: 'Unstaked',
      value: '${StakingFormat.lamportsSol(lamports)} SOL',
      trailing: _StakeClaimButton(onTap: onClaim, isClaiming: isClaiming),
    );
  }
}

/// Unclaimed season rewards — the SMORES sitting ZK-compressed in the wallet
/// after a season's prizes are distributed, plus the Claim (decompress) button.
///
/// Rendered off the compressed balance rather than the payload's
/// `smoresEarned`: earned is history, the compressed balance is what is still
/// claimable, so the cell disappears once the claim lands (webapp
/// `RecentRewardsContent`, which sizes its claim the same way).
///
/// Not part of [StakeStatusCards]: that group is the native-SOL trio, and the
/// tokens portfolio renders it without any rewards row.
class StakeRewardsCard extends StatelessWidget {
  const StakeRewardsCard({
    required this.smoresRaw,
    required this.onClaim,
    this.isClaiming = false,
    super.key,
  });

  final int smoresRaw;
  final VoidCallback onClaim;
  final bool isClaiming;

  @override
  Widget build(BuildContext context) {
    final smores = smoresRaw / StakingConstants.smoresUnitsPerToken;
    return _StakeStatusCard(
      title: 'Your Rewards',
      value: '${StakingFormat.withCommas(smores)} SMORES',
      trailing: _StakeClaimButton(onTap: onClaim, isClaiming: isClaiming),
    );
  }
}

/// The actionable badge on the right of a [_StakeStatusCard] — accent-bordered
/// and tappable, swapping to a loader while a transaction is in flight. Shared
/// by the unstaked-SOL and season-rewards claims so the two read as the same
/// affordance.
class _StakeClaimButton extends StatelessWidget {
  const _StakeClaimButton({required this.onTap, required this.isClaiming});

  final VoidCallback onTap;
  final bool isClaiming;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: isClaiming ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: _StakeStatusPill(
          // Accent, not divider: this is the one badge in the group that is
          // actually tappable.
          borderColor: colors.accent,
          label: 'Claim',
          child: isClaiming
              ? MallowLoader(size: 14, color: colors.accent)
              : null,
        ),
      ),
    );
  }
}

/// The badge on the right of a [_StakeStatusCard]. Defaults to a divider
/// border, so a countdown never reads as something you can tap; the Claim
/// button passes the accent [borderColor] to say that it is.
class _StakeStatusPill extends StatelessWidget {
  const _StakeStatusPill({required this.label, this.borderColor, this.child});

  final String label;
  final Color? borderColor;

  /// Replaces [label] entirely when set — the Claim button's mid-claim spinner.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing12,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        border: Border.all(color: borderColor ?? colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      ),
      child:
          child ??
          Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
    );
  }
}

/// Shared chrome for every status cell: [title] over [value] on the left, a
/// [trailing] pill/button on the right. [outlined] adds the accent border
/// [StakeActivatingCard] carries.
///
/// [value] is pre-formatted rather than lamports — the rewards cell counts
/// SMORES, not SOL.
class _StakeStatusCard extends StatelessWidget {
  const _StakeStatusCard({
    required this.title,
    required this.value,
    required this.trailing,
    this.outlined = false,
  });

  final String title;
  final String value;
  final Widget trailing;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        border: outlined ? Border.all(color: colors.accent) : null,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                Text(
                  value,
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
