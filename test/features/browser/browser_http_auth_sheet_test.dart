import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_http_auth_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';

void main() {
  /// Opens the sheet the way the WebView host does. The list collects what
  /// it pops, so a missed tap fails the test instead of hanging it.
  Future<List<BrowserHttpCredentials?>> open(
    WidgetTester tester,
    BrowserHttpAuthSheet sheet,
  ) async {
    final popped = <BrowserHttpCredentials?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context)
                  .push(
                    mallowSheetRoute<BrowserHttpCredentials>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => sheet,
                    ),
                  )
                  .then(popped.add),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('signing in returns the entered credentials', (tester) async {
    final result = await open(
      tester,
      const BrowserHttpAuthSheet(host: 'staging.example.com'),
    );
    expect(
      find.text('staging.example.com requires a username and password.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('http-auth-failed')), findsNothing);
    expect(find.textContaining('a different site'), findsNothing);

    await tester.enterText(find.byKey(const Key('http-auth-username')), 'ana');
    await tester.enterText(
      find.byKey(const Key('http-auth-password')),
      'p4ss word',
    );
    final password = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('http-auth-password')),
        matching: find.byType(TextField),
      ),
    );
    expect(password.obscureText, isTrue);

    await tester.ensureVisible(find.byKey(const Key('http-auth-sign-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('http-auth-sign-in')));
    await tester.pumpAndSettle();
    expect(result, [(username: 'ana', password: 'p4ss word')]);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    final result = await open(
      tester,
      const BrowserHttpAuthSheet(host: 'staging.example.com'),
    );
    await tester.enterText(find.byKey(const Key('http-auth-username')), 'ana');
    await tester.ensureVisible(find.byKey(const Key('http-auth-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('http-auth-cancel')));
    await tester.pumpAndSettle();
    expect(result, [null]);
  });

  testWidgets('a retry says why and keeps the username', (tester) async {
    final result = await open(
      tester,
      const BrowserHttpAuthSheet(
        host: 'api.other.dev',
        pageHost: 'app.example.com',
        failed: true,
        username: 'ana',
      ),
    );
    expect(find.byKey(const Key('http-auth-failed')), findsOneWidget);
    expect(
      find.text('It was asked for by app.example.com, a different site.'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const Key('http-auth-password')), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, [(username: 'ana', password: 'x')]);
  });
}
