import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Minimum touch-target dimension (logical px) for interactive elements.
const double kMinTapTarget = 40;

/// Expands the *hit-test* area of [child] to at least [minSize] × [minSize]
/// without changing its layout size — the child paints exactly as before, but
/// taps landing in the invisible margin around it are delivered to the child's
/// center (the same redirection Material's own tap-target padding uses).
///
/// Wrap this around the gesture-handling widget itself:
///
/// ```dart
/// TapTargetExpander(
///   child: GestureDetector(onTap: ..., child: SmallIcon()),
/// )
/// ```
///
/// Limitation: hit tests still flow through ancestors, so the expansion is
/// bounded by the nearest ancestor render box that is itself large enough to
/// contain the tap point (e.g. a 24px-tall Row caps vertical expansion of its
/// children at 24px). Apply the expander at the outermost small widget.
class TapTargetExpander extends SingleChildRenderObjectWidget {
  const TapTargetExpander({
    this.minSize = kMinTapTarget,
    super.child,
    super.key,
  });

  /// Minimum hit-test extent per axis. Axes already at or above this size are
  /// unaffected.
  final double minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderTapTargetExpander(minSize: minSize);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderTapTargetExpander renderObject,
  ) {
    renderObject.minSize = minSize;
  }
}

class RenderTapTargetExpander extends RenderProxyBox {
  RenderTapTargetExpander({required double minSize}) : _minSize = minSize;

  /// True while a sibling-arbitration probe hit-test is in flight. During a
  /// probe every expander answers only for its REAL painted pixels
  /// ([RenderProxyBox.hitTest]) — no slop claims and no nested probes — so the
  /// probe result is ground truth about what is visibly under the pointer.
  static bool _probing = false;

  double get minSize => _minSize;
  double _minSize;
  set minSize(double value) {
    if (_minSize == value) return;
    _minSize = value;
    markNeedsLayout();
  }

  /// Whether the point at [globalPosition] lands on another expander's real,
  /// painted child. Runs one probe hit-test from the root; because it is a
  /// live hit-test, expanders on hidden subtrees (offstage entries of
  /// kept-alive navigator routes below the current screen) can never appear
  /// in the result, unlike geometry checks against stale-but-attached boxes.
  bool _otherExpanderPixelsAt(Offset globalPosition) {
    final RenderObject? rootNode = owner?.rootNode;
    if (rootNode is! RenderView) return false;
    final HitTestResult probe = HitTestResult();
    _probing = true;
    try {
      rootNode.hitTest(probe, position: globalPosition);
    } finally {
      _probing = false;
    }
    for (final HitTestEntry entry in probe.path) {
      final Object target = entry.target;
      if (target is RenderTapTargetExpander && !identical(target, this)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    // During a probe only the real-pixel path (above) may answer: claiming
    // slop here would poison the probe result, and re-probing would re-enter.
    if (_probing) return false;
    if (child == null || child!.size.isEmpty) return false;

    final Rect hitRect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: math.max(size.width, _minSize),
      height: math.max(size.height, _minSize),
    );
    if (!hitRect.contains(position)) return false;

    // Slop-area hit: the point is outside this child's painted bounds but
    // inside its inflated target. Decline if it lands on ANOTHER expander's
    // real painted child — that sibling's visible pixels outrank this
    // expander's invisible margin. Declining returns the hit to the host
    // (e.g. a Column hit-testing children in reverse paint order), which then
    // delivers the tap to the sibling that actually owns those pixels.
    if (_otherExpanderPixelsAt(localToGlobal(position))) return false;

    // The point is outside the child's bounds but inside the expanded target
    // (and not shadowed by a sibling's real pixels): redirect the hit to the
    // nearest in-bounds point so position-sensitive children (e.g. text with
    // per-span recognizers) still see a meaningful local position.
    final Offset clamped = Offset(
      position.dx.clamp(0.0, math.max(0.0, child!.size.width - 0.1)),
      position.dy.clamp(0.0, math.max(0.0, child!.size.height - 0.1)),
    );
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(clamped),
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        assert(position == clamped);
        return child!.hitTest(result, position: clamped);
      },
    );
  }
}
