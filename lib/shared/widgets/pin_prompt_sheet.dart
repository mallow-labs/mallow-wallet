import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/security/pin_attempt_verifier.dart';
import '../../core/security/secure_storage.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import 'custom_number_pad.dart';
import 'mallow_sheet.dart';
import 'pin_cooldown_pad.dart';

/// Modal bottom-sheet PIN entry behind the re-auth gate and the step-up auth
/// fallback. Resolves with `true` when the user enters the correct PIN, `false`
/// after three wrong attempts or when the store cannot answer, and `null` when
/// they dismiss it.
///
/// Every attempt goes through [PinAttemptVerifier], so it spends the same
/// persisted budget as the lock screen: reopening the sheet buys no new
/// guesses. While a cooldown runs the sheet stays up and says so, with the pad
/// frozen, and dismissing it is the way out.
class PinPromptSheet extends StatefulWidget {
  const PinPromptSheet._();

  /// Convenience to open the sheet and await its bool result.
  static Future<bool?> show(BuildContext context) {
    return showMallowSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.mallowColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      builder: (_) => const PinPromptSheet._(),
    );
  }

  @override
  State<PinPromptSheet> createState() => _PinPromptSheetState();
}

class _PinPromptSheetState extends State<PinPromptSheet>
    with SingleTickerProviderStateMixin {
  static const _pinLength = 6;
  static const _maxAttempts = 3;

  String _pin = '';
  bool _isError = false;
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;

  late final PinAttemptVerifier _verifier = PinAttemptVerifier(
    sl<SecureWalletStorage>(),
  );

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

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
    unawaited(_loadCooldown());
  }

  Future<void> _loadCooldown() async {
    final until = await _verifier.activeCooldown();
    if (!mounted || until == null) return;
    setState(() => _cooldownUntil = until);
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  void _onNumber(String digit) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin += digit;
      _isError = false;
    });
    if (_pin.length == _pinLength) _validatePin();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _isError = false;
    });
  }

  Future<void> _validatePin() async {
    final result = await _verifier.verify(_pin);
    if (!mounted) return;
    switch (result) {
      case PinVerified():
        Navigator.of(context).pop(true);
      case PinCheckUnavailable():
        Navigator.of(context).pop(false);
      case PinCoolingDown(:final until):
        _showRejection(cooldownUntil: until);
      case PinRejected(:final cooldownUntil?):
        _showRejection(cooldownUntil: cooldownUntil);
      case PinRejected():
        final attempts = _failedAttempts + 1;
        if (attempts >= _maxAttempts) {
          Navigator.of(context).pop(false);
          return;
        }
        _failedAttempts = attempts;
        _showRejection();
    }
  }

  void _showRejection({DateTime? cooldownUntil}) {
    setState(() {
      _isError = true;
      _pin = '';
      _cooldownUntil = cooldownUntil;
    });
    // Error haptic paired with the wrong-PIN shake. Fired here, once per
    // rejected attempt alongside the shake, never on rebuild.
    unawaited(HapticFeedback.heavyImpact());
    unawaited(_shakeController.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            Text('Enter your PIN', style: MallowTheme.editorialSection),
            const SizedBox(height: 8),
            Text(
              'Confirm your PIN to authorize this transaction.',
              textAlign: TextAlign.center,
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
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
            const SizedBox(height: 24),
            PinCooldownPad(
              cooldownUntil: _cooldownUntil,
              child: CustomNumberPad(
                onNumberTap: _onNumber,
                onBackspace: _onBackspace,
              ),
            ),
            const SizedBox(height: 24),
          ],
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
