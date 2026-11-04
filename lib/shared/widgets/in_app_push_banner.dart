import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';

/// Banner for a push notification that arrives while the app is in the
/// foreground.
///
/// iOS re-presents foreground notifications itself (see
/// `setForegroundNotificationPresentationOptions` in `PushNotificationService`),
/// but Android shows nothing at all — this is that missing surface. Tapping the
/// banner runs `onTap`, which routes through the same link resolution a
/// notification tap uses, so foreground and background taps land in the same
/// place.
///
/// The banner does not float over the app. It is drawn by the
/// [InAppPushBannerHost] that wraps the whole app, which grows the top unsafe
/// area to make room for it and lays the app out in what is left — so nothing
/// on screen is covered while it shows.
class InAppPushBanner {
  InAppPushBanner._();

  static const Duration _defaultDuration = Duration(seconds: 5);

  /// Shows the banner in the nearest [InAppPushBannerHost] above [context],
  /// replacing any banner already up. The root navigator's own context works:
  /// the host wraps the router, so it is that navigator's ancestor.
  ///
  /// Returns false when nothing was shown — no host above [context], or the
  /// host is disabled because the app is locked.
  static bool show(
    BuildContext context, {
    required VoidCallback onTap,
    String? title,
    String? body,
    Duration duration = _defaultDuration,
  }) {
    final host = context.findAncestorStateOfType<InAppPushBannerHostState>();
    if (host == null) return false;
    return host._show(
      _BannerMessage(
        title: title,
        body: body,
        duration: duration,
        onTap: onTap,
      ),
    );
  }

  /// Animates out the banner in the nearest host above [context], if any.
  static void dismiss(BuildContext context) {
    context.findAncestorStateOfType<InAppPushBannerHostState>()?._dismiss();
  }
}

class _BannerMessage {
  const _BannerMessage({
    required this.title,
    required this.body,
    required this.duration,
    required this.onTap,
  });

  final String? title;
  final String? body;
  final Duration duration;
  final VoidCallback onTap;
}

/// Wraps the app and makes room for an [InAppPushBanner] at the top of the
/// screen, as if the unsafe area had grown.
///
/// While a banner shows, [child] is laid out below it with the status-bar
/// inset taken out of its `MediaQuery` (the band now covers the status bar),
/// and its top corners are rounded so the app reads as having shrunk rather
/// than being covered. The band is drawn in the inverse palette — near-black
/// over the light theme, near-white over the dark one — so it stands apart
/// from every screen it can sit above.
///
/// Must sit inside the `MaterialApp` (it reads the theme) and above the
/// router (so the root navigator's context can find it). Keep anything that
/// must cover the banner too — the privacy blur — outside it.
class InAppPushBannerHost extends StatefulWidget {
  const InAppPushBannerHost({
    required this.child,
    this.enabled = true,
    super.key,
  });

  final Widget child;

  /// When false, [InAppPushBanner.show] is refused and a banner already up is
  /// removed at once. The app passes false while it is locked, so a
  /// notification's text never shows above the lock screen.
  final bool enabled;

  /// Height the band adds below the status bar.
  static const double bandHeight = 76;

  static const double _cornerRadius = 20;
  static const Duration _enterDuration = Duration(milliseconds: 300);
  static const Duration _exitDuration = Duration(milliseconds: 250);

  /// Upward drag, in logical pixels past the touch slop, beyond which
  /// letting go dismisses.
  static const double _dismissDragDistance = 12;
  static const double _dismissFlingVelocity = 300;

  @override
  State<InAppPushBannerHost> createState() => InAppPushBannerHostState();
}

class InAppPushBannerHostState extends State<InAppPushBannerHost>
    with TickerProviderStateMixin {
  late final AnimationController _reveal;
  late final CurvedAnimation _revealCurve;
  late final AnimationController _countdown;
  _BannerMessage? _message;
  double _dragUp = 0;

  @override
  void initState() {
    super.initState();
    _reveal =
        AnimationController(
          vsync: this,
          duration: InAppPushBannerHost._enterDuration,
          reverseDuration: InAppPushBannerHost._exitDuration,
        )..addStatusListener((status) {
          // Drop the message only once the band is fully closed. A new
          // message during the exit turns the controller around instead, so
          // this never fires for it.
          if (status == AnimationStatus.dismissed && _message != null) {
            setState(() => _message = null);
          }
        });
    _revealCurve = CurvedAnimation(
      parent: _reveal,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _countdown = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _dismiss();
      });
  }

  @override
  void didUpdateWidget(InAppPushBannerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      // No exit animation: the lock screen is coming up under the band, and
      // the notification's text must not linger over it.
      _countdown.stop();
      _reveal.value = 0;
    }
  }

  @override
  void dispose() {
    _revealCurve.dispose();
    _reveal.dispose();
    _countdown.dispose();
    super.dispose();
  }

  bool _show(_BannerMessage message) {
    if (!widget.enabled) return false;
    // A second message while one is up swaps the text in place and restarts
    // the timer; the band stays open rather than closing and reopening.
    setState(() => _message = message);
    _countdown
      ..duration = message.duration
      ..forward(from: 0);
    _reveal.forward();
    return true;
  }

  void _dismiss() {
    _countdown.stop();
    if (_message == null) return;
    _reveal.reverse();
  }

  void _handleTap() {
    final message = _message;
    if (message == null || _reveal.status == AnimationStatus.reverse) return;
    message.onTap();
    _dismiss();
  }

  void _handleDragStart(DragStartDetails _) {
    _dragUp = 0;
    // Hold the timer while a finger is on the band.
    _countdown.stop();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragUp -= details.delta.dy;
  }

  void _handleDragEnd(DragEndDetails details) {
    final flungUp =
        (details.primaryVelocity ?? 0) <
        -InAppPushBannerHost._dismissFlingVelocity;
    if (flungUp || _dragUp > InAppPushBannerHost._dismissDragDistance) {
      _dismiss();
    } else if (_message != null) {
      _countdown.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    return AnimatedBuilder(
      animation: _reveal,
      // Passed through as `child` so the app subtree is never rebuilt by the
      // animation, only re-laid out.
      child: widget.child,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final statusInset = media.padding.top;
        // Reduce Motion: the app jumps to its new size instead of sliding,
        // and only the band's contents fade.
        final progress = reduceMotion
            ? (_reveal.isDismissed ? 0.0 : 1.0)
            : _revealCurve.value;
        final bandExtent =
            progress * (statusInset + InAppPushBannerHost.bandHeight);
        final radius = progress * InAppPushBannerHost._cornerRadius;
        final message = _message;

        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              // Reaches [radius] under the app so the band's color shows
              // through the app's rounded top corners.
              height: bandExtent + radius,
              child: message == null || progress == 0
                  ? const SizedBox.shrink()
                  : _Band(
                      message: message,
                      bottomInset: radius,
                      opacity: reduceMotion ? _reveal.value : 1,
                      countdown: _countdown,
                      onTap: _handleTap,
                      onDismiss: _dismiss,
                      onDragStart: _handleDragStart,
                      onDragUpdate: _handleDragUpdate,
                      onDragEnd: _handleDragEnd,
                    ),
            ),
            Positioned(
              top: bandExtent,
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(radius),
                ),
                clipBehavior: progress == 0 ? Clip.none : Clip.antiAlias,
                // The band covers the status bar, so the app gives up that
                // part of its top inset as the band grows. Its content
                // therefore moves down by [InAppPushBannerHost.bandHeight]
                // in total, not by the band's full extent.
                child: MediaQuery(
                  data: media.copyWith(
                    padding: media.padding.copyWith(
                      top: statusInset * (1 - progress),
                    ),
                    viewPadding: media.viewPadding.copyWith(
                      top: media.viewPadding.top * (1 - progress),
                    ),
                  ),
                  child: child!,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({
    required this.message,
    required this.bottomInset,
    required this.opacity,
    required this.countdown,
    required this.onTap,
    required this.onDismiss,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final _BannerMessage message;
  final double bottomInset;
  final double opacity;
  final Animation<double> countdown;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final appIsLight = Theme.of(context).brightness == Brightness.light;
    // The opposite theme's palette, so the band never matches the screen
    // under it.
    final band = appIsLight ? MallowColors.dark : MallowColors.light;
    final title = message.title;
    final body = message.body;
    final hasTitle = title != null && title.isNotEmpty;
    final hasBody = body != null && body.isNotEmpty;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MallowTheme.systemBarsOver(
        appIsLight ? Brightness.dark : Brightness.light,
      ),
      child: ColoredBox(
        color: band.bgPrimary,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          // The row keeps its full height and is anchored to the band's
          // bottom edge, so while the band grows it slides out from under
          // the status bar instead of squashing.
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: InAppPushBannerHost.bandHeight,
              maxHeight: InAppPushBannerHost.bandHeight,
              child: Opacity(
                opacity: opacity,
                child: Semantics(
                  container: true,
                  button: true,
                  liveRegion: true,
                  onDismiss: onDismiss,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    onVerticalDragStart: onDragStart,
                    onVerticalDragUpdate: onDragUpdate,
                    onVerticalDragEnd: onDragEnd,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        MallowTheme.spacing20,
                        0,
                        MallowTheme.spacingMd,
                        6,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: colors.accent,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: MallowSvgIcon(
                                    'assets/icons/bell.svg',
                                    width: 20,
                                    height: 20,
                                    color: colors.textOnAccent,
                                  ),
                                ),
                                const SizedBox(width: MallowTheme.spacing12),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (hasTitle)
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: MallowTheme.uiBody.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: band.textPrimary,
                                          ),
                                        ),
                                      if (hasTitle && hasBody)
                                        const SizedBox(height: 2),
                                      if (hasBody)
                                        Text(
                                          body,
                                          // Without a title the body has the
                                          // band to itself.
                                          maxLines: hasTitle ? 1 : 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: MallowTheme.uiMeta.copyWith(
                                            color: band.textSecondary,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 32,
                                  child: Center(
                                    child: MallowSvgIcon(
                                      'assets/icons/chevron_right.svg',
                                      width: 18,
                                      height: 18,
                                      color: band.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(
                              right: MallowTheme.spacingSm,
                            ),
                            child: _CountdownLine(
                              countdown: countdown,
                              track: band.textPrimary.withValues(alpha: 0.14),
                              // Salmon reads on the dark band; on the light
                              // one it is too faint, so use the band's ink.
                              fill: appIsLight
                                  ? colors.accent
                                  : band.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin bar that empties as the banner's auto-dismiss timer runs down.
class _CountdownLine extends StatelessWidget {
  const _CountdownLine({
    required this.countdown,
    required this.track,
    required this.fill,
  });

  final Animation<double> countdown;
  final Color track;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: SizedBox(
          height: 2,
          child: ColoredBox(
            color: track,
            child: AnimatedBuilder(
              animation: countdown,
              builder: (context, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 1 - countdown.value,
                child: ColoredBox(color: fill),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
