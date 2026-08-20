import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'tappable.dart';

/// A styled card widget following mallow design system.
///
/// Features:
/// - 16px rounded corners
/// - Subtle shadow for elevation
/// - White surface background
/// - Optional tap handler
class MallowCard extends StatelessWidget {
  const MallowCard({
    required this.child,
    super.key,
    this.onTap,
    this.padding,
    this.margin,
    this.elevation = 2,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double elevation;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(MallowTheme.radiusLg);

    Widget content = Container(
      decoration: BoxDecoration(
        color: context.mallowColors.bgSurface,
        borderRadius: radius,
        boxShadow: elevation > 0
            ? [
                BoxShadow(
                  color: context.mallowColors.shadow.withValues(alpha: 0.04),
                  blurRadius: elevation * 2,
                  offset: Offset(0, elevation),
                ),
                BoxShadow(
                  color: context.mallowColors.shadow.withValues(alpha: 0.02),
                  blurRadius: elevation,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: padding != null ? Padding(padding: padding!, child: child) : child,
    );

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    if (onTap != null) {
      return Tappable(
        onTap: onTap,
        behavior: HitTestBehavior.deferToChild,
        child: content,
      );
    }

    return content;
  }
}
