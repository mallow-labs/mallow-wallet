import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_sheet.dart';
import 'mallow_svg_icon.dart';
import 'sheet_drag_handle.dart';

/// Generic "Sort by" bottom sheet: drag handle, title, one row per option
/// with the current selection highlighted in the accent color (label +
/// checkmark). Pops with the tapped option, or null when dismissed.
///
/// Backs the profile/portfolio sort sheets and the Offers screen sort.
Future<T?> showSortOptionsSheet<T>(
  BuildContext context, {
  required List<T> options,
  required T currentSort,
  required String Function(T) labelFor,
}) {
  return showMallowSheet<T>(
    context: context,
    backgroundColor: context.mallowColors.bgPrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(MallowTheme.popupRadius),
      ),
    ),
    builder: (context) => _SortOptionsSheet<T>(
      options: options,
      currentSort: currentSort,
      labelFor: labelFor,
    ),
  );
}

class _SortOptionsSheet<T> extends StatelessWidget {
  const _SortOptionsSheet({
    required this.options,
    required this.currentSort,
    required this.labelFor,
  });

  final List<T> options;
  final T currentSort;
  final String Function(T) labelFor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetDragHandle(),
            const SizedBox(height: 4),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Sort by',
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Options
            for (final option in options)
              _SortOptionTile(
                label: labelFor(option),
                isSelected: option == currentSort,
                onTap: () => Navigator.of(context).pop(option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: MallowTheme.uiBody.copyWith(
                  color: isSelected
                      ? context.mallowColors.accent
                      : context.mallowColors.textSecondary,
                ),
              ),
            ),
            if (isSelected)
              MallowSvgIcon(
                'assets/icons/checkmark.svg',
                width: 18,
                height: 18,
                color: context.mallowColors.accent,
              ),
          ],
        ),
      ),
    );
  }
}
