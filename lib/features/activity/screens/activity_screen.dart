import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/address_scope_key.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/pagination/pagination_bloc.dart';
import '../../../shared/pagination/pagination_scroll_listener.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../data/activity_repository.dart';
import '../services/activity_refresh_signal.dart';
import '../services/pending_tx_actions.dart';
import '../widgets/activity_day_header.dart';
import '../widgets/activity_list_item.dart';
import '../widgets/pending_activity_section.dart';
import '../widgets/pending_tx_detail_sheet.dart';
import 'activity_detail_screen.dart';

const _kActivityPageSize = 50;

/// Opens the activity sheet as a full-screen modal bottom sheet.
Future<void> showActivitySheet(BuildContext context) async {
  await showFullScreenSheet<void>(
    context: context,
    child: const _ActivitySheet(),
  );
}

/// The full-screen activity sheet with nested detail navigation.
class _ActivitySheet extends StatefulWidget {
  const _ActivitySheet();

  @override
  State<_ActivitySheet> createState() => _ActivitySheetState();
}

class _ActivitySheetState extends State<_ActivitySheet>
    with SingleTickerProviderStateMixin {
  api.Activity? _selectedActivity;

  /// Chain of the active wallet, used as a fallback by the detail screen.
  /// The feed aggregates all session wallet addresses, so individual rows can
  /// belong to a different chain and must infer their own chain first.
  Chain? _activeChain;

  late final AnimationController _slideController;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _loadActiveChain();
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeInOut),
        );
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _loadActiveChain() async {
    try {
      final selection = await sl<WalletRepository>().getActiveSelection();
      if (!mounted) return;
      setState(() => _activeChain = selection?.$2.chainEnum);
    } catch (_) {
      // Non-fatal: the detail screen falls back to signature-based inference.
    }
  }

  void _showDetail(api.Activity activity) {
    setState(() => _selectedActivity = activity);
    _slideController.forward();
  }

  void _hideDetail() {
    _slideController.reverse().then((_) {
      if (mounted) setState(() => _selectedActivity = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    // List stays mounted to preserve scroll position; detail slides on top.
    return Stack(
      children: [
        _ActivityListView(onActivityTap: _showDetail),
        if (_selectedActivity != null)
          SlideTransition(
            position: _slideAnimation,
            child: SizedBox.expand(
              child: ColoredBox(
                color: colors.bgSurface,
                child: ActivityDetailScreen(
                  activity: _selectedActivity!,
                  onBack: _hideDetail,
                  chain: _activeChain,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The scrollable activity list view inside the sheet.
class _ActivityListView extends StatefulWidget {
  const _ActivityListView({required this.onActivityTap});

  final ValueChanged<api.Activity> onActivityTap;

  @override
  State<_ActivityListView> createState() => _ActivityListViewState();
}

class _ActivityListViewState extends State<_ActivityListView> {
  final _scrollController = ScrollController();
  late final PaginationScrollListener _paginationListener;
  late final PaginationBloc<api.Activity> _bloc;

  /// Cursor for the activity endpoint. The API takes a `before` signature in
  /// addition to `page` — we thread the latest one through fetchPage so each
  /// load-more call asks for activity *strictly older* than the last item we
  /// already have. Threading via a state-let (rather than the bloc state)
  /// avoids leaking activity-specific fields into the generic
  /// [PaginationLoaded].
  String? _lastSignature;

  /// Unresolved EVM transactions, rendered as the Pending group at the top of
  /// the feed list. Subscribing also starts the tracker's watcher, and
  /// [PendingEvmTxTracker.refreshNow] runs one pass immediately so opening the
  /// sheet reflects the chain rather than the last poll.
  late final Stream<List<PendingEvmTx>> _pendingEvmTxs;

  /// Refetch trigger for "a tracked transaction resolved while you were
  /// looking at the feed". The Pending cell disappears the moment the tracker
  /// resolves the slot, but the confirmed row only exists server-side, so
  /// without this the transaction appears to vanish until the sheet is
  /// reopened. Guarded so tests that don't bootstrap DI skip the subscription.
  StreamSubscription<ActivityRefreshEvent>? _refreshSignalSub;

  /// Activity fetch error type is exposed by the snack-bar pathway below.
  /// Track the last shown error so we don't pop the same snackbar twice for
  /// the same loadMore failure (BlocListener fires on every emit).
  Object? _lastShownLoadMoreError;

  /// Optimistic sends received while this sheet is open. Keeping these until
  /// the next page-0 response means a slow indexer cannot erase the row that
  /// was just inserted while its refresh is in flight.
  final Map<String, api.Activity> _optimisticActivities = {};

  @override
  void initState() {
    super.initState();
    _bloc = _buildBloc();
    _paginationListener = PaginationScrollListener(
      controller: _scrollController,
      onLoadMore: () => _bloc.add(const PaginationLoadMoreRequested()),
      canLoadMore: () {
        final s = _bloc.state;
        return s is PaginationLoaded<api.Activity> &&
            s.hasMore &&
            !s.isLoadingMore;
      },
    )..attach();
    final tracker = sl<PendingEvmTxTracker>();
    _pendingEvmTxs = tracker.watch();
    unawaited(tracker.refreshNow());
    if (sl.isRegistered<ActivityRefreshSignal>()) {
      _refreshSignalSub = sl<ActivityRefreshSignal>().stream.listen((event) {
        if (!mounted) return;
        final activity = event.optimisticActivity;
        if (activity != null) {
          _optimisticActivities[activity.id] = activity;
          final alreadyVisible = _bloc.state.items.any(
            (item) => item.id == activity.id,
          );
          if (!alreadyVisible) {
            _bloc.add(PaginationItemsPrepended<api.Activity>([activity]));
          }
        }
        _bloc.add(const PaginationRefreshRequested());
      });
    }
    _initialLoad();
  }

  @override
  void dispose() {
    unawaited(_refreshSignalSub?.cancel());
    _paginationListener.detach();
    _scrollController.dispose();
    _bloc.close();
    super.dispose();
  }

  PaginationBloc<api.Activity> _buildBloc() {
    final repo = sl<ActivityRepository>();
    return PaginationBloc<api.Activity>(
      fetchPage: (page) async {
        // Aggregate the feed over every session wallet address; the backend
        // routes each address by chain (Solana/EVM/Tezos), merges, and pages
        // the combined result. Empty set → empty feed (nothing to aggregate).
        final addresses = _sessionAddresses();
        if (addresses.isEmpty) {
          return const PaginatedPage<api.Activity>(items: [], hasMore: false);
        }
        final cacheKey = addressScopeKey(addresses);
        try {
          final response = await repo.getActivities(
            addresses: addresses,
            page: page,
            limit: _kActivityPageSize,
            // Cursor only applies on subsequent pages; on page 0 we want the
            // freshest slice (no `before`), which also lets us reset the
            // cursor on a refresh that re-enters page 0.
            before: page == 0 ? null : _lastSignature,
          );
          _lastSignature = response.pagination.lastSignature;
          final activities = page == 0
              ? _mergeOptimistic(response.result)
              : response.result;
          await repo.cacheActivities(cacheKey, activities);
          return PaginatedPage(
            items: activities,
            hasMore: response.pagination.hasMore,
          );
        } on ActivityException {
          // First-page cache fallback so cold-open after a network blip
          // still shows something. Load-more failures are bubbled up — the
          // bloc keeps the existing items and surfaces `loadMoreError`.
          if (page == 0) {
            final cached = await repo.getCachedActivities(
              cacheKey,
              limit: _kActivityPageSize,
            );
            if (cached.isNotEmpty) {
              return PaginatedPage(
                items: cached,
                hasMore: cached.length >= _kActivityPageSize,
              );
            }
          }
          rethrow;
        }
      },
    );
  }

  /// The session's owner addresses — the set the feed aggregates over. Scoped
  /// to the active Account's held wallets (or, in Profile mode, the active
  /// Profile's linked wallets), matching `offers_inbox_bloc.dart`, and
  /// normalised for the backend's lowercased owner index.
  List<String> _sessionAddresses() => sl<SessionManager>().apiOwnerAddresses;

  List<api.Activity> _mergeOptimistic(List<api.Activity> serverItems) {
    final serverKeys = {
      for (final activity in serverItems) ...[activity.id, activity.signature],
    };
    final resolvedIds = _optimisticActivities.values
        .where(
          (activity) =>
              serverKeys.contains(activity.id) ||
              serverKeys.contains(activity.signature),
        )
        .map((activity) => activity.id)
        .toList();
    for (final id in resolvedIds) {
      _optimisticActivities.remove(id);
    }
    final merged = [
      ...serverItems,
      ..._optimisticActivities.values.where(
        (activity) =>
            !serverKeys.contains(activity.id) &&
            !serverKeys.contains(activity.signature),
      ),
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return merged;
  }

  /// Snappy-start sequence:
  ///   1. read cache off the DB.
  ///   2. if cache is non-empty: seed the bloc so the list paints instantly,
  ///      then refresh in the background to replace with fresh data.
  ///   3. if cache is empty: a plain load shows the skeleton until the API
  ///      returns.
  Future<void> _initialLoad() async {
    final repo = sl<ActivityRepository>();
    final addresses = _sessionAddresses();
    try {
      if (addresses.isEmpty) throw StateError('no session wallets');
      final cached = await repo.getCachedActivities(
        addressScopeKey(addresses),
        limit: _kActivityPageSize,
      );
      if (!mounted) return;
      if (cached.isNotEmpty) {
        _bloc.add(
          PaginationItemsSeeded(
            cached,
            hasMore: cached.length >= _kActivityPageSize,
          ),
        );
        _bloc.add(const PaginationRefreshRequested());
        return;
      }
    } catch (_) {
      // Cache read failure is non-fatal; fall through to a plain load.
    }
    if (!mounted) return;
    _bloc.add(const PaginationLoadRequested());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              Text(
                'Recent activity',
                style: MallowTheme.editorialQuote.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
              ),
              const Spacer(),
              // Branded loader in the header while a background refresh is in
              // flight (cache flashes instantly, network refetch runs behind
              // it). Fixed-size box reserves the slot so nothing shifts.
              BlocBuilder<
                PaginationBloc<api.Activity>,
                PaginationState<api.Activity>
              >(
                bloc: _bloc,
                buildWhen: (prev, curr) =>
                    _isRefreshing(prev) != _isRefreshing(curr),
                builder: (context, state) => SizedBox(
                  width: 20,
                  height: 20,
                  child: _isRefreshing(state)
                      ? const MallowLoader(size: 20)
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Expanded(
          child: StreamBuilder<List<PendingEvmTx>>(
            stream: _pendingEvmTxs,
            builder: (context, snapshot) =>
                BlocConsumer<
                  PaginationBloc<api.Activity>,
                  PaginationState<api.Activity>
                >(
                  bloc: _bloc,
                  listenWhen: (prev, curr) =>
                      curr is PaginationLoaded<api.Activity> &&
                      curr.loadMoreError != null &&
                      curr.loadMoreError != _lastShownLoadMoreError,
                  listener: (context, state) {
                    final loaded = state as PaginationLoaded<api.Activity>;
                    _lastShownLoadMoreError = loaded.loadMoreError;
                    AppSnackBar.show(
                      context,
                      _errorMessage(loaded.loadMoreError),
                    );
                  },
                  builder: (context, state) =>
                      _buildBody(snapshot.data ?? const [], state),
                ),
          ),
        ),
      ],
    );
  }

  /// One scroll view for everything under the header: the Pending group is the
  /// first section of the same list as the dated groups — a "day" before
  /// Today — so it scrolls with the feed and neither can squeeze the other
  /// off the sheet, however many slots are stuck.
  Widget _buildBody(
    List<PendingEvmTx> pending,
    PaginationState<api.Activity> state,
  ) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: PendingActivitySection(
            entries: pending,
            signableAddresses: sl<SessionManager>().signableSessionAddresses,
            onOpenDetail: (entry) => showPendingTxDetailSheet(context, entry),
            onSpeedUp: (entry) => promptSpeedUp(context, entry),
            onCancel: (entry) => promptCancel(context, entry),
          ),
        ),
        ..._feedSlivers(pending, state),
      ],
    );
  }

  List<Widget> _feedSlivers(
    List<PendingEvmTx> pending,
    PaginationState<api.Activity> state,
  ) {
    if (state is PaginationLoading<api.Activity>) {
      return const [SliverToBoxAdapter(child: _ActivitySkeletonList())];
    }
    if (state is PaginationError<api.Activity>) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: MallowErrorView(
            message: _errorMessage(state.error),
            onRetry: () => _bloc.add(const PaginationLoadRequested()),
          ),
        ),
      ];
    }
    if (state is PaginationLoaded<api.Activity>) {
      if (state.items.isEmpty && !state.isLoadingMore) {
        // "No activity yet" would contradict a pending transaction rendered
        // right above it, so with something in flight the group stands alone.
        if (pending.isNotEmpty) return const [];
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: MallowEmptyView(
              iconAsset: 'assets/icons/clock.svg',
              title: 'No activity yet',
              message:
                  'Your transactions will appear here once you start using your wallet.',
            ),
          ),
        ];
      }
      // A flat list with day headers inserted where the date changes. This
      // preserves the API's sort order so paginated items always append at
      // the bottom instead of being re-grouped into earlier day buckets.
      final items = _buildFlatItems(state.items);
      final itemCount =
          items.length + (state.hasMore || state.isLoadingMore ? 1 : 0);
      return [
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 40),
          sliver: SliverList.builder(
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (index < items.length) return items[index];
              return const _ActivitySkeletonItem();
            },
          ),
        ),
      ];
    }
    return const [];
  }

  List<Widget> _buildFlatItems(List<api.Activity> activities) {
    final items = <Widget>[];
    DateTime? currentDay;

    for (final activity in activities) {
      final day = DateTime(
        activity.dateTime.year,
        activity.dateTime.month,
        activity.dateTime.day,
      );

      if (day != currentDay) {
        currentDay = day;
        items.add(ActivityDayHeader(date: day));
      }

      items.add(
        Builder(
          builder: (context) => Column(
            children: [
              ActivityListItem(
                activity: activity,
                onTap: () => widget.onActivityTap(activity),
              ),
              Divider(
                height: 1,
                indent: MallowTheme.spacing20,
                endIndent: MallowTheme.spacing20,
                color: context.mallowColors.dividerLight,
              ),
            ],
          ),
        ),
      );
    }

    return items;
  }

  bool _isRefreshing(PaginationState<api.Activity> state) =>
      state is PaginationLoaded<api.Activity> && state.isRefreshing;

  String _errorMessage(Object? error) {
    if (error is ActivityException) return error.message;
    return 'Failed to load activities';
  }
}

class _ActivitySkeletonList extends StatelessWidget {
  const _ActivitySkeletonList();

  static const _itemsPerGroup = [4, 3];

  @override
  Widget build(BuildContext context) {
    final dividerColor = context.mallowColors.dividerLight;
    final children = <Widget>[];
    for (final count in _itemsPerGroup) {
      children.add(const _ActivitySkeletonDayHeader());
      for (var i = 0; i < count; i++) {
        children
          ..add(const _ActivitySkeletonItem())
          ..add(
            Divider(
              height: 1,
              indent: MallowTheme.spacing20,
              endIndent: MallowTheme.spacing20,
              color: dividerColor,
            ),
          );
      }
    }
    // A plain column: the host embeds this in its scroll view (where a nested
    // ListView would have unbounded height), and shimmer rows are non-tappable.
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: Column(children: children),
      ),
    );
  }
}

class _ActivitySkeletonDayHeader extends StatelessWidget {
  const _ActivitySkeletonDayHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacing20,
        bottom: MallowTheme.spacingSm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ShimmerBox(
          width: 80,
          height: 18,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

class _ActivitySkeletonItem extends StatelessWidget {
  const _ActivitySkeletonItem();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing20,
        vertical: MallowTheme.spacing12,
      ),
      child: Row(
        children: [
          ShimmerBox(
            width: 48,
            height: 48,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          const SizedBox(width: MallowTheme.spacing12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(
                  width: 100,
                  height: 16,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 6),
                ShimmerBox(
                  width: 140,
                  height: 12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
          ),
          const SizedBox(width: MallowTheme.spacing12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ShimmerBox(
                width: 60,
                height: 14,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              ShimmerBox(
                width: 40,
                height: 11,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Legacy ActivityScreen wrapper for backward compatibility (push notifications).
///
/// Immediately shows the activity sheet and pops itself when the sheet closes.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await showActivitySheet(context);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: context.mallowColors.bgPrimary);
  }
}
