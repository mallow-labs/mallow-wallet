import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/mallow_colors.dart';

/// Verified checkmark badge shown next to usernames. The asset has two
/// hardcoded fills (`#121212` outer, `#FAF9F7` inner) — this widget swaps
/// them onto the active theme so the badge inverts in dark mode. When the
/// user has the `admin` role, the outer fill switches to the theme's
/// `selected` accent.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 20, this.isAdmin = false});

  final double size;
  final bool isAdmin;

  static const _sourceOuter = Color(0xFF121212);
  static const _sourceInner = Color(0xFFFAF9F7);

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SvgPicture.asset(
      'assets/icons/verified.svg',
      width: size,
      height: size,
      colorMapper: _VerifiedColorMapper(
        outer: isAdmin ? colors.accent : colors.textPrimary,
        inner: colors.bgPrimary,
      ),
    );
  }
}

@immutable
class _VerifiedColorMapper extends ColorMapper {
  const _VerifiedColorMapper({required this.outer, required this.inner});

  final Color outer;
  final Color inner;

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    if (color == VerifiedBadge._sourceOuter) return outer;
    if (color == VerifiedBadge._sourceInner) return inner;
    return color;
  }

  @override
  bool operator ==(Object other) =>
      other is _VerifiedColorMapper &&
      other.outer == outer &&
      other.inner == inner;

  @override
  int get hashCode => Object.hash(outer, inner);
}
