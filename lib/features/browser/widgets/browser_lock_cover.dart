import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// The solid panel that hides a website while the app is locked, in the
/// background, or behind another screen. Opaque by design: blur over a
/// platform view is unreliable and would leak the page.
class BrowserLockCover extends StatelessWidget {
  const BrowserLockCover({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      label: 'Website hidden',
      container: true,
      excludeSemantics: true,
      child: ColoredBox(
        color: colors.bgPrimary,
        child: Center(
          child: MallowSvgIcon(
            'assets/icons/mallow_icon.svg',
            width: 44,
            height: 35,
            color: colors.textTertiary,
          ),
        ),
      ),
    );
  }
}
