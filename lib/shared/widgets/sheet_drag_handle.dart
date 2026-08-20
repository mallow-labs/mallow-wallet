import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// The 60×3 rounded handle pill rendered at the top of every modal sheet.
///
/// Defaults to `colors.textTertiary` and the standard 7-top / 12-bottom
/// margin used by the confirmation sheets and [FullScreenSheet]. Pass
/// [color] to override (some sheets use `surfaceMuted` or `divider`).
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({
    super.key,
    this.color,
    this.margin = const EdgeInsets.only(top: 7, bottom: 12),
  });

  final Color? color;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 60,
        height: 3,
        margin: margin,
        decoration: BoxDecoration(
          color: color ?? context.mallowColors.textTertiary,
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
      ),
    );
  }
}
