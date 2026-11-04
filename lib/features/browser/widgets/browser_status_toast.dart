import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/success_ripple.dart';
import '../services/browser_transaction_tracker.dart';
import 'browser_tap.dart';

/// Shows the newest browser transaction while it confirms, then its outcome
/// for a few seconds. Receipts older than this screen's session are left to
/// Browser settings; a finished one only appears if it was seen pending here.
/// A transaction a send sheet is presenting stays off the toast.
class BrowserTransactionToast extends StatefulWidget {
  const BrowserTransactionToast({
    required this.tracker,
    required this.onView,
    this.child,
    this.suppressed = false,
    super.key,
  });

  final BrowserTransactionTracker tracker;
  final ValueChanged<BrowserTransactionRecord> onView;

  /// Keeps the toast off screen, with the address bar in its place, while
  /// the page in front holds the chrome under its own sheet. The transaction
  /// is still followed, and shows again once this is cleared if it is still
  /// pending or within its few seconds of showing an outcome.
  final bool suppressed;

  /// The address bar (including its loading indicator) to replace temporarily.
  /// It stays mounted so its expanded or compact state follows page scrolling.
  final Widget? child;

  @override
  State<BrowserTransactionToast> createState() =>
      _BrowserTransactionToastState();
}

class _BrowserTransactionToastState extends State<BrowserTransactionToast> {
  static const _recent = Duration(minutes: 3);
  static const _linger = Duration(seconds: 5);
  final _seenPending = <String>{};
  final _hidden = <String>{};
  BrowserTransactionRecord? _record;
  Timer? _timer;

  String _key(BrowserTransactionRecord record) =>
      '${record.chain}:${record.signature}';

  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(BrowserTransactionToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tracker != widget.tracker) {
      oldWidget.tracker.removeListener(_changed);
      widget.tracker.addListener(_changed);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(_sync);
  }

  void _dismiss() {
    final record = _record;
    if (record == null) return;
    _timer?.cancel();
    _hidden.add(_key(record));
    setState(() => _record = null);
  }

  void _sync() {
    final latest = widget.tracker.records.firstOrNull;
    BrowserTransactionRecord? next;
    if (latest != null && widget.tracker.isPresented(latest)) {
      // A send sheet is showing this one; whatever it shows is not repeated
      // here, so only a release while still pending brings it back.
      _seenPending.remove(_key(latest));
    } else if (latest != null && !_hidden.contains(_key(latest))) {
      final key = _key(latest);
      if (latest.status == BrowserTransactionStatus.pending) {
        if (DateTime.now().toUtc().difference(latest.createdAt) < _recent) {
          _seenPending.add(key);
          next = latest;
        }
      } else if (_seenPending.contains(key)) {
        next = latest;
        if (_record?.status != latest.status) {
          _timer?.cancel();
          _timer = Timer(_linger, () {
            _hidden.add(key);
            if (mounted) setState(() => _record = null);
          });
        }
      }
    }
    if (next == null) _timer?.cancel();
    _record = next;
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.suppressed ? null : _record;
    final reduceMotion = context.reduceMotion;
    final toastKey = record == null ? null : ValueKey(_key(record));
    final toast = AnimatedSwitcher(
      duration: MallowTheme.sheetDuration,
      switchInCurve: MallowTheme.sheetCurve,
      switchOutCurve: MallowTheme.sheetCurve,
      transitionBuilder: (child, animation) {
        final outgoing = child.key != toastKey;
        final fade = FadeTransition(
          opacity: animation,
          child: IgnorePointer(
            ignoring: outgoing,
            child: ExcludeSemantics(excluding: outgoing, child: child),
          ),
        );
        if (reduceMotion) return fade;
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.12),
            end: Offset.zero,
          ).animate(animation),
          child: fade,
        );
      },
      child: record == null
          ? const SizedBox.shrink()
          : BrowserStatusToast(
              key: toastKey,
              status: record.status,
              onView: () => widget.onView(record),
              onClose: _dismiss,
            ),
    );
    final bar = widget.child;
    if (bar == null) return toast;
    final showing = record != null;
    return Stack(
      alignment: Alignment.topCenter,
      clipBehavior: Clip.none,
      children: [
        IgnorePointer(
          ignoring: showing,
          child: ExcludeSemantics(
            excluding: showing,
            child: AnimatedSlide(
              offset: showing && !reduceMotion
                  ? const Offset(0, -0.12)
                  : Offset.zero,
              duration: MallowTheme.sheetDuration,
              curve: MallowTheme.sheetCurve,
              child: AnimatedOpacity(
                opacity: showing ? 0 : 1,
                duration: MallowTheme.sheetDuration,
                curve: MallowTheme.sheetCurve,
                child: bar,
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            MediaQuery.paddingOf(context).top + 6,
            12,
            6,
          ),
          child: Center(heightFactor: 1, child: toast),
        ),
      ],
    );
  }
}

/// The dark status pill that temporarily replaces the browser's address bar.
class BrowserStatusToast extends StatelessWidget {
  const BrowserStatusToast({
    required this.status,
    required this.onView,
    required this.onClose,
    super.key,
  });

  final BrowserTransactionStatus status;
  final VoidCallback onView;
  final VoidCallback onClose;

  static String label(BrowserTransactionStatus status) => switch (status) {
    BrowserTransactionStatus.pending => 'Transaction sent · Confirming',
    BrowserTransactionStatus.confirmed => 'Transaction confirmed',
    BrowserTransactionStatus.failed => 'Transaction failed',
    BrowserTransactionStatus.uncertain => 'Status uncertain · Check explorer',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final ink = BrowserToastSurface.ink(context);
    final Widget indicator = switch (status) {
      BrowserTransactionStatus.pending => _Spinner(
        color: colors.accent,
        track: ink.withValues(alpha: 0.2),
      ),
      BrowserTransactionStatus.confirmed => _Badge(
        color: colors.positive,
        child: MallowSvgIcon(
          'assets/icons/checkmark.svg',
          width: 10,
          height: 8,
          color: colors.textOnAccent,
        ),
      ),
      BrowserTransactionStatus.failed => _Badge(
        color: colors.error,
        child: MallowSvgIcon(
          'assets/icons/close.svg',
          width: 11,
          height: 11,
          color: ink,
        ),
      ),
      BrowserTransactionStatus.uncertain => MallowSvgIcon(
        'assets/icons/info_circle.svg',
        width: 18,
        height: 18,
        color: colors.warning,
      ),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: BrowserToastSurface(
        child: Stack(
          children: [
            if (status == BrowserTransactionStatus.confirmed)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: SuccessRipple(
                    color: colors.positive.withValues(alpha: 0.5),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: Center(child: indicator),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label(status),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiLabel.copyWith(color: ink),
                    ),
                  ),
                  const SizedBox(width: 10),
                  BrowserToastAction(
                    label: 'View',
                    semanticLabel: 'View transaction',
                    onTap: onView,
                  ),
                  const SizedBox(width: 4),
                  BrowserTap(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onClose();
                    },
                    label: 'Close transaction status',
                    minHitSize: 44,
                    child: SizedBox.square(
                      dimension: 32,
                      child: Center(
                        child: MallowSvgIcon(
                          'assets/icons/close.svg',
                          width: 14,
                          height: 14,
                          color: ink,
                        ),
                      ),
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

/// The pill the browser's toasts are drawn on.
class BrowserToastSurface extends StatelessWidget {
  const BrowserToastSurface({required this.child, super.key});

  final Widget child;

  /// An inverse pill in light mode, like a system toast. In dark mode the
  /// inverse would be a bright slab, so it stays a raised dark surface.
  static bool _inverse(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light;

  /// The colour of text and icons on the pill.
  static Color ink(BuildContext context) {
    final colors = context.mallowColors;
    return _inverse(context) ? colors.bgPrimary : colors.textPrimary;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final inverse = _inverse(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Container(
        constraints: BoxConstraints(
          minHeight: 44,
          maxWidth: MediaQuery.sizeOf(context).width - 32,
        ),
        decoration: BoxDecoration(
          color: inverse ? colors.textPrimary : colors.bgSurface,
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          border: inverse ? null : Border.all(color: colors.divider),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.22),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          child: child,
        ),
      ),
    );
  }
}

/// The accent capsule button on a [BrowserToastSurface].
class BrowserToastAction extends StatelessWidget {
  const BrowserToastAction({
    required this.label,
    required this.onTap,
    this.semanticLabel,
    super.key,
  });

  final String label;
  final VoidCallback onTap;

  /// Read by screen readers in place of [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => BrowserTap(
    onTap: () {
      HapticFeedback.selectionClick();
      onTap();
    },
    label: semanticLabel ?? label,
    minHitSize: 44,
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrowserToastSurface.ink(context).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
      ),
      child: Text(
        label,
        style: MallowTheme.uiLabel.copyWith(color: context.mallowColors.accent),
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: child,
  );
}

class _Spinner extends StatefulWidget {
  const _Spinner({required this.color, required this.track});

  final Color color;
  final Color track;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion holds a still quarter arc.
    if (context.reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _controller,
    child: CustomPaint(
      size: const Size.square(18),
      painter: _ArcPainter(color: widget.color, track: widget.track),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color, required this.track});

  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawArc(rect, 0, math.pi * 2, false, paint..color = track)
      ..drawArc(rect, -math.pi / 2, math.pi / 2, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.color != color || old.track != track;
}
