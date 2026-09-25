import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/reset_app_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAnalytics extends Mock implements AnalyticsService {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockAppLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

/// Reset app is a factory reset: it deletes the PIN hash the app lock checks
/// against, and the screen has no navigation of its own — the router takes the
/// user away only once the logout notifies it. Two things have to happen at the
/// end of the wipe or the user is stuck. The lock bloc — which app.dart keeps
/// alive for the whole process — has to stop reporting a live
/// unlocked-with-PIN session, or the next backgrounding raises a LockScreen no
/// PIN can dismiss. And the logout has to run even when the user leaves
/// mid-wipe: the wipe takes seconds and the settings header keeps its back
/// arrow, so this screen can be popped while it is still running.
void main() {
  late _MockAuth auth;
  late _MockWalletManager walletManager;
  late _MockAnalytics analytics;
  late _MockAuthNotifier authNotifier;
  late _MockAppLockBloc appLock;
  late GlobalKey<NavigatorState> navKey;

  setUpAll(() => registerFallbackValue(const AppLockEvent.init()));

  setUp(() {
    navKey = GlobalKey<NavigatorState>();
    auth = _MockAuth();
    walletManager = _MockWalletManager();
    analytics = _MockAnalytics();
    authNotifier = _MockAuthNotifier();
    appLock = _MockAppLockBloc();
    whenListen(
      appLock,
      const Stream<AppLockState>.empty(),
      initialState: const AppLockState.unlocked(hasPin: true),
    );

    for (final unregister in [
      () =>
          sl.isRegistered<AuthService>() ? sl.unregister<AuthService>() : null,
      () => sl.isRegistered<WalletManager>()
          ? sl.unregister<WalletManager>()
          : null,
      () => sl.isRegistered<AnalyticsService>()
          ? sl.unregister<AnalyticsService>()
          : null,
      () => sl.isRegistered<AuthStateNotifier>()
          ? sl.unregister<AuthStateNotifier>()
          : null,
    ]) {
      unregister();
    }
    sl.registerSingleton<AuthService>(auth);
    sl.registerSingleton<WalletManager>(walletManager);
    sl.registerSingleton<AnalyticsService>(analytics);
    sl.registerSingleton<AuthStateNotifier>(authNotifier);

    when(() => auth.logout()).thenAnswer((_) async {});
    when(() => walletManager.deleteWallet()).thenAnswer((_) async => const []);
    when(() => analytics.resetDeviceIdentity()).thenAnswer((_) async {});
    when(() => authNotifier.onLogout()).thenAnswer((_) async {});
  });

  tearDown(() {
    sl.unregister<AuthService>();
    sl.unregister<WalletManager>();
    sl.unregister<AnalyticsService>();
    sl.unregister<AuthStateNotifier>();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: appLock,
        child: MaterialApp(
          theme: MallowTheme.lightTheme,
          home: const ResetAppScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Same screen, pushed onto a navigator instead of being the whole app, so a
  /// test can pop it the way the settings header's back arrow does.
  Future<void> pumpPushedScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      BlocProvider<AppLockBloc>.value(
        value: appLock,
        child: MaterialApp(
          navigatorKey: navKey,
          theme: MallowTheme.lightTheme,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const ResetAppScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Never settles: on the success path the spinner keeps running until the
  // router redirect takes the screen away, and there is no router here. Pump
  // past the mocks and the snack-bar entry animation instead.
  Future<void> armAndReset(WidgetTester tester) async {
    await tester.tap(find.text('I have my recovery phrase saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset app').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the wipe resets the app lock as well as the wallets', (
    tester,
  ) async {
    await pumpScreen(tester);
    await armAndReset(tester);

    verify(() => walletManager.deleteWallet()).called(1);
    verify(() => authNotifier.onLogout()).called(1);
    verify(() => appLock.add(const AppLockEvent.reset())).called(1);
    // A clean wipe must not cry wolf: the warning belongs to a partial one.
    expect(find.text(_partialWipeMessage), findsNothing);
  });

  testWidgets('the button is inert until the checkbox is ticked', (
    tester,
  ) async {
    // The checkbox is the whole gate in front of this button: the wipe deletes
    // every mnemonic and private key on the device, and nothing can undo it.
    // A button that fired on the first tap would put a factory reset one
    // mis-tap away from a user who has not confirmed they hold the phrase.
    await pumpScreen(tester);

    await tester.tap(find.text('Reset app').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verifyNever(() => walletManager.deleteWallet());
    verifyNever(() => authNotifier.onLogout());
    verifyNever(() => appLock.add(any()));
  });

  testWidgets('a partial wipe warns once and still logs the user out', (
    tester,
  ) async {
    when(() => walletManager.deleteWallet()).thenAnswer(
      (_) async => const [EraseFailure('secure.mnemonic', 'PlatformException')],
    );

    await pumpScreen(tester);
    await armAndReset(tester);

    // One warning, not two: a half-wiped device is worth telling the user
    // about, but the logout is not a second failure to report.
    expect(find.text(_partialWipeMessage), findsOneWidget);
    // Half-wiped must not look signed in — the logout runs whatever failed.
    verify(() => authNotifier.onLogout()).called(1);
  });

  testWidgets('a back tap mid-wipe still logs the user out', (tester) async {
    // The wipe takes seconds on a real device and the back arrow stays live
    // through it, so the screen can be gone before the wipe returns. The
    // logout is the only thing that tells the router the wallets are gone:
    // skipped, the app sits on signed-in routes over a wiped database until
    // the next cold start.
    final wipe = Completer<List<EraseFailure>>();
    when(() => walletManager.deleteWallet()).thenAnswer((_) => wipe.future);

    await pumpPushedScreen(tester);
    await armAndReset(tester);
    verifyNever(() => authNotifier.onLogout());

    navKey.currentState!.pop();
    // Pumped rather than settled: the spinner is still on screen through the
    // pop transition and never settles. Stop as soon as the route is gone.
    for (
      var i = 0;
      i < 20 && find.byType(ResetAppScreen).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The route is really gone — the wipe below returns to a dead State.
    expect(find.byType(ResetAppScreen), findsNothing);

    wipe.complete(const [EraseFailure('secure.mnemonic', 'PlatformException')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => authNotifier.onLogout()).called(1);
    // ...and the tail must not reach for the dead context on the way: the
    // snack bar is the one step that needs it, so it is the one step skipped.
    expect(find.text(_partialWipeMessage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

const _partialWipeMessage = 'Some data could not be erased. Please try again.';
