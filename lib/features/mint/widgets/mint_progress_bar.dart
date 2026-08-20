import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';

/// 2px tall progress bar used at the top of each mint step.
///
/// The track uses `surfaceMuted` and the fill uses `accent`. The
/// `widthFactor` animates whenever [fraction] changes so the bar
/// visibly fills when the user moves between steps.
class MintProgressBar extends StatelessWidget {
  const MintProgressBar({required this.fraction, super.key});

  /// 0..1 fill fraction. Values outside the range are clamped.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final clamped = fraction.clamp(0.0, 1.0);
    return SizedBox(
      height: 2,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              widthFactor: clamped,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
