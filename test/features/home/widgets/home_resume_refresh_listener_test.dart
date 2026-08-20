import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/home/data/home_feed_repository.dart';
import 'package:mallow_wallet/features/home/services/home_bloc.dart';
import 'package:mallow_wallet/features/home/widgets/home_resume_refresh_listener.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';

/// Locks the resume/tab-return refresh contract: returning to the foreground
/// (or back to the home tab, which stays mounted across tab switches) silently
/// revalidates the home feed, but ONLY when the cache has gone stale and no
/// revalidation is already in flight — so a quick app-switch or tab flip never
/// re-fires the five home endpoints, and a resume can't race a pull-to-refresh.
void main() {
  tearDown(() {
    NavBarState.activeTab.value = MallowNavTab.home;
  });

  /// Delivers an [AppLifecycleState.resumed] notification so the widget's
  /// [WidgetsBindingObserver] fires. Dispatched via the binding rather than a
  /// raw [SystemChannels.lifecycle] push: the channel handler was registered
  /// outside the test's FakeAsync zone, so continuations after any `await` in
  /// the observer callback would be scheduled on the real event loop, which
  /// never runs while the test body pumps fake time — deadlocking [settle].
  void sendResumed(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  Future<HomeBloc> pumpListener(WidgetTester tester, _FakeHomeRepo repo) async {
    final bloc = HomeBloc(repo, _FakePortfolioRepo());
    addTearDown(bloc.close);
    await tester.pumpWidget(
      BlocProvider.value(
        value: bloc,
        child: HomeResumeRefreshListener(
          repository: repo,
          child: const SizedBox(),
        ),
      ),
    );
    return bloc;
  }

  Future<void> settle(HomeBloc bloc) =>
      bloc.stream.firstWhere((s) => s is HomeLoaded && !s.isRefreshing);

  testWidgets('resume with a stale cache silently revalidates the feed', (
    tester,
  ) async {
    final repo = _FakeHomeRepo()..stale = true;
    final bloc = await pumpListener(tester, repo);
    bloc.add(const HomeEvent.load());
    await settle(bloc);
    expect(repo.feedFetches, 1);

    sendResumed(tester);
    await settle(bloc);

    expect(repo.feedFetches, 2);
  });

  testWidgets('resume with a fresh cache does not refetch', (tester) async {
    final repo = _FakeHomeRepo()..stale = false;
    final bloc = await pumpListener(tester, repo);
    bloc.add(const HomeEvent.load());
    await settle(bloc);

    sendResumed(tester);
    await tester.idle();

    expect(repo.feedFetches, 1);
    expect((bloc.state as HomeLoaded).isRefreshing, isFalse);
  });

  testWidgets('returning to the home tab with a stale cache revalidates', (
    tester,
  ) async {
    final repo = _FakeHomeRepo()..stale = true;
    final bloc = await pumpListener(tester, repo);
    bloc.add(const HomeEvent.load());
    await settle(bloc);
    expect(repo.feedFetches, 1);

    NavBarState.activeTab.value = MallowNavTab.portfolio;
    await tester.idle();
    expect(repo.feedFetches, 1);

    NavBarState.activeTab.value = MallowNavTab.home;
    await settle(bloc);

    expect(repo.feedFetches, 2);
  });

  testWidgets('returning to the home tab with a fresh cache does not refetch', (
    tester,
  ) async {
    final repo = _FakeHomeRepo()..stale = false;
    final bloc = await pumpListener(tester, repo);
    bloc.add(const HomeEvent.load());
    await settle(bloc);

    NavBarState.activeTab.value = MallowNavTab.portfolio;
    NavBarState.activeTab.value = MallowNavTab.home;
    await tester.idle();

    expect(repo.feedFetches, 1);
    expect((bloc.state as HomeLoaded).isRefreshing, isFalse);
  });

  testWidgets(
    'resume during an in-flight refresh does not start a second revalidation',
    (tester) async {
      final repo = _FakeHomeRepo()..stale = true;
      final bloc = await pumpListener(tester, repo);
      bloc.add(const HomeEvent.load());
      await settle(bloc);

      // Hold the next feed fetch open so a refresh stays in flight.
      repo.gate = Completer<void>();
      bloc.add(const HomeEvent.refresh());
      await bloc.stream.firstWhere((s) => s is HomeLoaded && s.isRefreshing);
      await tester.idle();
      expect(repo.feedFetches, 2);

      sendResumed(tester);
      await tester.idle();
      expect(repo.feedFetches, 2);

      repo.gate!.complete();
      await settle(bloc);
    },
  );
}

/// Fake repository: overrides the network + cache surface (same pattern as
/// home_bloc_test.dart) and adds controllable staleness and a fetch gate.
class _FakeHomeRepo extends HomeFeedRepository {
  _FakeHomeRepo() : super(_FakeApi(), _FakeApiV2(), _FakeDb(), _FakeSession());

  bool stale = false;
  int feedFetches = 0;
  Completer<void>? gate;

  @override
  Future<bool> isCacheStale() async => stale;

  @override
  Future<CachedHomeSections?> getCachedHomeSections() async => null;

  @override
  Future<api.HomeFeedResponse> fetchHomeFeed() async {
    feedFetches++;
    if (gate != null) await gate!.future;
    return const api.HomeFeedResponse();
  }

  @override
  Future<api.HomeRecommendedResponse> fetchHomeRecommended() async =>
      const api.HomeRecommendedResponse();

  @override
  Future<api.HomeDiscoverResponse> fetchHomeDiscover() async =>
      const api.HomeDiscoverResponse();

  @override
  Future<api.HomePopularCollectionsResponse>
  fetchHomePopularCollections() async =>
      const api.HomePopularCollectionsResponse();

  @override
  Future<api.HomePopularCurationsResponse> fetchHomePopularCurations() async =>
      const api.HomePopularCurationsResponse();

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
/// here), keeping these tests focused on the resume-refresh path.
class _FakePortfolioRepo extends Fake implements PortfolioRepository {}
