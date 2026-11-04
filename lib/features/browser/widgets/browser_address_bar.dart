import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import 'browser_bottom_bar.dart';
import 'browser_host_text.dart';
import 'browser_site_tile.dart';
import 'browser_tap.dart';

/// The browser's top chrome: the address capsule under the status bar. The
/// bar itself paints nothing, so the page shows around the capsule; the
/// WebView treats the bar's height as an obscured inset (see
/// `BrowserObscuredInsets`). It never leaves the screen; while [compact] (the
/// page is scrolling down) the capsule shrinks to a small pill around the
/// host, without the site icon or reload button, and tapping it expands the
/// bar again.
///
/// Every string that names a website here must come from the natively
/// committed origin ([host]); a page's title never reaches this widget.
class BrowserAddressBar extends StatelessWidget {
  const BrowserAddressBar({
    required this.compact,
    required this.host,
    required this.blank,
    required this.loading,
    required this.onAddress,
    required this.onTabs,
    required this.onReloadOrStop,
    required this.onExpand,
    this.iconUrl,
    this.collapse,
    this.notSecure = false,
    super.key,
  });

  static const double capsuleHeight = 50;
  static const double compactCapsuleHeight = 28;
  static const double _pad = 6;
  static const double _compactPad = 2;
  static const double _side = 12;

  /// The height the expanded bar takes below the status bar; the website is
  /// laid out under it.
  static const double expandedHeight = _pad + capsuleHeight + _pad;

  /// The height the compact bar takes below the status bar.
  static const double compactHeight =
      _compactPad + compactCapsuleHeight + _compactPad;

  final bool compact;

  /// The committed host, or null before the first navigation commits.
  final String? host;

  /// The tab has no website. The start page brings its own search field in
  /// place of this bar, so the browser shows a blank bar only while the lock
  /// cover hides that page.
  final bool blank;
  final bool loading;
  final Uri? iconUrl;

  /// The user overrode a certificate warning on this site, so its identity
  /// is unverified: a warning sign takes the lock's place.
  final bool notSecure;
  final VoidCallback onAddress;
  final VoidCallback onTabs;
  final VoidCallback onReloadOrStop;
  final VoidCallback onExpand;

  /// Drives the shrink from outside, 0 expanded and 1 compact, so whatever
  /// sits under the bar can follow it frame by frame. Without it the bar
  /// animates to [compact] on its own.
  final Animation<double>? collapse;

  /// The height the bar takes below the status bar at [t] (0 expanded, 1
  /// compact).
  static double heightAt(double t) =>
      lerpDouble(expandedHeight, compactHeight, t)!;

  @override
  Widget build(BuildContext context) {
    final collapse = this.collapse;
    if (collapse != null) {
      return AnimatedBuilder(
        animation: collapse,
        builder: (context, _) => _bar(context, collapse.value),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: compact ? 1 : 0),
      duration: context.reduceMotion
          ? Duration.zero
          : MallowTheme.sheetDuration,
      curve: MallowTheme.sheetCurve,
      builder: (context, t, _) => _bar(context, t),
    );
  }

  Widget _bar(BuildContext context, double t) {
    final pad = lerpDouble(_pad, _compactPad, t)!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _side,
        MediaQuery.paddingOf(context).top + pad,
        _side,
        pad,
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.5,
        child: _AddressCapsule(bar: this, t: t),
      ),
    );
  }
}

class _AddressCapsule extends StatelessWidget {
  const _AddressCapsule({required this.bar, required this.t});

  static const double _compactSidePad = 12;

  /// The compact pill's width: lock, gap, the host at its compact style, and
  /// side padding, plus a pixel of slack so rounding never elides the host.
  static double _compactWidth(BuildContext context, String host) {
    final painter = TextPainter(
      text: TextSpan(text: host, style: MallowTheme.uiLabel),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return _compactSidePad * 2 + 11 + 6 + width + 1;
  }

  final BrowserAddressBar bar;

  /// 0 expanded, 1 compact.
  final double t;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final host = bar.host;
    final site = host != null && !bar.blank;
    final label = bar.blank ? 'Search or enter address' : host ?? 'Loading…';
    final decoration = browserPillDecoration(
      context,
      border: colors.dividerLight,
    );
    final hostStyle = TextStyle.lerp(
      MallowTheme.uiBody.copyWith(fontWeight: FontWeight.w500),
      MallowTheme.uiLabel,
      t,
    )!;
    final lockSize = lerpDouble(13, 11, t)!;
    final hPad = lerpDouble(10, _compactSidePad, t)!;
    final rPad = lerpDouble(5, _compactSidePad, t)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth;
        // The compact pill hugs the host: lock, gap, text, side padding.
        final compactWidth = site
            ? math.min(full, _compactWidth(context, host))
            : full;
        return Center(
          child: Container(
            width: lerpDouble(full, compactWidth, t),
            height: lerpDouble(
              BrowserAddressBar.capsuleHeight,
              BrowserAddressBar.compactCapsuleHeight,
              t,
            ),
            padding: EdgeInsets.only(left: hPad, right: rPad),
            decoration: decoration,
            child: _row(
              context,
              site: site,
              label: label,
              t: t,
              lockSize: lockSize,
              hostStyle: hostStyle,
            ),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context, {
    required bool site,
    required String label,
    required double t,
    required double lockSize,
    required TextStyle hostStyle,
  }) {
    final colors = context.mallowColors;
    final host = bar.host;
    final compact = bar.compact;
    final notSecure = site && bar.notSecure;
    // The site icon and reload button shrink out of the row as it narrows,
    // and leave it (and the semantics tree) once it is fully compact.
    Widget side(Widget child, Alignment alignment) => t >= 1
        ? const SizedBox.shrink()
        : IgnorePointer(
            ignoring: compact,
            child: ClipRect(
              child: Align(
                alignment: alignment,
                widthFactor: 1 - t,
                child: Opacity(opacity: 1 - t, child: child),
              ),
            ),
          );
    return Row(
      children: [
        side(
          site
              ? BrowserTap(
                  onTap: bar.onTabs,
                  label: 'Show tabs',
                  child: SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: BrowserSiteTile(
                        host: host!,
                        iconUrl: bar.iconUrl,
                        size: 28,
                      ),
                    ),
                  ),
                )
              : SizedBox.square(
                  dimension: 28,
                  child: Center(
                    child: MallowSvgIcon(
                      bar.blank
                          ? 'assets/icons/compass.svg'
                          : 'assets/icons/lock.svg',
                      width: 20,
                      height: 20,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
          Alignment.centerRight,
        ),
        Expanded(
          child: BrowserTap(
            onTap: compact ? bar.onExpand : bar.onAddress,
            label: compact
                ? '${host ?? 'Website'}${notSecure ? '. Not secure' : ''}. '
                      'Show toolbar'
                : bar.blank
                ? 'Enter website address'
                : 'Edit address, ${notSecure ? 'not secure, ' : ''}'
                      '${host ?? 'loading'}',
            child: SizedBox(
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (site) ...[
                    MallowSvgIcon(
                      notSecure
                          ? 'assets/icons/alert_triangle.svg'
                          : 'assets/icons/lock.svg',
                      key: notSecure
                          ? const Key('browser-address-not-secure')
                          : null,
                      width: lockSize,
                      height: lockSize,
                      color: notSecure ? colors.warning : colors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: site
                        ? BrowserHostText(
                            host!,
                            style: hostStyle.copyWith(
                              color: colors.textPrimary,
                            ),
                          )
                        : Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: MallowTheme.uiBody.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        side(
          bar.blank
              ? const SizedBox(width: 28)
              : BrowserBarIconButton(
                  asset: bar.loading
                      ? 'assets/icons/close.svg'
                      : 'assets/icons/reload.svg',
                  label: bar.loading ? 'Stop loading' : 'Reload',
                  size: 19,
                  width: 40,
                  onTap: bar.onReloadOrStop,
                ),
          Alignment.centerLeft,
        ),
      ],
    );
  }
}
