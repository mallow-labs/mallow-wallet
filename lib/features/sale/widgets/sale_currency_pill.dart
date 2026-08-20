import 'package:flutter/material.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Tappable pill that shows the currently selected token symbol and calls
/// [onSelected] when the user picks a different token.
///
/// The caller is responsible for showing a currency picker (e.g.
/// [showCurrencyPickerSheet]) and dispatching the resulting event — this
/// widget is intentionally bloc-agnostic.
class SaleCurrencyPill extends StatelessWidget {
  const SaleCurrencyPill({required this.token, required this.onTap, super.key});

  final MallowToken token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          children: [
            Text(
              token.symbol,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
            const Spacer(),
            MallowSvgIcon(
              'assets/icons/arrow_down.svg',
              width: 6,
              height: 6,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
