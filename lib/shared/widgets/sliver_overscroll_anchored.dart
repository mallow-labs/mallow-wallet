import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A [SliverToBoxAdapter] that scrolls away normally but holds still when the
/// scroll view is pulled past its top edge.
///
/// The app-wide physics bounce (`MallowScrollBehavior`), so a plain header
/// sliver slides down with the content on a pull-to-refresh. This one stays
/// pinned to the viewport edge through the overscroll — the same thing a
/// pinned [SliverPersistentHeader] does — without pinning it during a normal
/// scroll. Use it for a screen's top navigation bar when that bar is the
/// first sliver of a [CustomScrollView].
///
/// Only the leading sliver sees the negative overlap the viewport hands out
/// during a top overscroll, so it has no effect anywhere else in the list.
class SliverOverscrollAnchored extends SingleChildRenderObjectWidget {
  const SliverOverscrollAnchored({required Widget super.child, super.key});

  @override
  RenderSliverOverscrollAnchored createRenderObject(BuildContext context) =>
      RenderSliverOverscrollAnchored();
}

class RenderSliverOverscrollAnchored extends RenderSliverToBoxAdapter {
  RenderSliverOverscrollAnchored({super.child});

  @override
  void performLayout() {
    super.performLayout();
    final g = geometry!;
    // During a top overscroll the viewport passes the first sliver a negative
    // overlap equal to the overscroll distance. Painting that far back up
    // cancels the pull; scroll/layout extents are untouched, so the content
    // below still moves with the finger.
    final pull = constraints.overlap < 0 ? constraints.overlap : 0.0;
    if (pull == 0) return;
    geometry = SliverGeometry(
      scrollExtent: g.scrollExtent,
      paintExtent: g.paintExtent,
      paintOrigin: pull,
      layoutExtent: g.layoutExtent,
      maxPaintExtent: g.maxPaintExtent,
      hitTestExtent: g.hitTestExtent,
      cacheExtent: g.cacheExtent,
      hasVisualOverflow: g.hasVisualOverflow,
    );
  }
}
