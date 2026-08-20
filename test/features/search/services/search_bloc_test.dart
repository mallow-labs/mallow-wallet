import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/search/data/search_repository.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:mallow_wallet/features/search/services/search_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockRepo extends Mock implements SearchRepository {}

PortfolioArtwork _artwork(int i) => PortfolioArtwork(
  mintAccount: 'mint$i',
  title: 'art$i',
  imageUrl: 'https://img/$i.png',
  artistName: 'artist',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockRepo repo;

  setUpAll(() {
    registerFallbackValue(const api.ExploreFilter());
    registerFallbackValue(api.ExploreSort.recentActivity);
    registerFallbackValue(SearchFilterType.auction);
  });

  setUp(() async {
    repo = _MockRepo();

    // SearchBloc reads recent searches from `sl<PreferencesService>()` in its
    // initializer, so a real instance backed by mocked prefs must be present.
    SharedPreferences.setMockInitialValues({});
    if (sl.isRegistered<PreferencesService>()) {
      await sl.unregister<PreferencesService>();
    }
    sl.registerSingleton<PreferencesService>(await PreferencesService.create());
  });

  tearDown(() async {
    if (sl.isRegistered<PreferencesService>()) {
      await sl.unregister<PreferencesService>();
    }
  });

  SearchBloc buildBloc() => SearchBloc(repo);

  group('SearchBloc text search', () {
    blocTest<SearchBloc, SearchState>(
      'emits loading then loaded with the repository results',
      setUp: () {
        when(() => repo.search('art')).thenAnswer(
          (_) async => const SearchResults(
            tokens: [
              SearchTokenResult(
                mintAddress: 'mint',
                name: 'Token',
                symbol: 'TKN',
              ),
            ],
          ),
        );
      },
      build: buildBloc,
      // recentSearchTapped sets the current query and dispatches the internal
      // execute event, exercising the same path as the debounced search.
      act: (bloc) => bloc.add(const SearchEvent.recentSearchTapped('art')),
      expect: () => [
        const SearchState.loading(),
        isA<SearchLoaded>()
            .having((s) => s.query, 'query', 'art')
            .having((s) => s.results.tokens.length, 'token count', 1),
      ],
    );

    blocTest<SearchBloc, SearchState>(
      'surfaces stable copy without leaking raw error text when the repository throws',
      setUp: () {
        when(() => repo.search('art')).thenThrow(Exception('boom'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const SearchEvent.recentSearchTapped('art')),
      // The user must see fixed, actionable copy — never the interpolated
      // exception text ('boom'), which is error.toString() for `unknown`.
      expect: () => [
        const SearchState.loading(),
        isA<SearchError>()
            .having((s) => s.message, 'message', 'Search failed. Try again.')
            .having((s) => s.message, 'no raw detail', isNot(contains('boom'))),
      ],
    );
  });

  group('SearchBloc filter results', () {
    // A first-page filter fetch failure must surface
    // as an error the user can distinguish from an empty result set — the old
    // code swallowed it to a blank "no results" list. This is the behaviour the
    // Result/AppFailure migration exists to guarantee, so it must be pinned.
    blocTest<SearchBloc, SearchState>(
      'surfaces SearchError with stable copy (not the raw failure) when the '
      'first filter page fails',
      setUp: () {
        when(
          () => repo.fetchFilterResults(SearchFilterType.exhibitions),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.network('backend down')),
        );
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const SearchEvent.filterSelected(SearchFilterType.exhibitions),
      ),
      expect: () => [
        const SearchState.filterLoading(
          filterType: SearchFilterType.exhibitions,
        ),
        // Fixed, actionable copy — never the interpolated failure message
        // ('backend down'), which would leak transport detail to the UI.
        isA<SearchError>()
            .having(
              (s) => s.message,
              'message',
              "Couldn't load results. Try again.",
            )
            .having(
              (s) => s.message,
              'no raw detail',
              isNot(contains('backend down')),
            ),
      ],
    );

    // A failed *later* page (infinite scroll) must keep the already-loaded
    // items on screen and just drop the spinner — never wipe the list back to
    // empty. This is the second half of the migration's contract.
    final firstPage = List.generate(
      40,
      (i) => FilterResultItem(title: 'item$i'),
    );
    blocTest<SearchBloc, SearchState>(
      'keeps loaded items and clears the spinner when a later page fails',
      setUp: () {
        when(
          () => repo.fetchFilterResults(SearchFilterType.exhibitions),
        ).thenAnswer((_) async => ResultSuccess(firstPage));
        when(
          () => repo.fetchFilterResults(SearchFilterType.exhibitions, page: 1),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.network('page 2 down')),
        );
      },
      build: buildBloc,
      act: (bloc) => bloc
        ..add(const SearchEvent.filterSelected(SearchFilterType.exhibitions))
        ..add(const SearchEvent.loadMoreFilterResults()),
      // Final state must still hold the 40 loaded items with the spinner off —
      // the failure path must not blank the list.
      expect: () => [
        const SearchState.filterLoading(
          filterType: SearchFilterType.exhibitions,
        ),
        isA<SearchFilterResults>()
            .having((s) => s.items.length, 'items after page 0', 40)
            .having((s) => s.isLoadingMore, 'not loading', false),
        isA<SearchFilterResults>().having(
          (s) => s.isLoadingMore,
          'spinner on',
          true,
        ),
        isA<SearchFilterResults>()
            .having((s) => s.items.length, 'items preserved', 40)
            .having((s) => s.isLoadingMore, 'spinner dropped', false),
      ],
    );
  });

  group('SearchBloc artwork drilldown', () {
    /// Fetches held open so a test can choose the order two racing drilldown
    /// fetches resolve in.
    late Completer<Result<List<PortfolioArtwork>, AppFailure>> pendingFilterX;
    late Completer<Result<List<PortfolioArtwork>, AppFailure>> pendingFilterY;
    late Completer<Result<List<PortfolioArtwork>, AppFailure>> pendingPage;

    /// Opens a drilldown and waits for its first page to land before the test
    /// acts again. The open reads the shared view-mode pref asynchronously, so
    /// an event added immediately after `filterSelected` would arrive while
    /// the state is still `filterLoading` and be dropped by the guard. This
    /// also mirrors the real sequence — the user cannot scroll or re-filter a
    /// list that has not rendered yet.
    Future<void> openDrilldown(SearchBloc bloc, SearchFilterType type) async {
      bloc.add(SearchEvent.filterSelected(type));
      await bloc.stream.firstWhere((s) => s is SearchArtworkResults);
    }

    void stubFirstPage(List<PortfolioArtwork> artworks) {
      when(
        () => repo.fetchArtworkResults(
          any(),
          page: any(named: 'page'),
          filter: any(named: 'filter'),
          sort: any(named: 'sort'),
        ),
      ).thenAnswer((_) async => ResultSuccess(artworks));
    }

    // The two drilldown families are served by different endpoints with
    // different item models. Routing by isArtworkBrowse is what keeps the
    // artwork views from being handed exhibition rows.
    blocTest<SearchBloc, SearchState>(
      'routes an explore-backed filter to the artwork fetch, not the item one',
      setUp: () => stubFirstPage([_artwork(0)]),
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) => bloc.add(
        const SearchEvent.filterSelected(SearchFilterType.category3D),
      ),
      expect: () => [
        const SearchState.filterLoading(
          filterType: SearchFilterType.category3D,
        ),
        isA<SearchArtworkResults>()
            .having((s) => s.artworks.length, 'artworks', 1)
            .having((s) => s.sort, 'default sort', PortfolioSortOption.recent)
            .having(
              (s) => s.filter,
              'no user filter',
              const api.ExploreFilter(),
            ),
      ],
      verify: (_) {
        verifyNever(
          () => repo.fetchFilterResults(any(), page: any(named: 'page')),
        );
      },
    );

    // Same contract as the item drilldowns: a dead endpoint must not
    // render as "no results".
    blocTest<SearchBloc, SearchState>(
      'surfaces stable error copy when the first artwork page fails',
      setUp: () {
        when(
          () => repo.fetchArtworkResults(
            any(),
            page: any(named: 'page'),
            filter: any(named: 'filter'),
            sort: any(named: 'sort'),
          ),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.network('backend down')),
        );
      },
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) =>
          bloc.add(const SearchEvent.filterSelected(SearchFilterType.auction)),
      expect: () => [
        const SearchState.filterLoading(filterType: SearchFilterType.auction),
        isA<SearchError>()
            .having(
              (s) => s.message,
              'message',
              "Couldn't load results. Try again.",
            )
            .having(
              (s) => s.message,
              'no raw detail',
              isNot(contains('backend down')),
            ),
      ],
    );

    blocTest<SearchBloc, SearchState>(
      'keeps loaded artworks and clears the spinner when a later page fails',
      setUp: () {
        when(
          () => repo.fetchArtworkResults(
            SearchFilterType.auction,
            page: 0,
            filter: any(named: 'filter'),
            sort: any(named: 'sort'),
          ),
        ).thenAnswer((_) async => ResultSuccess(List.generate(40, _artwork)));
        when(
          () => repo.fetchArtworkResults(
            SearchFilterType.auction,
            page: 1,
            filter: any(named: 'filter'),
            sort: any(named: 'sort'),
          ),
        ).thenAnswer(
          (_) async => const ResultFailure(AppFailure.network('page 2 down')),
        );
      },
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.auction);
        bloc.add(const SearchEvent.loadMoreFilterResults());
      },
      skip: 2, // filterLoading + first page
      expect: () => [
        isA<SearchArtworkResults>().having(
          (s) => s.isLoadingMore,
          'spinner on',
          true,
        ),
        isA<SearchArtworkResults>()
            .having((s) => s.artworks.length, 'artworks preserved', 40)
            .having((s) => s.isLoadingMore, 'spinner dropped', false),
      ],
    );

    // Filter and sort are server-side constraints, so both have to refetch
    // page 0. Re-slicing the loaded page would reorder a window rather than
    // the result set, and disagree with itself as the user scrolls.
    blocTest<SearchBloc, SearchState>(
      'applying a filter refetches page 0 with the new filter',
      setUp: () => stubFirstPage([_artwork(0)]),
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.category3D);
        bloc.add(
          const SearchEvent.setDrilldownFilter(
            api.ExploreFilter(mediaTypes: ['video']),
          ),
        );
      },
      skip: 2,
      expect: () => [
        // Bar stays put while the refetch runs, so the change is undoable.
        isA<SearchArtworkResults>()
            .having((s) => s.isRefetching, 'refetching', true)
            .having((s) => s.artworks, 'list cleared', isEmpty)
            .having((s) => s.filter.mediaTypes, 'filter applied', ['video']),
        isA<SearchArtworkResults>()
            .having((s) => s.isRefetching, 'settled', false)
            .having((s) => s.currentPage, 'back to page 0', 0)
            .having((s) => s.filter.mediaTypes, 'filter kept', ['video']),
      ],
      verify: (_) {
        verify(
          () => repo.fetchArtworkResults(
            SearchFilterType.category3D,
            page: 0,
            filter: const api.ExploreFilter(mediaTypes: ['video']),
            sort: api.ExploreSort.recentActivity,
          ),
        ).called(1);
      },
    );

    blocTest<SearchBloc, SearchState>(
      'sorting by name refetches with the alphabetical wire sort',
      setUp: () => stubFirstPage([_artwork(0)]),
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.editions);
        bloc.add(const SearchEvent.setDrilldownSort(PortfolioSortOption.name));
      },
      skip: 3,
      expect: () => [
        isA<SearchArtworkResults>()
            .having((s) => s.sort, 'sort', PortfolioSortOption.name)
            .having((s) => s.isRefetching, 'settled', false),
      ],
      verify: (_) {
        verify(
          () => repo.fetchArtworkResults(
            SearchFilterType.editions,
            page: 0,
            filter: const api.ExploreFilter(),
            sort: api.ExploreSort.alphabetical,
          ),
        ).called(1);
      },
    );

    // The drilldown events run on the default concurrent transformer and bloc
    // cannot cancel an in-flight handler, so two quick taps leave two fetches
    // racing. Each fetch emits a whole state built from the filter/sort it
    // captured, so the loser landing last does not just show superseded
    // artworks — it reverts the filter bar to the selection the user already
    // replaced, silently undoing their pick.
    const filterX = api.ExploreFilter(mediaTypes: ['video']);
    const filterY = api.ExploreFilter(mediaTypes: ['image']);

    blocTest<SearchBloc, SearchState>(
      'keeps the newest filter when the previous filter fetch lands last',
      setUp: () {
        pendingFilterX = Completer();
        pendingFilterY = Completer();
        when(
          () => repo.fetchArtworkResults(
            any(),
            page: any(named: 'page'),
            filter: any(named: 'filter'),
            sort: any(named: 'sort'),
          ),
        ).thenAnswer((invocation) {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          if (filter == filterX) return pendingFilterX.future;
          if (filter == filterY) return pendingFilterY.future;
          // The drilldown's own opening page — unfiltered, resolves at once.
          return Future.value(ResultSuccess([_artwork(0)]));
        });
      },
      build: buildBloc,
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.category3D);
        bloc.add(const SearchEvent.setDrilldownFilter(filterX));
        await pumpEventQueue();
        bloc.add(const SearchEvent.setDrilldownFilter(filterY));
        await pumpEventQueue();
        // Y is what the user is looking at, and its fetch answers first...
        pendingFilterY.complete(ResultSuccess([_artwork(2)]));
        await pumpEventQueue();
        // ...then the superseded X answers. It must be dropped.
        pendingFilterX.complete(ResultSuccess([_artwork(1)]));
        await pumpEventQueue();
      },
      skip: 2, // filterLoading + the drilldown's opening page
      expect: () => [
        isA<SearchArtworkResults>()
            .having((s) => s.filter, 'bar moves to X', filterX)
            .having((s) => s.isRefetching, 'refetching', true),
        isA<SearchArtworkResults>()
            .having((s) => s.filter, 'bar moves to Y', filterY)
            .having((s) => s.isRefetching, 'refetching', true),
        isA<SearchArtworkResults>()
            .having((s) => s.filter, 'settles on Y', filterY)
            .having(
              (s) => s.artworks.single.mintAccount,
              "Y's results",
              'mint2',
            )
            .having((s) => s.isRefetching, 'settled', false),
        // No fourth state: X emits nothing at all once superseded.
      ],
      verify: (bloc) {
        final state = bloc.state as SearchArtworkResults;
        expect(
          state.filter,
          filterY,
          reason: 'the late X fetch must not revert the bar to its own filter',
        );
        expect(
          state.artworks.single.mintAccount,
          'mint2',
          reason: "the late X fetch must not replace Y's results",
        );
      },
    );

    // Pagination shares the same fetch. A page is an append against the list as
    // it was when the scroll fired, so once a filter change has replaced that
    // list the page belongs to a result set that is no longer on screen —
    // splicing it in would mix the old filter's artworks into the new one's.
    blocTest<SearchBloc, SearchState>(
      'drops an in-flight page when a filter change replaces the list',
      setUp: () {
        pendingPage = Completer();
        when(
          () => repo.fetchArtworkResults(
            any(),
            page: any(named: 'page'),
            filter: any(named: 'filter'),
            sort: any(named: 'sort'),
          ),
        ).thenAnswer((invocation) {
          final page = invocation.namedArguments[#page] as int?;
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          if (page == 1) return pendingPage.future;
          if (filter == filterX) {
            return Future.value(ResultSuccess([_artwork(9)]));
          }
          // A full opening page, so the list reports more to load.
          return Future.value(ResultSuccess(List.generate(40, _artwork)));
        });
      },
      build: buildBloc,
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.auction);
        bloc.add(const SearchEvent.loadMoreFilterResults());
        await pumpEventQueue();
        bloc.add(const SearchEvent.setDrilldownFilter(filterX));
        await pumpEventQueue();
        pendingPage.complete(ResultSuccess([_artwork(40)]));
        await pumpEventQueue();
      },
      skip: 2, // filterLoading + the drilldown's opening page
      expect: () => [
        isA<SearchArtworkResults>().having(
          (s) => s.isLoadingMore,
          'spinner on',
          true,
        ),
        isA<SearchArtworkResults>()
            .having((s) => s.filter, 'bar moves to X', filterX)
            .having((s) => s.isRefetching, 'refetching', true),
        isA<SearchArtworkResults>()
            .having(
              (s) => s.artworks.single.mintAccount,
              "X's results",
              'mint9',
            )
            .having((s) => s.currentPage, 'back to page 0', 0),
        // No fourth state: the page 1 of the pre-filter list is dropped.
      ],
    );

    // Leaving the drilldown discards its result set just as surely as a newer
    // filter replaces it. A fetch that lands afterwards would emit
    // artworkResults over the landing page, dragging the user back into the
    // drilldown they just left — with a list they never asked to see again.
    for (final (name, exitEvent) in const <(String, SearchEvent)>[
      ('back', SearchEvent.filterBack()),
      ('clear', SearchEvent.clear()),
    ]) {
      blocTest<SearchBloc, SearchState>(
        'drops an in-flight drilldown fetch once $name has returned to the '
        'landing page',
        setUp: () {
          pendingFilterX = Completer();
          when(
            () => repo.fetchArtworkResults(
              any(),
              page: any(named: 'page'),
              filter: any(named: 'filter'),
              sort: any(named: 'sort'),
            ),
          ).thenAnswer((invocation) {
            final filter =
                invocation.namedArguments[#filter] as api.ExploreFilter?;
            if (filter == filterX) return pendingFilterX.future;
            return Future.value(ResultSuccess([_artwork(0)]));
          });
        },
        build: buildBloc,
        act: (bloc) async {
          await openDrilldown(bloc, SearchFilterType.category3D);
          bloc.add(const SearchEvent.setDrilldownFilter(filterX));
          await pumpEventQueue();
          bloc.add(exitEvent);
          await pumpEventQueue();
          pendingFilterX.complete(ResultSuccess([_artwork(1)]));
          await pumpEventQueue();
        },
        skip: 2, // filterLoading + the drilldown's opening page
        expect: () => [
          isA<SearchArtworkResults>()
              .having((s) => s.filter, 'bar moves to X', filterX)
              .having((s) => s.isRefetching, 'refetching', true),
          isA<SearchInitial>(),
          // No third state: the landing page is the last word.
        ],
        verify: (bloc) => expect(
          bloc.state,
          isA<SearchInitial>(),
          reason: 'a late drilldown fetch must not re-enter the drilldown',
        ),
      );
    }

    blocTest<SearchBloc, SearchState>(
      'view toggle cycles masonry to list to grid and back',
      setUp: () => stubFirstPage([_artwork(0)]),
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.buyNow);
        bloc
          ..add(const SearchEvent.toggleDrilldownViewMode())
          ..add(const SearchEvent.toggleDrilldownViewMode())
          ..add(const SearchEvent.toggleDrilldownViewMode());
      },
      skip: 2,
      expect: () => [
        isA<SearchArtworkResults>().having(
          (s) => s.artworkViewMode,
          'detail',
          ArtworkViewMode.detail,
        ),
        isA<SearchArtworkResults>().having(
          (s) => s.artworkViewMode,
          'grid',
          ArtworkViewMode.grid,
        ),
        isA<SearchArtworkResults>().having(
          (s) => s.artworkViewMode,
          'back to masonry',
          ArtworkViewMode.masonry,
        ),
      ],
    );

    // The view preference is app-wide: the layout picked here is the one the
    // portfolio's "Artworks" tab and the profile read on their next load, so
    // it must land on the shared key, not a search-local one.
    blocTest<SearchBloc, SearchState>(
      'persists the view mode under the shared app-wide artwork key',
      setUp: () => stubFirstPage([_artwork(0)]),
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) async {
        await openDrilldown(bloc, SearchFilterType.buyNow);
        bloc.add(const SearchEvent.toggleDrilldownViewMode());
      },
      verify: (_) async {
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(artworkViewModePrefsKey),
          ArtworkViewMode.detail.name,
        );
        expect(
          prefs.getString(groupViewModePrefsKey),
          isNull,
          reason: 'the drilldown has no group tabs, so it never writes theirs',
        );
      },
    );

    // ...and read back from it, so a detail-view choice made in the portfolio
    // opens the drilldown in detail view rather than the masonry default.
    blocTest<SearchBloc, SearchState>(
      'opens in the view mode the portfolio last persisted',
      setUp: () {
        SharedPreferences.setMockInitialValues({
          artworkViewModePrefsKey: 'detail',
        });
        stubFirstPage([_artwork(0)]);
      },
      build: buildBloc,
      // The drilldown reads the shared view-mode pref before its first
      // emit; bloc_test's default window closes before that async hop.
      wait: const Duration(milliseconds: 50),
      act: (bloc) =>
          bloc.add(const SearchEvent.filterSelected(SearchFilterType.buyNow)),
      skip: 1,
      expect: () => [
        isA<SearchArtworkResults>().having(
          (s) => s.artworkViewMode,
          'detail',
          ArtworkViewMode.detail,
        ),
      ],
    );
  });
}
