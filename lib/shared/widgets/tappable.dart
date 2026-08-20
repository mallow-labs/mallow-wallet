import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tap_target_expander.dart';

/// The standard replacement for a bare `GestureDetector(onTap:)` in app code.
///
/// The app globally disables ink splash (`NoSplash`) without a replacement, so
/// plain `GestureDetector` tappables give the user no press feedback at all.
/// [Tappable] restores that feedback by briefly dimming its [child] while the
/// pointer is down (mirroring the number-pad key press pattern), and — unlike a
/// raw `GestureDetector` — exposes a proper button role to assistive tech.
///
/// Prefer this over `GestureDetector` for any interactive row, card, or nav
/// element that should feel pressable.
///
/// ```dart
/// Tappable(
///   onTap: () => open(),
///   semanticLabel: 'Settings',
///   child: const SettingsRow(),
/// )
/// ```
///
/// When [onTap] is null the widget is inert: the child renders at full opacity
/// with no gesture handling and no button semantics (i.e. a disabled state).
class Tappable extends StatefulWidget {
  const Tappable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    this.pressedOpacity = 0.55,
    this.enableHaptic = false,
    this.semanticLabel,
    this.semanticButton = true,
    this.minHitSize = kMinTapTarget,
    super.key,
  });

  final Widget child;

  /// Tap handler. When null the widget is disabled (no feedback, no gestures).
  final VoidCallback? onTap;

  /// Optional long-press handler.
  final VoidCallback? onLongPress;

  /// Hit-test behavior for the underlying gesture detector. Defaults to
  /// [HitTestBehavior.opaque] so the whole area (including padding) is tappable.
  final HitTestBehavior behavior;

  /// Opacity applied to [child] while the pointer is down.
  final double pressedOpacity;

  /// Whether to fire [HapticFeedback.selectionClick] on tap-up. Rows and cards
  /// usually don't need haptics, so this defaults to false.
  final bool enableHaptic;

  /// Accessibility label announced by screen readers.
  final String? semanticLabel;

  /// Whether to expose a button role to assistive tech when [onTap] is set.
  final bool semanticButton;

  /// Minimum hit-test extent per axis (see [TapTargetExpander]). The child's
  /// layout and paint are unaffected; only the tappable area grows. Pass null
  /// to disable expansion.
  final double? minHitSize;

  @override
  State<Tappable> createState() => _TappableState();
}

class _TappableState extends State<Tappable> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTapUp() {
    _setPressed(false);
    if (widget.enableHaptic) HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;

    Widget result = GestureDetector(
      behavior: widget.behavior,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _handleTapUp(),
      onTapCancel: () => _setPressed(false),
      child: AnimatedOpacity(
        opacity: _pressed ? widget.pressedOpacity : 1.0,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );

    if (widget.onTap != null && widget.semanticButton) {
      result = Semantics(
        button: true,
        label: widget.semanticLabel,
        child: result,
      );
    }

    final minHitSize = widget.minHitSize;
    if (minHitSize != null) {
      result = TapTargetExpander(minSize: minHitSize, child: result);
    }

    return result;
  }
}
