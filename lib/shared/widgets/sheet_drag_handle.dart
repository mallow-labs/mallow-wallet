import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// The 60×3 rounded handle pill rendered at the top of every modal sheet.
///
/// Colour (`colors.textTertiary`) and the 7 px gap above it are fixed so the
/// handle reads the same on every sheet. Place it as the first child of the
/// sheet surface, with no top padding above it — padding there pushes the
/// handle down and breaks that gap. [bottomSpacing] sets the space between the
/// handle and the sheet's content.
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key, this.bottomSpacing = 12});

  /// Gap between the handle and the content below it.
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 60,
        height: 3,
        margin: EdgeInsets.only(top: 7, bottom: bottomSpacing),
        decoration: BoxDecoration(
          color: context.mallowColors.textTertiary,
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
      ),
    );
  }
}
