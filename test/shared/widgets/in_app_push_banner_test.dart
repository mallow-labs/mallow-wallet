import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/in_app_push_banner.dart';

/// The banner is the only thing Android users see for a push that arrives while
/// the app is open (iOS re-presents the system banner itself). What these tests
/// pin down:
///  • the notification's text is actually shown, and
///  • tapping it hands control back to the caller so the tap routes exactly
///    like a tapped system notification would, and
///  • it takes layout — the app moves down below it instead of being covered.
void main() {
  const statusInset = 24.0;
  final navigatorKey = GlobalKey<NavigatorState>();
  final probeKey = GlobalKey();

  /// Pumps an app wrapped the way `app.dart` wraps it, with a status-bar inset,
  /// and a probe at the top of the routed content that prints the top padding
  /// it was given.
  Future<void> pumpApp(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: MallowTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(top: statusInset)),
          child: InAppPushBannerHost(enabled: enabled, child: child!),
        ),
        home: Builder(
          builder: (context) => Align(
            alignment: Alignment.topLeft,
            child: Text(
              'pad ${MediaQuery.paddingOf(context).top}',
              key: probeKey,
            ),
          ),
        ),
      ),
    );
  }

  /// The production caller passes the root navigator's own context.
  BuildContext rootContext() => navigatorKey.currentContext!;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows the notification title and body', (tester) async {
    await pumpApp(tester);
    InAppPushBanner.show(
      rootContext(),
      title: 'Offer received',
      body: '1.5 SOL on Untitled #4',
      onTap: () {},
    );
    await settle(tester);

    expect(find.text('Offer received'), findsOneWidget);
    expect(find.text('1.5 SOL on Untitled #4'), findsOneWidget);
  });

  testWidgets('pushes the app down instead of covering it', (tester) async {
    await pumpApp(tester);
    expect(tester.getTopLeft(find.byKey(probeKey)).dy, 0);
    expect(find.text('pad $statusInset'), findsOneWidget);

    InAppPushBanner.show(rootContext(), title: 'Offer received', onTap: () {});
    await settle(tester);

    // The band covers the status bar, so the app starts below the band and
    // no longer carries the status-bar inset itself.
    expect(
      tester.getTopLeft(find.byKey(probeKey)).dy,
      statusInset + InAppPushBannerHost.bandHeight,
    );
    expect(find.text('pad 0.0'), findsOneWidget);

    InAppPushBanner.dismiss(rootContext());
    await settle(tester);

    expect(tester.getTopLeft(find.byKey(probeKey)).dy, 0);
    expect(find.text('pad $statusInset'), findsOneWidget);
    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('tapping fires onTap and dismisses the banner', (tester) async {
    var taps = 0;
    await pumpApp(tester);
    InAppPushBanner.show(
      rootContext(),
      title: 'Offer received',
      onTap: () => taps++,
    );
    await settle(tester);

    await tester.tap(find.text('Offer received'));
    await settle(tester);

    expect(taps, 1);
    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('swiping up dismisses without firing onTap', (tester) async {
    var taps = 0;
    await pumpApp(tester);
    InAppPushBanner.show(
      rootContext(),
      title: 'Offer received',
      onTap: () => taps++,
    );
    await settle(tester);

    await tester.drag(find.text('Offer received'), const Offset(0, -40));
    await settle(tester);

    expect(taps, 0);
    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('two messages in one frame leave a single banner', (
    tester,
  ) async {
    // FCM delivers a burst as several messages in the same frame. The second
    // must replace the first, not stack a second banner beside it.
    await pumpApp(tester);
    InAppPushBanner.show(rootContext(), title: 'First', onTap: () {});
    InAppPushBanner.show(rootContext(), title: 'Second', onTap: () {});
    await settle(tester);

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('auto-dismisses after its duration', (tester) async {
    await pumpApp(tester);
    InAppPushBanner.show(
      rootContext(),
      title: 'Offer received',
      onTap: () {},
      duration: const Duration(seconds: 1),
    );
    await settle(tester);

    expect(find.text('Offer received'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('a disabled host refuses new banners', (tester) async {
    await pumpApp(tester, enabled: false);
    final shown = InAppPushBanner.show(
      rootContext(),
      title: 'Offer received',
      onTap: () {},
    );
    await settle(tester);

    expect(shown, isFalse);
    expect(find.text('Offer received'), findsNothing);
  });

  testWidgets('disabling the host removes the banner at once', (tester) async {
    // The app disables the host when it locks: the text must be gone on the
    // very next frame, not after an exit animation over the lock screen.
    await pumpApp(tester);
    InAppPushBanner.show(rootContext(), title: 'Offer received', onTap: () {});
    await settle(tester);

    await pumpApp(tester, enabled: false);
    await tester.pump();

    expect(find.text('Offer received'), findsNothing);
    expect(tester.getTopLeft(find.byKey(probeKey)).dy, 0);
  });

  testWidgets('without a host, show reports nothing was shown', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const SizedBox.shrink()),
    );

    expect(
      InAppPushBanner.show(key.currentContext!, title: 'x', onTap: () {}),
      isFalse,
    );
  });
}
