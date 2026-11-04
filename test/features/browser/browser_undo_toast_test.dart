import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_undo_toast.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

void main() {
  Future<BuildContext> pump(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold();
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('Undo runs once and the pill leaves', (tester) async {
    final context = await pump(tester);
    var undone = 0;
    BrowserUndoToast.show(context, 'Tab closed', onUndo: () => undone++);
    await tester.pumpAndSettle();
    expect(find.text('Tab closed'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, 1);
    expect(find.text('Tab closed'), findsNothing);
  });

  testWidgets('sits above the bottom bars and times out', (tester) async {
    final context = await pump(tester);
    BrowserUndoToast.show(context, 'Bookmark removed', onUndo: () {});
    await tester.pumpAndSettle();
    final screen = tester.getSize(find.byType(Scaffold));
    final pill = tester.getRect(find.text('Bookmark removed'));
    // Clear of a 48 dp bar above a 20 dp margin.
    expect(screen.height - pill.bottom, greaterThan(68));

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Bookmark removed'), findsNothing);
  });

  testWidgets('a new message replaces the one showing', (tester) async {
    final context = await pump(tester);
    var first = 0;
    BrowserUndoToast.show(context, 'Tab closed', onUndo: () => first++);
    await tester.pumpAndSettle();
    BrowserUndoToast.show(context, 'Bookmark removed', onUndo: () {});
    await tester.pumpAndSettle();
    expect(find.text('Tab closed'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(first, 0);
  });
}
