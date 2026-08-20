import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

/// A selectable icon + title + subtitle row used by the "pick a type" chooser
/// screens (mint type, sell type).
///
/// [disabled] only dims the text/icon to the tertiary color — [onTap] still
/// fires — so it is a "this option is unavailable to you right now" hint, not
/// a gate. No chooser passes it today; every row on both screens is live.
class ChooserTypeRow extends StatelessWidget {
  const ChooserTypeRow({
    required this.svgAsset,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.disabled = false,
    super.key,
  });

  final String svgAsset;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final titleColor = disabled ? colors.textTertiary : colors.textPrimary;
    final subtitleColor = disabled ? colors.textTertiary : colors.textSecondary;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            MallowSvgIcon(svgAsset, width: 24, height: 24, color: titleColor),
            const SizedBox(width: MallowTheme.spacingMd),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: MallowTheme.uiBody.copyWith(color: titleColor),
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                Text(
                  subtitle,
                  style: MallowTheme.uiCaption.copyWith(color: subtitleColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
