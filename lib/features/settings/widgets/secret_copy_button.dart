import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Pill copy button pinned to the bottom of the secret-reveal screens
/// (private key / recovery phrase).
class SecretCopyButton extends StatelessWidget {
  const SecretCopyButton({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MallowSvgIcon(
              'assets/icons/copy.svg',
              width: 16,
              height: 16,
              color: colors.textPrimary,
            ),
            const SizedBox(width: 8),
            Text(label, style: MallowTheme.uiBody),
          ],
        ),
      ),
    );
  }
}
