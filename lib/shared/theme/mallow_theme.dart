import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'mallow_colors.dart';
export 'mallow_colors.dart';

class MallowTheme {
  const MallowTheme._();

  // ==========================================================================
  // COLORS — static brand constants (theme-invariant)
  // For adaptive colors use context.mallowColors instead.
  // ==========================================================================

  /// Primary accent color - coral (brand, same in light and dark)
  static const accent = Color(0xFFFF9F8F);

  /// Accent variant (legacy alias, kept for compatibility)
  static const accentDark = Color(0xFFFF9F8F);

  /// Darker salmon used as the accent in light mode — the standard [accent]
  /// washes out on the cream light background. Mirrors
  /// [MallowColors.light.accent]; prefer `context.mallowColors.accent`.
  static const accentLightMode = Color(0xFFEF9080);

  /// Text color for use on accent-colored surfaces.
  static const textOnAccent = Color(0xFF1A1A1A);

  // Light-mode aliases kept for existing usages that have not yet been migrated.
  // Prefer context.mallowColors.X for new code.
  static const background = Color(0xFFFAF9F7);
  static const surface = Colors.white;
  static const textPrimary = Color(0xFF121212);
  static const textSecondary = Color(0xFF9A9A9A);
  static const divider = Color(0xFFDAD6D0);
  static const inactive = Color(0xFF9E9E9E);
  static const surfaceMuted = Color(0xFFF1EFEB);
  static const textTertiary = Color(0xFFC4C4C4);
  static const bgTransparent = Color(0x66F1EFEB);
  static const dividerLight = Color(0xFFE6E3DE);

  // ==========================================================================
  // SPACING (from Figma layout measurements)
  // ==========================================================================

  static const double spacingXs = 4;
  static const double spacingSm = 8;
  static const double spacing12 = 12;
  static const double spacingMd = 12;
  static const double spacing20 = 20;
  static const double spacingLg = 24;
  static const double spacing26 = 26;
  static const double spacingXl = 32;

  /// Popup/modal border radius
  static const double popupRadius = 12.0;

  /// Circular button size (for number pad)
  static const double circularButtonSize = 72.0;

  /// PIN dot indicator size
  static const double pinDotSize = 12.0;

  // ==========================================================================
  // BORDER RADIUS (from Figma design tokens)
  // ==========================================================================

  /// Primary radius for cards, thumbnails (4px)
  static const double radiusPrimary = 4;

  /// Small radius (legacy)
  static const double radiusSm = 8;

  /// Medium radius (legacy)
  static const double radiusMd = 12;

  /// Large radius (legacy)
  static const double radiusLg = 16;

  /// Circular/pill radius (69px from Figma)
  static const double radiusCircular = 69;

  /// Full radius for perfect circles
  static const double radiusFull = 999;

  // ==========================================================================
  // SHADOWS (from Figma effects)
  // ==========================================================================

  /// Shadow for bottom navigation bar
  static List<BoxShadow> navBarShadow(BuildContext context) => [
    BoxShadow(
      color: context.mallowColors.shadow.withValues(alpha: 0.15),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  /// Shadow for FAB button
  static List<BoxShadow> fabShadow(BuildContext context) => [
    BoxShadow(
      color: context.mallowColors.shadow.withValues(alpha: 0.16),
      blurRadius: 24,
      offset: const Offset(0, 4),
    ),
  ];

  // ==========================================================================
  // ANIMATION
  // ==========================================================================

  /// Standard curve for sheet enter transitions.
  static const Curve sheetCurve = Curves.easeOutCubic;

  /// Standard duration for sheet enter transitions.
  static const Duration sheetDuration = Duration(milliseconds: 240);

  /// Minimum time a sheet swallows taps after it starts displaying, even once
  /// the enter transition has finished. Guards against misclicks on an option
  /// that lands under the finger right as the sheet settles.
  static const Duration sheetTapGuardMinimum = Duration(milliseconds: 500);

  /// Page push transition for every platform: a pure slide with no opacity
  /// fade. Replaces Android's default [ZoomPageTransitionsBuilder] (which fades
  /// the incoming/outgoing screens) so pushing a screen — e.g. the profile
  /// page — slides cleanly without dimming.
  static const PageTransitionsTheme pageTransitionsTheme = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
    },
  );

  // ==========================================================================
  // TYPOGRAPHY — Tracking constants (letter-spacing em multipliers)
  // Apply as: fontSize * trackingTight  (Flutter uses px, not em)
  // ==========================================================================

  /// -0.025em — display headings
  static const double trackingTight = -0.025;

  /// 0 — default body/UI
  static const double trackingNormal = 0;

  /// +0.04em — uppercase labels
  static const double trackingWide = 0.04;

  // ==========================================================================
  // TYPOGRAPHY — Editorial (Newsreader, italic only)
  // Color-free: inherits from DefaultTextStyle / Theme for dark mode support.
  // ==========================================================================

  /// Hero headings — Newsreader SemiBold Italic 32px
  static TextStyle get editorialHero => GoogleFonts.newsreader(
    fontStyle: FontStyle.italic,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 43.5 / 32,
    letterSpacing: 32 * trackingTight,
  );

  /// Section headers — Newsreader Medium Italic 20px
  static TextStyle get editorialSection => GoogleFonts.newsreader(
    fontStyle: FontStyle.italic,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 28.0 / 20,
  );

  /// Subheadings — Newsreader Italic 17px
  static TextStyle get editorialSubhead => GoogleFonts.newsreader(
    fontStyle: FontStyle.italic,
    fontSize: 17,
    fontWeight: FontWeight.w400,
    height: 24.0 / 17,
  );

  /// Captions, quotes — Newsreader Italic 15px
  static TextStyle get editorialQuote => GoogleFonts.newsreader(
    fontStyle: FontStyle.italic,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 21.5 / 15,
  );

  // ==========================================================================
  // TYPOGRAPHY — UI (Geist)
  // Primary styles are color-free; secondary styles retain textSecondary
  // (readable in both light and dark modes).
  // ==========================================================================

  /// Screen titles — Geist SemiBold 32px.
  /// Tabular figures so balances rendered at this size hold their column as
  /// the amount updates (digits don't jitter).
  static const TextStyle uiHeadline = TextStyle(
    fontFamily: 'Geist',
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 38.5 / 32,
    letterSpacing: 32 * trackingTight,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Large numbers, balances — Geist SemiBold 24px
  static const TextStyle uiDisplay = TextStyle(
    fontFamily: 'Geist',
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 29.5 / 24,
    letterSpacing: 24 * trackingTight,
  );

  /// Card titles — Geist Medium 20px
  static const TextStyle uiTitle = TextStyle(
    fontFamily: 'Geist',
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 25.0 / 20,
  );

  /// Nav, tab labels — Geist Medium 17px
  static const TextStyle uiIdentity = TextStyle(
    fontFamily: 'Geist',
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 21.5 / 17,
  );

  /// Body copy — Geist Regular 15px
  static const TextStyle uiBody = TextStyle(
    fontFamily: 'Geist',
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 19.0 / 15,
  );

  /// Labels, tags — Geist Medium 13px
  static const TextStyle uiLabel = TextStyle(
    fontFamily: 'Geist',
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 16.5 / 13,
  );

  /// Secondary info — Geist Regular 13px.
  /// Small sizes get slightly positive tracking so glyphs breathe.
  static const TextStyle uiMeta = TextStyle(
    fontFamily: 'Geist',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 16.5 / 13,
    letterSpacing: 13 * trackingWide,
  );

  /// Footnotes, legal — Geist Regular 11px.
  /// Small sizes get slightly positive tracking so glyphs breathe.
  static const TextStyle uiCaption = TextStyle(
    fontFamily: 'Geist',
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 14.0 / 11,
    letterSpacing: 11 * trackingWide,
  );

  /// Large numbers / balances with tabular (monospaced) figures so digits
  /// hold their column as amounts update. Same metrics as [uiDisplay].
  static final TextStyle uiDisplayTabular = uiDisplay.copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Small numeric metadata with tabular figures. Same metrics as [uiMeta].
  static final TextStyle uiMetaTabular = uiMeta.copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Body copy for multi-line paragraphs — relaxed 1.4 line-height.
  static final TextStyle uiBodyRelaxed = uiBody.copyWith(height: 1.4);

  // ==========================================================================
  // THEME DATA
  // ==========================================================================

  /// Intentional pressed feedback that coexists with [NoSplash] (we keep the
  /// no-ripple aesthetic). This is a solid highlight, not a splash: it paints
  /// [base] at low alpha only while the button is pressed, so Material buttons
  /// still acknowledge a tap. Applied via each button theme's `overlayColor`.
  static WidgetStateProperty<Color?> _pressedOverlay(Color base) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return base.withValues(alpha: 0.1);
        }
        return null;
      });

  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: MallowColors.dark.bgPrimary,
    pageTransitionsTheme: pageTransitionsTheme,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        overlayColor: _pressedOverlay(MallowColors.dark.textPrimary),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        overlayColor: _pressedOverlay(MallowColors.dark.textPrimary),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(overlayColor: _pressedOverlay(accent)),
    ),
    colorScheme: const ColorScheme.dark().copyWith(
      primary: accent,
      secondary: accentDark,
      surface: MallowColors.dark.bgSurface,
      onPrimary: textOnAccent,
      onSecondary: textOnAccent,
      onSurface: MallowColors.dark.textPrimary,
    ),
    // Apply the Geist family to the BASE textTheme FIRST, then copyWith the
    // editorial (Newsreader) styles — otherwise `.apply` would clobber the
    // Newsreader family on displayLarge/displayMedium and produce faux-italics.
    textTheme: ThemeData.dark().textTheme
        .apply(fontFamily: 'Geist')
        .copyWith(
          displayLarge: editorialHero.copyWith(
            color: MallowColors.dark.textPrimary,
          ),
          displayMedium: editorialSection.copyWith(
            color: MallowColors.dark.textPrimary,
          ),
          bodyLarge: uiBody.copyWith(color: MallowColors.dark.textPrimary),
          bodyMedium: uiBody.copyWith(color: MallowColors.dark.textPrimary),
          labelLarge: uiLabel.copyWith(color: MallowColors.dark.textSecondary),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: MallowColors.dark.bgPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: editorialSubhead.copyWith(
        color: MallowColors.dark.textPrimary,
      ),
      iconTheme: IconThemeData(color: MallowColors.dark.textPrimary),
    ),
    cardTheme: CardThemeData(
      color: MallowColors.dark.bgSurface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: accentDark,
      foregroundColor: textOnAccent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MallowColors.dark.bgSurface,
      contentTextStyle: uiBody.copyWith(color: MallowColors.dark.textPrimary),
      behavior: SnackBarBehavior.fixed,
      shape: const RoundedRectangleBorder(),
    ),
    extensions: const [MallowColors.dark],
  );

  static ThemeData get lightTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: background,
    pageTransitionsTheme: pageTransitionsTheme,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(overlayColor: _pressedOverlay(textPrimary)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(overlayColor: _pressedOverlay(textPrimary)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(overlayColor: _pressedOverlay(accentLightMode)),
    ),
    colorScheme: const ColorScheme.light().copyWith(
      primary: accentLightMode,
      secondary: accentLightMode,
      surface: surface,
      onPrimary: textOnAccent,
      onSecondary: textOnAccent,
      onSurface: textPrimary,
    ),
    // Apply the Geist family to the BASE textTheme FIRST, then copyWith the
    // editorial (Newsreader) styles — otherwise `.apply` would clobber the
    // Newsreader family on displayLarge/displayMedium and produce faux-italics.
    textTheme: ThemeData.light().textTheme
        .apply(fontFamily: 'Geist')
        .copyWith(
          displayLarge: editorialHero.copyWith(color: textPrimary),
          displayMedium: editorialSection.copyWith(color: textPrimary),
          bodyLarge: uiBody.copyWith(color: textPrimary),
          bodyMedium: uiBody.copyWith(color: textPrimary),
          labelLarge: uiLabel.copyWith(color: textSecondary),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: editorialSubhead.copyWith(color: textPrimary),
      iconTheme: const IconThemeData(color: textPrimary),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: accentLightMode,
      foregroundColor: textOnAccent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surface,
      contentTextStyle: uiBody.copyWith(color: textPrimary),
      behavior: SnackBarBehavior.fixed,
      shape: const RoundedRectangleBorder(),
    ),
    extensions: const [MallowColors.light],
  );
}
