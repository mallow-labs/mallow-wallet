import 'package:flutter/material.dart';

/// mallow design system color tokens with light/dark variants.
///
/// Access via `context.mallowColors` in any widget with a [BuildContext].
/// Registered as a [ThemeExtension] on both [lightTheme] and [darkTheme].
class MallowColors extends ThemeExtension<MallowColors> {
  const MallowColors({
    required this.surfaceMuted,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.dividerLight,
    required this.bgTransparent,
    required this.bgSurface,
    required this.bgPrimary,
    required this.accent,
    required this.textOnAccent,
    required this.error,
    required this.positive,
    required this.negative,
    required this.warning,
    required this.shadow,
    required this.scrim,
  });

  final Color surfaceMuted;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color divider;
  final Color dividerLight;
  final Color bgTransparent;

  /// Screen/base background surface color.
  final Color bgSurface;

  /// Primary background color (nav bar, drawer).
  final Color bgPrimary;

  /// Primary accent color — adapts to light/dark mode.
  final Color accent;

  /// Text color for use on accent-colored backgrounds.
  final Color textOnAccent;

  /// Semantic error state color (destructive actions, validation failures).
  final Color error;

  /// Directional color for incoming transfers, gains, and price-up indicators.
  final Color positive;

  /// Directional color for outgoing transfers, losses, and price-down indicators.
  final Color negative;

  /// Cautionary state color for non-error warnings: high slippage, price
  /// impact, security advisories.
  final Color warning;

  /// Base color for box shadows. Apply alpha at the call site.
  final Color shadow;

  /// Modal/sheet barrier overlay (already includes alpha).
  final Color scrim;

  /// Light mode palette — warm off-white base.
  static const light = MallowColors(
    surfaceMuted: Color(0xFFF1EFEB),
    textPrimary: Color(0xFF121212),
    textSecondary: Color(0xFF9A9A9A),
    textTertiary: Color(0xFFC4C4C4),
    divider: Color(0xFFDAD6D0),
    dividerLight: Color(0xFFE6E3DE),
    bgTransparent: Color(0x66F1EFEB),
    bgSurface: Color(0xFFFFFFFF),
    bgPrimary: Color(0xFFFAF9F7),
    // Darker salmon for light mode — the lighter 0xFFFF9F8F (dark-mode accent)
    // washes out on the cream background.
    accent: Color(0xFFEF9080),
    textOnAccent: Color(0xFF1A1A1A),
    error: Color(0xFFAF3D3D),
    // Lighter, softer green for light mode — the deeper 0xFF3FAE5D (dark-mode
    // positive) reads heavy on the cream/white surfaces.
    positive: Color(0xFF5FC07E),
    negative: Color(0xFFAF3D3D),
    warning: Color(0xFFD68A2A),
    shadow: Color(0xFF66666E),
    scrim: Color(0x66000000),
  );

  /// Dark mode palette — from Figma dark mode design tokens.
  static const dark = MallowColors(
    surfaceMuted: Color(0xFF202020),
    textPrimary: Color(0xFFF2F2F2),
    textSecondary: Color(0xFFA1A1A1),
    // Lightened from 0xFF6F6F6F (3.7:1 on 0xFF121212, fails AA) to clear
    // WCAG AA 4.5:1 for body text — 0xFF7E7E7E computes to ~4.6:1.
    textTertiary: Color(0xFF7E7E7E),
    divider: Color(0xFF333333),
    dividerLight: Color(0xFF2A2A2A),
    bgTransparent: Color(0x66121212),
    bgSurface: Color(0xFF1A1A1A),
    bgPrimary: Color(0xFF121212),
    accent: Color(0xFFFF9F8F),
    textOnAccent: Color(0xFF1A1A1A),
    error: Color(0xFFC94444),
    positive: Color(0xFF3FAE5D),
    negative: Color(0xFFC94444),
    warning: Color(0xFFE6A85A),
    shadow: Color(0xFF000000),
    scrim: Color(0x99000000),
  );

  @override
  MallowColors copyWith({
    Color? surfaceMuted,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? divider,
    Color? dividerLight,
    Color? bgTransparent,
    Color? bgSurface,
    Color? bgPrimary,
    Color? accent,
    Color? textOnAccent,
    Color? error,
    Color? positive,
    Color? negative,
    Color? warning,
    Color? shadow,
    Color? scrim,
  }) {
    return MallowColors(
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      divider: divider ?? this.divider,
      dividerLight: dividerLight ?? this.dividerLight,
      bgTransparent: bgTransparent ?? this.bgTransparent,
      bgSurface: bgSurface ?? this.bgSurface,
      bgPrimary: bgPrimary ?? this.bgPrimary,
      accent: accent ?? this.accent,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      error: error ?? this.error,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      warning: warning ?? this.warning,
      shadow: shadow ?? this.shadow,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  MallowColors lerp(ThemeExtension<MallowColors>? other, double t) {
    if (other is! MallowColors) return this;
    return MallowColors(
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      dividerLight: Color.lerp(dividerLight, other.dividerLight, t)!,
      bgTransparent: Color.lerp(bgTransparent, other.bgTransparent, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgPrimary: Color.lerp(bgPrimary, other.bgPrimary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      error: Color.lerp(error, other.error, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

/// BuildContext extension for ergonomic mallow theme color access.
extension MallowColorsX on BuildContext {
  /// Access mallow design system colors, adapting automatically to light/dark mode.
  ///
  /// Falls back to [MallowColors.light] if the extension is not registered
  /// (should not happen in production).
  MallowColors get mallowColors =>
      Theme.of(this).extension<MallowColors>() ?? MallowColors.light;
}
