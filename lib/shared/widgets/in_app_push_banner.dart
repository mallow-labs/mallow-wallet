import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';

/// Top-anchored banner for a push notification that arrives while the app is
/// in the foreground.
///
/// iOS re-presents foreground notifications itself (see
/// `setForegroundNotificationPresentationOptions` in `PushNotificationService`),
/// but Android shows nothing at all — this is that missing surface. Tapping the
/// banner runs [onTap], which routes through the same link resolution a
/// notification tap uses, so foreground and background taps land in the same
/// place.
///
/// Mirrors `AppSnackBar`'s overlay mechanics (root overlay entry, slide in/out,
/// single instance at a time) with a tap target added.
class InAppPushBanner {
  InAppPushBanner._();

  static const Duration _defaultDuration = Duration(seconds: 5);
  static const Duration _animationDuration = Duration(milliseconds: 300);
  static const double _topInset = 60;
  static const double _horizontalInset = 16;

  /// The banner currently owning the overlay, tracked by key + entry rather
  /// than by state: the state doesn't exist until the entry has built, so two
  /// messages arriving in the same frame both used to see "nothing showing"
  /// and stack two banners on top of each other.
  static GlobalKey<_InAppPushBannerEntryState>? _currentKey;
  static OverlayEntry? _currentEntry;

  /// Shows the banner over the root overlay, replacing any banner already up.
  static void show(
    BuildContext context, {
    required VoidCallback onTap,
    String? title,
    String? body,
    Duration duration = _defaultDuration,
  }) {
    dismiss();
    // `Overlay.of` searches ancestors, so it throws when [context] is the root
    // Navigator's own context — which is exactly what the only production
    // caller passes (`PushNotificationService` has no widget context, so it
    // reaches for `AppRoutes.rootNavigatorKey.currentContext`). The root
    // Overlay is that Navigator's *descendant*. Ask the Navigator for it.
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true) ??
        Navigator.of(context, rootNavigator: true).overlay!;
    final key = GlobalKey<_InAppPushBannerEntryState>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _InAppPushBannerEntry(
        key: key,
        title: title,
        body: body,
        duration: duration,
        onTap: onTap,
        onRemoved: () {
          entry.remove();
          if (identical(_currentKey, key)) {
            _currentKey = null;
            _currentEntry = null;
          }
        },
      ),
    );
    _currentKey = key;
    _currentEntry = entry;
    overlay.insert(entry);
  }

  /// Animates out the currently visible banner, if any.
  static void dismiss() {
    final key = _currentKey;
    final entry = _currentEntry;
    _currentKey = null;
    _currentEntry = null;
    final state = key?.currentState;
    if (state != null) {
      state._dismiss();
    } else {
      // Inserted but not yet built (a second message in the same frame): there
      // is no state to animate out, so drop the entry directly.
      entry?.remove();
    }
  }
}

class _InAppPushBannerEntry extends StatefulWidget {
  const _InAppPushBannerEntry({
    required this.title,
    required this.body,
    required this.duration,
    required this.onTap,
    required this.onRemoved,
    super.key,
  });

  final String? title;
  final String? body;
  final Duration duration;
  final VoidCallback onTap;
  final VoidCallback onRemoved;

  @override
  State<_InAppPushBannerEntry> createState() => _InAppPushBannerEntryState();
}

class _InAppPushBannerEntryState extends State<_InAppPushBannerEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: InAppPushBanner._animationDuration,
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );
    _controller.forward();
    _autoDismissTimer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    if (!mounted) {
      widget.onRemoved();
      return;
    }
    try {
      await _controller.reverse();
    } finally {
      widget.onRemoved();
    }
  }

  void _handleTap() {
    widget.onTap();
    unawaited(_dismiss());
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final title = widget.title;
    final body = widget.body;

    // The slide tween moves by the child's full height, so the top inset is
    // baked into the child — dismissing then translates the whole block off.
    final Widget content = Padding(
      padding: EdgeInsets.only(
        top: InAppPushBanner._topInset + MediaQuery.paddingOf(context).top,
      ),
      child: Material(
        color: colors.bgSurface,
        elevation: 4,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
        child: InkWell(
          onTap: _handleTap,
          borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacingMd,
              vertical: MallowTheme.spacing12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null && title.isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                if (body != null && body.isNotEmpty)
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // Reduce Motion swaps the vertical slide for a plain opacity fade.
    final Widget transition = context.reduceMotion
        ? FadeTransition(opacity: _controller, child: content)
        : SlideTransition(position: _slide, child: content);

    return Positioned(
      top: 0,
      left: InAppPushBanner._horizontalInset,
      right: InAppPushBanner._horizontalInset,
      child: transition,
    );
  }
}
