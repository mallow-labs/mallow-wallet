import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/mallow_scroll_behavior.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

/// Every sheet opened through [showMallowSheet] can be pulled down from
/// anywhere in it — including its scrollables, but only once they are at the
/// top.
void main() {
  Future<void> openSheet(
    WidgetTester tester, {
    required int itemCount,
    bool canPop = true,
    bool enableDrag = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // The app-wide behavior: bouncing physics everywhere, so even a list
        // whose rows fit claims vertical drags from the route.
        scrollBehavior: const MallowScrollBehavior(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMallowSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  enableDrag: enableDrag,
                  builder: (_) => PopScope(
                    canPop: canPop,
                    child: Material(
                      child: SizedBox(
                        height: 400,
                        child: ListView.builder(
                          itemCount: itemCount,
                          itemBuilder: (_, i) =>
                              SizedBox(height: 50, child: Text('row $i')),
                        ),
                      ),
                    ),
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
    await tester.pumpAndSettle();
  }

  double listPixels(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  testWidgets('dragging down on a list that fits dismisses the sheet', (
    tester,
  ) async {
    await openSheet(tester, itemCount: 3);

    await tester.drag(find.text('row 1'), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.text('row 1'), findsNothing);
  });

  testWidgets('a short pull springs back instead of dismissing', (
    tester,
  ) async {
    await openSheet(tester, itemCount: 3);
    final restingTop = tester.getTopLeft(find.text('row 0')).dy;

    // Slow enough to stay under the velocity threshold, short of half height.
    await tester.timedDrag(
      find.text('row 1'),
      const Offset(0, 80),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();

    expect(find.text('row 1'), findsOneWidget);
    expect(tester.getTopLeft(find.text('row 0')).dy, closeTo(restingTop, 0.5));
  });

  testWidgets(
    'a scrolled list scrolls back to its top before the sheet moves',
    (tester) async {
      await openSheet(tester, itemCount: 40);
      final restingTop = tester.getTopLeft(find.byType(ListView)).dy;

      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(500);
      await tester.pump();

      // A slow drag shorter than the scroll offset only scrolls the content.
      await tester.timedDrag(
        find.byType(ListView),
        const Offset(0, 200),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();

      // The content scrolled (momentum may carry it past the drag distance,
      // never past the top) and the sheet stayed put.
      expect(find.byType(ListView), findsOneWidget);
      expect(listPixels(tester), inExclusiveRange(0, 500));
      expect(
        tester.getTopLeft(find.byType(ListView)).dy,
        closeTo(restingTop, 0.5),
      );

      // Back at the top, the same drag direction now pulls the sheet away.
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsNothing);
    },
  );

  testWidgets('a fling that coasts into the top does not move the sheet', (
    tester,
  ) async {
    await openSheet(tester, itemCount: 40);
    final restingTop = tester.getTopLeft(find.byType(ListView)).dy;

    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(200);
    await tester.pump();
    await tester.fling(find.byType(ListView), const Offset(0, 100), 3000);
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(listPixels(tester), 0);
    expect(
      tester.getTopLeft(find.byType(ListView)).dy,
      closeTo(restingTop, 0.5),
    );
  });

  testWidgets('a vetoed pop settles the sheet back into place', (tester) async {
    await openSheet(tester, itemCount: 3, canPop: false);
    final restingTop = tester.getTopLeft(find.byType(ListView)).dy;

    await tester.drag(find.text('row 1'), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(ListView)).dy,
      closeTo(restingTop, 0.5),
    );
  });

  testWidgets('a sheet opened with enableDrag: false cannot be pulled away', (
    tester,
  ) async {
    await openSheet(tester, itemCount: 3, enableDrag: false);

    await tester.drag(find.text('row 1'), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.text('row 1'), findsOneWidget);
  });
}
