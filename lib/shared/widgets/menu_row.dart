import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';
import 'tappable.dart';

/// Standard menu row: 36px height, 24x24 icon container, 15px Inter label.
///
/// Used by the account-menu drawer and the add-account / add-wallet screens.
class MenuRow extends StatelessWidget {
  const MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconSize = 24,
    super.key,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: MallowSvgIcon(icon, width: iconSize, height: iconSize),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
