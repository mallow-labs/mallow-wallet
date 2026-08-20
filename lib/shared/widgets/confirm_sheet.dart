import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';

/// Bottom sheet that asks the user to confirm an action. Returns `true`
/// when the user taps the primary action, `false`/`null` otherwise.
///
/// Set [destructive] to render the primary action in the danger variant.
/// Pass `cancelLabel: null` for a single-action info sheet (no cancel).
Future<bool?> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel = 'Cancel',
  bool destructive = false,
}) {
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ConfirmSheet(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? cancelLabel;
  final bool destructive;

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
            Padding(
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
                  MallowButton(
                    label: confirmLabel,
                    variant: destructive
                        ? MallowButtonVariant.danger
                        : MallowButtonVariant.primary,
                    isFullWidth: true,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  if (cancelLabel != null) ...[
                    const SizedBox(height: MallowTheme.spacingSm),
                    MallowButton(
                      label: cancelLabel!,
                      variant: MallowButtonVariant.secondary,
                      isFullWidth: true,
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
