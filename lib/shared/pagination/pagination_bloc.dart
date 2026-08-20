import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A single page returned by a paginated fetcher.
///
/// [items] is the slice for this page. [hasMore] is the authoritative
/// end-of-feed signal — true when the caller should keep paging.
class PaginatedPage<T> {
  const PaginatedPage({required this.items, required this.hasMore});

  /// Convenience for endpoints that don't return a `hasMore` flag: infer it
  /// from the page size (a short page means we're done).
  factory PaginatedPage.fromPageSize({
    required List<T> items,
    required int pageSize,
  }) => PaginatedPage(items: items, hasMore: items.length >= pageSize);

  final List<T> items;
  final bool hasMore;
}

sealed class PaginationEvent extends Equatable {
  const PaginationEvent();
  @override
  List<Object?> get props => const [];
}

class PaginationLoadRequested extends PaginationEvent {
  const PaginationLoadRequested();
}

class PaginationLoadMoreRequested extends PaginationEvent {
  const PaginationLoadMoreRequested();
}

class PaginationRefreshRequested extends PaginationEvent {
  const PaginationRefreshRequested();
}

/// Drop items matching [predicate] from the loaded list (e.g. after a burn).
class PaginationItemsRemoved<T> extends PaginationEvent {
  const PaginationItemsRemoved(this.predicate);
  final bool Function(T) predicate;
  @override
  List<Object?> get props => [predicate];
}

/// Replace items matching [predicate] with `update(item)` in the loaded list
/// (e.g. an optimistic hide/unhide flip). A no-op when nothing matches.
class PaginationItemsUpdated<T> extends PaginationEvent {
  const PaginationItemsUpdated(this.predicate, this.update);
  final bool Function(T) predicate;
  final T Function(T) update;
  @override
  List<Object?> get props => [predicate, update];
}

/// Insert items at the beginning of the loaded list.
class PaginationItemsPrepended<T> extends PaginationEvent {
  const PaginationItemsPrepended(this.items);
  final List<T> items;
  @override
  List<Object?> get props => [items];
}

/// Seed the loaded list with items from a non-network source (e.g. a local
/// cache). Only takes effect when the bloc is still in [PaginationInitial];
/// once a real fetch has started, the seed is dropped so a slow cache read
/// can't clobber fresh API data. Pair with [PaginationRefreshRequested] to
/// then refetch in the background — the cache flashes instantly while the
/// network call replaces it on success.
class PaginationItemsSeeded<T> extends PaginationEvent {
  const PaginationItemsSeeded(this.items, {this.hasMore = false});
  final List<T> items;
  final bool hasMore;
  @override
  List<Object?> get props => [items, hasMore];
}

sealed class PaginationState<T> extends Equatable {
  const PaginationState();

  List<T> get items;
  bool get isInitialLoading => this is PaginationLoading<T>;
  bool get hasError => this is PaginationError<T>;

  @override
  List<Object?> get props => const [];
}

class PaginationInitial<T> extends PaginationState<T> {
  const PaginationInitial();
  @override
  List<T> get items => const [];
}

class PaginationLoading<T> extends PaginationState<T> {
  const PaginationLoading();
  @override
  List<T> get items => const [];
}

class PaginationLoaded<T> extends PaginationState<T> {
  const PaginationLoaded({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
    this.isRefreshing = false,
    this.loadMoreError,
  });

  @override
  final List<T> items;
  final bool hasMore;
  final bool isLoadingMore;

  /// True while a [PaginationRefreshRequested] refetch is in flight. Lets
  /// pull-to-refresh hold its indicator until the new first page lands —
  /// and guarantees the refresh emits even when the refetched page is
  /// identical to the current one (bloc suppresses equal states).
  final bool isRefreshing;
  final Object? loadMoreError;

  PaginationLoaded<T> copyWith({
    List<T>? items,
    bool? hasMore,
    bool? isLoadingMore,
    bool? isRefreshing,
    Object? loadMoreError = _sentinel,
  }) => PaginationLoaded<T>(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    loadMoreError: identical(loadMoreError, _sentinel)
        ? this.loadMoreError
        : loadMoreError,
  );

  @override
  List<Object?> get props => [
    items,
    hasMore,
    isLoadingMore,
    isRefreshing,
    loadMoreError,
  ];
}

class PaginationError<T> extends PaginationState<T> {
  const PaginationError(this.error);
  final Object error;
  @override
  List<T> get items => const [];
  @override
  List<Object?> get props => [error];
}

const _sentinel = Object();

/// Generic pagination bloc.
///
/// Owns the page counter, hasMore flag, loading flags, and the merged item
/// list. The screen supplies a [fetchPage] callback that returns one page at
/// a time; the bloc handles ordering, re-entry, and error recovery.
///
/// Re-entry protection: `loadMore` is a no-op while a page is in flight, when
/// `hasMore` is false, or when not in [PaginationLoaded]. This is what
/// eliminates the double-load class of scroll-edge bugs.
class PaginationBloc<T> extends Bloc<PaginationEvent, PaginationState<T>> {
  PaginationBloc({
    required this.fetchPage,
    this.startPage = 0,
    List<T>? initialItems,
  }) : super(
         initialItems != null
             ? PaginationLoaded<T>(items: List.of(initialItems), hasMore: false)
             : PaginationInitial<T>(),
       ) {
    on<PaginationLoadRequested>(_onLoad);
    on<PaginationLoadMoreRequested>(_onLoadMore);
    on<PaginationRefreshRequested>(_onRefresh);
    on<PaginationItemsRemoved<T>>(_onItemsRemoved);
    on<PaginationItemsUpdated<T>>(_onItemsUpdated);
    on<PaginationItemsPrepended<T>>(_onItemsPrepended);
    on<PaginationItemsSeeded<T>>(_onItemsSeeded);
  }

  final Future<PaginatedPage<T>> Function(int page) fetchPage;
  final int startPage;

  int _currentPage = 0;

  int get currentPage => _currentPage;

  Future<void> _onLoad(
    PaginationLoadRequested event,
    Emitter<PaginationState<T>> emit,
  ) async {
    if (state is PaginationLoaded<T>) return;
    emit(PaginationLoading<T>());
    try {
      final page = await fetchPage(startPage);
      _currentPage = startPage;
      emit(
        PaginationLoaded<T>(items: List.of(page.items), hasMore: page.hasMore),
      );
    } catch (e) {
      emit(PaginationError<T>(e));
    }
  }

  Future<void> _onLoadMore(
    PaginationLoadMoreRequested event,
    Emitter<PaginationState<T>> emit,
  ) async {
    final current = state;
    if (current is! PaginationLoaded<T>) return;
    if (current.isLoadingMore || !current.hasMore) return;

    emit(current.copyWith(isLoadingMore: true, loadMoreError: null));
    final nextPage = _currentPage + 1;
    try {
      final page = await fetchPage(nextPage);
      _currentPage = nextPage;
      emit(
        current.copyWith(
          items: [...current.items, ...page.items],
          hasMore: page.hasMore,
          isLoadingMore: false,
        ),
      );
    } catch (e) {
      emit(current.copyWith(isLoadingMore: false, loadMoreError: e));
    }
  }

  Future<void> _onRefresh(
    PaginationRefreshRequested event,
    Emitter<PaginationState<T>> emit,
  ) async {
    final previous = state;
    if (previous is PaginationLoaded<T>) {
      emit(previous.copyWith(isRefreshing: true));
    }
    try {
      final page = await fetchPage(startPage);
      _currentPage = startPage;
      emit(
        PaginationLoaded<T>(items: List.of(page.items), hasMore: page.hasMore),
      );
    } catch (e) {
      final current = state;
      if (current is PaginationLoaded<T>) {
        emit(current.copyWith(isRefreshing: false, loadMoreError: e));
      } else {
        emit(PaginationError<T>(e));
      }
    }
  }

  void _onItemsRemoved(
    PaginationItemsRemoved<T> event,
    Emitter<PaginationState<T>> emit,
  ) {
    final current = state;
    if (current is! PaginationLoaded<T>) return;
    final next = current.items.where((e) => !event.predicate(e)).toList();
    if (next.length == current.items.length) return;
    emit(current.copyWith(items: next));
  }

  /// Convenience for screens — dispatches a [PaginationItemsRemoved] event.
  void removeWhere(bool Function(T) predicate) =>
      add(PaginationItemsRemoved<T>(predicate));

  void _onItemsUpdated(
    PaginationItemsUpdated<T> event,
    Emitter<PaginationState<T>> emit,
  ) {
    final current = state;
    if (current is! PaginationLoaded<T>) return;
    var changed = false;
    final next = [
      for (final item in current.items)
        if (event.predicate(item)) ...[event.update(item)] else ...[item],
    ];
    // Cheap reference-equality check so an update that no-ops (same instance
    // returned) doesn't emit a new state and rebuild the list.
    for (var i = 0; i < next.length; i++) {
      if (!identical(next[i], current.items[i])) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    emit(current.copyWith(items: next));
  }

  /// Convenience for screens — dispatches a [PaginationItemsUpdated] event.
  void updateWhere(bool Function(T) predicate, T Function(T) update) =>
      add(PaginationItemsUpdated<T>(predicate, update));

  void _onItemsPrepended(
    PaginationItemsPrepended<T> event,
    Emitter<PaginationState<T>> emit,
  ) {
    final current = state;
    if (current is! PaginationLoaded<T> || event.items.isEmpty) return;
    emit(current.copyWith(items: [...event.items, ...current.items]));
  }

  void _onItemsSeeded(
    PaginationItemsSeeded<T> event,
    Emitter<PaginationState<T>> emit,
  ) {
    if (state is! PaginationInitial<T>) return;
    emit(
      PaginationLoaded<T>(items: List.of(event.items), hasMore: event.hasMore),
    );
  }
}
