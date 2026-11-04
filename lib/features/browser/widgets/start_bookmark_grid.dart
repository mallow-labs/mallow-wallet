import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tappable.dart';
import '../models/browser_models.dart';
import 'browser_site_tile.dart';

/// Saved pages use the same icon size and responsive columns as Popular.
class StartBookmarkGrid extends StatefulWidget {
  const StartBookmarkGrid({
    required this.bookmarks,
    required this.reordering,
    required this.onOpen,
    required this.onMore,
    required this.onMove,
    super.key,
  });

  final List<BrowserBookmark> bookmarks;
  final bool reordering;
  final ValueChanged<BrowserBookmark> onOpen;
  final ValueChanged<BrowserBookmark> onMore;
  final void Function(Uri url, Uri target) onMove;

  @override
  State<StartBookmarkGrid> createState() => _StartBookmarkGridState();
}

class _StartBookmarkGridState extends State<StartBookmarkGrid> {
  static const _tile = 60.0;
  static const _gap = 12.0;
  EdgeDraggingAutoScroller? _autoScroller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    if (_autoScroller?.scrollable == scrollable) return;
    _autoScroller?.stopAutoScroll();
    _autoScroller = scrollable == null
        ? null
        : EdgeDraggingAutoScroller(scrollable, velocityScalar: 12);
  }

  @override
  void didUpdateWidget(StartBookmarkGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.reordering) _autoScroller?.stopAutoScroll();
  }

  @override
  void dispose() {
    _autoScroller?.stopAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = MediaQuery.textScalerOf(context).scale(12);
    final largeText = label > 16;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = label > 20 ? 2 : (largeText ? 3 : 4);
        final width = (constraints.maxWidth - _gap * (columns - 1)) / columns;
        return Wrap(
          spacing: _gap,
          runSpacing: 16,
          children: [
            for (final (index, bookmark) in widget.bookmarks.indexed)
              SizedBox(
                key: ValueKey(bookmark.url),
                width: width,
                child: _cell(bookmark, index, width, largeText),
              ),
          ],
        );
      },
    );
  }

  Widget _cell(
    BrowserBookmark bookmark,
    int index,
    double width,
    bool largeText,
  ) {
    final content = _BookmarkContent(
      bookmark: bookmark,
      twoLineLabel: largeText,
    );
    if (!widget.reordering) {
      return Semantics(
        button: true,
        label: 'Open ${bookmark.title}, ${bookmark.url.host}',
        onTap: () => widget.onOpen(bookmark),
        onLongPress: () => widget.onMore(bookmark),
        child: ExcludeSemantics(
          child: Tappable(
            onTap: () => widget.onOpen(bookmark),
            onLongPress: () => widget.onMore(bookmark),
            child: content,
          ),
        ),
      );
    }
    return Semantics(
      label:
          '${bookmark.title}, position ${index + 1} of ${widget.bookmarks.length}',
      hint: 'Drag to reorder',
      customSemanticsActions: {
        if (index > 0)
          const CustomSemanticsAction(label: 'Move earlier'): () =>
              widget.onMove(bookmark.url, widget.bookmarks[index - 1].url),
        if (index < widget.bookmarks.length - 1)
          const CustomSemanticsAction(label: 'Move later'): () =>
              widget.onMove(bookmark.url, widget.bookmarks[index + 1].url),
      },
      child: ExcludeSemantics(
        child: DragTarget<Uri>(
          onWillAcceptWithDetails: (details) => details.data != bookmark.url,
          onAcceptWithDetails: (details) =>
              widget.onMove(details.data, bookmark.url),
          builder: (context, candidates, rejected) => DecoratedBox(
            decoration: BoxDecoration(
              color: candidates.isEmpty
                  ? null
                  : context.mallowColors.surfaceMuted,
              borderRadius: BorderRadius.circular(MallowTheme.radiusLg),
              border: candidates.isEmpty
                  ? null
                  : Border.all(color: context.mallowColors.accent),
            ),
            child: Draggable<Uri>(
              data: bookmark.url,
              maxSimultaneousDrags: 1,
              onDragUpdate: (details) =>
                  _autoScroller?.startAutoScrollIfNecessary(
                    Rect.fromCenter(
                      center: details.globalPosition,
                      width: _tile,
                      height: _tile,
                    ),
                  ),
              onDragEnd: (_) => _autoScroller?.stopAutoScroll(),
              feedback: Material(
                type: MaterialType.transparency,
                child: SizedBox(width: width, child: content),
              ),
              childWhenDragging: Opacity(opacity: 0.25, child: content),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _BookmarkContent extends StatelessWidget {
  const _BookmarkContent({required this.bookmark, required this.twoLineLabel});

  final BrowserBookmark bookmark;
  final bool twoLineLabel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      BrowserSiteTile(
        host: bookmark.url.host,
        iconUrl: bookmark.iconUrl,
        size: _StartBookmarkGridState._tile,
      ),
      const SizedBox(height: MallowTheme.spacingSm),
      Text(
        bookmark.title,
        maxLines: twoLineLabel ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: MallowTheme.uiLabel.copyWith(
          fontSize: 12,
          height: 16 / 12,
          color: context.mallowColors.textPrimary,
        ),
      ),
    ],
  );
}
