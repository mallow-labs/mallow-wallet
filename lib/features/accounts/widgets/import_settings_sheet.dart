import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';

/// Import-picker settings sheet — toggles whether legacy/root Solana
/// derivation-scheme addresses are shown as additional selectable rows.
///
/// [onChanged] fires immediately on toggle so the picker can re-derive; the
/// sheet stays open until the user taps Done.
Future<void> showImportSettingsSheet(
  BuildContext context, {
  required bool includeLegacy,
  required ValueChanged<bool> onChanged,
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ImportSettingsSheet(
      initialIncludeLegacy: includeLegacy,
      onChanged: onChanged,
    ),
  );
}

class _ImportSettingsSheet extends StatefulWidget {
  const _ImportSettingsSheet({
    required this.initialIncludeLegacy,
    required this.onChanged,
  });

  final bool initialIncludeLegacy;
  final ValueChanged<bool> onChanged;

  @override
  State<_ImportSettingsSheet> createState() => _ImportSettingsSheetState();
}

class _ImportSettingsSheetState extends State<_ImportSettingsSheet> {
  late bool _includeLegacy = widget.initialIncludeLegacy;

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
                    'Settings',
                    style: MallowTheme.editorialSection.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Show legacy Solana accounts',
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      MallowToggle(
                        value: _includeLegacy,
                        onChanged: (v) {
                          setState(() => _includeLegacy = v);
                          widget.onChanged(v);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  MallowButton(
                    label: 'Done',
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
