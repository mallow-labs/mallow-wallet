import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/mallow_theme.dart';
import 'tap_target_expander.dart';

/// Underline tab bar matching the Figma spec:
/// all labels render in [MallowColors.textPrimary]; a 1px [MallowColors.divider]
/// runs the full width under every tab; a 2px [MallowColors.textPrimary]
/// underline marks the active tab and slides/resizes between tabs when
/// [activeIndex] changes.
///
/// Tabs are sized to their text content. When the combined tab width exceeds
/// the available horizontal space, the tab row scrolls horizontally; the
/// 1px divider always spans the full available width regardless of overflow.
class MallowUnderlineTabBar extends StatefulWidget {
  const MallowUnderlineTabBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTabSelected,
    this.duration = const Duration(milliseconds: 220),
    super.key,
  });

  final List<String> tabs;
  final int activeIndex;
  final ValueChanged<int> onTabSelected;
  final Duration duration;

  @override
  State<MallowUnderlineTabBar> createState() => _MallowUnderlineTabBarState();
}

class _MallowUnderlineTabBarState extends State<MallowUnderlineTabBar>
    with SingleTickerProviderStateMixin {
  late int _to = widget.activeIndex;

  /// Presentation anchor the active indicator animates *from*, in the same
  /// offset-space as the per-tab offsets/widths computed in [build]. Captured
  /// from the indicator's live position on every retarget so a tab tapped
  /// mid-slide continues from where the underline actually is instead of
  /// teleporting to the previous target. Null before the first move — the
  /// indicator then simply sits under the active tab.
  double? _startLeft;
  double? _startWidth;

  /// Latest offset-space geometry from [build], so [didUpdateWidget] can sample
  /// the indicator's current position when a new target arrives.
  List<double>? _lastOffsets;
  List<double>? _lastWidths;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// Per-tab keys for post-layout width measurement. The active 2px
  /// indicator is positioned from cumulative offsets; if those offsets
  /// drift even slightly from the actually-rendered tab widths the
  /// indicator visibly slips off the active label. `TextPainter`-based
  /// pre-measurement isn't reliable enough (font fallback, locale, text
  /// shaping all conspire to make the rendered `Text` width differ by a
  /// few pixels), so we read each tab's true rendered width via its key
  /// in a post-frame callback and re-render once.
  List<GlobalKey> _tabKeys = const [];
  List<double>? _renderedWidths;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void didUpdateWidget(MallowUnderlineTabBar old) {
    super.didUpdateWidget(old);
    if (widget.duration != old.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.activeIndex != _to) {
      // Capture the indicator's current presentation position as the new start
      // anchor, so retargeting mid-slide continues smoothly instead of jumping
      // to the previous target (offsets/widths are active-tab independent, so
      // the geometry cached in the last build is still valid here).
      final offsets = _lastOffsets;
      final widths = _lastWidths;
      if (offsets != null && widths != null && widths.isNotEmpty) {
        final toIdx = _to.clamp(0, widths.length - 1);
        final targetLeft = offsets[toIdx];
        final targetWidth = widths[toIdx];
        final t = _curved.value;
        _startLeft = lerpDouble(_startLeft ?? targetLeft, targetLeft, t);
        _startWidth = lerpDouble(_startWidth ?? targetWidth, targetWidth, t);
      } else {
        _startLeft = null;
        _startWidth = null;
      }
      _to = widget.activeIndex;
      _controller.forward(from: 0);
    }
    // Compare by CONTENT, not list identity: parents commonly rebuild the tab
    // labels into a fresh list instance every build (e.g. a `[for ...]`
    // comprehension), which is a new identity but the same tabs. An identity
    // check here would fire on every rebuild and null the slide anchor set just
    // above, collapsing the indicator animation to an instant snap.
    if (!listEquals(old.tabs, widget.tabs)) {
      _syncKeys();
      _renderedWidths = null;
      // Tab set genuinely changed → indices/offsets remap; drop the stale anchor
      // so the indicator settles onto the current target rather than a phantom
      // spot.
      _startLeft = null;
      _startWidth = null;
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncKeys() {
    if (_tabKeys.length != widget.tabs.length) {
      _tabKeys = List.generate(widget.tabs.length, (_) => GlobalKey());
    }
  }

  /// Read each tab's RenderBox width after the current frame and store
  /// the result. Triggers a single `setState` if widths changed; the
  /// callback then no-ops on subsequent frames until the tab list or
  /// rendered sizes change again.
  void _scheduleMeasure() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_tabKeys.length != widget.tabs.length) return;
      final widths = <double>[];
      for (final key in _tabKeys) {
        final ctx = key.currentContext;
        if (ctx == null) return;
        final ro = ctx.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return;
        widths.add(ro.size.width);
      }
      if (_renderedWidths == null || !_listsClose(_renderedWidths!, widths)) {
        setState(() => _renderedWidths = widths);
      }
    });
  }

  bool _listsClose(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.01) return false;
    }
    return true;
  }

  /// First-frame fallback: a `TextPainter`-based estimate of each tab's
  /// width. Rounded up to the next pixel so the surrounding row never
  /// overflows on the first paint, before [_renderedWidths] is populated.
  double _estimateTabWidth(String text, TextScaler textScaler) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: MallowTheme.uiCaption),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final width = tp.width.ceilToDouble();
    tp.dispose();
    return width + 2 * MallowTheme.spacingMd;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    _syncKeys();

    final colors = context.mallowColors;
    final textScaler = MediaQuery.textScalerOf(context);

    final widths =
        _renderedWidths ??
        [for (final t in widget.tabs) _estimateTabWidth(t, textScaler)];
    final offsets = <double>[];
    var x = 0.0;
    for (final w in widths) {
      offsets.add(x);
      x += w;
    }
    final totalWidth = x;

    final toIdx = _to.clamp(0, widths.length - 1);
    // Cache the geometry so a retarget in didUpdateWidget can sample the live
    // indicator position (see _startLeft / _startWidth).
    _lastOffsets = offsets;
    _lastWidths = widths;

    // Re-measure after this frame so the active indicator snaps onto the
    // truly-rendered tab widths. The callback only `setState`s when the
    // new measurement differs from the cached one, so this naturally
    // stabilizes after a frame or two.
    _scheduleMeasure();

    // LayoutBuilder pins a concrete width on the outer Stack so the inner
    // horizontal SingleChildScrollView always has a bounded viewport (it
    // would otherwise fail in loose-constraint parents like a Column with
    // `crossAxisAlignment.start`).
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : totalWidth;
        return SizedBox(
          width: viewportWidth,
          child: Stack(
            children: [
              // 1px full-width divider — always spans the available parent
              // width, regardless of whether the tab row overflows.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(height: 1, color: colors.divider),
              ),
              // Tabs + animated 2px active indicator. Scrolls horizontally
              // when the tabs collectively exceed [viewportWidth]; the 2px
              // indicator (drawn at the bottom of this scrolling content)
              // overlaps the 1px divider behind it on the active tab so the
              // active state's underline visually replaces the divider.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                // IntrinsicWidth sizes the inner Column to the Row's natural
                // width (sum of actual rendered tab widths). Avoids overflow
                // from `TextPainter`/`Text` sub-pixel mismatch that a
                // hard-coded `SizedBox(width: totalWidth)` would hit.
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < widget.tabs.length; i++)
                            _buildTab(i, colors),
                        ],
                      ),
                      SizedBox(
                        height: 2,
                        child: Stack(
                          children: [
                            AnimatedBuilder(
                              animation: _curved,
                              builder: (context, _) {
                                final t = _curved.value;
                                final targetLeft = offsets[toIdx];
                                final targetWidth = widths[toIdx];
                                final left = lerpDouble(
                                  _startLeft ?? targetLeft,
                                  targetLeft,
                                  t,
                                )!;
                                final width = lerpDouble(
                                  _startWidth ?? targetWidth,
                                  targetWidth,
                                  t,
                                )!;
                                return Positioned(
                                  left: left,
                                  width: width,
                                  bottom: 0,
                                  height: 2,
                                  child: ColoredBox(color: colors.textPrimary),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTab(int i, MallowColors colors) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onTabSelected(i),
        child: Padding(
          key: _tabKeys[i],
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingMd,
            vertical: MallowTheme.spacingSm,
          ),
          child: Text(
            widget.tabs[i],
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }
}
