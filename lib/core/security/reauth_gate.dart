import 'package:app_settings/app_settings.dart';
import 'package:flutter/widgets.dart';

import '../../di.dart';
import '../../shared/widgets/confirm_sheet.dart';
import '../../shared/widgets/pin_prompt_sheet.dart';
import 'biometric_auth.dart';
import 'secure_storage.dart';

/// Canonical re-authentication gate for sensitive surfaces: attempt biometric
/// first, then fall back to the PIN sheet. Returns true only when the user
/// actually clears the challenge.
///
/// Behaviour (the "correctly working method" — never auto-passes a cancel):
/// • Neither biometric nor a PIN configured → nothing to challenge with, so it
///   returns true (the app has no lock at all).
/// • Biometric enabled → prompt; success passes. A cancelled / failed /
///   unavailable attempt does NOT pass — it falls through to the PIN sheet when
///   a PIN exists, otherwise the gate is denied. The earlier bug was treating
///   "no PIN" as a pass after a cancelled biometric.
Future<bool> requireReauth(BuildContext context) async {
  final storage = sl<SecureWalletStorage>();
  final biometricsEnabled = await storage.loadBiometricEnabled();
  final hasPin = await storage.hasPin();

  // No second factor at all — nothing to gate on.
  if (!biometricsEnabled && !hasPin) return true;

  if (biometricsEnabled) {
    final result = await sl<BiometricAuthService>().authenticateForReauth();
    if (result.isSuccess) return true;
    // Biometrics couldn't run — e.g. on iOS the user denied the Face ID /
    // Touch ID permission prompt, none are enrolled, or there's no device
    // passcode. With no PIN fallback the gate would deny silently and the tap
    // that triggered it would appear to do nothing. Surface an actionable
    // prompt (with a link to Settings on both platforms) instead.
    if (_isBiometricSetupIssue(result) && !hasPin) {
      if (context.mounted) await _promptEnableBiometrics(context, result);
      return false;
    }
    // Cancelled / failed, or an error with a PIN fallback available → fall
    // through to the PIN sheet below.
  }

  // Biometric didn't clear the gate. Require the PIN; deny when none is set.
  if (!hasPin) return false;
  if (!context.mounted) return false;
  return await PinPromptSheet.show(context) == true;
}

/// Whether [result] is a biometric failure the user can fix in device
/// settings (permission denied, nothing enrolled, or no passcode) — as opposed
/// to a transient one (locked out) or a plain cancel.
bool _isBiometricSetupIssue(BiometricAuthResult result) =>
    result == BiometricAuthResult.notAvailable ||
    result == BiometricAuthResult.notEnrolled ||
    result == BiometricAuthResult.passcodeNotSet;

/// Tell the user why biometrics didn't run and offer to jump straight to the
/// app's Settings page so they can grant access / enrol.
///
/// Both platforms can hand off: `app_settings` fires
/// `ACTION_APPLICATION_DETAILS_SETTINGS` on Android and opens
/// `UIApplication.openSettingsURLString` on iOS. This used to be iOS-only
/// (`launchUrl('app-settings:')` behind `Platform.isIOS`), which left Android
/// users with an OK-only dead button on the one screen whose entire purpose is
/// recovering from a denied permission.
Future<void> _promptEnableBiometrics(
  BuildContext context,
  BiometricAuthResult result,
) async {
  // For notAvailable we can't tell "no hardware" from "permission denied", so
  // use wording that covers both. The other results already carry
  // settings-oriented guidance in their errorMessage.
  final message = result == BiometricAuthResult.notAvailable
      ? "mallow couldn't access biometrics. If you denied access, enable it "
            'for mallow in Settings.'
      : (result.errorMessage ?? 'Biometric authentication is unavailable.');

  final confirmed = await showConfirmSheet(
    context,
    title: 'Enable biometrics',
    message: message,
    confirmLabel: 'Open Settings',
  );

  if (confirmed == true) {
    try {
      await AppSettings.openAppSettings();
    } catch (_) {
      // Best-effort — nothing more we can do if the OS refuses to open Settings.
    }
  }
}
