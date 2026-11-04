import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/mallow_theme.dart';

/// A secondary button that confirms only after being held for
/// [holdDuration]: a fill sweeps across while held, with light haptic ticks,
/// and releasing early cancels. [onConfirmed] fires once, on completion, while
/// the finger is still down.
///
/// The hold is friction, not a security control: it slows a reflexive tap on
/// a risky request. Screen-reader users get a direct semantics action instead,
/// and reduced motion drops the fill (the hold itself stays).
class HoldToApproveButton extends StatefulWidget {
  const HoldToApproveButton({
    required this.label,
    required this.onConfirmed,
    this.accessibilityActionLabel = 'Approve',
    this.holdDuration = const Duration(milliseconds: 1200),
    super.key,
  });

  final String label;
  final VoidCallback onConfirmed;

  /// Name of the custom semantics action that confirms without holding.
  final String accessibilityActionLabel;
  final Duration holdDuration;

  @override
  State<HoldToApproveButton> createState() => _HoldToApproveButtonState();
}

class _HoldToApproveButtonState extends State<HoldToApproveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  )..addStatusListener(_onStatus);
  bool _holding = false;
  bool _confirmed = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _progress.addListener(_tick);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _tick() {
    if (!_holding) return;
    final quarter = (_progress.value * 4).floor();
    if (quarter > _ticks && quarter < 4) {
      _ticks = quarter;
      HapticFeedback.lightImpact();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _holding) _confirm();
  }

  void _confirm() {
    if (_confirmed) return;
    _confirmed = true;
    HapticFeedback.mediumImpact();
    widget.onConfirmed();
  }

  void _start() {
    if (_confirmed) return;
    setState(() => _holding = true);
    _ticks = 0;
    _progress.forward(from: 0);
  }

  void _release() {
    if (!_holding) return;
    setState(() => _holding = false);
    if (_confirmed) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = 0;
    } else {
      _progress.animateBack(0, duration: const Duration(milliseconds: 180));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      hint: 'Press and hold to confirm',
      onLongPress: _confirm,
      customSemanticsActions: {
        CustomSemanticsAction(label: widget.accessibilityActionLabel): _confirm,
      },
      excludeSemantics: true,
      child: GestureDetector(
        excludeFromSemantics: true,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: colors.bgSurface,
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
            border: Border.all(color: colors.divider, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (!still)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _progress,
                    builder: (context, _) => FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _progress.value,
                      child: ColoredBox(
                        color: colors.error.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                  vertical: MallowTheme.spacingMd,
                ),
                child: Text(
                  still && _holding ? 'Keep holding…' : widget.label,
                  textAlign: TextAlign.center,
                  // Same type as MallowButton, so the pair reads as one set.
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
