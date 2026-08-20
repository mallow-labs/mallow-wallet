import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/onboarding/widgets/carousel_focus.dart';

/// The welcome-screen ring shows 9 cards; every invariant here must hold for
/// any count, so a second count is exercised where cheap.
const _total = 9;
const _segment = 2 * math.pi / _total;

/// Rotation that puts card [index] dead-center in front of the camera.
double _rotationForFront(int index) =>
    CarouselFocus.frontAngle - index * _segment;

/// Everything the caption strip reads from the ring, exactly as the carousel
/// derives it on each rendered frame.
({int frontIndex, double opacity}) _captionState(double rotationY) => (
  frontIndex: CarouselFocus.frontIndex(_total, rotationY),
  opacity: CarouselFocus.captionOpacity(_total, rotationY),
);

/// Feeds [rotations] through a value-comparing listenable the way the carousel
/// feeds it frames, and reports how many rebuilds the caption would take.
int _captionRebuilds(Iterable<double> rotations) {
  final notifier = ValueNotifier(_captionState(rotations.first));
  var rebuilds = 0;
  notifier.addListener(() => rebuilds++);
  for (final rotation in rotations) {
    notifier.value = _captionState(rotation);
  }
  notifier.dispose();
  return rebuilds;
}

void main() {
  group('frontIndex', () {
    test('reports the card whose ring angle is at the camera', () {
      for (var k = 0; k < _total; k++) {
        expect(CarouselFocus.frontIndex(_total, _rotationForFront(k)), k);
      }
    });

    test('is wrap-safe across many full turns in both directions', () {
      // The ring rotates forever in auto-spin; the index must not drift or go
      // negative after any number of turns.
      for (var k = 0; k < _total; k++) {
        final base = _rotationForFront(k);
        for (final turns in [-3, -1, 1, 7]) {
          final rotated = base + turns * 2 * math.pi;
          expect(CarouselFocus.frontIndex(_total, rotated), k);
        }
      }
    });
  });

  group('focusStrength', () {
    test('peaks at exactly 1.0 when the card is dead-center front', () {
      expect(
        CarouselFocus.focusStrength(4, _total, _rotationForFront(4)),
        closeTo(1, 1e-9),
      );
    });

    test('holds full focus on a wide plateau around dead center', () {
      // The ramp completes while the card is still well off-center, so
      // "active" reads as a stable settled state and the rest→active
      // transition is quick instead of a drift that peaks for an instant.
      for (final fraction in [0.25, 0.5]) {
        final nearCenter = _rotationForFront(4) + fraction * (math.pi / _total);
        expect(
          CarouselFocus.focusStrength(4, _total, nearCenter),
          closeTo(1, 1e-9),
        );
      }
    });

    test('starts rising as soon as the card crosses the boundary', () {
      // "Start earlier": the pose change begins immediately on entering the
      // front segment, not after a long dead zone.
      final justInside = _rotationForFront(4) + 0.95 * (math.pi / _total);
      expect(
        CarouselFocus.focusStrength(4, _total, justInside),
        greaterThan(0),
      );
    });

    test('is exactly 0 at the segment boundary', () {
      // Both neighbours evaluate to 0 at the shared boundary, so the handoff
      // is continuous and two cards are never lifted at once.
      final atBoundary = _rotationForFront(4) + math.pi / _total;
      expect(
        CarouselFocus.focusStrength(4, _total, atBoundary),
        closeTo(0, 1e-9),
      );
    });

    test('springs a little past the settled pose, within bounds', () {
      // The easeOutBack ramp must overshoot 1 (that is the spring feel) but
      // only slightly — a wild overshoot would read as a glitch, not a
      // settle. The same bound protects the outward pass, which retraces
      // this curve.
      var peak = 0.0;
      for (var step = 0; step <= 100; step++) {
        final rotation = _rotationForFront(4) + step * (math.pi / _total) / 100;
        final strength = CarouselFocus.focusStrength(4, _total, rotation);
        if (strength > peak) peak = strength;
      }
      expect(peak, greaterThan(1));
      expect(peak, lessThan(1.15));
    });

    test('is 0 for a degenerate empty ring', () {
      expect(CarouselFocus.focusStrength(0, 0, 1.23), 0);
    });
  });

  group('captionOpacity', () {
    test('holds full opacity while the front card is near center', () {
      // Inside the fade-start zone the caption must be fully readable, not
      // permanently translucent.
      final nearCenter = _rotationForFront(2) + 0.3 * (math.pi / _total);
      expect(CarouselFocus.captionOpacity(_total, nearCenter), 1);
    });

    test('is invisible at the instant the front card changes', () {
      // The caption text swaps when frontIndex flips at the segment boundary.
      // Opacity must be ~0 on both sides of that flip, or the swap would be
      // visible as a hard text change mid-fade.
      final boundary = _rotationForFront(2) - _segment / 2;
      const epsilon = 1e-4;
      final before = CarouselFocus.frontIndex(_total, boundary + epsilon);
      final after = CarouselFocus.frontIndex(_total, boundary - epsilon);
      expect(before, isNot(after));
      expect(
        CarouselFocus.captionOpacity(_total, boundary + epsilon),
        closeTo(0, 1e-3),
      );
      expect(
        CarouselFocus.captionOpacity(_total, boundary - epsilon),
        closeTo(0, 1e-3),
      );
    });

    test('fades out monotonically from center to boundary', () {
      var previous = double.infinity;
      for (var step = 0; step <= 10; step++) {
        final rotation = _rotationForFront(2) + step * (_segment / 2) / 10;
        final opacity = CarouselFocus.captionOpacity(_total, rotation);
        expect(opacity, lessThanOrEqualTo(previous));
        previous = opacity;
      }
    });

    test('is 0 for a degenerate empty ring', () {
      expect(CarouselFocus.captionOpacity(0, 1.23), 0);
    });
  });

  group('caption rebuilds', () {
    // The GL loop advances the rotation 60–120 times a second, but the caption
    // strip reads only (frontIndex, captionOpacity). Driving it off that pair
    // instead of the raw rotation is what keeps the text and its font lookups
    // off the frame budget, so the pair must genuinely hold still — and must
    // still move where the eye can see it.
    test('none while a card holds the front at full opacity', () {
      final rotations = List.generate(
        60,
        // Sweep the whole plateau where the caption sits at opacity 1 — the
        // stretch of every segment the auto-spin spends longest in.
        (step) =>
            _rotationForFront(2) + (step / 59 - 0.5) * 0.68 * (_segment / 2),
      );
      expect(_captionRebuilds(rotations), 0);
    });

    test('one per frame through the fade and across the handoff', () {
      // From the plateau edge out past the segment boundary: the cross-fade
      // must stay frame-accurate, and the front card must still change hands.
      final start = _rotationForFront(2) + 0.36 * (_segment / 2);
      final end = _rotationForFront(2) + 1.1 * (_segment / 2);
      final rotations = List.generate(
        30,
        (step) => start + (end - start) * step / 29,
      );
      expect(_captionRebuilds(rotations), 29);
      expect(
        _captionState(rotations.last).frontIndex,
        isNot(_captionState(rotations.first).frontIndex),
      );
    });
  });
}
