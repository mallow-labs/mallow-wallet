import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A one-shot celebratory ripple painted behind the success state of
/// [TransactionPipelineSheet]. Visually echoes the artwork-loading shimmer
/// (a grid of cells whose brightness is keyed to their distance from an
/// origin) but plays exactly once: a single green wavefront blooms from the
/// centre of the sheet and sweeps outward on a fast ease-out curve, then
/// fades. Paired with haptics that fire as the wavefront launches.
///
/// Mount this only when the success phase appears (e.g. as a [Positioned.fill]
/// background). It runs its controller once in [initState] and never repeats,
/// so keeping it in the same slot across host rebuilds replays nothing.
class SuccessRipple extends StatefulWidget {
  const SuccessRipple({required this.color, super.key});

  /// Base hue of the ripple — the sheet's positive/success green.
  final Color color;

  @override
  State<SuccessRipple> createState() => _SuccessRippleState();
}

class _SuccessRippleState extends State<SuccessRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _wave;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 864),
      vsync: this,
    );
    // Fast, clean ease-out: the wavefront leaps from the centre and
    // decelerates as it reaches the edges.
    _wave = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
    _fireHaptics();
  }

  // A two-stage tap synced to the bloom: a medium "pop" as the wavefront
  // launches from the centre, then a lighter tap a beat later as it spreads —
  // reads as the ripple bursting and settling.
  void _fireHaptics() {
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) HapticFeedback.lightImpact();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _wave,
        builder: (context, _) => CustomPaint(
          painter: _SuccessRipplePainter(
            progress: _wave.value,
            color: widget.color,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

// Square cell size (logical px) — matches the artwork shimmer's grid rhythm
// closely enough that the two effects read as siblings.
const _rippleCellSize = 22.0;
// Peak opacity of the wavefront over the sheet surface. High enough that the
// green reads as green over the cream/dark background, still short of opaque
// so the ripple tints rather than masks the success copy.
const _rippleMaxAlpha = 0.6;

class _SuccessRipplePainter extends CustomPainter {
  _SuccessRipplePainter({required this.progress, required this.color});

  /// Eased 0→1 progress of the single wavefront.
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.clipRect(Offset.zero & size);

    final cols = (size.width / _rippleCellSize).ceil();
    final rows = (size.height / _rippleCellSize).ceil();

    // Origin: the centre of the sheet, in cell coordinates.
    final originCol = (cols - 1) / 2.0;
    final originRow = (rows - 1) / 2.0;

    // Farthest reachable distance (centre → corner), in cell units.
    final maxDist = math.sqrt(originCol * originCol + originRow * originRow);
    // Half-width of the moving wavefront band.
    final ringWidth = math.max(1.5, maxDist * 0.32);
    // Drive the band from the centre out past the corner so it fully exits.
    final waveRadius = progress * (maxDist + ringWidth);

    // Sine envelope so the one-shot has no hard start or stop — fades up as it
    // leaves the centre, fades out as it clears the edges.
    final envelope = math.sin(math.pi * progress.clamp(0.0, 1.0));

    // Brighter — but still saturated — green at the crest of the wave,
    // deepening toward the base hue at its trailing edge. Only a slight push
    // toward white so the crest stays unmistakably green rather than washing
    // out to grey at peak opacity.
    final crest = Color.lerp(color, Colors.white, 0.15)!;

    final paint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final dx = col - originCol;
        final dy = row - originRow;
        final distance = math.sqrt(dx * dx + dy * dy);
        // Gaussian bump centred on the current wavefront radius.
        final delta = (distance - waveRadius) / ringWidth;
        final pulse = math.exp(-delta * delta);
        if (pulse < 0.02) continue;
        paint.color = Color.lerp(
          color,
          crest,
          pulse,
        )!.withValues(alpha: pulse * envelope * _rippleMaxAlpha);
        canvas.drawRect(
          Rect.fromLTWH(
            col * _rippleCellSize,
            row * _rippleCellSize,
            _rippleCellSize,
            _rippleCellSize,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SuccessRipplePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
