import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// A single row in the settings menu.
///
/// Shows a 24×24 icon, label, optional badge pill, and optional chevron.
class SettingsMenuItem extends StatelessWidget {
  const SettingsMenuItem({
    required this.iconAsset,
    required this.label,
    required this.onTap,
    this.badge,
    this.trailingValue,
    this.showChevron = false,
    super.key,
  });

  /// Asset path for the 24×24 SVG icon.
  final String iconAsset;

  /// Row label text (ui_body style: Inter Regular 15px).
  final String label;

  /// Tap callback.
  final VoidCallback onTap;

  /// Optional trailing badge text (e.g. "12", "All"). Null = no badge.
  final String? badge;

  /// Optional right-aligned summary of the row's current setting (e.g. the
  /// selected priority fee). Unlike [badge] it is plain secondary text, not a
  /// pill — it reads as the row's value rather than as a count.
  final String? trailingValue;

  /// Whether to show a trailing chevron arrow.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: iconAsset.endsWith('.svg')
                    ? MallowSvgIcon(iconAsset, width: 24, height: 24)
                    : Image.asset(iconAsset, width: 24, height: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: MallowTheme.uiBody)),
              if (trailingValue case final v?)
                Text(
                  v,
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              if (badge != null) _BadgePill(text: badge!),
              if (showChevron) ...[
                const SizedBox(width: 8),
                const MallowSvgIcon(
                  'assets/icons/arrow_right.svg',
                  width: 16,
                  height: 16,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Text(
        text,
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textPrimary,
        ),
      ),
    );
  }
}
