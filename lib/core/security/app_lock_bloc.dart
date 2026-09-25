import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../database/database.dart';
import '../observability/app_logger.dart';
import 'biometric_auth.dart';
import 'secure_storage.dart';

part 'app_lock_bloc.freezed.dart';

/// Events for the AppLock bloc.
@freezed
sealed class AppLockEvent with _$AppLockEvent {
  /// Initialize the app lock state from storage.
  const factory AppLockEvent.init() = AppLockEventInit;

  /// Set up a new PIN.
  const factory AppLockEvent.setPin(String pin) = AppLockEventSetPin;

  /// Attempt to unlock with PIN.
  const factory AppLockEvent.unlockWithPin(String pin) =
      AppLockEventUnlockWithPin;

  /// Attempt to unlock with biometrics.
  const factory AppLockEvent.unlockWithBiometric() =
      AppLockEventUnlockWithBiometric;

  /// Lock the app (e.g., when backgrounded).
  const factory AppLockEvent.lock() = AppLockEventLock;

  /// Enable biometric unlock.
  const factory AppLockEvent.enableBiometric() = AppLockEventEnableBiometric;

  /// Disable biometric unlock.
  const factory AppLockEvent.disableBiometric() = AppLockEventDisableBiometric;

  /// Remove PIN and biometric (disable app lock).
  const factory AppLockEvent.disable(String pin) = AppLockEventDisable;

  /// Reset app lock (logout/clear all).
  ///
  /// Dispatched right after an explicit wipe has already swept the secure
  /// store, so the handler only deletes — it must never write a value back
  /// and leave an item behind the sweep.
  const factory AppLockEvent.reset() = AppLockEventReset;
}

/// State for the AppLock bloc.
@freezed
sealed class AppLockState with _$AppLockState {
  /// Initial state before loading.
  const factory AppLockState.uninitialized() = AppLockStateUninitialized;

  /// No PIN has been set up yet.
  const factory AppLockState.noPinSet() = AppLockStateNoPinSet;

  /// App is locked, waiting for PIN or biometric.
  const factory AppLockState.locked({
    @Default(false) bool wrongPinAttempt,
    @Default(false) bool biometricEnabled,
    @Default(false) bool hasPin,
    @Default(false) bool biometricAttempting,
    @Default(0) int failedAttempts,
    DateTime? cooldownUntil,
  }) = AppLockStateLocked;

  /// App is unlocked.
  const factory AppLockState.unlocked({
    @Default(false) bool biometricEnabled,
    @Default(false) bool hasPin,
  }) = AppLockStateUnlocked;

  /// Error state.
  const factory AppLockState.error(String message) = AppLockStateError;
}

/// Bloc for managing app lock (PIN + biometric).
///
/// Handles:
/// - PIN setup and verification
/// - Biometric enable/disable
/// - Locking when app is backgrounded
/// - Unlocking with PIN or biometrics
@injectable
class AppLockBloc extends Bloc<AppLockEvent, AppLockState> {
  AppLockBloc(this._storage, this._biometricAuth, this._db)
    : super(const AppLockState.uninitialized()) {
    on<AppLockEventInit>(_onInit);
    on<AppLockEventSetPin>(_onSetPin);
    on<AppLockEventUnlockWithPin>(_onUnlockWithPin);
    on<AppLockEventUnlockWithBiometric>(_onUnlockWithBiometric);
    on<AppLockEventLock>(_onLock);
    on<AppLockEventEnableBiometric>(_onEnableBiometric);
    on<AppLockEventDisableBiometric>(_onDisableBiometric);
    on<AppLockEventDisable>(_onDisable);
    on<AppLockEventReset>(_onReset);
  }

  final SecureWalletStorage _storage;
  final BiometricAuthService _biometricAuth;
  final MallowDatabase _db;

  static const _maxFailedAttempts = 5;

  /// Where a failed read lands: locked, with the PIN pad up.
  ///
  /// The reads behind the lock state can throw rather than answer — the vault
  /// reports an unreadable Keychain/Keystore item as an error, which is the
  /// point of it. An unhandled throw emits nothing at all, leaving the bloc
  /// `uninitialized` and the app on its splash for the rest of the launch, so
  /// every read here is caught and answered with this state instead.
  ///
  /// It claims a PIN because the caller only reaches it on a device whose
  /// database holds wallets: onboarding cannot finish there without a factor,
  /// and the PIN pad is the challenge every locked user can be offered. A
  /// biometric-only user stays locked until the read recovers — but with the
  /// store unreadable their unlock could not be verified either.
  static const _lockedOnUnreadableState = AppLockState.locked(hasPin: true);

  /// Run a lockout-bookkeeping store call whose failure must not decide an
  /// unlock. The handler around it has already worked out what the user sees;
  /// letting a refused write throw would skip that emit and leave the lock
  /// screen with no answer at all.
  Future<void> _bestEffort(String what, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      AppLogger.error('AppLockBloc', 'could not $what', e);
    }
  }

  /// The read half of [_bestEffort]: answer [fallback] rather than throw.
  ///
  /// The lockout counters are bookkeeping — which cooldown tier the next
  /// failure lands in. Letting one of their reads throw would hand the state
  /// to the fail-closed catch and replace a correctly read lock with
  /// [_lockedOnUnreadableState], a PIN-only lock a biometric-only user cannot
  /// satisfy and nothing re-inits out of. Only a *factor* read may decide
  /// that.
  Future<T> _bestEffortRead<T>(
    String what,
    Future<T> Function() read,
    T fallback,
  ) async {
    try {
      return await read();
    } catch (e) {
      AppLogger.error('AppLockBloc', 'could not $what', e);
      return fallback;
    }
  }

  Future<void> _onInit(
    AppLockEventInit event,
    Emitter<AppLockState> emit,
  ) async {
    // Gate AppLock on the local DB actually containing a wallet. iOS
    // Keychain persists across app uninstall/reinstall but the Face ID
    // permission grant does not — so on a reinstall, biometricEnabled may
    // still be true even though the user hasn't onboarded for this install
    // yet. Locking in that state would auto-fire biometric and surface the
    // iOS Face ID permission prompt before the user reaches the biometric
    // setup screen. Defer to the explicit opt-in on that screen instead.
    final bool hasWallets;
    try {
      hasWallets = await _db.hasAnyWallets();
    } catch (e) {
      // Only an emptiness this read *confirmed* may skip the lock.
      AppLogger.error('AppLockBloc', 'init could not read the wallet rows', e);
      emit(_lockedOnUnreadableState);
      return;
    }
    if (!hasWallets) {
      emit(const AppLockState.noPinSet());
      return;
    }

    try {
      // A missing PIN is re-read before it is believed — see
      // [SecureWalletStorage.loadAuthFactors].
      final factors = await _storage.loadAuthFactors();
      final hasPin = factors.hasPin;
      final biometricEnabled = factors.biometricEnabled;

      // Lock if either auth factor is set up. noPinSet means this device has
      // neither, which onboarding no longer allows — it is an install that
      // predates the mandatory app-lock floor. Dropping the PIN while
      // biometrics are on (change_pin_screen) is not that case: it leaves
      // biometricEnabled true, and still locks.
      if (hasPin || biometricEnabled) {
        // Rehydrate the lockout counters so force-close does not reset the
        // cooldown ladder. A cooldown that has already elapsed by the time we
        // wake is dropped — the persisted counter alone determines which tier
        // the next failure escalates to.
        // Best-effort, all three: see [_bestEffortRead]. The factors above
        // already decided which lock this user gets, and losing a counter
        // costs a cooldown tier — dropping it into the catch below would cost
        // them the lock screen they can actually answer.
        final failedAttempts = await _bestEffortRead(
          'read the failed-PIN counter',
          _storage.loadFailedPinAttempts,
          0,
        );
        final persistedCooldown = await _bestEffortRead<DateTime?>(
          'read the PIN cooldown',
          _storage.loadPinCooldownUntil,
          null,
        );
        final DateTime? cooldownUntil;
        if (persistedCooldown != null &&
            persistedCooldown.isAfter(DateTime.now())) {
          cooldownUntil = persistedCooldown;
        } else {
          cooldownUntil = null;
          if (persistedCooldown != null) {
            await _bestEffort(
              'drop the elapsed PIN cooldown',
              _storage.deletePinCooldownUntil,
            );
          }
        }

        emit(
          AppLockState.locked(
            hasPin: hasPin,
            biometricEnabled: biometricEnabled,
            // Pre-set the in-flight flag so the LockScreen renders the
            // privacy blur from frame 1 instead of flashing PIN UI before
            // the OS biometric prompt animates in.
            biometricAttempting: biometricEnabled,
            failedAttempts: failedAttempts,
            cooldownUntil: cooldownUntil,
          ),
        );
      } else {
        emit(const AppLockState.noPinSet());
      }
    } catch (e) {
      // See [_lockedOnUnreadableState]: the wallets are there, so an
      // unreadable lock state must not open the app.
      AppLogger.error('AppLockBloc', 'init could not read the lock state', e);
      emit(_lockedOnUnreadableState);
    }
  }

  Future<void> _onSetPin(
    AppLockEventSetPin event,
    Emitter<AppLockState> emit,
  ) async {
    await _storage.storePinHash(event.pin);
    emit(const AppLockState.unlocked(hasPin: true));
  }

  /// Progressive cooldown durations after reaching max failed attempts.
  static const _cooldownDurations = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  Future<void> _onUnlockWithPin(
    AppLockEventUnlockWithPin event,
    Emitter<AppLockState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AppLockStateLocked) return;

    // Reject attempts during cooldown without incrementing counter
    if (currentState.cooldownUntil != null &&
        DateTime.now().isBefore(currentState.cooldownUntil!)) {
      emit(currentState.copyWith(wrongPinAttempt: true));
      return;
    }

    // Biometric-only mode: PIN entry is not a valid unlock path.
    if (!currentState.hasPin) return;

    final bool verified;
    try {
      verified = await _storage.verifyPin(event.pin);
    } catch (e) {
      // The stored hash could not be read — the vault reports an unreadable
      // item as an error. Refuse the attempt without counting it: the PIN may
      // well be right, so escalating the cooldown ladder for a store glitch
      // would punish the user for it. `wrongPinAttempt` is the only signal
      // this state carries, so it is what the lock screen shows.
      AppLogger.error('AppLockBloc', 'could not read the stored PIN', e);
      emit(currentState.copyWith(wrongPinAttempt: true));
      return;
    }

    if (verified) {
      // Successful unlock — reset everything, including persisted lockout.
      // A refused clear must not hold the unlock hostage; the worst it leaves
      // behind is a stale counter.
      await _bestEffort('clear the PIN lockout', _storage.clearPinLockout);
      emit(
        AppLockState.unlocked(
          biometricEnabled: currentState.biometricEnabled,
          hasPin: currentState.hasPin,
        ),
      );
    } else {
      final newFailedAttempts = currentState.failedAttempts + 1;
      // Best-effort for the same reason as above: a failed counter write must
      // not skip the emit below and leave the lock screen holding a full,
      // unanswered PIN entry.
      await _bestEffort(
        'store the failed-PIN counter',
        () => _storage.storeFailedPinAttempts(newFailedAttempts),
      );

      if (newFailedAttempts >= _maxFailedAttempts) {
        // Calculate which cooldown tier we're in
        final lockoutRound =
            (newFailedAttempts - _maxFailedAttempts) ~/ _maxFailedAttempts;
        final tierIndex = lockoutRound.clamp(0, _cooldownDurations.length - 1);
        final cooldown = _cooldownDurations[tierIndex];
        final cooldownUntil = DateTime.now().add(cooldown);
        await _bestEffort(
          'store the PIN cooldown',
          () => _storage.storePinCooldownUntil(cooldownUntil),
        );

        emit(
          currentState.copyWith(
            wrongPinAttempt: true,
            failedAttempts: newFailedAttempts,
            cooldownUntil: cooldownUntil,
          ),
        );
      } else {
        emit(
          currentState.copyWith(
            wrongPinAttempt: true,
            failedAttempts: newFailedAttempts,
          ),
        );
      }
    }
  }

  Future<void> _onUnlockWithBiometric(
    AppLockEventUnlockWithBiometric event,
    Emitter<AppLockState> emit,
  ) async {
    final currentState = state;
    if (currentState is! AppLockStateLocked) return;
    if (!currentState.biometricEnabled) return;

    if (!currentState.biometricAttempting) {
      emit(currentState.copyWith(biometricAttempting: true));
    }

    BiometricAuthResult result;
    try {
      result = await _biometricAuth.authenticateToUnlock();
    } catch (_) {
      // Defense in depth: the service already catches PlatformException,
      // but any other throw here would leave biometricAttempting stuck at
      // true and the lock blur stranded with no retry button.
      result = BiometricAuthResult.error;
    }

    // State may have changed during the prompt (e.g. another lock event).
    final latest = state;
    if (latest is! AppLockStateLocked) return;

    if (result.isSuccess) {
      // Biometric unlock is a valid auth path — clear the persisted PIN
      // lockout so the counter does not bleed across a successful auth. Same
      // best-effort as the PIN path: the auth already succeeded, and a store
      // refusal here must not strand the user behind the blur.
      await _bestEffort('clear the PIN lockout', _storage.clearPinLockout);
      emit(
        AppLockState.unlocked(biometricEnabled: true, hasPin: latest.hasPin),
      );
    } else {
      // Failed/cancelled — clear the in-flight flag so the LockScreen
      // can reveal the PIN entry (or biometric retry button if no PIN).
      emit(latest.copyWith(biometricAttempting: false));
    }
  }

  void _onLock(AppLockEventLock event, Emitter<AppLockState> emit) {
    final currentState = state;
    if (currentState is AppLockStateUnlocked) {
      emit(
        AppLockState.locked(
          biometricEnabled: currentState.biometricEnabled,
          hasPin: currentState.hasPin,
          // See _onInit — start in the in-flight state so the lock screen
          // shows the privacy blur instead of the PIN UI.
          biometricAttempting: currentState.biometricEnabled,
        ),
      );
    }
  }

  Future<void> _onEnableBiometric(
    AppLockEventEnableBiometric event,
    Emitter<AppLockState> emit,
  ) async {
    await _storage.storeBiometricEnabled(true);
    final currentState = state;
    if (currentState is AppLockStateUnlocked) {
      emit(currentState.copyWith(biometricEnabled: true));
    } else if (currentState is AppLockStateLocked) {
      emit(currentState.copyWith(biometricEnabled: true));
    } else {
      // Arming from `noPinSet` — the biometric-only onboarding path, where the
      // user enables biometrics and then skips the PIN. Without this branch the
      // flag is written but the state stays `noPinSet`, and since `_onLock`
      // only transitions out of `unlocked` the background-lock trigger stays
      // inert for the whole first session. Emit `unlocked`, not `locked`: the
      // user authenticated seconds ago to enable this, so re-challenging them
      // here would be a prompt loop. `init()` is the right event only when the
      // credential predates the session (see `wallet_recovery_screen`).
      emit(
        AppLockState.unlocked(
          hasPin: await _storage.hasPin(),
          biometricEnabled: true,
        ),
      );
    }
  }

  Future<void> _onDisableBiometric(
    AppLockEventDisableBiometric event,
    Emitter<AppLockState> emit,
  ) async {
    await _storage.storeBiometricEnabled(false);
    final currentState = state;
    if (currentState is AppLockStateUnlocked) {
      emit(currentState.copyWith(biometricEnabled: false));
    } else if (currentState is AppLockStateLocked) {
      emit(currentState.copyWith(biometricEnabled: false));
    }
  }

  Future<void> _onDisable(
    AppLockEventDisable event,
    Emitter<AppLockState> emit,
  ) async {
    // Verify PIN before disabling
    if (!await _storage.verifyPin(event.pin)) {
      emit(const AppLockState.error('Incorrect PIN'));
      return;
    }

    await _storage.deletePin();
    await _storage.storeBiometricEnabled(false);
    await _storage.clearPinLockout();
    emit(const AppLockState.noPinSet());
  }

  Future<void> _onReset(
    AppLockEventReset event,
    Emitter<AppLockState> emit,
  ) async {
    // In-memory state first, and unconditionally. The store deletes below can
    // now fail loudly — the vault reports a refused delete instead of
    // swallowing it — and the wipe that dispatches this event has already
    // swept the store anyway. What this handler must not skip is dropping the
    // lock state: a bloc left holding `unlocked(hasPin: true)` raises the
    // LockScreen on the next backgrounding, and the PIN that would dismiss it
    // has just been deleted.
    emit(const AppLockState.noPinSet());

    // Deletes only — see [AppLockEvent.reset]. `storeBiometricEnabled(false)`
    // would write the flag back into the store the wipe has just emptied.
    // Each is independent: one refusal must not leave the others behind the
    // sweep, and on iOS a Keychain item outlives an app reinstall.
    Future<void> bestEffort(String what, Future<void> Function() delete) async {
      try {
        await delete();
      } catch (e) {
        AppLogger.error('AppLockBloc', 'reset could not delete $what', e);
      }
    }

    await bestEffort('the PIN', _storage.deletePin);
    await bestEffort('the biometric flag', _storage.deleteBiometricEnabled);
    await bestEffort('the PIN lockout', _storage.clearPinLockout);
  }
}
