import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import 'package:mallow_wallet/core/utils/reduce_motion.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Animated pill toggle backed by the `toggle.json` Lottie composition.
///
/// Colors are driven by the active [MallowColors] theme (so the control is
/// light/dark responsive) rather than the values baked into the asset: the
/// track cross-fades between [MallowColors.textSecondary] (off) and
/// [MallowColors.accent] (on), and the knob is painted [MallowColors.bgPrimary]
/// so it reads as a cut-out against the screen background.
///
/// Pass [onChanged] as `null` for a display-only toggle (taps are ignored).
class MallowToggle extends StatefulWidget {
  const MallowToggle({
    required this.value,
    required this.onChanged,
    super.key,
    this.label,
  });

  final bool value;

  /// Tap handler. When `null` the toggle is display-only and ignores taps.
  final ValueChanged<bool>? onChanged;

  final String? label;

  @override
  State<MallowToggle> createState() => _MallowToggleState();
}

class _MallowToggleState extends State<MallowToggle>
    with SingleTickerProviderStateMixin {
  // toggle.json is a 120-frame @ 60fps composition. The knob slides off→on
  // across frames 15–35 and on→off across frames 85–105; the spans in between
  // are identical static holds, so jumping across them is invisible.
  static const double _frames = 120;
  static const double _onStart = 15 / _frames;
  static const double _onEnd = 35 / _frames;
  static const double _offStart = 85 / _frames;
  static const double _offEnd = 105 / _frames;

  /// Each slide is 20 frames @ 60fps.
  static const Duration _segment = Duration(milliseconds: 333);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _segment,
  )..value = widget.value ? _onEnd : _onStart;

  @override
  void didUpdateWidget(MallowToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Controlled widget: the animation follows the parent-driven value. A tap
    // that the parent rejects leaves `value` unchanged, so the toggle holds.
    if (widget.value != oldWidget.value) _animateTo(widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(bool on) {
    // Reduce Motion: skip the slide entirely and snap to the target frame so
    // the knob simply appears in its new position.
    if (context.reduceMotion) {
      _controller.value = on ? _onEnd : _offEnd;
      return;
    }
    // Jump to the segment's start frame (an invisible hop across the held span)
    // then play the 20-frame slide. We leave the curve linear (animateTo's
    // default) — the easing is already baked into the Lottie keyframes, so
    // layering a Flutter curve would double it up.
    _controller
      ..value = on ? _onStart : _offStart
      ..animateTo(on ? _onEnd : _offEnd, duration: _segment);
  }

  /// 0 = off color, 1 = on color — cross-fades in lockstep with the slide so
  /// the track recolors as the knob travels, matching the baked keyframes.
  double _trackBlend(double frame) {
    if (frame <= 15) return 0;
    if (frame < 35) return (frame - 15) / 20;
    if (frame <= 85) return 1;
    if (frame < 105) return 1 - (frame - 85) / 20;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final offColor = colors.textSecondary;
    final onColor = colors.accent;

    return Semantics(
      container: true,
      toggled: widget.value,
      label: widget.label,
      enabled: widget.onChanged != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onChanged == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onChanged!(!widget.value);
              },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 40×40 touch target (accessibility minimum) with the half-scale pill
            // centered inside it. The composition canvas is square (512×512) and
            // the visible pill spans ~79% of it, so rendering at 28 yields a pill
            // ~22 wide — comfortably smaller than the hitbox it sits within.
            SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: Lottie.asset(
                  'assets/animations/toggle.json',
                  controller: _controller,
                  width: 28,
                  height: 28,
                  fit: BoxFit.contain,
                  delegates: LottieDelegates(
                    values: [
                      ValueDelegate.color(
                        const ['track', 'track-group', 'track-fill'],
                        callback: (info) => Color.lerp(
                          offColor,
                          onColor,
                          _trackBlend(info.overallProgress * _frames),
                        )!,
                      ),
                      ValueDelegate.color(const [
                        'knob',
                        'knob-group',
                        'knob-fill',
                      ], value: colors.bgPrimary),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.label != null) ...[
              const SizedBox(width: 12),
              Text(widget.label!, style: MallowTheme.uiBody),
            ],
          ],
        ),
      ),
    );
  }
}
