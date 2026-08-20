import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';
import 'package:mallow_wallet/shared/widgets/sheet_menu_row.dart';

Future<void> _pumpRow(
  WidgetTester tester, {
  String? subtitle,
  bool enabled = true,
  bool isWarning = false,
  bool isDestructive = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SheetMenuRow(
          label: 'Transfer artwork',
          subtitle: subtitle,
          enabled: enabled,
          isWarning: isWarning,
          isDestructive: isDestructive,
          onTap: () {},
        ),
      ),
    ),
  );
}

Color _labelColor(WidgetTester tester) =>
    tester.widget<Text>(find.text('Transfer artwork')).style!.color!;

void main() {
  testWidgets('a killed row explains itself instead of just greying out', (
    tester,
  ) async {
    // The kill-switch's inline surface. A disabled row with no explanation is
    // the "silently grey out" behaviour the server message field exists to
    // avoid — the subtitle is where the operator's copy lands.
    const message = 'Transfers are paused while we fix an indexer bug.';
    await _pumpRow(tester, subtitle: message, enabled: false);

    expect(find.text('Transfer artwork'), findsOneWidget);
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('the default single-line layout is unchanged', (tester) async {
    await _pumpRow(tester);

    expect(find.text('Transfer artwork'), findsOneWidget);
    // No subtitle means no second line and no Expanded wrapper — the layout
    // every existing caller renders today.
    expect(find.byType(Expanded), findsNothing);
  });

  testWidgets('a warning row reads as cautionary, not destructive', (
    tester,
  ) async {
    // Report … is a moderation action on someone else's content: it warns, it
    // does not destroy anything of the viewer's. Sharing the error red with
    // Burn / Delete / Block would tell the wrong story about what a tap does.
    await _pumpRow(tester, isWarning: true);
    expect(_labelColor(tester), MallowColors.light.warning);

    await _pumpRow(tester, isDestructive: true, isWarning: true);
    expect(_labelColor(tester), MallowColors.light.error);
  });
}
