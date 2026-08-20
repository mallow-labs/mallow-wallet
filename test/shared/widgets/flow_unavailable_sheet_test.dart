import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart'
    show kFlowDisabledFallbackMessage;
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/flow_unavailable_sheet.dart';

Future<void> _openSheet(WidgetTester tester, String message) async {
  await tester.pumpWidget(
    MaterialApp(
      // The real app always runs under MallowTheme, and the theme changes the
      // sheet's entrance timing — testing under the bare default theme would
      // exercise a configuration that never ships.
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showFlowUnavailableSheet(context, message),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  // `showMallowSheet` arms `_sheetSettleBuffer` (mallow_sheet.dart:79), a 100ms
  // barrier that swallows taps landing right as a sheet settles — app-wide
  // accidental-double-tap protection. It is a bare `Timer`, so it schedules no
  // frames and `pumpAndSettle` returns with the barrier still up; a tap here
  // would be silently eaten and the sheet would look unresponsive. Pump past it.
  await tester.pump(_entranceGuard);
}

/// Comfortably past `_sheetSettleBuffer`.
const _entranceGuard = Duration(milliseconds: 250);

void main() {
  testWidgets('renders the server message verbatim', (tester) async {
    // The operator's copy is the only thing that can tell a user mid-incident
    // whether their funds are safe. Any client-side rewording — truncation,
    // a prepended "Sorry,", a per-flow substitute — defeats the reason the
    // payload carries a message field at all.
    const message =
        'Ethereum sends are paused while we fix a fee-estimation bug. '
        'Your funds are safe.';

    await _openSheet(tester, message);

    expect(find.text(message), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('falls back to the generic copy for an empty message', (
    tester,
  ) async {
    // A blank message must still explain something — but with exactly one
    // bland fallback, not per-flow copy that would drift from the backend.
    await _openSheet(tester, '   ');

    expect(find.text(kFlowDisabledFallbackMessage), findsOneWidget);
  });

  testWidgets('OK dismisses the sheet', (tester) async {
    await _openSheet(tester, 'Paused.');

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Paused.'), findsNothing);
  });
}
