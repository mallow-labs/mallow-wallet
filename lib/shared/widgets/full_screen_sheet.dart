import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';
import 'sheet_overscroll_dismiss.dart';

/// Opens a modal bottom sheet sized to fill the screen from 20 px below the
/// top safe-area inset to the bottom edge.
///
/// The sheet includes the standard drag handle; callers supply the [child].
Future<T?> showFullScreenSheet<T>({
  required BuildContext context,
  required Widget child,
}) {
  return showMallowSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FullScreenSheet(child: child),
  );
}

/// A Container that fills the screen from 20 px below the top safe area,
/// with the standard rounded-top surface decoration and drag handle.
class FullScreenSheet extends StatelessWidget {
  const FullScreenSheet({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return SheetOverscrollDismiss(
      child: Container(
        height: maxSheetHeight(context),
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Column(
          children: [
            const SheetDragHandle(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
