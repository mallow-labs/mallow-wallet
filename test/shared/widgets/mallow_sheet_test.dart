import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

void main() {
  // A tap landing on a button mid-slide-in (e.g. a double-tap, or a tap
  // aimed at content behind the sheet) must not trigger the button — and
  // must not leak through the sheet to the barrier and dismiss it.
  group('showMallowSheet entrance tap guard', () {
    testWidgets('ignores taps while animating in, accepts them after', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showMallowSheet<void>(
                    context: context,
                    builder: (_) => TextButton(
                      onPressed: () => taps++,
                      child: const Text('Confirm'),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump();
      // Mid-entrance: half of MallowTheme.sheetDuration.
      await tester.pump(MallowTheme.sheetDuration ~/ 2);

      await tester.tap(find.text('Confirm'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(taps, 0, reason: 'tap during entrance must be swallowed');
      expect(
        find.text('Confirm'),
        findsOneWidget,
        reason: 'early tap must not fall through to the barrier and dismiss',
      );

      await tester.tap(find.text('Confirm'));
      expect(taps, 1, reason: 'tap after entrance must work');
    });
  });

  group('AnimatedSheetReveal entrance tap guard', () {
    testWidgets('ignores taps while animating in, accepts them after', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedSheetReveal(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('Confirm'),
              ),
            ),
          ),
        ),
      );

      await tester.pump(MallowTheme.sheetDuration ~/ 2);
      await tester.tap(find.text('Confirm'), warnIfMissed: false);
      expect(taps, 0, reason: 'tap during reveal must be swallowed');

      // The reveal has two gates: the slide animation AND the
      // sheetTapGuardMinimum window. Settle the animation, then pump past the
      // minimum so both gates open before the "should work" tap.
      await tester.pumpAndSettle();
      await tester.pump(MallowTheme.sheetTapGuardMinimum);
      await tester.tap(find.text('Confirm'));
      expect(taps, 1, reason: 'tap after reveal must work');
    });
  });
}
