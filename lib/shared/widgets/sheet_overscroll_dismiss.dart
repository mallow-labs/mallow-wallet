import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Bridges top-edge overscroll on an inner scrollable into pull-to-dismiss on
/// the enclosing modal sheet. Wrap a sheet body whose primary content is a
/// vertical [ListView]/[CustomScrollView]/etc. — when the scrollable sits at
/// offset 0 and the user keeps dragging down, the sheet follows the finger via
/// [Transform.translate]. While pulled, an upward drag retracts the sheet back
/// to zero before content begins to scroll again. On release:
///   * if downward flick velocity ≥ [dismissVelocity] (px/s), or
///   * the translation ≥ [dismissThreshold] × scrollable viewport height,
/// the route is popped; otherwise the translation animates back to zero.
///
/// Forces a hybrid scroll physics on descendant scrollables (via
/// [ScrollConfiguration]) that clamps the top edge — so pull-down past offset
/// 0 is reported as an [OverscrollNotification] for pull-to-dismiss — but
/// preserves [BouncingScrollPhysics]' spring at the bottom edge.
///
/// Sheets that pass an explicit `physics:` to their inner scrollable will
/// bypass this — omit `physics:` for this wrapper to work.
class SheetOverscrollDismiss extends StatefulWidget {
  const SheetOverscrollDismiss({
    required this.child,
    this.dismissVelocity = 700,
    this.dismissThreshold = 0.5,
    super.key,
  });

  final Widget child;

  /// Downward pointer velocity (px/s) that triggers a dismiss on release,
  /// regardless of how far the sheet has been pulled.
  final double dismissVelocity;

  /// Fraction of the inner scrollable's viewport height. If the sheet has
  /// been pulled down at least this far on release, it dismisses.
  final double dismissThreshold;

  @override
  State<SheetOverscrollDismiss> createState() => _SheetOverscrollDismissState();
}

class _SheetOverscrollDismissState extends State<SheetOverscrollDismiss>
    with SingleTickerProviderStateMixin {
  double _offset = 0;
  double _viewportHeight = 0;
  Offset? _lastPointerPosition;
  VelocityTracker _velocity = VelocityTracker.withKind(PointerDeviceKind.touch);

  /// When true, descendant scrollables freeze (see [_ClampTopBouncePhysics]).
  /// We hold this steady for the duration of a single pointer event so the
  /// scrollable's read of the value matches the decision made when the event
  /// arrived — otherwise an upward drag that retracts offset to 0 would also
  /// scroll content in the same frame.
  final ValueNotifier<bool> _frozen = ValueNotifier<bool>(false);

  // Unbounded so the spring can be driven directly (its value is the live
  // offset in px); stopped on pointer-down below so the return is interruptible.
  //
  // Built in [initState] rather than as a `late final` initializer: nothing
  // touches it until the first drag, so on a sheet the user never dragged the
  // initializer would instead run from [dispose], where `vsync: this` looks up
  // `TickerMode` on an already-deactivated element and throws.
  late final AnimationController _reset;

  /// Critically damped spring for the settle-back — no overshoot, but seeded
  /// with the release velocity so it continues the finger's motion.
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 500,
  );

  /// Upward flick speed (px/s) that cancels a pull-to-dismiss even from past
  /// [SheetOverscrollDismiss.dismissThreshold] — a clear "put it back" gesture
  /// overrides raw position.
  static const double _cancelVelocity = 700;

  @override
  void initState() {
    super.initState();
    _reset = AnimationController.unbounded(vsync: this)
      ..addListener(_onResetTick);
  }

  @override
  void dispose() {
    _reset.dispose();
    _frozen.dispose();
    super.dispose();
  }

  void _onResetTick() {
    // A velocity-seeded spring can dip slightly below the rest position; clamp
    // so the sheet never lifts above its resting point.
    final value = _reset.value;
    setState(() => _offset = value < 0 ? 0 : value);
  }

  void _setOffset(double value) {
    final clamped = value < 0 ? 0.0 : value;
    if (clamped == _offset) return;
    setState(() => _offset = clamped);
  }

  void _onPointerDown(PointerDownEvent e) {
    _reset.stop();
    _velocity = VelocityTracker.withKind(e.kind);
    _velocity.addPosition(e.timeStamp, e.position);
    _lastPointerPosition = e.position;
  }

  void _onPointerMove(PointerMoveEvent e) {
    _velocity.addPosition(e.timeStamp, e.position);
    final last = _lastPointerPosition;
    _lastPointerPosition = e.position;

    // Freeze decision for THIS event is made up-front based on the offset
    // state at event arrival. Holding it steady means the descendant
    // scrollable (which reads _frozen.value when it later processes the same
    // event in the gesture arena) sees the same decision we did.
    _frozen.value = _offset > 0;

    if (_frozen.value && last != null) {
      _setOffset(_offset + (e.position.dy - last.dy));
    }
  }

  void _onPointerEnd() {
    _frozen.value = false;
    _lastPointerPosition = null;
    if (_offset <= 0) return;
    final velocityY = _velocity.getVelocity().pixelsPerSecond.dy;
    final threshold = _viewportHeight * widget.dismissThreshold;
    // A strong upward flick is an explicit cancel: honour it over position so a
    // fast "put it back" swipe never dismisses even from past the threshold —
    // velocity direction beats how far the sheet was pulled.
    final cancelFlick = velocityY < -_cancelVelocity;
    final dismiss =
        !cancelFlick &&
        (velocityY > widget.dismissVelocity || _offset > threshold);
    if (dismiss) {
      Navigator.of(context).maybePop();
    } else {
      _animateBack(velocityY);
    }
  }

  void _animateBack(double velocityY) {
    // Seed the spring with the release velocity already tracked for this
    // gesture, so the settle continues the finger's motion instead of tweening
    // over a fixed duration.
    _reset.animateWith(SpringSimulation(_spring, _offset, 0, velocityY));
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.metrics.pixels <= 0) {
      _viewportHeight = n.metrics.viewportDimension;
      _setOffset(_offset - n.overscroll);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context).copyWith(
      physics: _ClampTopBouncePhysics(frozen: _frozen),
      overscroll: false,
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _onPointerEnd(),
      onPointerCancel: (_) => _onPointerEnd(),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Transform.translate(
          offset: Offset(0, _offset),
          child: ScrollConfiguration(behavior: behavior, child: widget.child),
        ),
      ),
    );
  }
}

/// Clamps the top edge (mirrors [ClampingScrollPhysics]) so pull-down past
/// offset 0 is reported as an [OverscrollNotification], while leaving the
/// bottom edge alone so [BouncingScrollPhysics]' rubber-band + spring-back
/// remains at end-of-content.
///
/// When [frozen] is true the scrollable is pinned — user drag deltas produce
/// no scroll movement (the wrapper consumes them via pointer events to
/// retract the pulled sheet).
class _ClampTopBouncePhysics extends BouncingScrollPhysics {
  const _ClampTopBouncePhysics({this.frozen, super.parent});

  final ValueListenable<bool>? frozen;

  @override
  _ClampTopBouncePhysics applyTo(ScrollPhysics? ancestor) =>
      _ClampTopBouncePhysics(frozen: frozen, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (frozen?.value ?? false) return 0;
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value < position.pixels &&
        position.pixels <= position.minScrollExtent) {
      return value - position.pixels;
    }
    if (value < position.minScrollExtent &&
        position.minScrollExtent < position.pixels) {
      return value - position.minScrollExtent;
    }
    return 0;
  }
}
