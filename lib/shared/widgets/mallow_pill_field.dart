import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/mallow_theme.dart';

/// 40px-tall circular pill input used across the wallet.
///
/// Border is a 1px hairline using the theme's divider colour; padding is
/// 16px horizontal. Optional [prefix] / [suffix] slots render inline
/// before/after the text field (e.g. `%` glyph for royalties, search icon
/// for search inputs, "SOL" suffix for price fields, paste/QR/MAX
/// trailing buttons).
///
/// [height], [padding] and [boxShadow] let a prominent field (the browser's
/// search capsule) grow without forking the widget; the defaults are the
/// standard 40px pill.
class MallowPillField extends StatelessWidget {
  const MallowPillField({
    required this.controller,
    super.key,
    this.focusNode,
    this.hintText,
    this.errorText,
    this.onChanged,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.prefix,
    this.suffix,
    this.inputFormatters,
    this.autofocus = false,
    this.enabled = true,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.obscureText = false,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
    this.textAlign = TextAlign.start,
    this.borderColor,
    this.backgroundColor,
    this.height = 40,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.boxShadow,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefix;
  final Widget? suffix;
  final List<TextInputFormatter>? inputFormatters;
  final bool autofocus;
  final bool enabled;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final TextCapitalization textCapitalization;
  final TextAlign textAlign;
  final Color? borderColor;
  final Color? backgroundColor;
  final double height;
  final EdgeInsetsGeometry padding;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final hasError = errorText != null && errorText!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            boxShadow: boxShadow,
            borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
            border: Border.all(
              color: hasError ? colors.error : (borderColor ?? colors.divider),
            ),
            color: backgroundColor ?? colors.bgPrimary,
          ),
          child: Row(
            children: [
              if (prefix != null) ...[
                prefix!,
                const SizedBox(width: MallowTheme.spacingXs),
              ],
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  maxLength: maxLength,
                  keyboardType: keyboardType,
                  textInputAction: textInputAction,
                  inputFormatters: inputFormatters,
                  autofocus: autofocus,
                  enabled: enabled,
                  autocorrect: autocorrect,
                  enableSuggestions: enableSuggestions,
                  obscureText: obscureText,
                  autofillHints: autofillHints,
                  textCapitalization: textCapitalization,
                  textAlign: textAlign,
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                  cursorColor: colors.accent,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    counterText: '',
                    hintText: hintText,
                    hintStyle: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
              if (suffix != null) ...[
                const SizedBox(width: MallowTheme.spacingXs),
                suffix!,
              ],
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: MallowTheme.spacingXs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              errorText!,
              style: MallowTheme.uiCaption.copyWith(color: colors.error),
            ),
          ),
        ],
      ],
    );
  }
}
