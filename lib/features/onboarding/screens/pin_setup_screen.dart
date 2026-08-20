import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/custom_number_pad.dart';
import '../../../shared/widgets/mallow_header.dart';

/// Screen for setting up a PIN code.
///
/// Users create a 6-digit PIN for app lock and transaction approval.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _pin = '';
  String? _firstPin;
  bool _isConfirming = false;
  String? _errorMessage;
  bool _biometricsEnabled = false;

  static const _pinLength = 6;

  @override
  void initState() {
    super.initState();
    _loadBiometricsState();
  }

  Future<void> _loadBiometricsState() async {
    final enabled = await sl<SecureWalletStorage>().loadBiometricEnabled();
    if (mounted) {
      setState(() => _biometricsEnabled = enabled);
    }
  }

  void _onBack() {
    if (_isConfirming) {
      setState(() {
        _firstPin = null;
        _pin = '';
        _isConfirming = false;
        _errorMessage = null;
      });
      return;
    }
    context.go(AppRoutes.biometricSetup);
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
              MallowHeader(
                title: _isConfirming ? 'Confirm your PIN' : 'Create a PIN',
                onBack: _onBack,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _isConfirming
                      ? 'Enter your PIN again to confirm'
                      : 'Create a 6-digit PIN to keep your wallet safe',
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Divider(color: context.mallowColors.dividerLight),
              const Spacer(),
              // PIN dots
              _buildPinDots(),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  style: MallowTheme.uiLabel.copyWith(
                    color: context.mallowColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              // Number pad
              CustomNumberPad(
                onNumberTap: _onNumberTap,
                onBackspace: _onDelete,
              ),
              const SizedBox(height: 80),
              if (_biometricsEnabled) ...[
                TextButton(
                  onPressed: _skipPin,
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
                const SizedBox(height: 20),
              ],
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

  Widget _buildPinDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLength, (index) {
        final isFilled = index < _pin.length;
        return Container(
          width: MallowTheme.pinDotSize,
          height: MallowTheme.pinDotSize,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled
                ? context.mallowColors.accent
                : context.mallowColors.dividerLight,
          ),
        );
      }),
    );
  }

  void _onNumberTap(String number) {
    if (_pin.length >= _pinLength) return;

    setState(() {
      _pin += number;
      _errorMessage = null;
    });

    if (_pin.length == _pinLength) {
      _onPinComplete();
    }
  }

  void _onDelete() {
    if (_pin.isEmpty) return;

    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorMessage = null;
    });
  }

  void _onPinComplete() {
    if (!_isConfirming) {
      // First entry - save and ask for confirmation
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _isConfirming = true;
      });
    } else {
      // Confirmation entry
      if (_pin == _firstPin) {
        _savePin();
      } else {
        setState(() {
          _pin = '';
          _errorMessage = 'PINs don\'t match. Try again.';
        });
      }
    }
  }

  Future<void> _savePin() async {
    try {
      // The app-provided AppLock instance (a factory in DI — read the one
      // wired into the widget tree, not a fresh sl() instance).
      final appLock = context.read<AppLockBloc>();

      // Store the PIN through the bloc, which is the single writer of the hash
      // and arms the lock in the same step. AppLock booted into `noPinSet`
      // (this install had no wallet at cold start) and `_onLock` only
      // transitions out of `unlocked`, so without this the background-lock
      // trigger stays inert for the whole first session.
      //
      // Deliberately not `storePinHash` + `init()`: `init()` emits `locked`,
      // which is right when the credential predates the session
      // (`wallet_recovery_screen` re-arms a restored wallet that way) but wrong
      // here — the user chose and confirmed this PIN seconds ago, so locking
      // would bounce them to the lock screen on the way out of onboarding.
      appLock.add(AppLockEvent.setPin(_pin));

      // Notify auth state that onboarding is complete
      final authNotifier = sl<AuthStateNotifier>();
      await authNotifier.onOnboardingCompleted();

      // Explicitly navigate to home - refreshListenable doesn't work reliably
      // with push() navigation stacks (see: github.com/flutter/flutter/issues/133985)
      if (mounted) {
        context.go('/');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Failed to save PIN: $e');
      }
    }
  }

  Future<void> _skipPin() async {
    final stillEnabled = await sl<SecureWalletStorage>().loadBiometricEnabled();
    if (!mounted) return;
    if (!stillEnabled) {
      setState(() {
        _biometricsEnabled = false;
        _errorMessage = 'Set a PIN to continue — biometrics are not enabled.';
      });
      return;
    }
    await sl<AuthStateNotifier>().onOnboardingCompleted();
    if (mounted) context.go('/');
  }
}
