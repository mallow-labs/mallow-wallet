import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/widgets/start_bookmark_grid.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

void main() {
  final bookmarks = [
    for (var i = 0; i < 24; i++)
      BrowserBookmark(
        url: Uri.parse('https://saved.example/$i'),
        title: 'Page $i',
      ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required void Function(Uri, Uri) onMove,
    ScrollController? controller,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 260,
            child: SingleChildScrollView(
              controller: controller,
              child: StartBookmarkGrid(
                bookmarks: bookmarks,
                reordering: true,
                onOpen: (_) => fail('Reordering must not open a bookmark'),
                onMore: (_) => fail('Reordering must not open its menu'),
                onMove: onMove,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'dragging near the viewport edge scrolls to offscreen bookmarks',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pump(tester, controller: controller, onMove: (_, _) {});
      await tester.pumpAndSettle();
      final first = find.byKey(ValueKey(bookmarks.first.url));
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final gesture = await tester.startGesture(tester.getCenter(first));
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 5));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(controller.offset, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      final stopped = controller.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offset, stopped);
    },
  );

  testWidgets('screen readers can move bookmarks earlier and later', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final moves = <(Uri, Uri)>[];
    await pump(tester, onMove: (url, target) => moves.add((url, target)));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(
      find.bySemanticsLabel('Page 1, position 2 of 24'),
    );
    final actions = node.getSemanticsData().customSemanticsActionIds!;
    expect(actions, hasLength(2));
    for (final id in actions) {
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
    }
    expect(
      moves,
      containsAll([
        (bookmarks[1].url, bookmarks[0].url),
        (bookmarks[1].url, bookmarks[2].url),
      ]),
    );
    handle.dispose();
  });
}
