import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/widgets/mallow_scroll_behavior.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

/// Amount fields across the app ask for a decimal numpad, and on iOS that
/// keypad has no return key — there is no keyboard-side way out of it. These
/// two behaviours are what replaces it, and both are platform-standard rather
/// than a bar we draw: drag the scrollable ([MallowScrollBehavior]), or tap a
/// bare patch of the sheet ([showMallowSheet]).
void main() {
  FocusNode newField() {
    final node = FocusNode();
    addTearDown(node.dispose);
    return node;
  }

  group('MallowScrollBehavior', () {
    testWidgets('dragging a scrollable dismisses the keyboard', (tester) async {
      final field = newField();
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const MallowScrollBehavior(),
          home: Scaffold(
            body: ListView(
              children: [
                TextField(focusNode: field),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(field.hasFocus, isTrue);

      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(field.hasFocus, isFalse);
    });
  });

  group('showMallowSheet', () {
    testWidgets('tapping bare sheet space dismisses the keyboard', (
      tester,
    ) async {
      final field = newField();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showMallowSheet<void>(
                    context: context,
                    builder: (_) => ColoredBox(
                      color: const Color(0xFFFFFFFF),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(focusNode: field),
                          // The bare patch — no interactive child claims it.
                          const SizedBox(height: 120, child: Text('body')),
                        ],
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

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(field.hasFocus, isTrue);

      await tester.tap(find.text('body'));
      await tester.pumpAndSettle();

      expect(field.hasFocus, isFalse);
      // The tap must dismiss the keyboard only — a sheet that closed instead
      // would take the half-typed amount with it.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('a tap on sheet content still reaches its own handler', (
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pump();

      expect(taps, 1);
    });
  });
}
