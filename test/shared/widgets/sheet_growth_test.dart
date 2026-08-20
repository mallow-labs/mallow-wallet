import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/generic_confirmation_sheet.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

// Content that appears late in a confirmation sheet — the "Transaction may
// fail" simulation warning above all — is exactly the content a user must not
// have to hunt for. A sheet that keeps its height and scrolls the warning
// under the fold is how a failing transaction gets confirmed by accident, so
// these tests pin the rule: dynamic content grows the sheet, and scrolling is
// the last resort once the sheet has filled the screen.
void main() {
  const failed = SimulationResult(success: false, error: 'insufficient funds');

  /// Opens a confirmation sheet whose body is [bodyHeight] tall. Flipping the
  /// returned notifier adds the simulation warning to the live sheet, the way
  /// a late simulation result does.
  Future<ValueNotifier<bool>> pumpSheet(
    WidgetTester tester, {
    bool warning = false,
    double bodyHeight = 100,
  }) async {
    final warn = ValueNotifier(warning);
    addTearDown(warn.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showMallowSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: warn,
                    builder: (context, warning, _) => GenericConfirmationSheet(
                      title: 'Confirm send',
                      confirmLabel: 'Send',
                      onConfirm: () {},
                      body: [SizedBox(height: bodyHeight)],
                      simulation: SimulationBannerState(
                        isSimulating: false,
                        result: warning ? failed : null,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return warn;
  }

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(GenericConfirmationSheet)).height;

  double maxScrollExtent(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).last)
      .position
      .maxScrollExtent;

  testWidgets('a simulation warning grows the sheet instead of scrolling it', (
    tester,
  ) async {
    final warn = await pumpSheet(tester);
    final quiet = sheetHeight(tester);
    expect(maxScrollExtent(tester), 0, reason: 'nothing to scroll yet');

    warn.value = true;
    await tester.pumpAndSettle();

    expect(
      sheetHeight(tester),
      greaterThan(quiet),
      reason: 'the warning must make the sheet taller',
    );
    expect(
      maxScrollExtent(tester),
      0,
      reason: 'a sheet with room to grow must not scroll the warning away',
    );
    expect(find.text('Transaction may fail'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('growth stops at the full-screen sheet height, then scrolls', (
    tester,
  ) async {
    // Body taller than the screen: growth is capped and the body scrolls.
    await pumpSheet(tester, warning: true, bodyHeight: 2000);

    final context = tester.element(find.byType(GenericConfirmationSheet));
    expect(
      sheetHeight(tester),
      moreOrLessEquals(maxSheetHeight(context), epsilon: 0.5),
      reason: 'a sheet may grow to — and no further than — full screen',
    );
    expect(
      maxScrollExtent(tester),
      greaterThan(0),
      reason: 'past the cap the body scrolls rather than overflowing',
    );
    // The CTA row stays pinned below the scrolling body, on screen.
    expect(
      tester.getRect(find.text('Send')).bottom,
      lessThanOrEqualTo(tester.getSize(find.byType(MaterialApp)).height),
    );
  });
}
