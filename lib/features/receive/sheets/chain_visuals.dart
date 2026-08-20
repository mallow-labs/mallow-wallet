import 'package:flutter/material.dart';

import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// A chain logo rendered at a visually consistent size inside a square [size]
/// box.
///
/// All three assets ([Chain.paddedIconAsset]) pad their glyph to ~58% of a
/// square viewBox, so rendering each with `BoxFit.contain` at an equal box size
/// makes the three read as one size — no per-chain scaling needed.
class ChainGlyph extends StatelessWidget {
  const ChainGlyph({
    required this.chain,
    this.size = 24,
    this.color,
    this.useOriginalColors = false,
    super.key,
  });

  final Chain chain;
  final double size;

  /// Monochrome tint (ignored when [useOriginalColors] is true).
  final Color? color;
  final bool useOriginalColors;

  @override
  Widget build(BuildContext context) {
    return MallowSvgIcon(
      chain.paddedIconAsset,
      width: size,
      height: size,
      color: useOriginalColors ? null : color,
      useOriginalColors: useOriginalColors,
    );
  }
}
