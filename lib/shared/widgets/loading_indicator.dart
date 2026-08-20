import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lottie/lottie.dart';

import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';

/// Branded looping loader — the mallow mark pulsing through its four shapes.
///
/// Drop-in replacement for a stock [CircularProgressIndicator] spinner. Renders
/// `mallow_loader.json` on a continuous loop, tinted [MallowColors.accent] by
/// default. Under Reduce Motion it holds a static mid-composition frame (all
/// four shapes visible), matching [MallowRefreshIndicator].
class MallowLoader extends StatefulWidget {
  const MallowLoader({super.key, this.size = 40, this.color});

  /// Rendered width/height in logical px.
  final double size;

  /// Tint applied to all four shapes. Defaults to [MallowColors.accent].
  final Color? color;

  @override
  State<MallowLoader> createState() => _MallowLoaderState();
}

class _MallowLoaderState extends State<MallowLoader>
    with SingleTickerProviderStateMixin {
  /// mallow_loader.json is a 130-frame composition @ 60fps.
  static const Duration _loopDuration = Duration(milliseconds: 2167);

  /// Static frame held under Reduce Motion — mid-composition, all four shapes
  /// visible.
  static const double _reducedMotionFrame = 0.5;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _loopDuration,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is only valid here, not in initState.
    if (context.reduceMotion) {
      _controller
        ..stop()
        ..value = _reducedMotionFrame;
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
    final color = widget.color ?? context.mallowColors.accent;
    return Lottie.asset(
      'assets/animations/mallow_loader.json',
      controller: _controller,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      delegates: LottieDelegates(
        values: [
          for (final layer in const [
            ['petal-top-right', 'petal', 'fill'],
            ['dot-bottom-right', 'dot', 'fill'],
            ['body-center', 'body', 'fill'],
            ['wedge-bottom-left', 'wedge', 'fill'],
          ])
            ValueDelegate.color(layer, value: color),
        ],
      ),
    );
  }
}

/// A branded loading indicator for mallow.
///
/// Provides consistent loading states across the app.
class MallowLoadingIndicator extends StatelessWidget {
  const MallowLoadingIndicator({
    super.key,
    this.size = MallowLoadingSize.medium,
    this.color,
    this.message,
  });

  final MallowLoadingSize size;
  final Color? color;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? context.mallowColors.accent;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MallowLoader(size: size.dimension, color: effectiveColor),
        if (message != null) ...[
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            message!,
            style: MallowTheme.uiMeta.copyWith(
              color: context.mallowColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

/// Loading sizes for the mallow loading indicator.
enum MallowLoadingSize {
  small(24, 2),
  medium(40, 3),
  large(56, 4);

  const MallowLoadingSize(this.dimension, this.strokeWidth);

  final double dimension;
  final double strokeWidth;
}

/// A full-screen loading overlay.
///
/// Useful for blocking interactions during async operations.
class MallowLoadingOverlay extends StatelessWidget {
  const MallowLoadingOverlay({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.mallowColors.bgPrimary.withValues(alpha: 0.9),
      child: Center(
        child: MallowLoadingIndicator(
          size: MallowLoadingSize.large,
          message: message,
        ),
      ),
    );
  }
}

/// A shimmer loading placeholder for content.
///
/// Used while content is loading to provide visual feedback.
class MallowShimmer extends StatefulWidget {
  const MallowShimmer({required this.child, super.key});

  final Widget child;

  @override
  State<MallowShimmer> createState() => _MallowShimmerState();
}

class _MallowShimmerState extends State<MallowShimmer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2800),
      vsync: this,
    );
    // Linear travel from fully off-left to fully off-right. At both endpoints
    // the gradient is entirely outside the visible band, so the loop wrap is
    // imperceptible — no easing curve, no snap-back.
    _animation = Tween<double>(begin: -1.5, end: 2.5).animate(_controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion: leave the controller parked so the sweep holds a single
    // static gradient frame instead of looping.
    if (context.reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Neutral grey shimmer band stops — kept off pure white/black so the
  // sweep reads as a soft sheen rather than a blown highlight. The masked
  // child supplies the visible color; these only set the alpha envelope.
  static const _shimmerGradientStops = <Color>[
    Color(0xFFE0E0E0),
    Color(0xFFEAEAEA),
    Color(0xFFF5F5F5),
    Color(0xFFEAEAEA),
    Color(0xFFE0E0E0),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) {
        final v = _animation.value;
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: _shimmerGradientStops,
              stops: [v - 1.5, v - 0.75, v, v + 0.75, v + 1.5],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

/// A grid of grey squares that ripple outward from the bottom-left corner,
/// oscillating smoothly through four shades.
///
/// The grid tiles the parent area: cell count varies with image size, and
/// cells are 40×40 on larger images / 12×12 on small thumbnails so the
/// ripple stays visible at any size. Cell count is capped at 8 per axis —
/// images larger than 320 px scale their cells up to honor the cap.
/// Each cell's brightness is a
/// phase-shifted sine wave keyed to its distance from the bottom-left
/// origin, so concentric arcs sweep diagonally toward the top-right.
/// The palette switches between light and dark sets based on theme.
class ImageShimmerGrid extends StatefulWidget {
  const ImageShimmerGrid({
    super.key,
    this.width,
    this.height,
    this.singleRow = false,
    this.borderRadius,
  });

  final double? width;
  final double? height;

  /// When true, the squares are laid out as a single row whose cell size
  /// equals the painted height; the column count is derived from the width.
  /// The ripple sweeps left→right. Used for text placeholders.
  final bool singleRow;

  /// Rounds the painted area. The image grid is normally clipped by a parent
  /// `ClipRRect`; text placeholders round themselves via this.
  final BorderRadius? borderRadius;

  @override
  State<ImageShimmerGrid> createState() => _ImageShimmerGridState();
}

// Cell tile sizes (logical px). Small images use the smaller cell so the
// ripple has enough cells to read as a wave.
const _imageShimmerCellSizeLarge = 40.0;
const _imageShimmerCellSizeSmall = 12.0;
// Switch to small cells when the shortest side falls below this threshold.
const _imageShimmerSmallThresholdPx = 200.0;
// Hard cap: never render more than this many cells per axis. Cells are
// scaled up beyond their nominal size to honor the cap on large images.
const _imageShimmerMaxCellsPerSide = 8;

// Period of one full bright→dark→bright oscillation per cell.
const _imageShimmerCycleMs = 2800;

// Phase delay added per unit of distance from the wave origin. Larger =
// longer "wavelength" (more rings visible at once).
const _imageShimmerWaveDelayMsPerUnit = 180;

// Neutral grey palettes — four stops each, kept clear of pure white/black so
// the placeholder reads as grey rather than blown-out highlight or shadow.
const _imageShimmerShadesLight = <Color>[
  Color(0xFFCECECE),
  Color(0xFFD4D4D4),
  Color(0xFFDADADA),
  Color(0xFFE0E0E0),
];
const _imageShimmerShadesDark = <Color>[
  Color(0xFF1E1E1E),
  Color(0xFF252525),
  Color(0xFF2B2B2B),
  Color(0xFF323232),
];

class _ImageShimmerGridState extends State<ImageShimmerGrid>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _nowMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() {
        _nowMs = elapsed.inMilliseconds;
      });
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? _imageShimmerShadesDark : _imageShimmerShadesLight;
    return CustomPaint(
      painter: _ShimmerGridPainter(
        _nowMs,
        palette,
        singleRow: widget.singleRow,
        borderRadius: widget.borderRadius,
      ),
      // Match the old Container(width, height, color) sizing semantics:
      // tight to width/height when given, otherwise expand to fill bounded
      // parent constraints and collapse to 0×0 in unbounded parents.
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: LimitedBox(
          maxWidth: 0,
          maxHeight: 0,
          child: ConstrainedBox(constraints: const BoxConstraints.expand()),
        ),
      ),
    );
  }
}

class _ShimmerGridPainter extends CustomPainter {
  _ShimmerGridPainter(
    this.nowMs,
    this.palette, {
    this.singleRow = false,
    this.borderRadius,
  });

  final int nowMs;
  final List<Color> palette;
  final bool singleRow;
  final BorderRadius? borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // Single-row text placeholders: cells are squares as tall as the row, so
    // the column count follows the width. The full grid sizes cells by image
    // size and caps the count per axis.
    final double cellSize;
    if (singleRow) {
      cellSize = size.height;
    } else {
      final nominalCellSize = size.shortestSide < _imageShimmerSmallThresholdPx
          ? _imageShimmerCellSizeSmall
          : _imageShimmerCellSizeLarge;
      // Enforce the per-axis cap by floor-bounding cell size — for square
      // cells, the binding constraint is the longer side.
      final minCellSize = size.longestSide / _imageShimmerMaxCellsPerSide;
      cellSize = math.max(nominalCellSize, minCellSize);
    }

    // ceil() ensures the bottom/right edges are fully covered; the clip
    // trims overflow so we don't paint outside the widget's bounds.
    final borderRadius = this.borderRadius;
    if (borderRadius != null) {
      canvas.clipRRect(borderRadius.toRRect(Offset.zero & size));
    } else {
      canvas.clipRect(Offset.zero & size);
    }
    final cols = (size.width / cellSize).ceil();
    final rows = singleRow ? 1 : (size.height / cellSize).ceil();

    // Wave origin: bottom-left cell. That cell leads the cycle and the
    // wavefronts sweep outward toward the top-right (left→right for a row).
    const originCol = 0.0;
    final originRow = (rows - 1).toDouble();

    final paint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final dx = col - originCol;
        final dy = row - originRow;
        final distance = math.sqrt(dx * dx + dy * dy);
        paint.color = _colorAtDistance(distance);
        canvas.drawRect(
          Rect.fromLTWH(col * cellSize, row * cellSize, cellSize, cellSize),
          paint,
        );
      }
    }
  }

  Color _colorAtDistance(double distance) {
    final phaseMs = nowMs - distance * _imageShimmerWaveDelayMsPerUnit;
    final cyclePhase = phaseMs / _imageShimmerCycleMs;
    // Smooth oscillation in [0, 1] driven by sine — no discontinuities.
    final brightness = (math.sin(2 * math.pi * cyclePhase) + 1) / 2;
    final scaled = brightness * (palette.length - 1);
    final idx = scaled.floor().clamp(0, palette.length - 2);
    final t = scaled - idx;
    return Color.lerp(palette[idx], palette[idx + 1], t)!;
  }

  @override
  bool shouldRepaint(_ShimmerGridPainter oldDelegate) =>
      oldDelegate.nowMs != nowMs ||
      oldDelegate.palette != palette ||
      oldDelegate.singleRow != singleRow ||
      oldDelegate.borderRadius != borderRadius;
}

/// A placeholder box with shimmer effect. Renders the same rippling-squares
/// design as [ImageShimmerGrid], laid out as a single row of squares whose
/// column count follows the box width.
class ShimmerBox extends StatelessWidget {
  const ShimmerBox({super.key, this.width, this.height, this.borderRadius});

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return ImageShimmerGrid(
      width: width,
      height: height,
      singleRow: true,
      borderRadius:
          borderRadius ?? BorderRadius.circular(MallowTheme.radiusPrimary),
    );
  }
}
