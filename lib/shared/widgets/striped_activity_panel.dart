import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';

/// In-progress activity panel with diagonal striped background.
///
/// The two-tone stripes translate horizontally to the right on a continuous
/// loop. [label] and [sublabel] are displayed centered over the pattern and
/// can be updated; the animation keeps running across rebuilds.
class StripedActivityPanel extends StatefulWidget {
  const StripedActivityPanel({
    required this.label,
    super.key,
    this.sublabel,
    this.padding = const EdgeInsets.symmetric(
      horizontal: MallowTheme.spacing20,
      vertical: MallowTheme.spacing20,
    ),
    this.borderRadius,
    this.duration = const Duration(seconds: 6),
    this.colorA,
    this.colorB,
  });

  final String label;
  final String? sublabel;
  final EdgeInsets padding;
  final BorderRadius? borderRadius;

  /// Time for the stripe pattern to advance one full period.
  final Duration duration;

  /// Override stripe colors. Defaults to `bgPrimary` / `bgSurface`.
  final Color? colorA;
  final Color? colorB;

  @override
  State<StripedActivityPanel> createState() => _StripedActivityPanelState();
}

class _StripedActivityPanelState extends State<StripedActivityPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant StripedActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller
        ..stop()
        ..duration = widget.duration;
      _syncAnimation();
    }
  }

  /// Runs the stripe loop, unless Reduce Motion is on — then the pattern holds
  /// static at its first frame.
  void _syncAnimation() {
    if (context.reduceMotion) {
      if (_controller.isAnimating) {
        _controller
          ..stop()
          ..value = 0;
      }
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final radius =
        widget.borderRadius ?? BorderRadius.circular(MallowTheme.radiusPrimary);
    final colorA = widget.colorA ?? colors.bgPrimary;
    final colorB = widget.colorB ?? colors.bgSurface;
    final sublabel = widget.sublabel;

    return ClipRRect(
      borderRadius: radius,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: _StripesPainter(
                progress: _controller.value,
                colorA: colorA,
                colorB: colorB,
              ),
              child: child,
            );
          },
          child: Padding(
            padding: widget.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RollingText(
                  text: widget.label,
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                if (sublabel != null) ...[
                  const SizedBox(height: MallowTheme.spacingSm),
                  _RollingText(
                    // Sublabel trails the main label so the pair reads as one
                    // cascading swap rather than two simultaneous rolls.
                    text: sublabel,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                    startDelay: const Duration(milliseconds: 100),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single line of centered text that "rolls" on change: the outgoing string
/// translates up and fades out while the incoming one rises from below and
/// fades in, the whole thing clipped to the text's own height so neither line
/// ever spills past its slot.
///
/// [startDelay] holds the roll back by a fixed amount before it begins, so a
/// stack of these (e.g. a main label + sublabel) can be staggered into a
/// cascade rather than moving in lockstep.
class _RollingText extends StatefulWidget {
  const _RollingText({
    required this.text,
    required this.style,
    this.startDelay = Duration.zero,
    this.slideDuration = const Duration(milliseconds: 340),
  });

  final String text;
  final TextStyle style;
  final Duration startDelay;
  final Duration slideDuration;

  @override
  State<_RollingText> createState() => _RollingTextState();
}

class _RollingTextState extends State<_RollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The string rolling up and out. Null when the widget is at rest. The
  /// incoming string is always [widget.text] (read live in build) so that a
  /// change arriving mid-roll simply retargets the rising line — see
  /// [didUpdateWidget].
  String? _outgoing;

  static const Curve _curve = Curves.easeOutCubic;

  /// Past this raw-controller progress a fresh change starts a new roll from
  /// the top; below it the change instead retargets the still-rising line.
  /// Keeps a burst of near-instant status changes (e.g. mint's local-signer
  /// "Signing…" → "Confirming…", which fire a frame apart) as one continuous
  /// roll to the newest label rather than a jarring restart.
  static const double _retargetBelow = 0.85;

  /// Fraction of the controller's run that is dead time before the slide, so
  /// [startDelay] can be baked into a single controller instead of an async
  /// timer that could outlive a superseding label change.
  double get _delayFraction {
    final total = widget.startDelay + widget.slideDuration;
    if (total == Duration.zero) return 0;
    return widget.startDelay.inMicroseconds / total.inMicroseconds;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.startDelay + widget.slideDuration,
      // Start settled — the first build shows the initial text at rest.
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant _RollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;

    if (context.reduceMotion) {
      // No vestibular motion — snap straight to the new string.
      _outgoing = null;
      _controller.value = 1;
      return;
    }

    if (!_controller.isCompleted && _controller.value < _retargetBelow) {
      // A roll is already in flight and hasn't nearly landed. Keep [_outgoing]
      // and the controller's progress; because the rising line renders
      // [widget.text] live, it now shows the newest label and finishes the
      // same continuous roll. The superseded label is never stranded on-screen.
      return;
    }

    // Settled (or all but settled): start a fresh roll with the text that was
    // showing sliding up and out.
    _outgoing = oldWidget.text;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _line(String text) => Text(
    text,
    style: widget.style,
    textAlign: TextAlign.center,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final delay = _delayFraction;
          // Remap past the dead time, then ease.
          final raw = delay >= 1
              ? 0.0
              : ((_controller.value - delay) / (1 - delay)).clamp(0.0, 1.0);
          final t = _curve.transform(raw);

          final incoming = FractionalTranslation(
            translation: Offset(0, 1 - t),
            child: Opacity(opacity: t, child: _line(widget.text)),
          );

          final outgoing = _outgoing;
          if (outgoing == null || t >= 1) {
            return incoming;
          }

          return Stack(
            alignment: Alignment.center,
            children: [
              FractionalTranslation(
                translation: Offset(0, -t),
                child: Opacity(opacity: 1 - t, child: _line(outgoing)),
              ),
              incoming,
            ],
          );
        },
      ),
    );
  }
}

class _StripesPainter extends CustomPainter {
  _StripesPainter({
    required this.progress,
    required this.colorA,
    required this.colorB,
  });

  /// 0..1, wraps every cycle.
  final double progress;
  final Color colorA;
  final Color colorB;

  static const double _stripeWidth = 30;
  static const double _rotationDeg = -30;

  @override
  void paint(Canvas canvas, Size size) {
    const rotation = _rotationDeg * math.pi / 180;
    // The stripe pattern repeats every `2 * stripeWidth` along its perpendicular,
    // which projects to `2 * stripeWidth / cos(angleFromVertical)` along screen X.
    final horizontalPeriod = (2 * _stripeWidth) / math.cos(rotation.abs());
    final shift = progress * horizontalPeriod;

    canvas.save();
    // Translate the rotation pivot horizontally by `shift` — this slides the
    // entire pattern right in screen space without changing stripe orientation.
    canvas.translate(size.width / 2 + shift, size.height / 2);
    canvas.rotate(rotation);

    // Oversize generously so the rotated rect always covers the panel.
    final extent = (size.width + size.height) * 1.5 + horizontalPeriod;

    final paintA = Paint()..color = colorA;
    final paintB = Paint()..color = colorB;

    for (double x = -extent; x < extent; x += _stripeWidth * 2) {
      canvas.drawRect(
        Rect.fromLTWH(x, -extent, _stripeWidth, extent * 2),
        paintA,
      );
      canvas.drawRect(
        Rect.fromLTWH(x + _stripeWidth, -extent, _stripeWidth, extent * 2),
        paintB,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StripesPainter old) =>
      old.progress != progress || old.colorA != colorA || old.colorB != colorB;
}
