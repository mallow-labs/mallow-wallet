import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';

/// One answer on a [showChoiceSheet].
class ChoiceSheetOption<T> {
  const ChoiceSheetOption({
    required this.label,
    required this.value,
    this.variant = MallowButtonVariant.secondary,
  });

  final String label;
  final T value;
  final MallowButtonVariant variant;
}

/// Bottom sheet that asks a question with more than a yes and a no: a title,
/// a message and one button per entry of [options], top to bottom. Returns
/// the value of the option tapped, or null when the sheet is dismissed.
///
/// For a plain confirm / cancel pair use `showConfirmSheet`.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required String message,
  required List<ChoiceSheetOption<T>> options,
}) {
  return showMallowSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _ChoiceSheet<T>(title: title, message: message, options: options),
  );
}

class _ChoiceSheet<T> extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.message,
    required this.options,
  });

  final String title;
  final String message;
  final List<ChoiceSheetOption<T>> options;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingSm,
                  MallowTheme.spacing20,
                  MallowTheme.spacing20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: MallowTheme.editorialSection.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingSm),
                    Text(
                      message,
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                    for (final (index, option) in options.indexed) ...[
                      if (index > 0)
                        const SizedBox(height: MallowTheme.spacingSm),
                      MallowButton(
                        label: option.label,
                        variant: option.variant,
                        isFullWidth: true,
                        onPressed: () =>
                            Navigator.of(context).pop(option.value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
