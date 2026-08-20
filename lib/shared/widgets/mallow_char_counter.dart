import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// "N characters remaining" caption shown under pill/textarea inputs.
/// Uses `uiCaption` styling in `textSecondary`.
class MallowCharCounter extends StatelessWidget {
  const MallowCharCounter({required this.remaining, super.key});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final value = remaining < 0 ? 0 : remaining;
    return Text(
      '$value characters remaining',
      style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
    );
  }
}
