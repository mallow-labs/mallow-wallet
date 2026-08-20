import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// One page of a [PagedSection] fetch: the rows plus the next page index
/// (null when the listing is exhausted).
typedef PagedResult<T> = ({List<T> items, int? nextPage});

/// Paged list section for the artwork page tabs (History / Offers). Owns
/// the load-more state machine: fetches page 0 on mount, renders a
/// "Load more" affordance while [fetchPage] reports another page, and
/// falls back to [emptyLabel] before the first rows land — or, when the
/// first fetch *threw*, to [errorLabel] plus a "Try again" retry. Those two
/// states are deliberately distinct: an empty history and an unreachable one
/// mean opposite things to someone checking provenance.
///
/// When [refreshToken] changes (bumped by the parent on an indexer-driven
/// refresh) the section re-pulls page 0 *in the background*: the current
/// rows stay on screen — no spinner flash — and any newly-arrived rows
/// fade in at the top. This replaces the old remount-on-key approach,
/// which cleared the list and flashed the loading indicator on every
/// refresh even when data was already showing.
class PagedSection<T> extends StatefulWidget {
  const PagedSection({
    required this.fetchPage,
    required this.rowBuilder,
    required this.emptyLabel,
    this.errorLabel,
    this.refreshToken = 0,
    this.identity,
    super.key,
  });

  final Future<PagedResult<T>> Function(int page) fetchPage;
  final Widget Function(T item) rowBuilder;

  /// Shown when the first page comes back empty.
  final String emptyLabel;

  /// Shown instead of [emptyLabel] when the latest fetch threw. Null falls
  /// back to [emptyLabel].
  final String? errorLabel;

  /// Bumped by the parent to request a background refresh of page 0. A
  /// change triggers an in-place re-pull that preserves the visible rows.
  final int refreshToken;

  /// Stable identity for a row, used to key rows across a background
  /// refresh so unchanged rows are reused (no re-animation) and genuinely
  /// new rows can fade in. Null disables keyed reuse and entry animation.
  final String Function(T item)? identity;

  @override
  State<PagedSection<T>> createState() => _PagedSectionState<T>();
}

class _PagedSectionState<T> extends State<PagedSection<T>> {
  final List<T> _items = [];
  int? _nextPage = 0;
  bool _loading = false;
  bool _failed = false;

  /// Background page-0 re-pull in flight. Distinct from [_loading]: it does
  /// NOT gate the empty-state spinner, so the current rows stay visible.
  bool _refreshing = false;

  /// A refresh requested while one was already in flight — coalesced and
  /// run once the current one finishes (the listing flow fires two).
  bool _refreshQueued = false;

  /// Row identities added by the most recent background refresh. Newly
  /// mounted rows whose id is in here fade in; everything else appears flat.
  Set<String> _entering = const {};

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void didUpdateWidget(covariant PagedSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshToken != oldWidget.refreshToken) {
      if (_items.isEmpty) {
        // Nothing on screen to preserve — reset pagination and reload from
        // the top (the empty-state spinner here is harmless).
        _nextPage = 0;
        _loadMore();
      } else {
        _refresh();
      }
    }
  }

  Future<void> _loadMore() async {
    final page = _nextPage;
    if (_loading || page == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await widget.fetchPage(page);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _nextPage = result.nextPage;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Re-pull page 0 without clearing the list. Swaps in the fresh window
  /// once it lands, marking rows not previously shown so they fade in.
  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    setState(() => _refreshing = true);
    try {
      final result = await widget.fetchPage(0);
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _failed = false;
        final entering = <String>{};
        final identity = widget.identity;
        if (identity != null) {
          final existing = _items.map(identity).toSet();
          for (final item in result.items) {
            final id = identity(item);
            if (!existing.contains(id)) entering.add(id);
          }
        }
        _entering = entering;
        _items
          ..clear()
          ..addAll(result.items);
        _nextPage = result.nextPage;
      });
    } catch (_) {
      // Keep the existing rows on a failed background refresh.
      if (!mounted) return;
      setState(() => _refreshing = false);
    }
    if (_refreshQueued && mounted) {
      _refreshQueued = false;
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    if (_items.isEmpty) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: MallowTheme.spacingMd),
          child: Center(child: MallowLoadingIndicator()),
        );
      }
      final caption = MallowTheme.uiCaption.copyWith(
        color: colors.textSecondary,
      );
      // A failed first page is NOT an empty one. Say so, and give the user a
      // way out — otherwise a dropped request reads as "this artwork has no
      // history", which on a provenance surface is worse than an error.
      if (_failed) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.errorLabel ?? widget.emptyLabel, style: caption),
            TapTargetExpander(
              child: GestureDetector(
                onTap: _loadMore,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: MallowTheme.spacingSm),
                  child: Text(
                    'Try again',
                    style: MallowTheme.uiCaption.copyWith(color: colors.accent),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return Text(widget.emptyLabel, style: caption);
    }
    final identity = widget.identity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in _items)
          if (identity == null)
            widget.rowBuilder(item)
          else
            _EnteringRow(
              key: ValueKey(identity(item)),
              animate: _entering.contains(identity(item)),
              child: widget.rowBuilder(item),
            ),
        if (_nextPage != null)
          Align(
            alignment: Alignment.centerLeft,
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: MallowTheme.spacingSm,
                    ),
                    child: MallowLoadingIndicator(),
                  )
                : TapTargetExpander(
                    child: GestureDetector(
                      onTap: _loadMore,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: MallowTheme.spacingSm,
                        ),
                        child: Text(
                          'Load more',
                          style: MallowTheme.uiCaption.copyWith(
                            color: colors.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}

/// Wraps a row so it fades + expands into place the first time it mounts as
/// part of a background refresh. Reused rows (matched by key) keep their
/// state, so their [initState] never re-runs and they don't animate.
class _EnteringRow extends StatefulWidget {
  const _EnteringRow({required this.animate, required this.child, super.key});

  final bool animate;
  final Widget child;

  @override
  State<_EnteringRow> createState() => _EnteringRowState();
}

class _EnteringRowState extends State<_EnteringRow>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _curve;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      final controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
      );
      _controller = controller;
      _curve = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
      controller.forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    if (curve == null) return widget.child;
    return SizeTransition(
      sizeFactor: curve,
      alignment: const AlignmentDirectional(-1.0, -1.0),
      child: FadeTransition(opacity: curve, child: widget.child),
    );
  }
}
