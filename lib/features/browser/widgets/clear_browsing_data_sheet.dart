import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';

/// Confirms "Clear browsing data". Resolves to whether bookmarks are kept,
/// or null when cancelled.
Future<bool?> showClearBrowsingDataSheet(BuildContext context) =>
    runGuardedSheet<bool>(
      'browserClearData',
      () => showMallowSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const ClearBrowsingDataSheet(),
      ),
    );

class ClearBrowsingDataSheet extends StatefulWidget {
  const ClearBrowsingDataSheet({super.key});

  @override
  State<ClearBrowsingDataSheet> createState() => _ClearBrowsingDataSheetState();
}

class _ClearBrowsingDataSheetState extends State<ClearBrowsingDataSheet> {
  var _keepBookmarks = true;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: SingleChildScrollView(
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
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Clear browsing data?',
                    style: MallowTheme.editorialSection.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'This closes all tabs, disconnects sites, and removes '
                    'website cookies, storage, and saved sign-in details.',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacing20),
                  MallowCheckbox(
                    key: const Key('keep-bookmarks'),
                    value: _keepBookmarks,
                    label: 'Keep bookmarks',
                    onChanged: (value) =>
                        setState(() => _keepBookmarks = value),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  MallowButton(
                    label: 'Clear data',
                    variant: MallowButtonVariant.danger,
                    isFullWidth: true,
                    onPressed: () => Navigator.of(context).pop(_keepBookmarks),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  MallowButton(
                    label: 'Cancel',
                    variant: MallowButtonVariant.secondary,
                    isFullWidth: true,
                    onPressed: () => Navigator.of(context).pop(),
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
