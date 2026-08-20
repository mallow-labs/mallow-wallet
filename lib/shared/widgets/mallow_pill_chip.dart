import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// Outlined pill matching the Figma artwork-info chip spec:
/// transparent fill, 1px [MallowColors.divider] border, `radiusFull`,
/// 12h × 6v padding, `uiCaption` text in [MallowColors.textPrimary].
///
/// When [width] is supplied the pill takes that fixed width and centers its
/// label (per the Figma spec — the proceeds-row recipient chips). With
/// [width] left null the pill hugs its label, which is what the artwork-info
/// usage expects.
class MallowPillChip extends StatelessWidget {
  const MallowPillChip(this.label, {super.key, this.width, this.color});

  final String label;
  final double? width;

  /// Overrides both the border and label color (e.g. the Offers auction
  /// card's accent "View" when a settle/claim awaits). Defaults to the
  /// divider border + textPrimary label.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: width,
      alignment: width != null ? Alignment.center : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color ?? colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MallowTheme.uiCaption.copyWith(
          color: color ?? colors.textPrimary,
        ),
      ),
    );
  }
}
