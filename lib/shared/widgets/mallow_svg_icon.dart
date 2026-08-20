import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';

/// SVG icon widget that automatically adapts to light/dark mode.
///
/// Uses [context.mallowColors.textPrimary] by default, making icons
/// white in dark mode and dark in light mode. Pass [color] to override.
class MallowSvgIcon extends StatelessWidget {
  const MallowSvgIcon(
    this.assetPath, {
    super.key,
    this.width,
    this.height,
    this.color,
    this.fit = BoxFit.contain,
    this.useOriginalColors = false,
    this.semanticLabel,
  });

  final String assetPath;
  final double? width;
  final double? height;

  /// Override color. When null, uses [context.mallowColors.textPrimary].
  final Color? color;

  final BoxFit fit;

  /// When true, renders the SVG with its original colors (no color filter).
  final bool useOriginalColors;

  /// Accessibility label exposed to screen readers. When null (the default)
  /// the icon is treated as decorative and excluded from the semantics tree.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? context.mallowColors.textPrimary;
    return SvgPicture.asset(
      assetPath,
      width: width,
      height: height,
      fit: fit,
      semanticsLabel: semanticLabel,
      colorFilter: useOriginalColors
          ? null
          : ColorFilter.mode(effectiveColor, BlendMode.srcIn),
    );
  }
}
