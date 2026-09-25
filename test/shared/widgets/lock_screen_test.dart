import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';

class _MockAppLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

/// The lockout hint is the one place the app tells a user who cannot get past
/// the PIN what to do next, and following it costs them the wallet on the
/// device if they do not hold the recovery phrase. What a reinstall destroys
/// differs by platform — on iOS the Keychain outlives it and the app comes
/// back to a Restore screen, on Android the app's storage and keystore aliases
/// go with the uninstall and there is no Restore screen at all — so a single
/// piece of copy cannot be true for both.
void main() {
  late _MockAppLockBloc appLock;

  setUp(() {
    appLock = _MockAppLockBloc();
    whenListen(
      appLock,
      const Stream<AppLockState>.empty(),
      initialState: AppLockState.locked(
        hasPin: true,
        failedAttempts: 5,
        cooldownUntil: DateTime.now().add(const Duration(seconds: 30)),
      ),
    );
  });

  Future<void> pumpLockScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: appLock,
        child: MaterialApp(
          theme: MallowTheme.lightTheme,
          home: const LockScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  // The override has to be cleared inside the test body: the test framework
  // checks that no foundation debug variable outlives the body, and it checks
  // before tearDown runs.
  testWidgets('on Android the hint says the reinstall erases the wallet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpLockScreen(tester);

      expect(
        find.textContaining(
          'Reinstalling the app erases the wallet stored on this device',
        ),
        findsOneWidget,
      );
      // There is no Restore screen on Android, so it must not be offered as a
      // way back in.
      expect(find.textContaining('Start fresh'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on iOS the Start fresh route is kept, behind the phrase', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpLockScreen(tester);

      expect(find.textContaining('Start fresh'), findsOneWidget);
      // The phrase is named before the steps: the steps end at an import that
      // needs it.
      expect(
        find.textContaining('You will need your recovery phrase'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
