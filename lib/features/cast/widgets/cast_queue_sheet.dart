import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../models/cast_queue.dart';
import '../services/cast_bloc.dart';
import 'cast_error_view.dart';

/// Shows the cast queue management sheet — reorderable list with
/// swipe-left-to-delete. Settings/preferences live in the configuration sheet.
Future<void> showCastQueueSheet(BuildContext context) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: sl<CastBloc>(),
      child: const _CastQueueSheet(),
    ),
  );
}

class _CastQueueSheet extends StatelessWidget {
  const _CastQueueSheet();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.bgSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: BlocBuilder<CastBloc, CastState>(
            builder: (context, state) {
              // A dropped session used to leave this sheet completely blank —
              // no message, no way back. Render the failure and a retry, which
              // re-enters discovery with the queue the session was carrying.
              if (state is CastError) {
                return Column(
                  children: [
                    const SheetDragHandle(),
                    _Header(canClear: false, onClear: () {}, colors: colors),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          child: CastErrorView(message: state.message),
                        ),
                      ),
                    ),
                  ],
                );
              }
              final view = _viewModelOf(state);
              if (view == null) return const SizedBox.shrink();
              return Column(
                children: [
                  const SheetDragHandle(),
                  _Header(
                    canClear: view.items.isNotEmpty,
                    onClear: () {
                      context.read<CastBloc>().add(
                        const CastEvent.clearQueue(),
                      );
                      Navigator.of(context).pop();
                    },
                    colors: colors,
                  ),
                  Expanded(
                    child: view.items.isEmpty
                        ? _EmptyState(colors: colors)
                        : _QueueList(
                            items: view.items,
                            currentIndex: view.currentIndex,
                            scrollController: scrollController,
                            colors: colors,
                          ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.canClear,
    required this.onClear,
    required this.colors,
  });

  final bool canClear;
  final VoidCallback onClear;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        MallowTheme.spacingSm,
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Cast queue',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              textAlign: TextAlign.left,
            ),
          ),
          Opacity(
            opacity: canClear ? 1 : 0.4,
            child: TapTargetExpander(
              child: GestureDetector(
                onTap: canClear ? onClear : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacingMd,
                    vertical: MallowTheme.spacingXs + 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.textTertiary),
                    borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
                  ),
                  child: Text(
                    'Clear',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colors});

  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: Text(
          'No items in queue',
          style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}

/// Snapshot of what the queue sheet should render. [currentIndex] is null
/// when nothing is actively playing yet (pre-active states), in which case
/// no row is highlighted and tapping a row is a no-op (skipToIndex is
/// gated on an active session).
class _QueueView {
  const _QueueView({required this.items, required this.currentIndex});

  final List<CastQueueItem> items;
  final int? currentIndex;
}

_QueueView? _viewModelOf(CastState state) => switch (state) {
  CastActive(:final queue) => _QueueView(
    items: queue.items,
    currentIndex: queue.currentIndex,
  ),
  CastDiscovering(:final pendingItems) => _QueueView(
    items: pendingItems,
    currentIndex: null,
  ),
  CastConnecting(:final pendingItems) => _QueueView(
    items: pendingItems,
    currentIndex: null,
  ),
  _ => null,
};

class _QueueList extends StatelessWidget {
  const _QueueList({
    required this.items,
    required this.currentIndex,
    required this.scrollController,
    required this.colors,
  });

  final List<CastQueueItem> items;
  final int? currentIndex;
  final ScrollController scrollController;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final bottomInset = sheetBottomInset(context);
    return ReorderableListView.builder(
      scrollController: scrollController,
      buildDefaultDragHandles: false,
      padding: EdgeInsets.only(bottom: bottomInset),
      itemCount: items.length,
      onReorderItem: (oldIndex, newIndex) {
        context.read<CastBloc>().add(
          CastEvent.reorderQueue(oldIndex, newIndex),
        );
      },
      itemBuilder: (context, index) {
        final item = items[index];
        final isCurrent = currentIndex != null && index == currentIndex;
        return _DismissibleQueueRow(
          // Key must be stable across reorders for both Dismissible and
          // ReorderableListView — mintAccount + index covers duplicate mints.
          key: ValueKey('${item.mintAccount}_$index'),
          item: item,
          index: index,
          isCurrent: isCurrent,
          // Tapping to skip only makes sense when actively playing.
          tappable: currentIndex != null,
          colors: colors,
        );
      },
    );
  }
}

/// Artist row beneath the title. Renders `@handle` as a tap-through to the
/// user's profile when a username is set; otherwise falls back to the
/// display name (or `@unknown`) as plain text since there is no profile
/// to navigate to.
class _ArtistLabel extends StatelessWidget {
  const _ArtistLabel({required this.item, required this.color});

  final CastQueueItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = MallowTheme.uiCaption.copyWith(color: color);
    final username = item.artistUsername?.trim();
    if (username != null && username.isNotEmpty) {
      return UserHandleText(
        username: username,
        address: null,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final name = item.artistName?.trim();
    final fallback = (name != null && name.isNotEmpty) ? name : '@unknown';
    return Text(
      fallback,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _DismissibleQueueRow extends StatelessWidget {
  const _DismissibleQueueRow({
    required this.item,
    required this.index,
    required this.isCurrent,
    required this.tappable,
    required this.colors,
    super.key,
  });

  final CastQueueItem item;
  final int index;
  final bool isCurrent;
  final bool tappable;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('dismiss_${item.mintAccount}_$index'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: colors.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacingLg),
        child: MallowSvgIcon(
          'assets/icons/trash.svg',
          width: 20,
          height: 20,
          color: colors.textOnAccent,
        ),
      ),
      onDismissed: (_) =>
          context.read<CastBloc>().add(CastEvent.removeFromQueue(index)),
      child: ReorderableDelayedDragStartListener(
        index: index,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (!tappable || isCurrent)
              ? null
              : () =>
                    context.read<CastBloc>().add(CastEvent.skipToIndex(index)),
          child: Container(
            color: colors.bgSurface,
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
              vertical: MallowTheme.spacingSm,
            ),
            child: Row(
              children: [
                MallowNetworkImage(
                  imageUrl: item.imageUrl,
                  logicalSize: 52,
                  width: 52,
                  height: 52,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                ),
                const SizedBox(width: MallowTheme.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        style: MallowTheme.editorialQuote.copyWith(
                          color: isCurrent ? colors.accent : colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          SvgPicture.asset(
                            'assets/icons/queue.svg',
                            width: 11,
                            height: 11,
                            colorFilter: ColorFilter.mode(
                              colors.textSecondary,
                              BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: MallowTheme.spacingXs),
                          Flexible(
                            child: _ArtistLabel(
                              item: item,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 3-dot icon — design specifies the affordance but no action
                // is wired yet. Placeholder; future actions sheet hooks here.
                Padding(
                  padding: const EdgeInsets.all(MallowTheme.spacingSm),
                  child: SvgPicture.asset(
                    'assets/icons/dots_vertical.svg',
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(
                      colors.textSecondary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
