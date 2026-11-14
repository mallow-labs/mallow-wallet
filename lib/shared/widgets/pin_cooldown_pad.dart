import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/security/pin_attempt_verifier.dart';
import '../theme/mallow_theme.dart';

/// Wraps a PIN pad on a surface behind the lock screen: while [cooldownUntil]
/// is ahead, the countdown shows above the pad and the pad takes no input.
///
/// Presentation only. [PinAttemptVerifier] refuses an attempt during a cooldown
/// whatever this widget shows.
class PinCooldownPad extends StatefulWidget {
  const PinCooldownPad({
    required this.cooldownUntil,
    required this.child,
    super.key,
  });

  final DateTime? cooldownUntil;
  final Widget child;

  @override
  State<PinCooldownPad> createState() => _PinCooldownPadState();
}

class _PinCooldownPadState extends State<PinCooldownPad> {
  Timer? _ticker;

  bool get _isCoolingDown {
    final until = widget.cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(PinCooldownPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cooldownUntil != widget.cooldownUntil) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!_isCoolingDown) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isCoolingDown) timer.cancel();
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final coolingDown = _isCoolingDown;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (coolingDown) ...[
          Text(
            pinCooldownMessage(widget.cooldownUntil!),
            textAlign: TextAlign.center,
            style: MallowTheme.uiLabel.copyWith(
              color: context.mallowColors.error,
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
        ],
        IgnorePointer(
          ignoring: coolingDown,
          child: Opacity(opacity: coolingDown ? 0.4 : 1.0, child: widget.child),
        ),
      ],
    );
  }
}
