import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/in_app_push_banner.dart';

/// The banner is the only thing Android users see for a push that arrives while
/// the app is open (iOS re-presents the system banner itself). Two properties
/// matter and are what these tests pin down:
///  • the notification's text is actually shown, and
///  • tapping it hands control back to the caller so the tap routes exactly
///    like a tapped system notification would.
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

  tearDown(InAppPushBanner.dismiss);

  testWidgets('shows the notification title and body', (tester) async {
    await pumpHost(
      tester,
      onReady: (context) => InAppPushBanner.show(
        context,
        title: 'Offer received',
        body: '1.5 SOL on Untitled #4',
        onTap: () {},
      ),
    );

    expect(find.text('Offer received'), findsOneWidget);
    expect(find.text('1.5 SOL on Untitled #4'), findsOneWidget);
  });

  testWidgets('tapping fires onTap and dismisses the banner', (tester) async {
    var taps = 0;
    await pumpHost(
      tester,
      onReady: (context) => InAppPushBanner.show(
        context,
        title: 'Offer received',
        onTap: () => taps++,
      ),
    );

    await tester.tap(find.text('Offer received'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(taps, 1);
    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('shows from the root navigator context — the production path', (
    tester,
  ) async {
    // The only production caller is `PushNotificationService`, which has no
    // widget context and passes `AppRoutes.rootNavigatorKey.currentContext`.
    // That is the *Navigator's own* context, and the root Overlay is its
    // descendant — so an ancestor-only `Overlay.of` lookup throws and no
    // Android foreground push ever renders. The tests above all pass a context
    // from inside a route, which resolves fine and hides the defect entirely.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: MallowTheme.lightTheme,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    InAppPushBanner.show(
      navigatorKey.currentContext!,
      title: 'Offer received',
      body: '1.5 SOL on Untitled #4',
      onTap: () {},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Offer received'), findsOneWidget);
    expect(find.text('1.5 SOL on Untitled #4'), findsOneWidget);
  });

  testWidgets('two messages in one frame leave a single banner', (
    tester,
  ) async {
    // FCM delivers a burst as several messages in the same frame. The
    // "currently showing" handle used to be assigned in a post-frame callback,
    // so the second `show` saw nothing to dismiss and stacked its banner on
    // top of the first — two overlapping cards, one of them unreachable.
    await pumpHost(
      tester,
      onReady: (context) {
        InAppPushBanner.show(context, title: 'First', onTap: () {});
        InAppPushBanner.show(context, title: 'Second', onTap: () {});
      },
    );

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('auto-dismisses after its duration', (tester) async {
    await pumpHost(
      tester,
      onReady: (context) => InAppPushBanner.show(
        context,
        title: 'Offer received',
        onTap: () {},
        duration: const Duration(seconds: 1),
      ),
    );

    expect(find.text('Offer received'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Offer received'), findsNothing);
  });
}
