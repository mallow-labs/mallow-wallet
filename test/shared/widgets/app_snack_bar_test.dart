import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';

/// `AppSnackBar` is the app's single transient-message surface, and it promises
/// that only one is visible at a time — several call sites fire in bursts (a
/// failed refresh that also reports a stale session, a signer switch that then
/// fails), so a second message must replace the first rather than stack on it.
void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    required void Function(BuildContext) onReady,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => onReady(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  tearDown(AppSnackBar.dismiss);

  testWidgets('shows the message', (tester) async {
    await pumpHost(
      tester,
      onReady: (context) => AppSnackBar.show(context, 'Offer cancelled'),
    );

    expect(find.text('Offer cancelled'), findsOneWidget);
  });

  testWidgets('two messages in one frame leave a single snack bar', (
    tester,
  ) async {
    // The "currently showing" handle used to be assigned in a post-frame
    // callback while `dismiss()` ran synchronously, so a second `show` in the
    // same frame saw nothing to dismiss and stacked its snack bar on top of the
    // first — two overlapping cards, one of them unreachable.
    await pumpHost(
      tester,
      onReady: (context) {
        AppSnackBar.show(context, 'First');
        AppSnackBar.show(context, 'Second');
      },
    );

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('a later message replaces the one on screen', (tester) async {
    await pumpHost(
      tester,
      onReady: (context) => AppSnackBar.show(context, 'First'),
    );
    expect(find.text('First'), findsOneWidget);

    await pumpHost(
      tester,
      onReady: (context) => AppSnackBar.show(context, 'Second'),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });
}
