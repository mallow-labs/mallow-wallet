import 'package:flutter/material.dart';

/// Fades content out and back in whenever [activeIndex] changes.
///
/// Pair with a tab bar that exposes the selected index (e.g.
/// `MallowUnderlineTabBar`) — the parent owns selection state, this widget
/// just bridges the swap with a short cross-fade so content doesn't pop.
class AnimatedTabContent extends StatefulWidget {
  const AnimatedTabContent({
    required this.activeIndex,
    required this.builder,
    this.duration = const Duration(milliseconds: 150),
    this.animateSize = true,
    super.key,
  });

  final int activeIndex;
  final IndexedWidgetBuilder builder;
  final Duration duration;

  /// Wraps the child in an [AnimatedSize] so the height transitions smoothly
  /// between tabs instead of snapping at swap time. On by default — opt out
  /// (`animateSize: false`) when the swap host is unbounded (e.g. a tab
  /// pinned above a large scrolling list whose intrinsic height fights the
  /// layout).
  final bool animateSize;

  @override
  State<AnimatedTabContent> createState() => _AnimatedTabContentState();
}

class _AnimatedTabContentState extends State<AnimatedTabContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic.flipped,
  );
  late int _visibleIndex = widget.activeIndex;

  @override
  void didUpdateWidget(AnimatedTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.activeIndex != _visibleIndex &&
        _controller.status != AnimationStatus.reverse) {
      _controller.reverse().then((_) {
        if (!mounted) return;
        setState(() => _visibleIndex = widget.activeIndex);
        _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = FadeTransition(
      opacity: _opacity,
      child: widget.builder(context, _visibleIndex),
    );
    if (!widget.animateSize) return fade;
    return AnimatedSize(
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: fade,
    );
  }
}

/// Sliver variant of [AnimatedTabContent]. The [builder] returns a single
/// sliver per tab — wrap multi-sliver content in [SliverMainAxisGroup].
class SliverAnimatedTabContent extends StatefulWidget {
  const SliverAnimatedTabContent({
    required this.activeIndex,
    required this.builder,
    this.duration = const Duration(milliseconds: 150),
    super.key,
  });

  final int activeIndex;
  final Widget Function(BuildContext, int) builder;
  final Duration duration;

  @override
  State<SliverAnimatedTabContent> createState() =>
      _SliverAnimatedTabContentState();
}

class _SliverAnimatedTabContentState extends State<SliverAnimatedTabContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic.flipped,
  );
  late int _visibleIndex = widget.activeIndex;

  @override
  void didUpdateWidget(SliverAnimatedTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.activeIndex != _visibleIndex &&
        _controller.status != AnimationStatus.reverse) {
      _controller.reverse().then((_) {
        if (!mounted) return;
        setState(() => _visibleIndex = widget.activeIndex);
        _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverFadeTransition(
      opacity: _opacity,
      sliver: widget.builder(context, _visibleIndex),
    );
  }
}
