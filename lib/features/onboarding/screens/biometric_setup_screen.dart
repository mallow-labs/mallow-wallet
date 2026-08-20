import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/security/biometric_auth.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Screen for setting up biometric authentication.
///
/// Allows users to enable Face ID / Touch ID for sensitive operations.
class BiometricSetupScreen extends StatefulWidget {
  const BiometricSetupScreen({super.key});

  @override
  State<BiometricSetupScreen> createState() => _BiometricSetupScreenState();
}

class _BiometricSetupScreenState extends State<BiometricSetupScreen> {
  bool _isCheckingBiometrics = true;
  bool _biometricsAvailable = false;

  /// Which sensor the device offers. Drives both the display label and the
  /// icon — never compare the label string, it is platform-dependent copy.
  _BiometricKind _biometricKind = _BiometricKind.generic;

  /// User-facing name of the sensor. "Face ID" / "Touch ID" are Apple
  /// trademarks and must never be shown on Android.
  String get _biometricType => switch (_biometricKind) {
    _BiometricKind.face =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'Face unlock'
          : 'Face ID',
    _BiometricKind.fingerprint =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'Fingerprint'
          : 'Touch ID',
    _BiometricKind.generic => 'Biometrics',
  };

  @override
  void initState() {
    super.initState();
    _checkBiometricAvailability();
  }

  Future<void> _checkBiometricAvailability() async {
    try {
      final biometricAuth = sl<BiometricAuthService>();
      final isAvailable = await biometricAuth.isAvailable();

      // No biometric hardware on this device — skip the step entirely rather
      // than showing a setup screen the user can't act on.
      if (!isAvailable) {
        if (mounted) context.go(AppRoutes.pinSetup);
        return;
      }

      var kind = _BiometricKind.generic;
      if (await biometricAuth.hasFaceId()) {
        kind = _BiometricKind.face;
      } else if (await biometricAuth.hasFingerprint()) {
        kind = _BiometricKind.fingerprint;
      }

      if (mounted) {
        setState(() {
          _biometricsAvailable = isAvailable;
          _biometricKind = kind;
          _isCheckingBiometrics = false;
        });
      }
    } catch (e) {
      // Treat a failed availability probe like "no biometrics" — skip ahead
      // so onboarding can't dead-end on this screen.
      if (mounted) context.go(AppRoutes.pinSetup);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              SizedBox(
                height: 40,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Enable $_biometricType',
                    style: MallowTheme.editorialSection,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Divider(color: context.mallowColors.dividerLight),
              const Spacer(),
              if (_isCheckingBiometrics)
                const MallowLoader()
              else ...[
                // Large face / fingerprint icon
                if (_biometricKind == _BiometricKind.face)
                  MallowSvgIcon(
                    'assets/icons/face_id.svg',
                    width: 92,
                    height: 92,
                    color: context.mallowColors.textSecondary,
                  )
                else
                  MallowSvgIcon(
                    'assets/icons/fingerprint.svg',
                    width: 92,
                    height: 92,
                    color: context.mallowColors.textPrimary,
                  ),
                const SizedBox(height: 24),
                Text(
                  'Unlock mallow with $_biometricType',
                  style: MallowTheme.uiBody,
                ),
                const SizedBox(height: 8),
                Text(
                  '$_biometricType data never leaves your device',
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ],
              const Spacer(),
              // Enable button
              if (_biometricsAvailable && !_isCheckingBiometrics) ...[
                MallowButton(
                  label: 'Enable $_biometricType',
                  onPressed: _enableBiometrics,
                  isFullWidth: true,
                ),
                const SizedBox(height: 16),
                // Skip link
                TextButton(
                  onPressed: _skipBiometrics,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Skip for now',
                    style: MallowTheme.uiIdentity.copyWith(
                      color: context.mallowColors.accent,
                    ),
                  ),
                ),
              ] else if (!_isCheckingBiometrics)
                MallowButton(
                  label: 'Continue',
                  onPressed: _skipBiometrics,
                  isFullWidth: true,
                ),
              const SizedBox(height: 20),
              // Caption
              Text(
                'You can change this anytime in settings',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enableBiometrics() async {
    try {
      final biometricAuth = sl<BiometricAuthService>();
      // The app-provided AppLock instance (a factory in DI — read the one
      // wired into the widget tree, not a fresh sl() instance).
      final appLock = context.read<AppLockBloc>();
      final result = await biometricAuth.authenticate(
        reason: 'Authenticate to enable $_biometricType',
      );

      if (result == BiometricAuthResult.success) {
        // Arm the app lock through the bloc, which is the single writer of the
        // biometric flag. AppLock booted into `noPinSet` (this install had no
        // wallet at cold start) and `_onLock` only transitions out of
        // `unlocked`, so the background-lock trigger is inert until something
        // arms it — this is the only arm point on the biometric-only path,
        // where the user goes on to skip the PIN.
        //
        // Deliberately not `init()`: that emits `locked`, which is correct when
        // the credential predates the session (`wallet_recovery_screen`) but
        // wrong here — the user authenticated seconds ago to enable this, so
        // it would re-challenge them mid-onboarding.
        appLock.add(const AppLockEvent.enableBiometric());

        if (mounted) {
          context.go(AppRoutes.pinSetup);
        }
      } else {
        if (mounted) {
          AppSnackBar.show(
            context,
            result.errorMessage ?? 'Authentication failed. Please try again.',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Failed to enable biometrics: $e');
      }
    }
  }

  void _skipBiometrics() {
    context.go(AppRoutes.pinSetup);
  }
}

/// The sensor the device exposes, independent of the platform-specific name
/// shown for it.
enum _BiometricKind { face, fingerprint, generic }
