import 'dart:math' as math;

import 'package:flutter/animation.dart';

/// Pure rotation→presentation math for `PerspectiveCarousel3D`.
///
/// Every value here is a function of the ring's current rotation only — no
/// timers, no animation controllers. That is what keeps the focus lift/scale
/// and the caption fade moving at exactly the speed of the spin, whether the
/// ring is auto-rotating or being dragged by a finger.
class CarouselFocus {
  const CarouselFocus._();

  /// Ring angle at which a card is closest to the camera. Cards sit at
  /// `(cos a · r, sin a · r)` in the XZ plane and the camera looks down +Z,
  /// so the front is where `sin` peaks.
  static const double frontAngle = math.pi / 2;

  /// Fraction of the half-segment over which the caption holds full opacity
  /// before it starts easing out toward the handoff boundary.
  static const double _captionFadeStart = 0.35;

  /// Fractions of the half-segment bounding the focus ramp: fully focused
  /// within [_focusFullZone], fully at rest beyond [_focusRestZone]. The
  /// rest↔focused transition runs only between the two — the ramp starts the
  /// moment a card crosses the segment boundary (1.0) and completes while it
  /// is still well off-center, so the pose change is early and quick.
  static const double _focusFullZone = 0.65;
  static const double _focusRestZone = 1.0;

  /// Current ring angle of card [index] out of [total].
  static double cardAngle(int index, int total, double rotationY) =>
      (index / total) * 2 * math.pi + rotationY;

  /// Signed shortest angular distance from [angle] to the front position,
  /// wrap-safe, in (-π, π].
  static double deltaFromFront(double angle) {
    final a = angle - frontAngle;
    return math.atan2(math.sin(a), math.cos(a));
  }

  /// How focused card [index] is: 0 at the segment boundary, ramping through
  /// [Curves.easeOutBack] to a held 1 within [_focusFullZone] of center. The
  /// back-curve overshoots slightly past 1 before settling, so the pose
  /// change reads as a quick spring — in both directions, since leaving
  /// center retraces the same angle-driven curve. Callers must tolerate
  /// values a little above 1.
  static double focusStrength(int index, int total, double rotationY) {
    if (total <= 0) return 0;
    final halfSegment = math.pi / total;
    final d = deltaFromFront(cardAngle(index, total, rotationY)).abs();
    final n = d / halfSegment;
    final linear = ((_focusRestZone - n) / (_focusRestZone - _focusFullZone))
        .clamp(0.0, 1.0);
    return Curves.easeOutBack.transform(linear);
  }

  /// Index of the card currently closest to the camera.
  static int frontIndex(int total, double rotationY) {
    final segment = 2 * math.pi / total;
    return ((frontAngle - rotationY) / segment).round() % total;
  }

  /// Caption opacity for the current front card: full while the card is near
  /// center, easing to exactly 0 at the segment boundary — the same instant
  /// [frontIndex] changes, so the text swap is never visible.
  static double captionOpacity(int total, double rotationY) {
    if (total <= 0) return 0;
    final halfSegment = math.pi / total;
    final index = frontIndex(total, rotationY);
    final d = deltaFromFront(cardAngle(index, total, rotationY)).abs();
    final n = (d / halfSegment).clamp(0.0, 1.0);
    final t = ((n - _captionFadeStart) / (1 - _captionFadeStart)).clamp(
      0.0,
      1.0,
    );
    return 1 - Curves.easeInOut.transform(t);
  }
}
