import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/security/app_lock_bloc.dart';
import '../theme/mallow_theme.dart';
import 'custom_number_pad.dart';
import 'mallow_svg_icon.dart';

/// Full-screen lock overlay that requires PIN or biometric to dismiss.
///
/// Shown when the app returns from background if a PIN is set.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  static const _pinLength = 6;
  Timer? _cooldownTimer;

  // Haptic-firing guards. The BlocConsumer listener re-runs on every locked
  // state emission, so these track the last observed attempt to ensure the
  // error buzz fires once per genuinely new rejected attempt and the unlock
  // buzz fires once per unlock transition.
  int _lastFailedAttempts = 0;
  bool _lastWrongPinAttempt = false;
  bool _didFireUnlockHaptic = false;

  @override
  void initState() {
    super.initState();
    // Attempt biometric unlock when lock screen appears
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attemptBiometricUnlock();
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Trigger rebuild to update countdown display
      if (mounted) setState(() {});
    });
  }

  void _attemptBiometricUnlock() {
    final bloc = context.read<AppLockBloc>();
    final state = bloc.state;

    if (state is AppLockStateLocked && state.biometricEnabled) {
      bloc.add(const AppLockEvent.unlockWithBiometric());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AppLockBloc, AppLockState>(
      listener: (context, state) {
        if (state is AppLockStateUnlocked) {
          // Subtle success haptic paired with the lock screen dismissing.
          // Covers both PIN and biometric unlock (both emit Unlocked).
          // Guarded so it fires once per unlock transition.
          if (!_didFireUnlockHaptic) {
            _didFireUnlockHaptic = true;
            HapticFeedback.mediumImpact();
          }
        }
        // Reset PIN when there's a wrong attempt
        if (state is AppLockStateLocked && state.wrongPinAttempt) {
          setState(() => _pin = '');
          // Error haptic paired with the wrong-PIN visual (red dots + retry
          // message). Fire only on a genuinely new rejected attempt — the
          // failed count increased, or wrongPinAttempt just flipped true (a
          // cooldown-rejected try) — so re-emitted locked states (e.g. a
          // cancelled biometric prompt) don't re-buzz.
          final isNewAttempt =
              state.failedAttempts != _lastFailedAttempts ||
              !_lastWrongPinAttempt;
          if (isNewAttempt) HapticFeedback.heavyImpact();
        }
        // Start cooldown timer when locked out
        if (state is AppLockStateLocked && state.cooldownUntil != null) {
          _startCooldownTimer();
        }
        if (state is AppLockStateLocked) {
          _lastFailedAttempts = state.failedAttempts;
          _lastWrongPinAttempt = state.wrongPinAttempt;
          // Re-arm the unlock haptic so a later unlock (after a relock while
          // this widget is still mounted) buzzes again.
          _didFireUnlockHaptic = false;
        }
      },
      builder: (context, state) {
        final locked = state is AppLockStateLocked ? state : null;
        final hasPin = locked?.hasPin ?? false;
        final biometricEnabled = locked?.biometricEnabled ?? false;
        final biometricAttempting = locked?.biometricAttempting ?? false;

        // Default to the privacy-style blur whenever the OS biometric
        // prompt is in flight or the user has no PIN. This avoids a flash
        // of PIN UI on resume, and keeps the biometric-only unlock path
        // free of a number pad that can't accept input anyway.
        if (biometricAttempting || !hasPin) {
          return _LockBlurView(
            onBiometricRetry: biometricEnabled && !biometricAttempting
                ? _attemptBiometricUnlock
                : null,
          );
        }

        final wrongPinAttempt = locked?.wrongPinAttempt ?? false;
        final failedAttempts = locked?.failedAttempts ?? 0;
        final cooldownUntil = locked?.cooldownUntil;
        final isInCooldown =
            cooldownUntil != null && DateTime.now().isBefore(cooldownUntil);

        return Material(
          color: context.mallowColors.bgPrimary,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(MallowTheme.spacingLg),
              child: Column(
                children: [
                  const Spacer(),
                  _buildLogo(),
                  const SizedBox(height: MallowTheme.spacingXl),
                  Text(
                    'Welcome back',
                    style: MallowTheme.editorialSection,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  Text(
                    'Enter your PIN to unlock',
                    style: MallowTheme.uiMeta.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: MallowTheme.spacingXl),
                  _buildPinDots(wrongPinAttempt),
                  if (isInCooldown) ...[
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      _formatCooldownMessage(cooldownUntil),
                      style: MallowTheme.uiLabel.copyWith(
                        color: context.mallowColors.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ] else if (wrongPinAttempt) ...[
                    const SizedBox(height: MallowTheme.spacingMd),
                    Text(
                      failedAttempts >= 3
                          ? 'Wrong PIN. ${5 - (failedAttempts % 5)} attempts remaining.'
                          : 'Wrong PIN. Please try again.',
                      style: MallowTheme.uiLabel.copyWith(
                        color: context.mallowColors.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: MallowTheme.spacingXl),
                  IgnorePointer(
                    ignoring: isInCooldown,
                    child: Opacity(
                      opacity: isInCooldown ? 0.4 : 1.0,
                      child: CustomNumberPad(
                        onNumberTap: _onNumberTap,
                        onBackspace: _onDelete,
                      ),
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  if (biometricEnabled)
                    GestureDetector(
                      onTap: _attemptBiometricUnlock,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: MallowTheme.spacingLg,
                          vertical: MallowTheme.spacingMd,
                        ),
                        decoration: BoxDecoration(
                          color: context.mallowColors.accent.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusFull,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MallowSvgIcon(
                              'assets/icons/fingerprint.svg',
                              color: context.mallowColors.accent,
                            ),
                            const SizedBox(width: MallowTheme.spacingSm),
                            Text(
                              'Use biometrics',
                              style: MallowTheme.uiBody.copyWith(
                                color: context.mallowColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogo() {
    // Bare mallow mark, same treatment as the welcome and recovery screens:
    // black on light, inverted on dark so it stays legible in both themes.
    return SvgPicture.asset(
      'assets/icons/mallow_icon.svg',
      width: 41,
      colorFilter: ColorFilter.mode(
        context.mallowColors.textPrimary,
        BlendMode.srcIn,
      ),
    );
  }

  Widget _buildPinDots(bool hasError) {
    final errorColor = context.mallowColors.error;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLength, (index) {
        final isFilled = index < _pin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 16,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled
                ? (hasError ? errorColor : context.mallowColors.accent)
                : Colors.transparent,
            border: Border.all(
              color: hasError ? errorColor : context.mallowColors.accent,
              width: 2,
            ),
          ),
        );
      }),
    );
  }

  String _formatCooldownMessage(DateTime cooldownUntil) {
    final remaining = cooldownUntil.difference(DateTime.now());
    if (remaining.isNegative) return 'You can try again now.';

    if (remaining.inMinutes >= 1) {
      final mins = remaining.inMinutes;
      final secs = remaining.inSeconds % 60;
      return 'Too many failed attempts.\nTry again in ${mins}m ${secs}s.';
    }
    return 'Too many failed attempts.\nTry again in ${remaining.inSeconds}s.';
  }

  void _onNumberTap(String number) {
    if (_pin.length >= _pinLength) return;

    setState(() => _pin += number);

    if (_pin.length == _pinLength) {
      _onPinComplete();
    }
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _onPinComplete() {
    context.read<AppLockBloc>().add(AppLockEvent.unlockWithPin(_pin));
  }
}

/// Blurred placeholder shown while the OS biometric prompt is pending or when
/// the user has biometric-only auth (no PIN). Visually mirrors the privacy
/// blur used for app-switcher snapshots so the transition between the two is
/// seamless.
class _LockBlurView extends StatelessWidget {
  const _LockBlurView({this.onBiometricRetry});

  final VoidCallback? onBiometricRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: ColoredBox(
          color: context.mallowColors.bgPrimary.withValues(alpha: 0.6),
          child: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: SvgPicture.asset(
                    'assets/icons/mallow_icon.svg',
                    width: 42,
                    height: 42,
                    colorFilter: ColorFilter.mode(
                      context.mallowColors.accent,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                if (onBiometricRetry != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: MallowTheme.spacingXl,
                    child: Center(
                      child: GestureDetector(
                        onTap: onBiometricRetry,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: MallowTheme.spacingLg,
                            vertical: MallowTheme.spacingMd,
                          ),
                          decoration: BoxDecoration(
                            color: context.mallowColors.accent.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(
                              MallowTheme.radiusFull,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MallowSvgIcon(
                                'assets/icons/fingerprint.svg',
                                color: context.mallowColors.accent,
                              ),
                              const SizedBox(width: MallowTheme.spacingSm),
                              Text(
                                'Use biometrics',
                                style: MallowTheme.uiBody.copyWith(
                                  color: context.mallowColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
