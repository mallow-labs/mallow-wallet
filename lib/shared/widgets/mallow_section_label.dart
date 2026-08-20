import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// "(Optional) Label" header above each form input.
///
/// Renders `(Optional) ` in `textSecondary` when [optional] is true and the
/// label itself in `textPrimary`, using `MallowTheme.uiMeta` (Geist Regular
/// 13px) per Figma spec.
class MallowSectionLabel extends StatelessWidget {
  const MallowSectionLabel({
    required this.label,
    super.key,
    this.optional = false,
  });

  final String label;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return RichText(
      text: TextSpan(
        style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
        children: [
          if (optional)
            TextSpan(
              text: '(Optional) ',
              style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
            ),
          TextSpan(text: label),
        ],
      ),
    );
  }
}
