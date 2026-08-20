import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_colors.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Corner "hidden from profile" badge overlaid on an owner's artwork thumbnail.
///
/// Mirrors the webapp's eye-slash affordance: it marks the items the viewer has
/// hidden from their own profile. It is purely indicative — the hide/unhide
/// toggle lives in the artwork "..." menu — so it ignores pointer events.
///
/// Gated by the caller on `artwork.isHidden`, which the backend only reports as
/// true to the requesting owner, so the badge is inherently owner-only.
class HiddenArtworkBadge extends StatelessWidget {
  const HiddenArtworkBadge({this.size = 28, super.key});

  /// Diameter of the circular badge in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colors.bgSurface.withValues(alpha: 0.85),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
            ),
          ],
        ),
        child: Center(
          child: MallowSvgIcon(
            'assets/icons/invisible.svg',
            width: size * 0.55,
            height: size * 0.55,
            color: colors.textPrimary,
            semanticLabel: 'Hidden from your profile',
          ),
        ),
      ),
    );
  }
}
