import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
// freezed generates an unprefixed reference to ExploreFilter's deep-copy
// helper for the `filter` field; bring just that symbol into scope so the
// generated `.freezed.dart` resolves it (the type itself stays `api.`-prefixed).
// ignore: unused_shown_name
import 'package:mallow_api/mallow_api.dart' show $ExploreFilterCopyWith;

import '../../../core/result/result.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../data/search_repository.dart';
import '../models/recently_viewed_item.dart';
import '../models/search_models.dart';

part 'search_bloc.freezed.dart';

/// Public events for the search sheet.
@freezed
sealed class SearchEvent with _$SearchEvent {
  /// User changed the search query (debounced internally).
  const factory SearchEvent.queryChanged(String query) = SearchQueryChanged;

  /// User cleared the search.
  const factory SearchEvent.clear() = SearchClear;

  /// User tapped a filter button on the landing page.
  const factory SearchEvent.filterSelected(SearchFilterType filterType) =
      SearchFilterSelected;

  /// User tapped back from filter results to return to landing.
  const factory SearchEvent.filterBack() = SearchFilterBack;

  /// Infinite scroll trigger — load more filter results.
  const factory SearchEvent.loadMoreFilterResults() =
      SearchLoadMoreFilterResults;

  /// User applied the filters sheet on an artwork drilldown. Refetches from
  /// page 0 — the filter is a server-side constraint, not a view of what's
  /// already loaded.
  const factory SearchEvent.setDrilldownFilter(api.ExploreFilter filter) =
      SearchSetDrilldownFilter;

  /// User picked a sort on an artwork drilldown. Also refetches from page 0
  /// (see [SearchRepository.fetchArtworkResults]).
  const factory SearchEvent.setDrilldownSort(PortfolioSortOption sort) =
      SearchSetDrilldownSort;

  /// User tapped the view toggle on an artwork drilldown:
  /// masonry → detail → grid → masonry.
  const factory SearchEvent.toggleDrilldownViewMode() =
      SearchToggleDrilldownViewMode;

  /// User tapped a recent search item.
  const factory SearchEvent.recentSearchTapped(String query) =
      SearchRecentSearchTapped;

  /// User tapped "Clear all" on recent searches.
  const factory SearchEvent.clearRecentSearches() = SearchClearRecentSearches;

  /// User tapped "Clear all" on recently viewed.
  const factory SearchEvent.clearRecentlyViewed() = SearchClearRecentlyViewed;

  /// Internal: debounce timer fired — execute the search now.
  const factory SearchEvent.execute(String query) = _SearchExecute;
}

/// States for the search sheet.
@freezed
sealed class SearchState with _$SearchState {
  /// Initial/empty state — landing page with recent searches and recently
  /// viewed content.
  const factory SearchState.initial({
    @Default([]) List<String> recentSearches,
    @Default([]) List<RecentlyViewedItem> recentlyViewed,
  }) = SearchInitial;

  /// Searching in progress.
  const factory SearchState.loading() = SearchLoading;

  /// Text search results loaded.
  const factory SearchState.loaded({
    required SearchResults results,
    required String query,
  }) = SearchLoaded;

  /// Error state.
  const factory SearchState.error({required String message}) = SearchError;

  /// Non-artwork drilldown results — `curations` and `exhibitions`, which
  /// render as plain rows with no filter/sort/view bar.
  const factory SearchState.filterResults({
    required SearchFilterType filterType,
    required List<FilterResultItem> items,
    required int currentPage,
    @Default(true) bool hasMore,
    @Default(false) bool isLoadingMore,
  }) = SearchFilterResults;

  /// Artwork drilldown results — every explore-backed filter type (see
  /// [SearchFilterType.isArtworkBrowse]). Carries the same filter / sort /
  /// view-mode knobs as the portfolio's "Artworks" tab.
  ///
  /// [filter] holds only what the user picked in the sheet; the drilldown's
  /// own constraint is pinned on at fetch time, so it can never be cleared.
  const factory SearchState.artworkResults({
    required SearchFilterType filterType,
    required List<PortfolioArtwork> artworks,
    required int currentPage,
    @Default(api.ExploreFilter()) api.ExploreFilter filter,
    @Default(PortfolioSortOption.recent) PortfolioSortOption sort,
    @Default(ArtworkViewMode.masonry) ArtworkViewMode artworkViewMode,
    @Default(true) bool hasMore,
    @Default(false) bool isLoadingMore,

    /// A filter or sort change is in flight: the list is cleared but the bar
    /// stays on screen so the change that caused it remains undoable.
    @Default(false) bool isRefetching,
  }) = SearchArtworkResults;

  /// Filter results loading (first page).
  const factory SearchState.filterLoading({
    required SearchFilterType filterType,
  }) = SearchFilterLoading;
}

/// BLoC for the search feature.
///
/// Debounces [SearchQueryChanged] events by 250ms using an internal
/// [_SearchExecute] event dispatched after the timer fires.
@injectable
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc(this._repository)
    : super(
        SearchState.initial(
          recentSearches: sl<PreferencesService>().recentSearches,
          recentlyViewed: sl<PreferencesService>().recentlyViewed,
        ),
      ) {
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchClear>(_onClear);
    on<_SearchExecute>(_onExecute);
    on<SearchFilterSelected>(_onFilterSelected);
    on<SearchFilterBack>(_onFilterBack);
    on<SearchLoadMoreFilterResults>(_onLoadMore);
    on<SearchSetDrilldownFilter>(_onSetDrilldownFilter);
    on<SearchSetDrilldownSort>(_onSetDrilldownSort);
    on<SearchToggleDrilldownViewMode>(_onToggleDrilldownViewMode);
    on<SearchRecentSearchTapped>(_onRecentSearchTapped);
    on<SearchClearRecentSearches>(_onClearRecentSearches);
    on<SearchClearRecentlyViewed>(_onClearRecentlyViewed);
  }

  final SearchRepository _repository;

  Timer? _debounceTimer;
  String _currentQuery = '';

  /// Generation of the artwork drilldown's result set. Bumped by every fetch
  /// that *replaces* the list (drilldown open, filter change, sort change) and
  /// by every exit that *discards* it (back, clear); captured by the one that
  /// *appends* to it (pagination).
  ///
  /// The drilldown events run concurrently and are not cancellable, so two
  /// quick filter taps leave two fetches in flight. If the first one resolves
  /// last it would emit a full state built from its own captured filter/sort —
  /// showing the superseded results *and* reverting the bar to the selection
  /// the user just replaced. The generation check drops it instead.
  int _artworkGen = 0;

  PreferencesService get _prefs => sl<PreferencesService>();

  /// The landing state, re-read from storage so both lists reflect the latest
  /// persisted values (recent searches and recently viewed content).
  SearchState get _landingState => SearchState.initial(
    recentSearches: _prefs.recentSearches,
    recentlyViewed: _prefs.recentlyViewed,
  );

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    return super.close();
  }

  // ---------------------------------------------------------------------------
  // Text search
  // ---------------------------------------------------------------------------

  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    final query = event.query.trim();
    _currentQuery = query;
    _debounceTimer?.cancel();

    if (query.isEmpty) {
      emit(_landingState);
      return;
    }

    emit(const SearchState.loading());

    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      if (!isClosed) add(SearchEvent.execute(query));
    });
  }

  Future<void> _onExecute(
    _SearchExecute event,
    Emitter<SearchState> emit,
  ) async {
    if (_currentQuery != event.query) return;

    final result = await Result.guard(() => _repository.search(event.query));
    // The query may have changed while the request was in flight; drop a
    // stale result rather than clobbering the newer search.
    if (_currentQuery != event.query) return;

    switch (result) {
      case ResultSuccess(:final value):
        // Save to recent searches
        await _prefs.saveRecentSearch(event.query);
        emit(SearchState.loaded(results: value, query: event.query));
      case ResultFailure(:final error):
        // Keep stable, actionable copy for users; the raw failure detail
        // (which is error.toString() for `unknown`) goes to logs only.
        debugPrint('[SearchBloc] Search failed: ${error.message}');
        emit(const SearchState.error(message: 'Search failed. Try again.'));
    }
  }

  void _onClear(SearchClear event, Emitter<SearchState> emit) {
    _debounceTimer?.cancel();
    _currentQuery = '';
    // Leaving the drilldown invalidates its fetches for the same reason a
    // newer filter does — see [_artworkGen].
    _artworkGen++;
    emit(_landingState);
  }

  // ---------------------------------------------------------------------------
  // Recent searches
  // ---------------------------------------------------------------------------

  void _onRecentSearchTapped(
    SearchRecentSearchTapped event,
    Emitter<SearchState> emit,
  ) {
    _currentQuery = event.query;
    emit(const SearchState.loading());
    add(SearchEvent.execute(event.query));
  }

  Future<void> _onClearRecentSearches(
    SearchClearRecentSearches event,
    Emitter<SearchState> emit,
  ) async {
    await _prefs.clearRecentSearches();
    // Preserve recently-viewed content; only the searches were cleared.
    emit(_landingState);
  }

  Future<void> _onClearRecentlyViewed(
    SearchClearRecentlyViewed event,
    Emitter<SearchState> emit,
  ) async {
    await _prefs.clearRecentlyViewed();
    // Preserve recent searches; only the recently-viewed list was cleared.
    emit(_landingState);
  }

  // ---------------------------------------------------------------------------
  // Filter browsing
  // ---------------------------------------------------------------------------

  Future<void> _onFilterSelected(
    SearchFilterSelected event,
    Emitter<SearchState> emit,
  ) async {
    emit(SearchState.filterLoading(filterType: event.filterType));

    if (event.filterType.isArtworkBrowse) {
      await _loadArtworkPage(
        emit,
        filterType: event.filterType,
        filter: const api.ExploreFilter(),
        sort: PortfolioSortOption.recent,
        artworkViewMode: await loadArtworkViewMode(),
      );
      return;
    }

    final result = await _repository.fetchFilterResults(event.filterType);
    switch (result) {
      case ResultSuccess(:final value):
        emit(
          SearchState.filterResults(
            filterType: event.filterType,
            items: value,
            currentPage: 0,
            hasMore: value.length >= 40,
          ),
        );
      case ResultFailure(:final error):
        // Surface the failure instead of an empty result set: a transport
        // error must read as an error (with retry) rather than an
        // indistinguishable "no results here". Stable user copy; the typed
        // detail goes to logs only.
        debugPrint('[SearchBloc] Filter fetch failed: ${error.message}');
        emit(
          const SearchState.error(message: "Couldn't load results. Try again."),
        );
    }
  }

  void _onFilterBack(SearchFilterBack event, Emitter<SearchState> emit) {
    _currentQuery = '';
    // As in [_onClear]: a drilldown fetch still in flight belongs to a list the
    // user has left, so it must not emit artworkResults over the landing page
    // and drag them back into the drilldown.
    _artworkGen++;
    emit(_landingState);
  }

  Future<void> _onLoadMore(
    SearchLoadMoreFilterResults event,
    Emitter<SearchState> emit,
  ) async {
    if (state is SearchArtworkResults) {
      await _loadMoreArtworks(emit);
      return;
    }

    final current = state;
    if (current is! SearchFilterResults ||
        current.isLoadingMore ||
        !current.hasMore) {
      return;
    }

    // Curations don't paginate
    if (current.filterType == SearchFilterType.curations) return;

    emit(current.copyWith(isLoadingMore: true));

    final nextPage = current.currentPage + 1;
    final result = await _repository.fetchFilterResults(
      current.filterType,
      page: nextPage,
    );
    switch (result) {
      case ResultSuccess(:final value):
        emit(
          SearchState.filterResults(
            filterType: current.filterType,
            items: [...current.items, ...value],
            currentPage: nextPage,
            hasMore: value.length >= 40,
          ),
        );
      case ResultFailure(:final error):
        // A failed later page must not wipe already-loaded results — drop the
        // spinner and keep what's on screen so the user can retry the scroll.
        debugPrint('[SearchBloc] Load more failed: ${error.message}');
        emit(current.copyWith(isLoadingMore: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Artwork drilldown (filter / sort / view mode)
  // ---------------------------------------------------------------------------

  Future<void> _onSetDrilldownFilter(
    SearchSetDrilldownFilter event,
    Emitter<SearchState> emit,
  ) async {
    final current = state;
    if (current is! SearchArtworkResults) return;
    if (current.filter == event.filter) return;

    // Clear the list but keep the bar: the filter that caused the refetch has
    // to stay visible and undoable while it's in flight.
    emit(
      current.copyWith(
        filter: event.filter,
        artworks: const [],
        currentPage: 0,
        hasMore: true,
        isLoadingMore: false,
        isRefetching: true,
      ),
    );

    await _loadArtworkPage(
      emit,
      filterType: current.filterType,
      filter: event.filter,
      sort: current.sort,
      artworkViewMode: current.artworkViewMode,
    );
  }

  Future<void> _onSetDrilldownSort(
    SearchSetDrilldownSort event,
    Emitter<SearchState> emit,
  ) async {
    final current = state;
    if (current is! SearchArtworkResults) return;
    if (current.sort == event.sort) return;

    emit(
      current.copyWith(
        sort: event.sort,
        artworks: const [],
        currentPage: 0,
        hasMore: true,
        isLoadingMore: false,
        isRefetching: true,
      ),
    );

    await _loadArtworkPage(
      emit,
      filterType: current.filterType,
      filter: current.filter,
      sort: event.sort,
      artworkViewMode: current.artworkViewMode,
    );
  }

  // Synchronous emit-then-persist, mirroring PortfolioBloc: the toggle must
  // not open an await window between reading and re-emitting the state, and
  // the UI shouldn't wait on a best-effort preference write.
  //
  // The drilldown shares the app-wide artwork layout with the portfolio's
  // "Artworks" tab and the profile, so the layout the user picked follows them
  // across every artwork list. Both of those blocs are DI factories that
  // re-read on load, so a change made here lands the next time either mounts.
  void _onToggleDrilldownViewMode(
    SearchToggleDrilldownViewMode event,
    Emitter<SearchState> emit,
  ) {
    final current = state;
    if (current is! SearchArtworkResults) return;

    final next = current.artworkViewMode.next;
    emit(current.copyWith(artworkViewMode: next));
    unawaited(saveArtworkViewMode(next));
  }

  /// Fetch page 0 of an artwork drilldown and emit the result. Shared by the
  /// initial open and by every filter/sort change — both are server-side
  /// constraints, so both refetch rather than re-slice what's loaded.
  Future<void> _loadArtworkPage(
    Emitter<SearchState> emit, {
    required SearchFilterType filterType,
    required api.ExploreFilter filter,
    required PortfolioSortOption sort,
    required ArtworkViewMode artworkViewMode,
  }) async {
    // Bumped, not captured: this fetch replaces the list, so an earlier
    // filter/sort fetch still in flight must drop its result when it lands.
    final gen = ++_artworkGen;

    final result = await _repository.fetchArtworkResults(
      filterType,
      filter: filter,
      sort: _exploreSort(sort),
    );
    // Superseded by a newer filter/sort change — both branches below would
    // emit this run's captured filter and sort over the newer selection.
    if (isClosed || gen != _artworkGen) return;

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          SearchState.artworkResults(
            filterType: filterType,
            artworks: value,
            currentPage: 0,
            filter: filter,
            sort: sort,
            artworkViewMode: artworkViewMode,
            hasMore: value.length >= 40,
          ),
        );
      case ResultFailure(:final error):
        // Same contract as the non-artwork drilldowns: a transport error must
        // read as an error, never as an empty result set.
        debugPrint('[SearchBloc] Artwork fetch failed: ${error.message}');
        emit(
          const SearchState.error(message: "Couldn't load results. Try again."),
        );
    }
  }

  Future<void> _loadMoreArtworks(Emitter<SearchState> emit) async {
    final current = state;
    if (current is! SearchArtworkResults ||
        current.isLoadingMore ||
        current.isRefetching ||
        !current.hasMore) {
      return;
    }

    // Captured, not bumped: a page append doesn't replace the list, but the
    // page belongs to the list as of now — if a filter/sort change replaces it
    // mid-flight, drop the page instead of splicing it into the new list.
    final gen = _artworkGen;
    emit(current.copyWith(isLoadingMore: true));

    final nextPage = current.currentPage + 1;
    final result = await _repository.fetchArtworkResults(
      current.filterType,
      page: nextPage,
      filter: current.filter,
      sort: _exploreSort(current.sort),
    );
    if (isClosed || gen != _artworkGen) return;
    // Re-read rather than reusing `current`: a view-mode toggle may have landed
    // while the page was in flight, and copying the pre-fetch state back would
    // revert it.
    final latest = state;
    if (latest is! SearchArtworkResults) return;

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          latest.copyWith(
            artworks: [...latest.artworks, ...value],
            currentPage: nextPage,
            hasMore: value.length >= 40,
            isLoadingMore: false,
          ),
        );
      case ResultFailure(:final error):
        // As above: keep the loaded pages, just drop the spinner.
        debugPrint('[SearchBloc] Artwork load more failed: ${error.message}');
        emit(latest.copyWith(isLoadingMore: false));
    }
  }

  /// The wire sort for a [PortfolioSortOption]. `count` orders groups by item
  /// count and is never offered on an artwork list, so it falls back to the
  /// default rather than inventing an ordering.
  static api.ExploreSort _exploreSort(PortfolioSortOption sort) =>
      switch (sort) {
        PortfolioSortOption.name => api.ExploreSort.alphabetical,
        PortfolioSortOption.recent ||
        PortfolioSortOption.count => api.ExploreSort.recentActivity,
      };
}
