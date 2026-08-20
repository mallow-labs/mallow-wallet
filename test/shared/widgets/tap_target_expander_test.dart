import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/tap_target_expander.dart';
import 'package:mallow_wallet/shared/widgets/tappable.dart';

void main() {
  group('TapTargetExpander', () {
    testWidgets('taps in the expanded margin reach the child, layout size is '
        'unchanged', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 16, height: 16),
              ),
            ),
          ),
        ),
      );

      // Layout must not shift: the expander reports the child's own size.
      expect(
        tester.getSize(find.byType(TapTargetExpander)),
        const Size(16, 16),
      );

      final center = tester.getCenter(find.byType(TapTargetExpander));

      // Inside the painted child.
      await tester.tapAt(center);
      expect(taps, 1);

      // 15px off-center: outside the 16px child, inside the 40px target.
      await tester.tapAt(center + const Offset(0, 15));
      expect(taps, 2);
      await tester.tapAt(center + const Offset(-15, 0));
      expect(taps, 3);

      // 25px off-center: outside the 40px target — must NOT fire, otherwise
      // expanded targets would swallow taps meant for distant siblings.
      await tester.tapAt(center + const Offset(0, 25));
      expect(taps, 3);
    });

    testWidgets('a tap on a sibling row\'s real pixels fires that row, not the '
        'expander whose slop overlaps it', (tester) async {
      // Two stacked ~18px interactive rows with zero gap — the exact shape
      // of the wallet-address / MallowKvList rows. Each row's 40px target
      // reaches (40-18)/2 = 11px into the row above, so without sibling
      // arbitration a tap on the lower half of the upper row is claimed by
      // the lower row's invisible slop.
      var upperTaps = 0;
      var lowerTaps = 0;
      Widget row(Key key, VoidCallback onTap) => TapTargetExpander(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(key: key, width: 200, height: 18),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row(const Key('upper'), () => upperTaps++),
                row(const Key('lower'), () => lowerTaps++),
                // Empty space below the pair, inside the Column, so the
                // lower row's downward slop lands on genuinely empty area.
                const SizedBox(width: 200, height: 30),
              ],
            ),
          ),
        ),
      );

      final upperRect = tester.getRect(find.byKey(const Key('upper')));
      final lowerRect = tester.getRect(find.byKey(const Key('lower')));

      // Tap the lower half of the UPPER row's painted pixels. This point is
      // inside the LOWER row's upward slop, and the Column tests the lower
      // row first (reverse paint order) — the fix must decline that slop and
      // let the tap reach the upper row's real pixels.
      await tester.tapAt(Offset(upperRect.center.dx, upperRect.bottom - 2));
      expect(upperTaps, 1);
      expect(lowerTaps, 0);

      // Tap the lower row's own painted pixels: direct hit, fires it.
      await tester.tapAt(lowerRect.center);
      expect(upperTaps, 1);
      expect(lowerTaps, 1);

      // Tap in the genuinely empty slop just below the lower row (within its
      // 40px target, no sibling pixels there): normal slop expansion still
      // fires the lower row.
      await tester.tapAt(Offset(lowerRect.center.dx, lowerRect.bottom + 6));
      expect(upperTaps, 1);
      expect(lowerTaps, 2);
    });

    testWidgets(
      'an Offstage expander (kept-alive hidden route) does not shadow '
      'slop taps on the visible screen',
      (tester) async {
        // Simulates a navigator route kept alive below the current screen:
        // its subtree stays ATTACHED with laid-out geometry, but it is not
        // hit-testable. Its expander overlaps the visible expander's screen
        // position — a slop tap near the visible expander must still expand
        // normally, not be declined because of the hidden layer.
        var visibleTaps = 0;
        var hiddenTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                Offstage(
                  child: Center(
                    child: TapTargetExpander(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => hiddenTaps++,
                        child: const SizedBox(width: 200, height: 200),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: TapTargetExpander(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => visibleTaps++,
                      child: const SizedBox(
                        key: Key('visible'),
                        width: 16,
                        height: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        // Slop tap: outside the visible 16px child, inside its 40px target,
        // and inside the hidden 200px expander's (stale) child geometry.
        final center = tester.getCenter(find.byKey(const Key('visible')));
        await tester.tapAt(center + const Offset(0, 15));
        expect(visibleTaps, 1);
        expect(hiddenTaps, 0);
      },
    );

    testWidgets('axes already >= minSize are not expanded', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 100, height: 16),
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(TapTargetExpander));

      // Horizontal: child is 100 wide, wider than minSize — no expansion.
      await tester.tapAt(center + const Offset(52, 0));
      expect(taps, 0);

      // Vertical: expanded to 40.
      await tester.tapAt(center + const Offset(0, 15));
      expect(taps, 1);
    });
  });

  group('Tappable minHitSize', () {
    testWidgets('small Tappable children get a 40px hit target by default', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Tappable(
              onTap: () => taps++,
              child: const SizedBox(width: 20, height: 20),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(Tappable));
      await tester.tapAt(center + const Offset(14, 14));
      expect(taps, 1);
    });

    testWidgets('minHitSize: null disables expansion', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Tappable(
              onTap: () => taps++,
              minHitSize: null,
              child: const SizedBox(width: 20, height: 20),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(Tappable));
      await tester.tapAt(center + const Offset(14, 14));
      expect(taps, 0);
      await tester.tapAt(center);
      expect(taps, 1);
    });
  });
}
