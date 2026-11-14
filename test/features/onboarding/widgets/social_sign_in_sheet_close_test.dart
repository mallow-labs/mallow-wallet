import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/features/onboarding/widgets/create_wallet_menu.dart';
import 'package:mallow_wallet/features/social_vault/services/social_sign_in_routing.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// A Google or Apple sign-in ends twice. The app shell hears the result and
/// replaces the screen the sign-in started from; a moment later the sign-in
/// returns to the sheet that started it, which closes itself.
///
/// By then the sheet may already be on its way out. Started from Add account,
/// the shell goes Home and the sheet slides away over it, still mounted for
/// the length of that animation. A sheet that then asks the navigator to pop
/// closes the page underneath instead: Home, the only page left. The app
/// showed an empty black screen until it was restarted.
void main() {
  late GoRouter router;
  late StreamController<SocialAuthResult> results;
  StreamSubscription<SocialAuthResult>? shell;

  final result = SocialAuthResult(
    wallet: const WalletInfo(
      id: 'w-solana',
      address: '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin',
      name: 'Google Wallet',
      walletType: WalletType.social,
      chain: 'solana',
      socialProvider: 'google',
    ),
    provider: 'google',
    existed: false,
  );

  /// The sign-in as the service runs its last steps: publish the result,
  /// wait for the app to arrive where the shell takes it (the notices that
  /// follow a sign-in do), then return to the sheet.
  Future<SocialAuthResult?> signIn() async {
    results.add(result);
    await SocialSignInRouting.instance.settled();
    return result;
  }

  /// The app shell: it hears the result and replaces the screen with
  /// [destination]. At once during onboarding; from Add account only [after]
  /// it has made the wallet the active one, which takes about a second.
  void routeResultsTo(String destination, {Duration after = Duration.zero}) {
    shell = results.stream.listen((_) async {
      final routed = SocialSignInRouting.instance.begin();
      try {
        if (after > Duration.zero) await Future<void>.delayed(after);
        router.go(destination);
      } finally {
        routed();
      }
    });
  }

  Widget page(String name) => Scaffold(body: Center(child: Text(name)));

  /// A page with the one button that opens the create sheet, as the Welcome
  /// and Add account screens do.
  Widget startPage(String name) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => CreateWalletMenu.show(
            context,
            onGoogleSignIn: signIn,
            onAppleSignIn: signIn,
            onRecoveryPhraseTap: () {},
          ),
          child: Text(name),
        ),
      ),
    ),
  );

  setUp(() {
    results = StreamController<SocialAuthResult>.broadcast();
    router = GoRouter(
      navigatorKey: AppRoutes.rootNavigatorKey,
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => page('home')),
        GoRoute(path: '/add', builder: (_, _) => startPage('add account')),
        GoRoute(path: '/welcome', builder: (_, _) => startPage('welcome')),
        GoRoute(path: '/app-lock', builder: (_, _) => page('app lock setup')),
      ],
    );
  });

  tearDown(() async {
    await shell?.cancel();
    shell = null;
    await results.close();
    router.dispose();
    SocialSignInRouting.instance.reset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    // Wide enough that the test font (every glyph a fixed, oversized box)
    // doesn't overflow the button rows the way a real font wouldn't.
    tester.view.physicalSize = const Size(2400, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the sheet from the page named [start], signs in, and lets the
  /// shell's navigation and every animation run out.
  Future<void> signInFrom(WidgetTester tester, String start) async {
    await tester.tap(find.text(start));
    await tester.pumpAndSettle();
    // A sheet takes no taps until a moment after it has slid in.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    // The shell's second, then the navigation and the sheet's way out.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('started from Add account, the sheet does not take Home with it '
      'when it closes', (tester) async {
    routeResultsTo('/', after: const Duration(seconds: 1));
    await pumpApp(tester);
    unawaited(router.push('/add'));
    await tester.pumpAndSettle();

    await signInFrom(tester, 'add account');

    expect(tester.takeException(), isNull);
    expect(router.routerDelegate.currentConfiguration.isNotEmpty, isTrue);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('add account'), findsNothing);
  });

  testWidgets('started from Welcome, the app-lock setup stays up', (
    tester,
  ) async {
    routeResultsTo('/app-lock');
    await pumpApp(tester);
    router.go('/welcome');
    await tester.pumpAndSettle();

    await signInFrom(tester, 'welcome');

    expect(tester.takeException(), isNull);
    expect(router.routerDelegate.currentConfiguration.isNotEmpty, isTrue);
    expect(find.text('app lock setup'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
  });

  testWidgets('a sign-in that returns while the sheet is still the top route '
      'closes the sheet, and nothing else', (tester) async {
    // No shell: nothing replaces the page, so the sheet closes itself.
    await pumpApp(tester);
    unawaited(router.push('/add'));
    await tester.pumpAndSettle();

    await signInFrom(tester, 'add account');

    expect(tester.takeException(), isNull);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('add account'), findsOneWidget);
  });

  testWidgets('with something still on top of it, the sheet goes and what is '
      'on top stays', (tester) async {
    await pumpApp(tester);
    unawaited(router.push('/add'));
    await tester.pumpAndSettle();
    // A sign-in that leaves a notice up when it returns.
    shell = results.stream.listen((_) {
      unawaited(
        showDialog<void>(
          context: AppRoutes.rootNavigatorKey.currentContext!,
          builder: (_) => const AlertDialog(content: Text('a notice')),
        ),
      );
    });

    await signInFrom(tester, 'add account');

    expect(tester.takeException(), isNull);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('a notice'), findsOneWidget);
    expect(find.text('add account'), findsOneWidget);
  });
}
