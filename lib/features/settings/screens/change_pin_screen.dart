import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/custom_number_pad.dart';
import '../widgets/settings_page_scaffold.dart';

enum _Step { currentPin, newPin, confirmPin }

/// Change PIN flow — 3-step multi-screen flow within a single widget.
///
/// Step 1: Enter current PIN (validates against stored PIN).
/// Step 2: Enter new PIN.
/// Step 3: Confirm new PIN, then save securely.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.currentPin;
  String _pin = '';
  String _newPin = '';
  bool _isError = false;
  bool _ready = false;
  bool _hasExistingPin = false;

  final _focusNode = FocusNode();

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  static const _pinLength = 6;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation =
        TweenSequence([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 1),
          TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: 8.0, end: -8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
        ]).animate(
          CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut),
        );
    _initStep();
  }

  Future<void> _initStep() async {
    final hasPinSet = await sl<SecureWalletStorage>().hasPin();
    if (!mounted) return;
    setState(() {
      _hasExistingPin = hasPinSet;
      _step = hasPinSet ? _Step.currentPin : _Step.newPin;
      _ready = true;
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final char = event.character;
    if (char != null && RegExp(r'^[0-9]$').hasMatch(char)) {
      _onNumber(char);
    } else if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _onBackspace();
    }
  }

  String get _title {
    return switch (_step) {
      _Step.currentPin => 'Enter your current PIN',
      _Step.newPin => 'Enter a new PIN',
      _Step.confirmPin => 'Confirm your new PIN',
    };
  }

  void _onNumber(String digit) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin += digit;
      _isError = false;
    });
    if (_pin.length == _pinLength) _onComplete();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _isError = false;
    });
  }

  Future<void> _onComplete() async {
    switch (_step) {
      case _Step.currentPin:
        await _validateCurrentPin();
      case _Step.newPin:
        // Store new PIN and move to confirm step
        _newPin = _pin;
        setState(() {
          _pin = '';
          _step = _Step.confirmPin;
        });
      case _Step.confirmPin:
        await _confirmAndSave();
    }
  }

  Future<void> _validateCurrentPin() async {
    final storage = sl<SecureWalletStorage>();
    if (!await storage.hasPin()) {
      // No PIN set — allow user through (e.g. PIN was previously disabled)
      setState(() {
        _pin = '';
        _step = _Step.newPin;
      });
      return;
    }
    if (await storage.verifyPin(_pin)) {
      setState(() {
        _pin = '';
        _step = _Step.newPin;
      });
    } else {
      _triggerError();
    }
  }

  Future<void> _confirmAndSave() async {
    if (_pin == _newPin) {
      await sl<SecureWalletStorage>().storePinHash(_pin);
      if (mounted) {
        AppSnackBar.show(context, 'PIN changed successfully.');
        context.pop();
      }
    } else {
      _triggerError();
    }
  }

  void _triggerError() {
    setState(() {
      _isError = true;
      _pin = '';
    });
    _shakeController.forward(from: 0);
  }

  Future<void> _confirmTurnOffPin() async {
    // At least one lock must remain — block removing the PIN unless biometrics
    // are enabled to take over (mirrors disabling biometrics requiring a PIN).
    final biometricsEnabled = await sl<SecureWalletStorage>()
        .loadBiometricEnabled();
    if (!mounted) return;
    if (!biometricsEnabled) {
      await _showEnableBiometricsFirstDialog();
      return;
    }
    final confirmed = await showConfirmSheet(
      context,
      title: 'Turn off PIN?',
      message:
          'Removing your PIN reduces your wallet security. '
          'Are you sure you want to turn it off?',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (confirmed == true && mounted) {
      await sl<SecureWalletStorage>().deletePin();
      if (mounted) {
        AppSnackBar.show(context, 'PIN turned off.');
        context.pop();
      }
    }
  }

  Future<bool?> _showEnableBiometricsFirstDialog() {
    return showConfirmSheet(
      context,
      title: 'Enable biometrics first',
      message:
          'You need biometric authentication enabled before you can turn off '
          'your PIN — otherwise the app would have no lock.',
      confirmLabel: 'Got it',
      cancelLabel: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showTurnOff = _hasExistingPin && _step != _Step.currentPin;

    if (!_ready) {
      return const SettingsPageScaffold(
        title: 'Change PIN',
        child: SizedBox.shrink(),
      );
    }

    return SettingsPageScaffold(
      title: 'Change PIN',
      onBack: () {
        if (_step == _Step.currentPin || _step == _Step.newPin) {
          if (context.canPop()) context.pop();
        } else {
          setState(() {
            _step = _Step.newPin;
            _pin = '';
            _isError = false;
          });
        }
      },
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Text(_title, style: MallowTheme.editorialSection),
              const SizedBox(height: 20),
              Divider(
                height: 1,
                thickness: 1,
                color: context.mallowColors.dividerLight,
              ),
              const Spacer(),
              // PIN dots with shake animation
              AnimatedBuilder(
                animation: _shakeAnimation,
                builder: (context, child) => Transform.translate(
                  offset: Offset(_shakeAnimation.value, 0),
                  child: child,
                ),
                child: _PinDots(
                  length: _pinLength,
                  filled: _pin.length,
                  isError: _isError,
                ),
              ),
              const SizedBox(height: 32),
              CustomNumberPad(
                onNumberTap: _onNumber,
                onBackspace: _onBackspace,
              ),
              const SizedBox(height: 32),
              if (showTurnOff) ...[
                Center(
                  child: TextButton(
                    onPressed: _confirmTurnOffPin,
                    child: Text(
                      'Turn off PIN',
                      style: MallowTheme.uiBody.copyWith(
                        color: context.mallowColors.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'You can change this anytime in settings',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ),
              ] else
                const SizedBox(height: 48),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.length,
    required this.filled,
    required this.isError,
  });

  final int length;
  final int filled;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (index) {
        final isFilled = index < filled;
        return Container(
          width: MallowTheme.pinDotSize,
          height: MallowTheme.pinDotSize,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isError && isFilled
                ? context.mallowColors.error
                : isFilled
                ? context.mallowColors.accent
                : context.mallowColors.dividerLight,
          ),
        );
      }),
    );
  }
}
