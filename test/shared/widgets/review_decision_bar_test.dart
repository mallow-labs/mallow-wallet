import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';

const _approve = Key('approve');
const _reject = Key('reject');

void main() {
  late int approvals;
  late int rejections;

  setUp(() {
    approvals = 0;
    rejections = 0;
  });

  Widget bar() => ReviewDecisionBar(
    rejectKey: _reject,
    approveKey: _approve,
    onReject: () => rejections++,
    onApprove: () => approvals++,
  );

  /// Opens the bar in a modal bottom sheet, the way the review sheets are
  /// shown, and pumps one frame: the sheet is on screen and still rising.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) =>
                      Padding(padding: const EdgeInsets.all(16), child: bar()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  testWidgets('a tap while the sheet is still animating in is ignored', (
    tester,
  ) async {
    await openSheet(tester);
    final route = ModalRoute.of(tester.element(find.byKey(_approve)))!;
    expect(route.animation!.isCompleted, isFalse);

    await tester.tap(find.byKey(_approve), warnIfMissed: false);
    await tester.pump();
    expect(approvals, 0);

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 1);
  });

  testWidgets('the delay runs from when the sheet settles, not from open', (
    tester,
  ) async {
    await openSheet(tester);
    final route = ModalRoute.of(tester.element(find.byKey(_approve)))!;
    // Let the entrance finish, without settling the arming delay.
    while (!route.animation!.isCompleted) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.pump(
      ReviewDecisionBar.armDelay - const Duration(milliseconds: 100),
    );
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 0, reason: 'settled, but inside the arming delay');

    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 1);
  });

  testWidgets('a press that began before arming does not approve', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_approve)),
    );
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pump();
    expect(approvals, 0);

    // The next, fresh press works.
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 1);
  });

  testWidgets('reject responds at once', (tester) async {
    await openSheet(tester);
    // Up far enough to hit, and still well inside the arming window.
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      ModalRoute.of(
        tester.element(find.byKey(_reject)),
      )!.animation!.isCompleted,
      isFalse,
    );
    await tester.tap(find.byKey(_reject));
    await tester.pump();
    expect(rejections, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('outside an animated route, the delay runs from first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(body: Center(child: bar())),
      ),
    );
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 0);

    // The first pump starts the clock, the second runs the whole delay, and
    // the frame after it completes the controller.
    await tester.pump();
    await tester.pump(ReviewDecisionBar.armDelay);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byKey(_approve));
    await tester.pump();
    expect(approvals, 1);
  });
}
