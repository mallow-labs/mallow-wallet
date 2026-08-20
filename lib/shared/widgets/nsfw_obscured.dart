import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/network/auth_service.dart';
import '../../core/services/preferences_service.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import '../utils/nsfw_setting.dart';
import 'app_snack_bar.dart';
import 'mallow_button.dart';
import 'mallow_sheet.dart';
import 'mallow_svg_icon.dart';
import 'mallow_toggle.dart';
import 'sheet_drag_handle.dart';

/// Below this overlay width the full "NSFW / Reveal artwork" treatment
/// doesn't fit; the whole overlay collapses to an eye-only reveal control
/// (webapp parity: the `@[200px]` container query in `useNsfw`).
const double _compactWidthBreakpoint = 200;

/// Obscures NSFW-flagged artwork behind a frosted blur until the viewer's
/// show-NSFW setting is on or they reveal this artwork (webapp `useNsfw`
/// parity).
///
/// Renders [child] unchanged when [nsfw] is false — without resolving
/// [PreferencesService], so unflagged call sites neither pay for nor depend on
/// it and can wrap unconditionally. When true and the global
/// setting is off, a scrim + backdrop blur covers the media with a "Reveal
/// artwork" affordance. A reveal is local to this widget (a one-off peek, not
/// persisted); the first reveal on the device also opens the one-time NSFW
/// warning sheet, and flipping the global setting off re-blurs revealed
/// artwork. The overlay absorbs taps, so a blurred tile can't navigate (or
/// reach the fullscreen/video controls) until revealed.
class NsfwObscured extends StatefulWidget {
  const NsfwObscured({
    required this.nsfw,
    required this.child,
    super.key,
    this.contentId,
    this.borderRadius,
  });

  final bool nsfw;
  final Widget child;

  /// Stable identity of the artwork behind the overlay (e.g. its image URL or
  /// mint account). Hosting grids build tiles via a keyless
  /// [SliverChildBuilderDelegate], so [Widget.canUpdate] reuses this widget's
  /// [State] when a *different* artwork lands at the same slot after a
  /// refresh/filter/pagination. Without an identity input the local reveal
  /// would leak onto that new artwork, exposing it unblurred. Supplying
  /// [contentId] lets the state re-blur whenever the underlying artwork
  /// changes.
  final String? contentId;

  /// Corner radius of the media the overlay covers, so the frost clips to the
  /// same corners.
  final BorderRadius? borderRadius;

  @override
  State<NsfwObscured> createState() => _NsfwObscuredState();
}

class _NsfwObscuredState extends State<NsfwObscured> {
  PreferencesService? _prefs;
  bool _revealed = false;

  /// Resolved (and subscribed to) on the first `nsfw == true` build, never for
  /// an unflagged artwork. Lazy rather than in [initState] so a widget whose
  /// flag flips false → true mid-lifecycle still blurs on that first flagged
  /// build.
  PreferencesService _ensurePrefs() {
    final existing = _prefs;
    if (existing != null) return existing;
    final prefs = sl<PreferencesService>()
      ..showNsfwNotifier.addListener(_onShowNsfwChanged);
    _prefs = prefs;
    return prefs;
  }

  @override
  void didUpdateWidget(NsfwObscured oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled slot: the tile now shows a different artwork, or an unflagged
    // artwork just flipped to flagged. Either way, drop the local peek so the
    // new artwork starts blurred rather than inheriting the previous reveal.
    final swappedContent = oldWidget.contentId != widget.contentId;
    final reFlagged = !oldWidget.nsfw && widget.nsfw;
    if ((swappedContent || reFlagged) && _revealed) {
      _revealed = false;
    }
  }

  @override
  void dispose() {
    _prefs?.showNsfwNotifier.removeListener(_onShowNsfwChanged);
    super.dispose();
  }

  /// Any global-setting change resets the local peek, so switching the
  /// setting off re-blurs already-revealed artwork (webapp parity).
  void _onShowNsfwChanged() {
    if (mounted) setState(() => _revealed = false);
  }

  void _reveal() {
    // Moderation lock: a locked account can't bypass its blur per-artwork.
    if (sl<AuthService>().currentUser?.disableNsfwSetting ?? false) {
      AppSnackBar.show(
        context,
        'NSFW setting is disabled',
        type: AppSnackBarType.error,
      );
      return;
    }
    setState(() => _revealed = true);
    maybeShowNsfwWarningSheet(context);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.nsfw) return widget.child;
    final blurred = !_ensurePrefs().showNsfw && !_revealed;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (blurred)
          Positioned.fill(
            child: _NsfwOverlay(
              borderRadius: widget.borderRadius,
              onReveal: _reveal,
            ),
          ),
      ],
    );
  }
}

class _NsfwOverlay extends StatelessWidget {
  const _NsfwOverlay({required this.onReveal, this.borderRadius});

  final VoidCallback onReveal;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scrim = (dark ? Colors.black : Colors.white).withValues(alpha: 0.5);

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: ColoredBox(
          color: scrim,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < _compactWidthBreakpoint) {
                // Tile-sized: the whole overlay is the reveal control.
                return Semantics(
                  button: true,
                  label: 'Reveal artwork',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onReveal,
                    child: Center(
                      child: MallowSvgIcon(
                        'assets/icons/eye.svg',
                        width: 24,
                        height: 24,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                );
              }
              // Full-size: label + explicit reveal button. The scrim absorbs
              // taps so a blurred surface can't navigate until revealed.
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'NSFW',
                      style: MallowTheme.editorialSection.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                    MallowButton(
                      label: 'Reveal artwork',
                      variant: MallowButtonVariant.secondary,
                      size: MallowButtonSize.small,
                      svgAsset: 'assets/icons/eye.svg',
                      onPressed: onReveal,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Shows the one-time NSFW warning sheet on the first per-artwork reveal
/// (webapp `NsfwModal` parity). No-ops once acknowledged on this device.
Future<void> maybeShowNsfwWarningSheet(BuildContext context) async {
  final prefs = sl<PreferencesService>();
  if (prefs.nsfwWarningShown) return;
  await prefs.setNsfwWarningShown(true);
  if (!context.mounted) return;
  await showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _NsfwWarningSheet(),
  );
}

class _NsfwWarningSheet extends StatefulWidget {
  const _NsfwWarningSheet();

  @override
  State<_NsfwWarningSheet> createState() => _NsfwWarningSheetState();
}

class _NsfwWarningSheetState extends State<_NsfwWarningSheet> {
  bool _busy = false;

  Future<void> _onToggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await applyShowNsfwSetting(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      AppSnackBar.show(context, error, type: AppSnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final showNsfw = sl<PreferencesService>().showNsfw;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingSm,
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'NSFW settings',
                    style: MallowTheme.uiTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'Would you like to permanently disable the '
                    'not-safe-for-work (NSFW) artwork blur setting?',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'Warning: You may see content that could trigger '
                    'negative emotions.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Disable NSFW artwork blur setting',
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      MallowToggle(value: showNsfw, onChanged: _onToggle),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Text(
                    'You can change this setting at any time in '
                    'Settings → Preferences.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
