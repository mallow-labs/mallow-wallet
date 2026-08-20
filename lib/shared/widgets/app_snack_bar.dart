import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/utils/reduce_motion.dart';
import '../theme/mallow_theme.dart';

/// Semantic category that drives the snack bar's border color.
enum AppSnackBarType { info, success, error }

/// Top-anchored replacement for [ScaffoldMessenger]'s [SnackBar].
///
/// Slides in from the top with [Curves.easeOutCubic] and out with
/// [Curves.easeInCubic]. Positioned 80px from the top of the screen with 16px
/// horizontal padding and 4px rounded corners. Styling (background, text)
/// follows [ThemeData.snackBarTheme] so the existing dark/light theme entries
/// remain the source of truth.
class AppSnackBar {
  AppSnackBar._();

  static const Duration _defaultDuration = Duration(seconds: 4);
  static const Duration _animationDuration = Duration(milliseconds: 300);
  static const double _topInset = 80;
  static const double _horizontalInset = 16;
  static const double _radius = 4;

  /// The snack bar currently owning the overlay, tracked by key + entry rather
  /// than by state: the state doesn't exist until the entry has built, so two
  /// messages arriving in the same frame both used to see "nothing showing"
  /// and stack two snack bars on top of each other.
  static GlobalKey<_AppSnackBarEntryState>? _currentKey;
  static OverlayEntry? _currentEntry;

  /// Shows [message] in a top-anchored snack bar over the root overlay.
  /// Any currently visible snack bar is animated out before this one appears.
  static void show(
    BuildContext context,
    String message, {
    Duration duration = _defaultDuration,
    AppSnackBarType type = AppSnackBarType.info,
  }) {
    dismiss();
    // `Overlay.of` searches ancestors, so it throws when [context] is the root
    // Navigator's own context (e.g. `rootNavigatorKey.currentContext`, used by
    // services that have no widget context of their own) — the root Overlay is
    // that Navigator's *descendant*, not its ancestor. Fall back to asking the
    // Navigator for the overlay it owns.
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true) ??
        Navigator.of(context, rootNavigator: true).overlay!;
    final key = GlobalKey<_AppSnackBarEntryState>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppSnackBarEntry(
        key: key,
        message: message,
        duration: duration,
        type: type,
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

  /// Animates out the currently visible snack bar, if any.
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

class _AppSnackBarEntry extends StatefulWidget {
  const _AppSnackBarEntry({
    required this.message,
    required this.duration,
    required this.type,
    required this.onRemoved,
    super.key,
  });

  final String message;
  final Duration duration;
  final AppSnackBarType type;
  final VoidCallback onRemoved;

  @override
  State<_AppSnackBarEntry> createState() => _AppSnackBarEntryState();
}

class _AppSnackBarEntryState extends State<_AppSnackBarEntry>
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
      duration: AppSnackBar._animationDuration,
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

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snackBarTheme = theme.snackBarTheme;
    final colors = context.mallowColors;
    final background =
        snackBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final textStyle =
        snackBarTheme.contentTextStyle ?? theme.textTheme.bodyMedium;
    final borderColor = switch (widget.type) {
      AppSnackBarType.success => colors.positive,
      AppSnackBarType.error => colors.error,
      AppSnackBarType.info => colors.divider,
    };
    // The slide tween moves by the child's full height, so we bake the top
    // inset into the child via padding. That way dismissing translates the
    // entire padded block (inset + snackbar) off-screen in one motion.
    final Widget body = Padding(
      padding: const EdgeInsets.only(top: AppSnackBar._topInset),
      child: Material(
        color: background,
        elevation: 4,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: borderColor),
          borderRadius: BorderRadius.circular(AppSnackBar._radius),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Text(widget.message, style: textStyle),
        ),
      ),
    );
    // Reduce Motion swaps the vertical slide for a plain opacity fade so the
    // toast doesn't travel across the screen.
    final Widget transition = context.reduceMotion
        ? FadeTransition(opacity: _controller, child: body)
        : SlideTransition(position: _slide, child: body);
    return Positioned(
      top: 0,
      left: AppSnackBar._horizontalInset,
      right: AppSnackBar._horizontalInset,
      child: transition,
    );
  }
}
