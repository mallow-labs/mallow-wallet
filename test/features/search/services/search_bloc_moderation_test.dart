import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/search/data/search_repository.dart';
import 'package:mallow_wallet/features/search/models/recently_viewed_item.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:mallow_wallet/features/search/services/search_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../moderation/support/moderation_fakes.dart';

// The repository filters every fetch. These cover the other half: results
// already on screen when the viewer blocks an account or reports something
// from a route pushed on top of them, and paging that follows the pages the
// repository actually read.

class _MockRepo extends Mock implements SearchRepository {}

const _blocked = 'BlockedArtist1111111111111111111111111111111';
const _artist = 'SomeArtist111111111111111111111111111111111';
const _target = TagDrilldownTarget('sunset');

PortfolioArtwork _artwork(String mint) => PortfolioArtwork(
  mintAccount: mint,
  title: mint,
  imageUrl: 'https://img/$mint.png',
  artistName: 'artist',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockRepo repo;
  late ModerationFilter moderation;
  late BlockStore blocks;
  late ModerationHideStore hides;
  late Map<int, Result<ArtworkResultsPage, AppFailure>> pages;
  late List<int> pagesAsked;

  setUpAll(() {
    registerFallbackValue(const api.ExploreFilter());
    registerFallbackValue(api.ExploreSort.recentActivity);
    registerFallbackValue(SearchFilterType.auction);
    registerFallbackValue(() {});
  });

  setUp(() async {
    ModerationFilter.resetAttributions();
    final m = moderationOver();
    moderation = m.filter;
    blocks = m.blocks;
    hides = m.hides;
    repo = _MockRepo();
    pages = {};
    pagesAsked = [];
    when(
      () => repo.fetchArtworkResults(
        any(),
        page: any(named: 'page'),
        filter: any(named: 'filter'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((invocation) async {
      final page = invocation.namedArguments[#page] as int? ?? 0;
      pagesAsked.add(page);
      return pages[page] ??
          ResultSuccess(
            ArtworkResultsPage(artworks: const [], page: page, hasMore: false),
          );
    });

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

  SearchBloc buildBloc() {
    final bloc = SearchBloc(repo, moderation: () => moderation);
    addTearDown(bloc.close);
    return bloc;
  }

  /// What the repository does as artworks pass through it: tells the filter
  /// who made each one.
  void seen(String mint, String creator) =>
      moderation.hidesArtwork(mint, by: [creator]);

  Result<ArtworkResultsPage, AppFailure> page(
    List<String> mints, {
    required int number,
    required bool hasMore,
  }) => ResultSuccess(
    ArtworkResultsPage(
      artworks: mints.map(_artwork).toList(),
      page: number,
      hasMore: hasMore,
    ),
  );

  Future<SearchArtworkResults> open(SearchBloc bloc) async {
    bloc.add(const SearchEvent.drilldownOpened(_target));
    return await bloc.stream.firstWhere((s) => s is SearchArtworkResults)
        as SearchArtworkResults;
  }

  Future<SearchArtworkResults> settled(SearchBloc bloc) async {
    await pumpEventQueue();
    return bloc.state as SearchArtworkResults;
  }

  group('drilldown paging', () {
    // The repository skips pages the filter emptied. Asking for
    // "current + 1" off the page that was requested would fetch one of the
    // skipped pages again.
    test('pages on from the last page the repository read', () async {
      pages[0] = page(['a'], number: 2, hasMore: true);
      pages[3] = page(['b'], number: 3, hasMore: false);
      final bloc = buildBloc();

      final first = await open(bloc);
      expect(first.currentPage, 2);
      expect(first.hasMore, isTrue);

      bloc.add(const SearchEvent.loadMoreFilterResults());
      final second = await settled(bloc);

      expect(pagesAsked, [0, 3]);
      expect(second.artworks.map((a) => a.mintAccount), ['a', 'b']);
      expect(second.hasMore, isFalse);
    });

    // A page shortened by the filter is not the end of the list.
    test('takes "is there more" from the repository, not the page '
        'length', () async {
      pages[0] = page(['a', 'b'], number: 0, hasMore: true);
      final bloc = buildBloc();

      final first = await open(bloc);

      expect(first.artworks, hasLength(2));
      expect(first.hasMore, isTrue);
    });

    test(
      'a first page with nothing left and no more is "no results"',
      () async {
        pages[0] = page([], number: 4, hasMore: false);
        final bloc = buildBloc();

        final first = await open(bloc);

        expect(first.artworks, isEmpty);
        expect(first.hasMore, isFalse);
      },
    );
  });

  group('a block made while a drilldown is on screen', () {
    test('drops the blocked artist\'s work in place and loads the next '
        'page', () async {
      seen('theirs-1', _blocked);
      seen('theirs-2', _blocked);
      seen('fine', _artist);
      pages[0] = page(
        ['theirs-1', 'fine', 'theirs-2'],
        number: 0,
        hasMore: true,
      );
      pages[1] = page(['next'], number: 1, hasMore: false);
      final bloc = buildBloc();
      await open(bloc);

      blocks.blocked.value = {_blocked};
      final after = await settled(bloc);

      expect(after.artworks.map((a) => a.mintAccount), ['fine', 'next']);
      expect(pagesAsked, [0, 1], reason: 'no refetch from the top');
    });

    test('a list it empties does not show "no results" while the next page '
        'is loading, and ends if that page is empty too', () async {
      seen('theirs', _blocked);
      pages[0] = page(['theirs'], number: 0, hasMore: true);
      // The repository already read past the filtered pages and found
      // nothing, with more still on the server.
      pages[1] = page([], number: 5, hasMore: true);
      final bloc = buildBloc();
      await open(bloc);

      final states = <SearchArtworkResults>[];
      final sub = bloc.stream.listen(
        (s) => states.add(s as SearchArtworkResults),
      );
      addTearDown(sub.cancel);
      blocks.blocked.value = {_blocked};
      final after = await settled(bloc);

      expect(
        states.where((s) => s.artworks.isEmpty && s.isLoadingMore),
        isNotEmpty,
        reason: 'the screen shows its skeleton for this state',
      );
      expect(after.artworks, isEmpty);
      expect(after.hasMore, isFalse, reason: 'nothing left to ask with');
      expect(after.isLoadingMore, isFalse);
      expect(pagesAsked, [0, 1], reason: 'one more fetch, not a loop');
    });

    test('nothing changes when the blocked account has nothing in the '
        'list', () async {
      seen('fine', _artist);
      pages[0] = page(['fine'], number: 0, hasMore: false);
      final bloc = buildBloc();
      final before = await open(bloc);

      blocks.blocked.value = {_blocked};
      final after = await settled(bloc);

      expect(after, before);
      expect(pagesAsked, [0]);
    });
  });

  // A drilldown's first page loads while the bloc still reports the landing
  // state. A change that lands in that window must not cancel the page: the
  // screen would sit on its skeleton for good.
  test('a change during a drilldown\'s first page does not strand '
      'it', () async {
    final firstPage = Completer<Result<ArtworkResultsPage, AppFailure>>();
    when(
      () => repo.fetchArtworkResults(
        any(),
        page: any(named: 'page'),
        filter: any(named: 'filter'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) => firstPage.future);
    final bloc = buildBloc();
    bloc.add(const SearchEvent.drilldownOpened(_target));
    await pumpEventQueue();
    expect(bloc.state, isA<SearchInitial>());

    blocks.blocked.value = {_blocked};
    await pumpEventQueue();
    firstPage.complete(page(['a'], number: 0, hasMore: false));
    await pumpEventQueue();

    expect(bloc.state, isA<SearchArtworkResults>());
    expect((bloc.state as SearchArtworkResults).artworks, hasLength(1));
  });

  test('a report made while a drilldown is on screen drops that '
      'artwork', () async {
    pages[0] = page(['a', 'b'], number: 0, hasMore: false);
    final bloc = buildBloc();
    await open(bloc);

    hides.hide(api.ReportTargetType.artwork, 'a');
    final after = await settled(bloc);

    expect(after.artworks.map((a) => a.mintAccount), ['b']);
  });

  test('a block made while text results are on screen searches again, '
      'through the repository\'s filter', () async {
    var searches = 0;
    when(() => repo.search('art', onUpdate: any(named: 'onUpdate'))).thenAnswer(
      (_) async {
        searches++;
        return SearchResults(
          users: [
            if (!moderation.hidesAddress(_blocked))
              const SearchUserResult(username: 'blocked', address: _blocked),
            const SearchUserResult(username: 'artist', address: _artist),
          ],
        );
      },
    );
    final bloc = buildBloc();
    bloc.add(const SearchEvent.recentSearchTapped('art'));
    await bloc.stream.firstWhere((s) => s is SearchLoaded);
    expect((bloc.state as SearchLoaded).results.users, hasLength(2));

    blocks.blocked.value = {_blocked};
    await pumpEventQueue();

    expect(searches, 2);
    expect((bloc.state as SearchLoaded).results.users.map((u) => u.username), [
      'artist',
    ]);
  });

  group('recently viewed', () {
    Future<void> record() async {
      final prefs = sl<PreferencesService>();
      await prefs.saveRecentlyViewed(
        RecentlyViewedItem.user(
          const SearchUserResult(username: 'blocked', address: _blocked),
        ),
      );
      await prefs.saveRecentlyViewed(
        RecentlyViewedItem.user(
          const SearchUserResult(username: 'artist', address: _artist),
        ),
      );
    }

    List<String?> usernames(SearchBloc bloc) => (bloc.state as SearchInitial)
        .recentlyViewed
        .map((i) => i.user?.username)
        .toList();

    test('leaves out an account the viewer blocked', () async {
      await record();
      blocks.blocked.value = {_blocked};

      expect(usernames(buildBloc()), ['artist']);
    });

    // The stored history is untouched, so the row is back after an unblock.
    test('follows a block and an unblock made while it is on screen', () async {
      await record();
      final bloc = buildBloc();
      expect(usernames(bloc), unorderedEquals(['artist', 'blocked']));

      blocks.blocked.value = {_blocked};
      await pumpEventQueue();
      expect(usernames(bloc), ['artist']);

      blocks.blocked.value = {};
      await pumpEventQueue();
      expect(usernames(bloc), unorderedEquals(['artist', 'blocked']));
    });
  });
}
