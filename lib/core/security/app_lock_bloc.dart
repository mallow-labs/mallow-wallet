import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../database/database.dart';
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
    final hasWallets = await _db.hasAnyWallets();
    if (!hasWallets) {
      emit(const AppLockState.noPinSet());
      return;
    }

    final hasPin = await _storage.hasPin();
    final biometricEnabled = await _storage.loadBiometricEnabled();

    // Lock if either auth factor is set up. noPinSet only applies to a
    // fresh install with no auth at all (pre-onboarding).
    if (hasPin || biometricEnabled) {
      // Rehydrate the lockout counters so force-close does not reset the
      // cooldown ladder. A cooldown that has already elapsed by the time we
      // wake is dropped — the persisted counter alone determines which tier
      // the next failure escalates to.
      final failedAttempts = await _storage.loadFailedPinAttempts();
      final persistedCooldown = await _storage.loadPinCooldownUntil();
      final DateTime? cooldownUntil;
      if (persistedCooldown != null &&
          persistedCooldown.isAfter(DateTime.now())) {
        cooldownUntil = persistedCooldown;
      } else {
        cooldownUntil = null;
        if (persistedCooldown != null) {
          await _storage.deletePinCooldownUntil();
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
    if (await _storage.verifyPin(event.pin)) {
      // Successful unlock — reset everything, including persisted lockout.
      await _storage.clearPinLockout();
      emit(
        AppLockState.unlocked(
          biometricEnabled: currentState.biometricEnabled,
          hasPin: currentState.hasPin,
        ),
      );
    } else {
      final newFailedAttempts = currentState.failedAttempts + 1;
      await _storage.storeFailedPinAttempts(newFailedAttempts);

      if (newFailedAttempts >= _maxFailedAttempts) {
        // Calculate which cooldown tier we're in
        final lockoutRound =
            (newFailedAttempts - _maxFailedAttempts) ~/ _maxFailedAttempts;
        final tierIndex = lockoutRound.clamp(0, _cooldownDurations.length - 1);
        final cooldown = _cooldownDurations[tierIndex];
        final cooldownUntil = DateTime.now().add(cooldown);
        await _storage.storePinCooldownUntil(cooldownUntil);

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
      // lockout so the counter does not bleed across a successful auth.
      await _storage.clearPinLockout();
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
    await _storage.deletePin();
    await _storage.storeBiometricEnabled(false);
    await _storage.clearPinLockout();
    emit(const AppLockState.noPinSet());
  }
}
