import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/services/cast_awake_guard.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/cast/services/cast_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

class _MockAppLockBloc extends MockBloc<AppLockEvent, AppLockState>
    implements AppLockBloc {}

void main() {
  late _MockCastBloc castBloc;
  late _MockAppLockBloc appLockBloc;
  late StreamController<CastState> castStates;
  late StreamController<AppLockState> lockStates;
  late List<bool> awakeCalls;

  // Short enough to await for real, long enough that a "reset the countdown"
  // interaction is unambiguously distinguishable from an expiry.
  const idleTimeout = Duration(milliseconds: 60);

  setUpAll(() {
    registerFallbackValue(const AppLockEvent.lock());
  });

  setUp(() {
    castStates = StreamController<CastState>.broadcast();
    lockStates = StreamController<AppLockState>.broadcast();
    awakeCalls = [];

    castBloc = _MockCastBloc();
    appLockBloc = _MockAppLockBloc();
    whenListen(
      castBloc,
      castStates.stream,
      initialState: const CastState.idle(),
    );
    whenListen(
      appLockBloc,
      lockStates.stream,
      initialState: const AppLockState.unlocked(hasPin: true),
    );
  });

  tearDown(() async {
    await castStates.close();
    await lockStates.close();
  });

  CastAwakeGuard buildGuard() => CastAwakeGuard(
    castBloc: castBloc,
    appLockBloc: appLockBloc,
    idleTimeout: idleTimeout,
    setScreenAwake: (enable) async => awakeCalls.add(enable),
  );

  CastState activeOn(CastDeviceType type, {int currentIndex = 0}) =>
      CastState.active(
        device: CastDevice(id: 'd1', name: 'Device', type: type),
        queue: CastQueue(currentIndex: currentIndex),
      );

  // Lets the guard's stream listener run before we assert.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> waitPastIdleTimeout() =>
      Future<void>.delayed(idleTimeout * 2 + const Duration(milliseconds: 20));

  group('keep-awake', () {
    test('holds the screen awake only while a session is active', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);
      await settle();

      // Idle at start: nothing to keep alive, so no wakelock is taken.
      expect(awakeCalls, isEmpty);

      // The slideshow clock lives in CastBloc and every slide is pushed from
      // the phone, so a suspended app freezes the receiver mid-session.
      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();
      expect(awakeCalls, [true]);

      // Session over — release it rather than draining the battery.
      castStates.add(const CastState.idle());
      await settle();
      expect(awakeCalls, [true, false]);
    });

    test('does not re-toggle while the session stays active', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();
      // e.g. a queue reorder or an availableDevices refresh mid-session.
      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();

      expect(awakeCalls, [true]);
    });

    test('releases the wakelock on dispose', () async {
      final guard = buildGuard()..start();
      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();

      await guard.dispose();

      expect(awakeCalls, [true, false]);
    });
  });

  group('idle re-lock', () {
    test('locks the app after the idle timeout while casting', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();
      verifyNever(() => appLockBloc.add(any()));

      await waitPastIdleTimeout();

      // The whole point of holding the phone awake is that it is left
      // unattended — it must not stay transactable.
      verify(() => appLockBloc.add(const AppLockEvent.lock())).called(1);
    });

    test('a touch restarts the countdown', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();

      // Someone actively using the app must never be locked out mid-task.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(idleTimeout ~/ 2);
        guard.notifyInteraction();
      }
      verifyNever(() => appLockBloc.add(any()));

      // ...but the countdown still expires once the touches stop.
      await waitPastIdleTimeout();
      verify(() => appLockBloc.add(const AppLockEvent.lock())).called(1);
    });

    test('a slideshow advance does not restart the countdown', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();

      // CastBloc emits a fresh CastActive on every auto-advance and the
      // default interval (30s) is half the idle timeout, so counting those
      // emissions as presence would keep the countdown alive forever —
      // during a slideshow, which is precisely when the phone is left
      // unattended next to the screen it is casting to.
      for (var i = 1; i <= 4; i++) {
        await Future<void>.delayed(idleTimeout ~/ 2);
        castStates.add(activeOn(CastDeviceType.chromecast, currentIndex: i));
        await settle();
      }

      verify(() => appLockBloc.add(const AppLockEvent.lock())).called(1);
    });

    test('stands down while the app is not in the foreground', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();

      // A Face ID / passcode sheet parks the app in `inactive` and delivers
      // no pointer events while it is up, so a running countdown would lock
      // the app out from under an authentication already in progress.
      guard.setForegrounded(false);
      await waitPastIdleTimeout();
      verifyNever(() => appLockBloc.add(any()));

      // ...and it picks back up once the app has the foreground again.
      guard.setForegrounded(true);
      verifyNever(() => appLockBloc.add(any()));
      await waitPastIdleTimeout();
      verify(() => appLockBloc.add(const AppLockEvent.lock())).called(1);
    });

    test('never locks with no session', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);
      await settle();

      guard.notifyInteraction();
      await waitPastIdleTimeout();

      verifyNever(() => appLockBloc.add(any()));
    });

    test('disarms when the session ends', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.chromecast));
      await settle();
      castStates.add(const CastState.idle());
      await settle();

      await waitPastIdleTimeout();

      verifyNever(() => appLockBloc.add(any()));
    });

    test('stays disarmed for a local "This device" session', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      // The phone screen IS the display here: app.dart swaps the routed app
      // (LocalCastReceiverOverlay included) for the lock screen, so locking
      // would black out the artwork the user asked to see.
      castStates.add(activeOn(CastDeviceType.local));
      await settle();
      await waitPastIdleTimeout();

      verifyNever(() => appLockBloc.add(any()));
      // Keep-awake still applies — the local slideshow needs the screen on.
      expect(awakeCalls, [true]);
    });

    test('re-arms after the user unlocks, and not before', () async {
      final guard = buildGuard()..start();
      addTearDown(guard.dispose);

      castStates.add(activeOn(CastDeviceType.airplay));
      await settle();
      lockStates.add(const AppLockState.locked(hasPin: true));
      await settle();

      // Already locked — no countdown should be running against it.
      await waitPastIdleTimeout();
      verifyNever(() => appLockBloc.add(any()));

      lockStates.add(const AppLockState.unlocked(hasPin: true));
      await settle();
      await waitPastIdleTimeout();

      verify(() => appLockBloc.add(const AppLockEvent.lock())).called(1);
    });
  });
}
