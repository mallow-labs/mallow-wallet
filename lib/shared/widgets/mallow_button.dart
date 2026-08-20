import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'loading_indicator.dart';
import 'mallow_svg_icon.dart';

/// Button variants for mallow design system.
enum MallowButtonVariant {
  /// Primary filled button with accent background
  primary,

  /// Secondary outlined button
  secondary,

  /// Text-only button
  text,

  /// Destructive action — filled button with the semantic error color
  /// background (e.g. burn artwork, reset app).
  danger,
}

/// Button sizes for mallow design system.
enum MallowButtonSize { small, medium, large }

/// A styled button following mallow design system.
///
/// Supports three variants:
/// - Primary: Filled button with accent color
/// - Secondary: Outlined button
/// - Text: Text-only button
class MallowButton extends StatelessWidget {
  const MallowButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.variant = MallowButtonVariant.primary,
    this.size = MallowButtonSize.medium,
    this.icon,
    this.svgAsset,
    this.svgUseOriginalColors = false,
    this.foregroundColor,
    this.isLoading = false,
    this.isFullWidth = false,
    this.enabled = true,
    this.onDisabledTap,
  });

  final String label;
  final VoidCallback? onPressed;
  final MallowButtonVariant variant;
  final MallowButtonSize size;
  final IconData? icon;
  final String? svgAsset;
  final bool svgUseOriginalColors;

  /// Overrides the foreground color (text, icon, and outline) for this button.
  final Color? foregroundColor;
  final bool isLoading;
  final bool isFullWidth;
  final bool enabled;

  /// Tap handler used while [enabled] is false — lets a greyed-out button
  /// explain itself (e.g. "Swap is only available on Solana") instead of going
  /// dead. Deliberately not consulted while [isLoading]: a button mid-flight is
  /// busy, not unavailable, and has nothing to explain.
  final VoidCallback? onDisabledTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final effectiveOnPressed = enabled && !isLoading ? onPressed : null;

    final button = switch (variant) {
      MallowButtonVariant.primary => _buildPrimary(effectiveOnPressed, colors),
      MallowButtonVariant.secondary => _buildSecondary(
        effectiveOnPressed,
        colors,
      ),
      MallowButtonVariant.text => _buildText(effectiveOnPressed, colors),
      MallowButtonVariant.danger => _buildDanger(
        effectiveOnPressed,
        colors,
        Theme.of(context).brightness == Brightness.light,
      ),
    };

    Widget pressable = _PressScale(
      enabled: effectiveOnPressed != null,
      child: button,
    );

    // The underlying Material button swallows pointer events once its
    // `onPressed` is null, so the explanation tap has to be caught above it.
    if (!enabled && !isLoading && onDisabledTap != null) {
      pressable = GestureDetector(
        onTap: onDisabledTap,
        behavior: HitTestBehavior.opaque,
        child: pressable,
      );
    }

    if (isFullWidth) {
      return SizedBox(width: double.infinity, child: pressable);
    }

    return pressable;
  }

  Widget _buildPrimary(VoidCallback? onPressed, MallowColors colors) {
    final fg = foregroundColor ?? MallowColors.light.textPrimary;
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: fg,
        disabledBackgroundColor: colors.textTertiary,
        disabledForegroundColor: fg.withValues(alpha: 0.7),
        padding: _padding,
        minimumSize: _minimumSize,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
        elevation: 0,
      ),
      child: _buildContent(fg),
    );
  }

  Widget _buildSecondary(VoidCallback? onPressed, MallowColors colors) {
    final enabledFg = foregroundColor ?? colors.accent;
    // Grey the label + border together when disabled — `_buildContent`
    // paints the text from this `fg`, so without dimming it here a disabled
    // secondary button keeps full-colour text and only the border greys out,
    // making it still look tappable.
    final fg = onPressed != null ? enabledFg : colors.textTertiary;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.textPrimary,
        disabledForegroundColor: colors.textTertiary,
        padding: _padding,
        minimumSize: _minimumSize,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
        side: BorderSide(color: fg, width: 1.5),
      ),
      child: _buildContent(fg),
    );
  }

  Widget _buildDanger(
    VoidCallback? onPressed,
    MallowColors colors,
    bool isLight,
  ) {
    // White text reads on the red fill in light mode; the default dark
    // textOnAccent washes into the darker error red on the cream background.
    final fg =
        foregroundColor ?? (isLight ? Colors.white : colors.textOnAccent);
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.error,
        foregroundColor: fg,
        disabledBackgroundColor: colors.textTertiary,
        disabledForegroundColor: fg.withValues(alpha: 0.7),
        padding: _padding,
        minimumSize: _minimumSize,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
        elevation: 0,
      ),
      child: _buildContent(fg),
    );
  }

  Widget _buildText(VoidCallback? onPressed, MallowColors colors) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        disabledForegroundColor: colors.textTertiary,
        padding: _padding,
        minimumSize: _minimumSize,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
        ),
      ),
      child: _buildContent(colors.accent),
    );
  }

  Widget _buildContent(Color color) {
    if (isLoading) {
      // Keep the label laid out (but invisible) beneath the spinner so the
      // button's intrinsic width doesn't collapse toward `minimumSize` and
      // shift surrounding layout the moment loading commits.
      return Stack(
        alignment: Alignment.center,
        children: [
          Opacity(opacity: 0, child: _buildLabel(color)),
          // Match the button's resolved foreground so the loader tracks
          // the label colour (incl. danger's white text in light mode).
          MallowLoader(size: _iconSize, color: color),
        ],
      );
    }

    return _buildLabel(color);
  }

  Widget _buildLabel(Color color) {
    if (icon != null || svgAsset != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (svgAsset != null)
            MallowSvgIcon(
              svgAsset!,
              width: _iconSize,
              height: _iconSize,
              color: color,
              useOriginalColors: svgUseOriginalColors,
            )
          else
            Icon(icon, size: _iconSize),
          const SizedBox(width: MallowTheme.spacingSm),
          Text(label, style: _textStyle.copyWith(color: color)),
        ],
      );
    }

    return Text(label, style: _textStyle.copyWith(color: color));
  }

  EdgeInsetsGeometry get _padding => switch (size) {
    MallowButtonSize.small => const EdgeInsets.symmetric(
      horizontal: MallowTheme.spacingMd,
      vertical: MallowTheme.spacingSm,
    ),
    MallowButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: MallowTheme.spacingLg,
      vertical: MallowTheme.spacingMd,
    ),
    MallowButtonSize.large => const EdgeInsets.symmetric(
      horizontal: MallowTheme.spacingXl,
      vertical: MallowTheme.spacingLg,
    ),
  };

  Size get _minimumSize => switch (size) {
    MallowButtonSize.small => const Size(64, 48),
    MallowButtonSize.medium => const Size(88, 48),
    MallowButtonSize.large => const Size(120, 48),
  };

  double get _iconSize => switch (size) {
    MallowButtonSize.small => 16,
    MallowButtonSize.medium => 20,
    MallowButtonSize.large => 24,
  };

  TextStyle get _textStyle => switch (size) {
    MallowButtonSize.small => MallowTheme.uiLabel.copyWith(
      fontWeight: FontWeight.w600,
    ),
    MallowButtonSize.medium => MallowTheme.uiBody,
    // 17px identity style at semibold — an on-scale step with the correct
    // line-height, rather than an off-scale 18px on the body height.
    MallowButtonSize.large => MallowTheme.uiIdentity.copyWith(
      fontWeight: FontWeight.w600,
    ),
  };
}

/// Wraps a button in a subtle press-down scale (0.97) that springs back on
/// release, giving tactile feedback while preserving the no-ripple aesthetic.
/// Driven by raw pointer events so it works regardless of the wrapped button's
/// gesture handling. Disabled buttons don't scale.
class _PressScale extends StatefulWidget {
  const _PressScale({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  // Release the press when the pointer drags outside the button bounds, so a
  // slide-away cancels the scale rather than firing on release — matching
  // Tappable's cancel-on-drag-away behavior.
  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pressed) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final local = event.localPosition;
    final outside =
        local.dx < 0 ||
        local.dy < 0 ||
        local.dx > size.width ||
        local.dy > size.height;
    if (outside) _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
