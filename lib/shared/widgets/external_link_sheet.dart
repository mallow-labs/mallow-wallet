import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'sheet_drag_handle.dart';

/// Confirmation sheet shown before sending the user to an external website.
///
/// Returns `true` when the user taps "Open", `false`/`null` otherwise.
/// [displayUrl] is the human-readable destination (e.g. host) rendered in the
/// subtitle.
Future<bool?> showExternalLinkSheet(
  BuildContext context, {
  required String displayUrl,
}) {
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ExternalLinkSheet(displayUrl: displayUrl),
  );
}

class _ExternalLinkSheet extends StatelessWidget {
  const _ExternalLinkSheet({required this.displayUrl});

  final String displayUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                MallowTheme.spacingMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'External link',
                    style: MallowTheme.uiTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'This will open $displayUrl',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: MallowButton(
                          label: 'Cancel',
                          variant: MallowButtonVariant.secondary,
                          isFullWidth: true,
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                      ),
                      const SizedBox(width: MallowTheme.spacingMd),
                      Expanded(
                        child: MallowButton(
                          label: 'Open',
                          isFullWidth: true,
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
