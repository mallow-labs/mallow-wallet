import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/services/push_notification_service.dart';
import 'package:mallow_wallet/features/onboarding/screens/push_setup_screen.dart';

void main() {
  final sl = GetIt.instance;

  /// The screen resolves the push stack lazily, only on "Turn on". Nothing is
  /// registered here on purpose — see the "push stack unavailable" case.
  setUp(() {
    if (sl.isRegistered<PushNotificationService>()) {
      sl.unregister<PushNotificationService>();
    }
  });

  Widget buildTestWidget({required List<String> navigatedPaths}) {
    final router = GoRouter(
      initialLocation: '/onboarding/notifications',
      routes: [
        GoRoute(
          path: '/onboarding/notifications',
          builder: (context, state) => const PushSetupScreen(),
        ),
        GoRoute(
          path: '/',
          builder: (context, state) {
            navigatedPaths.add('/');
            return const Scaffold(body: Center(child: Text('Home Screen')));
          },
        ),
      ],
    );
    return MaterialApp.router(routerConfig: router);
  }

  Future<void> sizeScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
  }

  group('PushSetupScreen', () {
    testWidgets('asks before spending the one OS permission prompt', (
      tester,
    ) async {
      await sizeScreen(tester);
      final navigatedPaths = <String>[];

      await tester.pumpWidget(buildTestWidget(navigatedPaths: navigatedPaths));
      await tester.pumpAndSettle();

      // Both answers must be on screen. An "enable" with no way past it would
      // make an optional extra the last gate of the first run.
      expect(find.text('Turn on notifications'), findsWidgets);
      expect(find.text('Not now'), findsOneWidget);
      // Nothing has navigated yet: the question is actually being asked.
      expect(navigatedPaths, isEmpty);
    });

    testWidgets('"Not now" reaches home without touching the push stack', (
      tester,
    ) async {
      await sizeScreen(tester);
      final navigatedPaths = <String>[];

      await tester.pumpWidget(buildTestWidget(navigatedPaths: navigatedPaths));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      // Nothing was registered in GetIt, so a declined prompt that still
      // resolved PushNotificationService would have thrown here.
      expect(tester.takeException(), isNull);
      expect(navigatedPaths, contains('/'));
      expect(find.text('Home Screen'), findsOneWidget);
    });

    testWidgets('an unavailable push stack still lets the user reach home', (
      tester,
    ) async {
      await sizeScreen(tester);
      final navigatedPaths = <String>[];

      await tester.pumpWidget(buildTestWidget(navigatedPaths: navigatedPaths));
      await tester.pumpAndSettle();

      // Firebase can be missing on a real device whose init failed. Onboarding
      // is already complete by the time this screen mounts, so the only wrong
      // outcome is stranding the user on it.
      await tester.tap(find.text('Turn on notifications').last);
      await tester.pumpAndSettle();

      expect(navigatedPaths, contains('/'));
      expect(find.text('Home Screen'), findsOneWidget);
    });
  });
}
