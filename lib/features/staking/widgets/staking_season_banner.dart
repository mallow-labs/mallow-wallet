import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../staking_format.dart';

/// The season header card at the top of the stake sheet: season label, blurb,
/// then reward pool and end date sharing a footer row. Based on the Figma
/// spec, which put the reward pool up on the label row.
class StakingSeasonBanner extends StatelessWidget {
  const StakingSeasonBanner({required this.season, this.onDismiss, super.key});

  final StakingSeason season;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MallowTheme.spacingSm),
      decoration: BoxDecoration(
        color: colors.dividerLight,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  season.label,
                  style: MallowTheme.editorialSubhead.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: MallowTheme.spacingSm),
                TapTargetExpander(
                  child: GestureDetector(
                    onTap: onDismiss,
                    behavior: HitTestBehavior.opaque,
                    child: MallowSvgIcon(
                      'assets/icons/x.svg',
                      width: 12,
                      height: 12,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: MallowTheme.spacingXs + 2),
          Text(
            'Stake your SOL, accrue points and get your share of the prize pool',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${StakingFormat.abbreviate(season.rewardPool)} SMORES reward pool',
                  style: MallowTheme.uiCaption.copyWith(color: colors.accent),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                'Season end: ${StakingFormat.seasonEnd(season.endsAt)}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
