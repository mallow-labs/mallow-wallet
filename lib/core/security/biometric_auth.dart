import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';
import 'package:local_auth/local_auth.dart';

/// Service for biometric authentication (Face ID, Touch ID, Fingerprint).
///
/// Wraps the local_auth package with proper error handling
/// and mallow-specific configuration.
@lazySingleton
class BiometricAuthService {
  BiometricAuthService() : _localAuth = LocalAuthentication();

  final LocalAuthentication _localAuth;

  /// Check if biometric authentication is available on this device.
  Future<bool> isAvailable() async {
    try {
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return canCheckBiometrics && isDeviceSupported;
    } on PlatformException {
      return false;
    }
  }

  /// Get the list of available biometric types.
  ///
  /// Returns types like [BiometricType.face] (Face ID) or
  /// [BiometricType.fingerprint] (Touch ID/Fingerprint).
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  /// Check if Face ID is available (iOS).
  Future<bool> hasFaceId() async {
    final biometrics = await getAvailableBiometrics();
    return biometrics.contains(BiometricType.face);
  }

  /// Check if Touch ID/Fingerprint is available.
  Future<bool> hasFingerprint() async {
    final biometrics = await getAvailableBiometrics();
    return biometrics.contains(BiometricType.fingerprint);
  }

  /// Authenticate using biometrics.
  ///
  /// [reason] is displayed to the user explaining why authentication is needed.
  /// [biometricOnly] if true, only allows biometric auth (no PIN/pattern fallback).
  ///
  /// Returns true if authentication succeeded, false otherwise.
  Future<BiometricAuthResult> authenticate({
    required String reason,
    bool biometricOnly = false,
  }) async {
    try {
      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        persistAcrossBackgrounding: true,
      );

      return didAuthenticate
          ? BiometricAuthResult.success
          : BiometricAuthResult.failed;
    } on PlatformException catch (e) {
      return _handlePlatformException(e);
    } catch (_) {
      // Any non-PlatformException must still produce a result — otherwise
      // callers waiting on biometric to clear an in-flight flag (e.g. the
      // app lock blur) get stranded.
      return BiometricAuthResult.error;
    }
  }

  /// Authenticate for viewing seed phrase.
  ///
  /// Uses biometric-only authentication for maximum security.
  Future<BiometricAuthResult> authenticateForSeedPhrase() async {
    return authenticate(
      reason: 'Authenticate to view your recovery phrase',
      biometricOnly: true,
    );
  }

  /// Authenticate to enter a protected area (e.g. Security & Privacy).
  ///
  /// Biometric-only — the caller handles the PIN fallback.
  Future<BiometricAuthResult> authenticateForReauth() async {
    return authenticate(
      reason: 'Authenticate to continue',
      biometricOnly: true,
    );
  }

  /// Authenticate for signing a transaction.
  Future<BiometricAuthResult> authenticateForTransaction() async {
    return authenticate(reason: 'Authenticate to sign this transaction');
  }

  /// Authenticate to unlock the app.
  Future<BiometricAuthResult> authenticateToUnlock() async {
    return authenticate(reason: 'Authenticate to unlock mallow');
  }

  /// Cancel any ongoing authentication.
  Future<void> cancelAuthentication() async {
    await _localAuth.stopAuthentication();
  }

  BiometricAuthResult _handlePlatformException(PlatformException e) {
    switch (e.code) {
      case 'NotAvailable':
        return BiometricAuthResult.notAvailable;
      case 'NotEnrolled':
        return BiometricAuthResult.notEnrolled;
      case 'LockedOut':
        return BiometricAuthResult.lockedOut;
      case 'PermanentlyLockedOut':
        return BiometricAuthResult.permanentlyLockedOut;
      case 'PasscodeNotSet':
        return BiometricAuthResult.passcodeNotSet;
      default:
        return BiometricAuthResult.error;
    }
  }
}

/// Result of a biometric authentication attempt.
enum BiometricAuthResult {
  /// Authentication succeeded.
  success,

  /// Authentication failed (user cancelled or wrong biometric).
  failed,

  /// Biometric authentication is not available on this device.
  notAvailable,

  /// No biometrics are enrolled on this device.
  notEnrolled,

  /// Too many failed attempts, temporarily locked out.
  lockedOut,

  /// Too many failed attempts, permanently locked out until device passcode is used.
  permanentlyLockedOut,

  /// Device passcode is not set (required for biometrics).
  passcodeNotSet,

  /// An unknown error occurred.
  error,
}

extension BiometricAuthResultX on BiometricAuthResult {
  /// Whether this result indicates successful authentication.
  bool get isSuccess => this == BiometricAuthResult.success;

  /// Whether this result indicates the user should be shown an error message.
  bool get isError =>
      this != BiometricAuthResult.success && this != BiometricAuthResult.failed;

  /// Get a user-friendly error message for this result.
  String? get errorMessage {
    switch (this) {
      case BiometricAuthResult.success:
      case BiometricAuthResult.failed:
        return null;
      case BiometricAuthResult.notAvailable:
        return 'Biometric authentication is not available on this device.';
      case BiometricAuthResult.notEnrolled:
        return 'No biometrics are enrolled. Please set up Face ID or fingerprint in your device settings.';
      case BiometricAuthResult.lockedOut:
        return 'Too many failed attempts. Please try again later.';
      case BiometricAuthResult.permanentlyLockedOut:
        return 'Biometric authentication is locked. Please use your device passcode to unlock.';
      case BiometricAuthResult.passcodeNotSet:
        return 'Please set up a device passcode to use biometric authentication.';
      case BiometricAuthResult.error:
        return 'An error occurred during authentication. Please try again.';
    }
  }
}
