import 'package:custom_refresh_indicator/custom_refresh_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import 'package:mallow_wallet/core/utils/reduce_motion.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Pull-to-refresh wrapper that renders the mallow mark instead of the stock
/// Material spinner.
///
/// While the user drags, the mark rides the pull at its resting first frame;
/// once released past the arm threshold, the four shapes pulse in a loop
/// (`mallow_loader.json`) until [onRefresh] completes and the indicator
/// retracts. The mark is tinted [MallowColors.accent], on a
/// [MallowColors.bgPrimary] plate for readability when it floats over
/// content.
class MallowRefreshIndicator extends StatefulWidget {
  const MallowRefreshIndicator({
    required this.onRefresh,
    required this.child,
    this.edgeOffset = 0,
    super.key,
  });

  /// Started on release; the indicator stays visible until it completes.
  final Future<void> Function() onRefresh;

  /// The scrollable this indicator listens to.
  final Widget child;

  /// Extra distance below the top edge before the indicator appears (e.g. to
  /// clear a full-bleed banner behind the status bar).
  final double edgeOffset;

  @override
  State<MallowRefreshIndicator> createState() => _MallowRefreshIndicatorState();
}

class _MallowRefreshIndicatorState extends State<MallowRefreshIndicator>
    with SingleTickerProviderStateMixin {
  /// Pull distance (beyond [MallowRefreshIndicator.edgeOffset]) that arms the
  /// refresh — matches the Material indicator's feel.
  static const double _offsetToArmed = 100;

  /// Resting distance of the plate below the top edge while refreshing.
  static const double _displacement = 40;

  static const double _plateSize = 44;

  /// mallow_loader.json is a 130-frame composition @ 60fps.
  static const Duration _loopDuration = Duration(milliseconds: 2167);

  /// Static frame the mark holds on when Reduce Motion is on — mid-composition,
  /// where all four shapes are visible.
  static const double _reducedMotionFrame = 0.5;

  late final AnimationController _lottie = AnimationController(
    vsync: this,
    duration: _loopDuration,
  );

  // Captured in build() (where the MediaQuery lookup is valid) and read from
  // the [_onStateChanged] callback.
  bool _reduceMotion = false;

  @override
  void dispose() {
    _lottie.dispose();
    super.dispose();
  }

  void _onStateChanged(IndicatorStateChange change) {
    if (change.didChange(to: IndicatorState.armed)) {
      // Pull just crossed the trigger threshold — confirm with a haptic bump.
      HapticFeedback.mediumImpact();
    } else if (change.didChange(to: IndicatorState.settling)) {
      // Released past the arm threshold. Loop the mark while refreshing, or —
      // under Reduce Motion — hold a static frame instead.
      if (_reduceMotion) {
        _lottie
          ..stop()
          ..value = _reducedMotionFrame;
      } else {
        _lottie.repeat();
      }
    } else if (change.didChange(to: IndicatorState.idle)) {
      // Retract finished (or drag canceled): rest on the first frame.
      _lottie
        ..stop()
        ..value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    _reduceMotion = context.reduceMotion;
    final colors = context.mallowColors;

    return CustomRefreshIndicator(
      onRefresh: widget.onRefresh,
      offsetToArmed: _offsetToArmed,
      onStateChanged: _onStateChanged,
      builder: (context, child, controller) {
        // Slides from fully hidden above the edge (value 0) to _displacement
        // below it (value 1, the armed/loading position); overdrag past the
        // threshold keeps pulling it proportionally further.
        final hiddenTop = widget.edgeOffset - _plateSize - 8;
        final shownTop = widget.edgeOffset + _displacement;
        return Stack(
          children: [
            child,
            Positioned(
              left: 0,
              right: 0,
              top: hiddenTop + controller.value * (shownTop - hiddenTop),
              child: IgnorePointer(
                child: Opacity(
                  opacity: (controller.value / 0.4).clamp(0.0, 1.0),
                  child: Center(
                    child: Container(
                      width: _plateSize,
                      height: _plateSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.bgPrimary,
                        boxShadow: [
                          BoxShadow(
                            color: colors.shadow.withValues(alpha: 0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Lottie.asset(
                          'assets/animations/mallow_loader.json',
                          controller: _lottie,
                          width: 34,
                          height: 34,
                          fit: BoxFit.contain,
                          delegates: LottieDelegates(
                            values: [
                              for (final layer in const [
                                ['petal-top-right', 'petal', 'fill'],
                                ['dot-bottom-right', 'dot', 'fill'],
                                ['body-center', 'body', 'fill'],
                                ['wedge-bottom-left', 'wedge', 'fill'],
                              ])
                                ValueDelegate.color(
                                  layer,
                                  value: colors.accent,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
