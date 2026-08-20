import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'mallow_toggle.dart';
import 'sheet_drag_handle.dart';

/// Maximum length of a curation name.
const _maxNameLength = 32;

/// What the user entered in the New Curation sheet.
class NewCurationResult {
  const NewCurationResult({required this.name, required this.isPrivate});

  final String name;

  /// Whether "Make curation private" was toggled on. Curations are public
  /// by default.
  final bool isPrivate;
}

/// Prompts for a new curation name (and optional private visibility) and
/// returns the result, or `null` when cancelled. Shared by the collection
/// screen and the artwork detail menu so the "New curation" affordance
/// looks and behaves identically. Both callers create the curation and
/// immediately add the artwork in context, hence the "Create & Add" button
/// label.
Future<NewCurationResult?> showNewCurationSheet(BuildContext context) {
  return showMallowSheet<NewCurationResult>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => const _NewCurationSheet(),
  );
}

/// Same sheet in edit mode — prefilled with the curation's current name and
/// visibility, titled "Edit Curation" with a "Save" primary button. Returns
/// the edited values, or `null` when cancelled.
Future<NewCurationResult?> showEditCurationSheet(
  BuildContext context, {
  required String name,
  required bool isPrivate,
}) {
  return showMallowSheet<NewCurationResult>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _NewCurationSheet(initialName: name, initialIsPrivate: isPrivate),
  );
}

class _NewCurationSheet extends StatefulWidget {
  const _NewCurationSheet({this.initialName, this.initialIsPrivate = false});

  /// When non-null the sheet is in edit mode.
  final String? initialName;
  final bool initialIsPrivate;

  bool get isEdit => initialName != null;

  @override
  State<_NewCurationSheet> createState() => _NewCurationSheetState();
}

class _NewCurationSheetState extends State<_NewCurationSheet> {
  late final _controller = TextEditingController(text: widget.initialName);
  late bool _isPrivate = widget.initialIsPrivate;

  @override
  void initState() {
    super.initState();
    // Rebuild on every keystroke so the remaining-characters counter and
    // the Create & Add enabled state stay in sync with the field.
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(
      context,
    ).pop(NewCurationResult(name: name, isPrivate: _isPrivate));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final remaining = _maxNameLength - _controller.text.length;
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
                      widget.isEdit ? 'Edit Curation' : 'New Curation',
                      style: MallowTheme.editorialSubhead.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    Text(
                      'Curation Name',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingMd),
                    _NameField(controller: _controller, onSubmitted: _submit),
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      '$remaining characters remaining',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Make curation private',
                            style: MallowTheme.uiBody.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        MallowToggle(
                          value: _isPrivate,
                          onChanged: (value) =>
                              setState(() => _isPrivate = value),
                        ),
                      ],
                    ),
                    const SizedBox(height: MallowTheme.spacingXl),
                    Container(
                      padding: const EdgeInsets.all(MallowTheme.spacingMd),
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: BorderRadius.circular(
                          MallowTheme.radiusPrimary,
                        ),
                      ),
                      child: Text(
                        'Curation image will auto-populate when artworks '
                        'are added',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
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
                            label: widget.isEdit ? 'Save' : 'Create & Add',
                            isFullWidth: true,
                            enabled: _controller.text.trim().isNotEmpty,
                            onPressed: _submit,
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

/// Pill-shaped name input (40px tall, subtle border, fully rounded).
class _NameField extends StatelessWidget {
  const _NameField({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      borderSide: BorderSide(color: colors.dividerLight),
    );
    return TextField(
      controller: controller,
      autofocus: true,
      maxLength: _maxNameLength,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => onSubmitted(),
      style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Name',
        hintStyle: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        counterText: '',
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
    );
  }
}
