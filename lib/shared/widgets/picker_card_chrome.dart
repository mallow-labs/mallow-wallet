import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

// Card geometry shared by every account-picker card — the seed-phrase/Ledger
// import picker and the Create/Edit Profile wallet step — and by each one's
// loading skeleton, so the connector rail and row dividers line up both across
// the load handoff and between the two pickers.
const double kPickerHeaderHeight = 40;
const double kPickerRailX = 8; // avatar centre / rail x / row-divider start
const double kPickerAvatarBottom =
    (kPickerHeaderHeight + 16) / 2; // 16 = avatar size
const double kPickerWalletRowHeight = 40;

/// The small activity chip on a picker card's account header: `filled` for a
/// value the wallet actually has (artwork count, USD balance), `outlined` for a
/// status word ("No activity", "Imported").
class PickerChip extends StatelessWidget {
  const PickerChip({
    required this.label,
    this.filled = false,
    this.outlined = false,
    super.key,
  });

  final String label;
  final bool filled;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? context.mallowColors.surfaceMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: outlined
            ? Border.all(color: context.mallowColors.dividerLight)
            : null,
      ),
      child: Text(
        label,
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    );
  }
}
