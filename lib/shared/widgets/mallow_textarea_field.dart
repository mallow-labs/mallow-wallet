import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/mallow_theme.dart';

/// Multi-line text area used for long-form input (descriptions, notes).
/// 120px tall, 12px rounded rectangle, same hairline border palette as
/// [MallowPillField].
class MallowTextareaField extends StatelessWidget {
  const MallowTextareaField({
    required this.controller,
    super.key,
    this.focusNode,
    this.hintText,
    this.onChanged,
    this.maxLength,
    this.inputFormatters,
    this.enabled = true,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      height: 120,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
        border: Border.all(color: colors.divider),
        color: colors.bgPrimary,
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        maxLength: maxLength,
        inputFormatters: inputFormatters,
        enabled: enabled,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        textCapitalization: textCapitalization,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        cursorColor: colors.accent,
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          counterText: '',
          hintText: hintText,
          hintStyle: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}
