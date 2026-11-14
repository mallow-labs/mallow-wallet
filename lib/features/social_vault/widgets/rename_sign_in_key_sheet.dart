import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/social_vault/social_vault_service.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/sign_in_key_label.dart';

/// What the name field keeps of [raw]: the part of it the vault service
/// takes as a label.
///
/// - Line breaks and tabs become spaces; every other control character, and
///   the Unicode controls that change the direction text is drawn in, are
///   dropped. A label is one line of display text, shown wherever the wallet
///   lists its keys.
/// - It is cut to [SocialVaultService.maxSlotLabelLength] code points, which
///   is how the service counts. Counting what a reader sees as one character
///   instead would let through a name the service then refuses: one emoji
///   can be several code points. The cut never splits such a character.
///
/// The ends are not trimmed here, or a space could not be typed between two
/// words; the sheet trims when the name is saved, which only shortens it.
///
/// This is the field's own copy of the label rule, called from one place,
/// [_SignInKeyNameFormatter.accepted]. `SocialVaultService.normalizeSlotLabel`
/// refuses a label that is too long rather than cutting it, which serves the
/// Save button; the field needs the cut, so that nothing it shows can be
/// refused.
String _acceptedSignInKeyLabel(String raw) {
  final out = StringBuffer();
  var length = 0;
  for (final character in stripSignInKeyLabelControls(raw).characters) {
    length += character.runes.length;
    if (length > SocialVaultService.maxSlotLabelLength) break;
    out.write(character);
  }
  return out.toString();
}

/// Holds the name field to what the service takes, as it is typed or pasted.
class _SignInKeyNameFormatter extends TextInputFormatter {
  const _SignInKeyNameFormatter();

  /// [text] as the field keeps it. The single use of the label rule.
  static String accepted(String text) => _acceptedSignInKeyLabel(text);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = accepted(newValue.text);
    if (text == newValue.text) return newValue;
    // Something was dropped or cut. Keep the caret after what was typed
    // before it: the same rule, applied to the text up to the caret.
    final caret = newValue.selection.isValid
        ? accepted(
            newValue.text.substring(0, newValue.selection.extentOffset),
          ).length.clamp(0, text.length)
        : text.length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
  }
}

/// Asks for a passkey's new name. Returns the name to save — trimmed, and
/// held to what the service takes as a label; an empty one clears the label
/// — or null when cancelled.
///
/// [current] prefills the field; pass null for a passkey with no label of its
/// own, which starts empty and shows the kind as its hint. A label written
/// elsewhere that this app would not accept is prefilled as the app would
/// keep it.
Future<String?> showRenameSignInKeySheet(
  BuildContext context, {
  required String? current,
}) => showMallowSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _RenameSignInKeySheet(current: current),
);

class _RenameSignInKeySheet extends StatefulWidget {
  const _RenameSignInKeySheet({required this.current});

  final String? current;

  @override
  State<_RenameSignInKeySheet> createState() => _RenameSignInKeySheetState();
}

class _RenameSignInKeySheetState extends State<_RenameSignInKeySheet> {
  late final _controller = TextEditingController(
    text: _SignInKeyNameFormatter.accepted(widget.current ?? ''),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      borderSide: BorderSide(color: colors.dividerLight),
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: sheetBottomInset(context, includeKeyboard: false),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingMd,
                  MallowTheme.spacing20,
                  MallowTheme.spacing20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Rename passkey',
                      style: MallowTheme.editorialSubhead.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      'The name is shown wherever this wallet lists its '
                      'sign-in keys, in the app and on the web.',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    TextField(
                      key: const ValueKey('rename-sign-in-key-field'),
                      controller: _controller,
                      autofocus: true,
                      // One line, and no longer than the service keeps.
                      // The formatter counts as the service does; the
                      // field's own `maxLength` counts differently.
                      inputFormatters: const [_SignInKeyNameFormatter()],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Passkey',
                        hintStyle: MallowTheme.uiBody.copyWith(
                          color: colors.textSecondary,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: MallowTheme.spacingLg,
                          vertical: MallowTheme.spacingSm,
                        ),
                        filled: false,
                        border: border,
                        enabledBorder: border,
                        focusedBorder: border.copyWith(
                          borderSide: BorderSide(color: colors.textPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    Row(
                      children: [
                        Expanded(
                          child: MallowButton(
                            label: 'Cancel',
                            variant: MallowButtonVariant.secondary,
                            isFullWidth: true,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: MallowTheme.spacingSm),
                        Expanded(
                          child: MallowButton(
                            label: 'Save',
                            isFullWidth: true,
                            onPressed: _save,
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
      ),
    );
  }
}
