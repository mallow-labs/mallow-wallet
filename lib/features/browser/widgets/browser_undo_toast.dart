import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import 'browser_status_toast.dart';

/// A small pill that rises from the bottom of the screen with a message and
/// an Undo button, on the same surface as the transaction status pill.
///
/// It sits over the root overlay, so it outlives the route that showed it:
/// closing the last tab leaves the browser while the pill is still up. It
/// clears the browser's bottom bar, the tab switcher's New tab button and the
/// app's tab bar, which all stand about the same height above the safe area.
class BrowserUndoToast {
  BrowserUndoToast._();

  static const _duration = Duration(seconds: 4);

  /// Longer with a screen reader, which has to reach the button first.
  static const _accessibleDuration = Duration(seconds: 10);

  static GlobalKey<_UndoToastEntryState>? _currentKey;
  static OverlayEntry? _currentEntry;

  /// Shows [message] with an Undo button that runs [onUndo]. Replaces any
  /// pill already showing.
  static void show(
    BuildContext context,
    String message, {
    required VoidCallback onUndo,
  }) {
    dismiss();
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true) ??
        Navigator.of(context, rootNavigator: true).overlay!;
    final key = GlobalKey<_UndoToastEntryState>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _UndoToastEntry(
        key: key,
        message: message,
        onUndo: onUndo,
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

  /// Animates out the pill showing, if any.
  static void dismiss() {
    final key = _currentKey;
    final entry = _currentEntry;
    _currentKey = null;
    _currentEntry = null;
    final state = key?.currentState;
    if (state != null) {
      state._dismiss();
    } else {
      // Inserted but not yet built: nothing to animate out.
      entry?.remove();
    }
  }
}

class _UndoToastEntry extends StatefulWidget {
  const _UndoToastEntry({
    required this.message,
    required this.onUndo,
    required this.onRemoved,
    super.key,
  });

  final String message;
  final VoidCallback onUndo;
  final VoidCallback onRemoved;

  @override
  State<_UndoToastEntry> createState() => _UndoToastEntryState();
}

class _UndoToastEntryState extends State<_UndoToastEntry>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: MallowTheme.sheetDuration,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: MallowTheme.sheetCurve,
  );
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer ??= Timer(
      MediaQuery.accessibleNavigationOf(context)
          ? BrowserUndoToast._accessibleDuration
          : BrowserUndoToast._duration,
      _dismiss,
    );
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
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
    _timer?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = math.max(
      math.max(media.padding.bottom, 20.0) + 68,
      media.viewInsets.bottom + 12,
    );
    final ink = BrowserToastSurface.ink(context);
    Widget pill = Semantics(
      liveRegion: true,
      container: true,
      child: BrowserToastSurface(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiLabel.copyWith(color: ink),
                ),
              ),
              const SizedBox(width: 12),
              BrowserToastAction(
                label: 'Undo',
                onTap: () {
                  _dismiss();
                  widget.onUndo();
                },
              ),
            ],
          ),
        ),
      ),
    );
    pill = FadeTransition(opacity: _curve, child: pill);
    if (!context.reduceMotion) {
      pill = SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.6),
          end: Offset.zero,
        ).animate(_curve),
        child: pill,
      );
    }
    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: Center(
        child: Dismissible(
          key: const ValueKey('browser-undo-toast'),
          direction: DismissDirection.down,
          onDismissed: (_) {
            _dismissing = true;
            _timer?.cancel();
            widget.onRemoved();
          },
          // Gives the text its theme style: the root overlay has none.
          child: Material(type: MaterialType.transparency, child: pill),
        ),
      ),
    );
  }
}
