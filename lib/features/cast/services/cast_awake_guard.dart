import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/security/app_lock_bloc.dart';
import 'cast_bloc.dart';
import 'cast_service.dart';

/// Sets the platform keep-screen-awake flag. Injected so tests never reach
/// the wakelock plugin channel.
typedef ScreenAwakeSetter = Future<void> Function(bool enable);

/// Keeps the phone awake while a cast session is live, and re-locks the app
/// after [idleTimeout] without a touch.
///
/// **Why keep-awake:** the slideshow clock is a `Timer.periodic` inside
/// [CastBloc] and every slide is *pushed* from the phone. When the device
/// auto-locks, iOS suspends the app within seconds, Dart timers stop, and the
/// display freezes on whatever slide was up (on AirPlay the secondary
/// FlutterEngine stops rendering as well). Holding the screen awake keeps the
/// sender alive for as long as the art is up.
///
/// **Why the idle re-lock:** keep-awake leaves an unlocked phone sitting
/// unattended next to the screen it is casting to, which is exactly the
/// window in which someone else could pick it up and transact. After
/// [idleTimeout] with no touch, [AppLockBloc] is driven back to `locked` and
/// the PIN/biometric screen covers the app. Casting is unaffected: the
/// session lives in [CastBloc] (a DI singleton, not part of the locked
/// subtree) and the art renders on the external display.
///
/// The re-lock is armed for external displays only. With
/// [CastDeviceType.local] the phone screen *is* the display, and `app.dart`
/// swaps the whole routed app — `LocalCastReceiverOverlay` included — for the
/// lock screen while locked, so arming it there would black out the very
/// thing the user asked to see.
///
/// A user with neither PIN nor biometric configured is unaffected:
/// [AppLockBloc] only transitions out of `unlocked`, so the lock event is a
/// no-op in the `noPinSet` state.
class CastAwakeGuard {
  CastAwakeGuard({
    required CastBloc castBloc,
    required AppLockBloc appLockBloc,
    ScreenAwakeSetter? setScreenAwake,
    this.idleTimeout = defaultIdleTimeout,
  }) : _castBloc = castBloc,
       _appLockBloc = appLockBloc,
       _setScreenAwake = setScreenAwake ?? _toggleWakelock;

  /// Matches `_backgroundLockThreshold` in `app.dart` — an unattended phone
  /// gets the same grace period whether it was backgrounded or left awake on
  /// a table mid-cast.
  static const defaultIdleTimeout = Duration(seconds: 60);

  final CastBloc _castBloc;
  final AppLockBloc _appLockBloc;
  final ScreenAwakeSetter _setScreenAwake;
  final Duration idleTimeout;

  StreamSubscription<CastState>? _castSubscription;
  StreamSubscription<AppLockState>? _lockSubscription;
  Timer? _idleTimer;
  bool _isScreenAwake = false;
  bool _isIdleLockArmed = false;
  bool _isForegrounded = true;

  /// Begins observing the cast session. Safe to call more than once.
  void start() {
    _castSubscription ??= _castBloc.stream.listen(_onCastState);
    _lockSubscription ??= _appLockBloc.stream.listen(_onLockState);
    _onCastState(_castBloc.state);
  }

  /// Restarts the idle countdown. Wired to a root-level pointer listener in
  /// `app.dart`, so any touch anywhere in the app counts as presence.
  void notifyInteraction() {
    if (!_isIdleLockArmed) return;
    _restartIdleTimer();
  }

  /// Stands the idle countdown down while the app is not the foreground app,
  /// and restarts it on the way back. Wired to `didChangeAppLifecycleState`.
  ///
  /// A Face ID / passcode prompt — and any other platform overlay, like the
  /// share sheet or an OAuth browser hop — parks the app in `inactive` and
  /// delivers no Flutter pointer events while it is up. Without this the
  /// countdown runs straight through an authentication the user is actively
  /// completing and locks the app underneath it. Backgrounding is covered by
  /// the same signal at no cost: `app.dart` already re-locks past
  /// `_backgroundLockThreshold` on resume, so a countdown here would be
  /// redundant with it.
  ///
  /// This does *not* cover a hardware-wallet approval — a Ledger confirmation
  /// happens on the Ledger, so the app stays `resumed` with no pointer events
  /// for as long as the user takes to press the buttons.
  void setForegrounded(bool isForegrounded) {
    if (isForegrounded == _isForegrounded) return;
    _isForegrounded = isForegrounded;
    if (isForegrounded) {
      _restartIdleTimer();
    } else {
      _cancelIdleTimer();
    }
  }

  Future<void> dispose() async {
    await _castSubscription?.cancel();
    _castSubscription = null;
    await _lockSubscription?.cancel();
    _lockSubscription = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _isIdleLockArmed = false;
    await _setAwake(false);
  }

  void _onCastState(CastState state) {
    unawaited(_setAwake(state is CastActive));

    final wasArmed = _isIdleLockArmed;
    _isIdleLockArmed =
        state is CastActive && state.device.type != CastDeviceType.local;
    if (!_isIdleLockArmed) {
      _cancelIdleTimer();
    } else if (!wasArmed) {
      // Start the countdown when the session *arms* it, never on a later
      // emission. [CastBloc] re-emits on every slideshow advance — 30s by
      // default, half of [idleTimeout] — so restarting per emission would
      // hold the countdown open forever on exactly the unattended phone this
      // re-lock exists for.
      _restartIdleTimer();
    }
  }

  void _onLockState(AppLockState state) {
    if (state is AppLockStateLocked) {
      _cancelIdleTimer();
    } else if (state is AppLockStateUnlocked && _isIdleLockArmed) {
      _restartIdleTimer();
    }
  }

  /// The single gate on the countdown: it runs only for an armed session, in
  /// the foreground, against an app that is not already locked (`_onLockState`
  /// re-arms it on the way back to unlocked).
  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer =
        _isIdleLockArmed &&
            _isForegrounded &&
            _appLockBloc.state is! AppLockStateLocked
        ? Timer(idleTimeout, _onIdleTimeout)
        : null;
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _onIdleTimeout() {
    _idleTimer = null;
    _appLockBloc.add(const AppLockEvent.lock());
  }

  Future<void> _setAwake(bool enable) async {
    if (enable == _isScreenAwake) return;
    _isScreenAwake = enable;
    try {
      await _setScreenAwake(enable);
    } catch (_) {
      // Best-effort: an unsupported platform or a missing plugin must not
      // take a cast session down with it. Roll the cached flag back so the
      // next transition retries instead of assuming the call landed.
      _isScreenAwake = !enable;
    }
  }

  static Future<void> _toggleWakelock(bool enable) =>
      WakelockPlus.toggle(enable: enable);
}
