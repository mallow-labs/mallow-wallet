import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';

/// Bordered label/value card used by the stake-form and leaderboard tabs.
class StakingStatCard extends StatelessWidget {
  const StakingStatCard({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacingSm),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          // Three of these sit side by side on the stake tab; a large total
          // ("1,234,567 SOL") must shrink rather than overflow the card.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
