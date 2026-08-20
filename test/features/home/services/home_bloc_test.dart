import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/home/data/home_feed_repository.dart';
import 'package:mallow_wallet/features/home/services/home_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';

/// Behavioural tests for [HomeBloc]'s cache-first + progressive revalidation.
///
/// These lock the UX contract added in the home-load speedup:
///  - a fresh load surfaces each fetched section and clears `isRefreshing`;
///  - a section whose payload is byte-identical to the cache is NOT re-emitted
///    (so an unchanged row is never rebuilt / scrolled back to offset 0);
///  - pull-to-refresh drives `isRefreshing` true → false so the indicator can
///    track real progress.
///
/// The bloc is driven through a fake [HomeFeedRepository] that overrides only
/// the network/cache methods — the real mappers still run, so the state the
/// screen renders is exercised end-to-end.
void main() {
  // ---- fixtures -----------------------------------------------------------

  const feed = api.HomeFeedResponse();
  const discoverOneArtist = api.HomeDiscoverResponse(
    artists: [
      api.HomeDiscoverArtist(
        address: 'A1',
        username: 'alice',
        featuredArtworkUrl: 'art',
      ),
    ],
  );
  const emptyRecommended = api.HomeRecommendedResponse();
  const emptyCollections = api.HomePopularCollectionsResponse();
  const emptyCurations = api.HomePopularCurationsResponse();

  _FakeHomeRepo repo() => _FakeHomeRepo(
    feed: feed,
    discover: discoverOneArtist,
    recommended: emptyRecommended,
    popularCollections: emptyCollections,
    popularCurations: emptyCurations,
  );

  HomeBloc blocFrom(_FakeHomeRepo r) => HomeBloc(r, _FakePortfolioRepo());

  /// Drives [bloc] until it settles on a non-refreshing state, collecting
  /// every emission along the way.
  Future<List<HomeState>> run(HomeBloc bloc, HomeEvent event) async {
    final states = <HomeState>[];
    final sub = bloc.stream.listen(states.add);
    bloc.add(event);
    await bloc.stream.firstWhere(
      (s) => (s is HomeLoaded && !s.isRefreshing) || s is HomeError,
    );
    await sub.cancel();
    return states;
  }

  // ---- tests --------------------------------------------------------------

  test('fresh load with no cache surfaces fetched sections and stops '
      'refreshing', () async {
    final bloc = blocFrom(repo());

    await run(bloc, const HomeEvent.load());

    final state = bloc.state;
    expect(state, isA<HomeLoaded>());
    state as HomeLoaded;
    expect(state.artists, hasLength(1));
    expect(state.artists.single.username, 'alice');
    expect(state.isRefreshing, isFalse);
  });

  test('unchanged sections are not re-emitted when the cache already matches '
      'the network', () async {
    final r = repo();
    // Cache holds the exact same payloads the network will return, so every
    // section — feed and all four supplementary — must be skipped.
    r.cached = const CachedHomeSections(
      feed: feed,
      recommended: emptyRecommended,
      discover: discoverOneArtist,
      popularCollections: emptyCollections,
      popularCurations: emptyCurations,
    );
    final bloc = blocFrom(r);

    final states = await run(bloc, const HomeEvent.load());

    // Only two emissions: the instant cache paint (refreshing) and the final
    // clear. No section re-emitted because nothing changed.
    expect(states, hasLength(2));
    expect((states.first as HomeLoaded).isRefreshing, isTrue);
    expect((states.last as HomeLoaded).isRefreshing, isFalse);
    // The cached data is preserved, not wiped by the skipped sections.
    expect((bloc.state as HomeLoaded).artists, hasLength(1));
  });

  test('changed section IS re-emitted over the cache paint', () async {
    final r = repo();
    // Cache has no discover artists; the network returns one → must re-emit.
    r.cached = const CachedHomeSections(
      feed: feed,
      discover: api.HomeDiscoverResponse(),
    );
    final bloc = blocFrom(r);

    await run(bloc, const HomeEvent.load());

    expect((bloc.state as HomeLoaded).artists, hasLength(1));
  });

  test('pull-to-refresh drives isRefreshing true then false', () async {
    final bloc = blocFrom(repo());
    // Land in a loaded state first.
    await run(bloc, const HomeEvent.load());

    final states = await run(bloc, const HomeEvent.refresh());

    expect(states.first, isA<HomeLoaded>());
    expect((states.first as HomeLoaded).isRefreshing, isTrue);
    expect((bloc.state as HomeLoaded).isRefreshing, isFalse);
  });
}

/// Fake repository: overrides the network + cache surface, keeps the real
/// mapping logic so bloc output matches what the screen renders.
class _FakeHomeRepo extends HomeFeedRepository {
  _FakeHomeRepo({
    required this.feed,
    required this.discover,
    required this.recommended,
    required this.popularCollections,
    required this.popularCurations,
  }) : super(_FakeApi(), _FakeApiV2(), _FakeDb(), _FakeSession());

  api.HomeFeedResponse feed;
  api.HomeDiscoverResponse discover;
  api.HomeRecommendedResponse recommended;
  api.HomePopularCollectionsResponse popularCollections;
  api.HomePopularCurationsResponse popularCurations;
  CachedHomeSections? cached;

  @override
  Future<CachedHomeSections?> getCachedHomeSections() async => cached;

  @override
  Future<api.HomeFeedResponse> fetchHomeFeed() async => feed;

  @override
  Future<api.HomeRecommendedResponse> fetchHomeRecommended() async =>
      recommended;

  @override
  Future<api.HomeDiscoverResponse> fetchHomeDiscover() async => discover;

  @override
  Future<api.HomePopularCollectionsResponse>
  fetchHomePopularCollections() async => popularCollections;

  @override
  Future<api.HomePopularCurationsResponse> fetchHomePopularCurations() async =>
      popularCurations;

  @override
  Future<void> cacheAllHomeSections({
    required api.HomeFeedResponse feed,
    api.HomeRecommendedResponse? recommended,
    api.HomeDiscoverResponse? discover,
    api.HomePopularCollectionsResponse? popularCollections,
    api.HomePopularCurationsResponse? popularCurations,
  }) async {}
}

class _FakeApi extends Fake implements api.MallowApiClient {}

class _FakeApiV2 extends Fake implements api.MallowApiV2Client {}

class _FakeDb extends Fake implements MallowDatabase {}

class _FakeSession extends Fake implements SessionManager {}

/// Spotlight fetch throws → bloc falls back to feed-derived trending (empty
/// here), which keeps these tests focused on the section revalidation path.
class _FakePortfolioRepo extends Fake implements PortfolioRepository {}
