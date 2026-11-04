import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_bottom_overlay.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';

void main() {
  final start = DateTime(2026, 10, 3, 12);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  test('starts above the bar and moves under it after two safe probes', () {
    final policy = BrowserBottomOverlay();
    expect(policy.overlay, isFalse);
    expect(policy.report(true, now: at(0)), isFalse);
    expect(policy.overlay, isFalse);
    expect(policy.report(true, now: at(1)), isTrue);
    expect(policy.overlay, isTrue);
    expect(policy.report(true, now: at(2)), isFalse);
  });

  test('an unsafe probe in between restarts the count', () {
    final policy = BrowserBottomOverlay();
    policy.report(true, now: at(0));
    policy.report(false, now: at(1));
    expect(policy.report(true, now: at(2)), isFalse);
    expect(policy.overlay, isFalse);
    expect(policy.report(true, now: at(3)), isTrue);
  });

  test('one unsafe probe returns the page above the bar at once', () {
    final policy = BrowserBottomOverlay()
      ..report(true, now: at(0))
      ..report(true, now: at(1));
    expect(policy.report(false, now: at(2)), isTrue);
    expect(policy.overlay, isFalse);
    expect(policy.report(false, now: at(3)), isFalse);
  });

  test('a page that keeps flipping stays above the bar', () {
    final policy = BrowserBottomOverlay();
    for (var round = 0; round < 3; round++) {
      policy
        ..report(true, now: at(round * 3))
        ..report(true, now: at(round * 3 + 1));
      expect(policy.overlay, isTrue, reason: 'round $round');
      policy.report(false, now: at(round * 3 + 2));
    }
    expect(policy.report(true, now: at(9)), isFalse);
    expect(policy.report(true, now: at(10)), isFalse);
    expect(policy.overlay, isFalse);
  });

  test('exits spread out over time do not pin the page', () {
    final policy = BrowserBottomOverlay();
    for (var round = 0; round < 3; round++) {
      policy
        ..report(true, now: at(round * 20))
        ..report(true, now: at(round * 20 + 1))
        ..report(false, now: at(round * 20 + 2));
    }
    policy
      ..report(true, now: at(70))
      ..report(true, now: at(71));
    expect(policy.overlay, isTrue);
  });

  test('a new document keeps the mode but clears the pin and the count', () {
    final policy = BrowserBottomOverlay();
    for (var round = 0; round < 3; round++) {
      policy
        ..report(true, now: at(round * 3))
        ..report(true, now: at(round * 3 + 1))
        ..report(false, now: at(round * 3 + 2));
    }
    policy.report(true, now: at(9));
    policy.newDocument();
    expect(policy.report(true, now: at(10)), isFalse);
    expect(policy.report(true, now: at(11)), isTrue);
    policy.newDocument();
    expect(policy.overlay, isTrue);
  });

  test('reads the probe verdict, or null where it did not probe', () {
    expect(browserProbeOverlay({'overlay': true}), isTrue);
    expect(browserProbeOverlay({'overlay': false}), isFalse);
    expect(browserProbeOverlay('{"overlay":true}'), isTrue);
    expect(browserProbeOverlay({'overlay': null}), isNull);
    expect(browserProbeOverlay({'overlay': 'true'}), isNull);
    expect(browserProbeOverlay(null), isNull);
    expect(browserProbeOverlay('{not json'), isNull);
  });
}
