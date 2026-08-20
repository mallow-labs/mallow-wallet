import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/result/result.dart';
import '../../../di.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../data/home_feed_repository.dart';

part 'home_bloc.freezed.dart';

/// Model for daily spotlight artwork
class SpotlightArtwork {
  const SpotlightArtwork({
    required this.mintAccount,
    required this.title,
    required this.imageUrl,
    required this.artistName,
    required this.artistAddress,
    this.collectionName,
    this.playbackId,
    this.clipPlaybackId,
    this.nsfw = false,
  });

  final String mintAccount;
  final String title;
  final String imageUrl;
  final String artistName;
  final String artistAddress;
  final String? collectionName;
  final String? playbackId;
  final String? clipPlaybackId;

  /// Moderation flag: artwork marked not-safe-for-work. The spotlight tile
  /// blurs it unless the viewer's show-NSFW setting is on.
  final bool nsfw;
}

/// Model for a curation (collection of artworks)
class Curation {
  const Curation({
    required this.id,
    required this.name,
    required this.curatorName,
    required this.curatorAddress,
    required this.imageUrls,
  });

  final String id;
  final String name;
  final String curatorName;
  final String curatorAddress;
  final List<String> imageUrls;
}

/// Model for an artist preview
class ArtistPreview {
  const ArtistPreview({
    required this.address,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    required this.featuredArtworkUrl,
  });

  final String address;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String featuredArtworkUrl;
}

/// Model for a featured listing card (NFT with buy-now price)
class FeaturedListing {
  const FeaturedListing({
    required this.mintAccount,
    required this.title,
    required this.artistName,
    required this.artistUsername,
    required this.artistAddress,
    required this.imageUrl,
    this.collectionName,
    this.priceRawAmount,
    this.currencyMint,
    this.buyerSetsPrice = false,
    this.playbackId,
    this.clipPlaybackId,
    this.nsfw = false,
  });

  final String mintAccount;
  final String title;
  final String artistName;
  final String artistUsername;
  final String artistAddress;
  final String imageUrl;
  final String? collectionName;
  final String? playbackId;
  final String? clipPlaybackId;

  /// Moderation flag: artwork marked not-safe-for-work. The card blurs it
  /// unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  /// Raw price in smallest on-chain units (e.g. lamports for SOL).
  /// Use [PriceFormatter.formatRawAmountWithSymbol] to display.
  final double? priceRawAmount;

  /// The currency mint address for [priceRawAmount].
  final String? currencyMint;

  /// True for a SYOP ("set your own price") buy-now listing, whose on-chain
  /// price is 0 — the card renders the label, not the figure.
  final bool buyerSetsPrice;
}

/// Model for a recommended-for-you category card
class RecommendedCategory {
  const RecommendedCategory({
    required this.label,
    required this.imageUrls,
    required this.artistUsernames,
    required this.artworks,
  });

  final String label;
  final List<String> imageUrls;
  final List<String> artistUsernames;
  final List<PortfolioArtwork> artworks;
}

/// Model for a popular collection card
class PopularCollection {
  const PopularCollection({
    required this.id,
    required this.name,
    required this.artistName,
    required this.artistAddress,
    required this.imageUrl,
  });

  final String id;
  final String name;
  final String artistName;
  final String artistAddress;
  final String imageUrl;
}

/// Events for home screen
@freezed
sealed class HomeEvent with _$HomeEvent {
  /// Load home screen data
  const factory HomeEvent.load() = HomeLoad;

  /// Refresh home screen data
  const factory HomeEvent.refresh() = HomeRefresh;

  /// Optimistically drop [mintAccount] from the owned surfaces (spotlight +
  /// featured) the instant a transfer/burn confirms, via the app-wide
  /// [ArtworkRemovalSignal].
  const factory HomeEvent.artworkRemoved(String mintAccount) =
      HomeArtworkRemoved;
}

/// States for home screen
@freezed
sealed class HomeState with _$HomeState {
  /// Initial state
  const factory HomeState.initial() = HomeInitial;

  /// Loading state
  const factory HomeState.loading() = HomeLoading;

  /// Loaded state with data
  const factory HomeState.loaded({
    required List<Curation> curations,
    required List<ArtistPreview> artists,
    @Default([]) List<SpotlightArtwork> spotlightArtworks,
    @Default([]) List<FeaturedListing> featuredListings,
    @Default([]) List<RecommendedCategory> recommendedCategories,
    @Default([]) List<PopularCollection> popularCollections,
    @Default([]) List<ArtistPreview> trendingArtists,
    @Default(false) bool isRefreshing,
  }) = HomeLoaded;

  /// Error state
  const factory HomeState.error({required String message}) = HomeError;
}

/// Bloc for home screen.
///
/// Fetches home feed data from the API via [HomeFeedRepository].
/// Uses cache-first pattern: emits cached data immediately, then
/// fetches fresh data in background.
@injectable
class HomeBloc extends Bloc<HomeEvent, HomeState> {
  HomeBloc(this._repository, this._portfolioRepository)
    : super(const HomeState.initial()) {
    on<HomeLoad>(_onLoad);
    on<HomeRefresh>(_onRefresh);
    on<HomeArtworkRemoved>(_onArtworkRemoved);

    // The spotlight carousel and featured tiles are long-pressable into a
    // transfer/burn — drop the item on the spot when it leaves the wallet.
    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen(
        (mint) => add(HomeEvent.artworkRemoved(mint)),
      );
    }

    // A money action (list / update / cancel / buy / bid / settle) or a
    // metadata edit changes the price, badge and thumbnail the featured-
    // listing and spotlight rails render. Home's only other revalidation
    // triggers are pull-to-refresh and the stale-TTL check in
    // `HomeResumeRefreshListener`, so without this the rails kept showing the
    // pre-action price for the whole TTL — including for the very artwork the
    // user just acted on. `_sectionUnchanged` makes an unchanged feed a
    // no-op, so this can't reset a rail's scroll offset.
    if (sl.isRegistered<ArtworkEditedSignal>()) {
      _editedSignalSub = sl<ArtworkEditedSignal>().stream.listen((_) {
        // Skip while a revalidation is already in flight — the default bloc
        // transformer is concurrent, so a second event would fetch in
        // parallel with the first (same guard `HomeResumeRefreshListener`
        // applies).
        final current = state;
        if (current is HomeLoaded && !current.isRefreshing) {
          add(const HomeEvent.refresh());
        }
      });
    }
  }

  final HomeFeedRepository _repository;
  final PortfolioRepository _portfolioRepository;

  StreamSubscription<String>? _removalSignalSub;
  StreamSubscription<String>? _editedSignalSub;

  @override
  Future<void> close() {
    _removalSignalSub?.cancel();
    _editedSignalSub?.cancel();
    return super.close();
  }

  /// Optimistically drop a transferred/burnt artwork from the two owned-art
  /// entry points on Home (the spotlight carousel and featured listings) so it
  /// disappears immediately. The full refresh reconciles the rest.
  void _onArtworkRemoved(HomeArtworkRemoved event, Emitter<HomeState> emit) {
    final current = state;
    if (current is! HomeLoaded) return;
    final mint = event.mintAccount;
    final inSpotlight = current.spotlightArtworks.any(
      (a) => a.mintAccount == mint,
    );
    final inFeatured = current.featuredListings.any(
      (a) => a.mintAccount == mint,
    );
    if (!inSpotlight && !inFeatured) return;

    emit(
      current.copyWith(
        spotlightArtworks: [
          for (final a in current.spotlightArtworks)
            if (a.mintAccount != mint) a,
        ],
        featuredListings: [
          for (final a in current.featuredListings)
            if (a.mintAccount != mint) a,
        ],
      ),
    );
  }

  /// Picks 4 random [SpotlightArtwork]s from the user's collection.
  /// Falls back to the top 30 trending artworks from the home feed if the
  /// user owns no artworks.
  Future<List<SpotlightArtwork>> _buildSpotlightArtworks(
    api.HomeFeedResponse feed,
  ) async {
    try {
      final result = await _portfolioRepository.getOwnedArtworks();
      if (result.artworks.isNotEmpty) {
        final shuffled = List.of(result.artworks)..shuffle(Random());
        return shuffled
            .take(4)
            .map(
              (a) => SpotlightArtwork(
                mintAccount: a.mintAccount,
                title: a.title,
                imageUrl: a.imageUrl,
                artistName: a.artistName,
                artistAddress: '',
                nsfw: a.nsfw,
              ),
            )
            .toList();
      }
    } catch (e) {
      debugPrint('[HomeBloc] Failed to fetch owned artworks for spotlight: $e');
    }

    // Fallback: pick 4 random from top 30 trending NFTs in the home feed
    final trending = _repository.mapTrendingForSpotlight(feed);
    final shuffled = List.of(trending)..shuffle(Random());
    return shuffled.take(4).toList();
  }

  /// Build a [HomeLoaded] from cached sections for the instant first paint.
  HomeLoaded _mapCachedToLoaded(
    CachedHomeSections cached,
    List<SpotlightArtwork> spotlightArtworks, {
    required bool isRefreshing,
  }) {
    return HomeState.loaded(
          spotlightArtworks: spotlightArtworks,
          curations: cached.popularCurations != null
              ? _repository.mapPopularCurations(cached.popularCurations!)
              : const [],
          artists: cached.discover != null
              ? _repository.mapDiscoverArtists(cached.discover!)
              : const [],
          trendingArtists: _repository.mapCreators(cached.feed.creators),
          featuredListings: _repository.mapFeaturedListings(cached.feed),
          recommendedCategories: cached.recommended != null
              ? _repository.mapRecommendedCategories(cached.recommended!)
              : const [],
          popularCollections: cached.popularCollections != null
              ? _repository.mapPopularCollections(cached.popularCollections!)
              : const [],
          isRefreshing: isRefreshing,
        )
        as HomeLoaded;
  }

  /// Current loaded state, or an empty loaded shell when nothing is displayed
  /// yet (cold start with no cache). Base for progressive section merges.
  HomeLoaded _loadedOrEmpty() {
    final current = state;
    if (current is HomeLoaded) return current;
    return const HomeState.loaded(curations: [], artists: []) as HomeLoaded;
  }

  /// True when two API section payloads serialise identically. Lets us skip
  /// re-emitting (and thus rebuilding + resetting the horizontal scroll offset
  /// of) a section whose data has not changed since the last paint.
  bool _sectionUnchanged(Object? a, Object? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return jsonEncode((a as dynamic).toJson()) ==
        jsonEncode((b as dynamic).toJson());
  }

  /// Fetch one supplementary section and emit it the moment it lands — but
  /// only if it changed vs [baseline]. Returns the raw response so the caller
  /// can persist the combined cache. Failures are swallowed so one broken
  /// endpoint never takes down the rest of the screen.
  Future<T?> _fetchSection<T extends Object>(
    Emitter<HomeState> emit, {
    required Future<T> Function() fetch,
    required T? baseline,
    required HomeLoaded Function(HomeLoaded current, T response) apply,
  }) async {
    try {
      final response = await fetch();
      if (!_sectionUnchanged(baseline, response)) {
        final current = state;
        if (current is HomeLoaded) emit(apply(current, response));
      }
      return response;
    } catch (e) {
      debugPrint('[HomeBloc] Supplementary fetch failed: $e');
      return null;
    }
  }

  /// Fetch fresh feed + supplementary sections and emit them progressively,
  /// each landing independently. [baseline] is the last-cached payload, used
  /// to skip unchanged sections. Persists the combined result at the end.
  Future<void> _revalidate(
    Emitter<HomeState> emit, {
    required CachedHomeSections? baseline,
  }) async {
    // 1. Feed drives featured listings, trending artists and the spotlight.
    final feedResult = await Result.guard(() async {
      final feed = await _repository.fetchHomeFeed();
      final spotlightArtworks = await _buildSpotlightArtworks(feed);
      return (feed, spotlightArtworks);
    });

    final api.HomeFeedResponse feed;
    switch (feedResult) {
      case ResultSuccess(:final value):
        feed = value.$1;
        if (baseline == null || !_sectionUnchanged(baseline.feed, feed)) {
          emit(
            _loadedOrEmpty().copyWith(
              spotlightArtworks: value.$2,
              featuredListings: _repository.mapFeaturedListings(feed),
              trendingArtists: _repository.mapCreators(feed.creators),
              isRefreshing: true,
            ),
          );
        }
      case ResultFailure(:final error):
        debugPrint('[HomeBloc] Feed fetch failed: ${error.message}');
        final current = state;
        if (current is HomeLoaded) {
          emit(current.copyWith(isRefreshing: false));
        } else {
          emit(
            HomeState.error(message: 'Failed to load home: ${error.message}'),
          );
        }
        return;
    }

    // 2. Supplementary sections — fetched in parallel, each emitted the moment
    //    it resolves rather than waiting on the slowest of the four.
    api.HomeRecommendedResponse? recommended;
    api.HomeDiscoverResponse? discover;
    api.HomePopularCollectionsResponse? popularCollections;
    api.HomePopularCurationsResponse? popularCurations;

    await Future.wait([
      _fetchSection<api.HomeRecommendedResponse>(
        emit,
        fetch: _repository.fetchHomeRecommended,
        baseline: baseline?.recommended,
        apply: (current, r) => current.copyWith(
          recommendedCategories: _repository.mapRecommendedCategories(r),
        ),
      ).then((r) => recommended = r),
      _fetchSection<api.HomeDiscoverResponse>(
        emit,
        fetch: _repository.fetchHomeDiscover,
        baseline: baseline?.discover,
        apply: (current, r) =>
            current.copyWith(artists: _repository.mapDiscoverArtists(r)),
      ).then((r) => discover = r),
      _fetchSection<api.HomePopularCollectionsResponse>(
        emit,
        fetch: _repository.fetchHomePopularCollections,
        baseline: baseline?.popularCollections,
        apply: (current, r) => current.copyWith(
          popularCollections: _repository.mapPopularCollections(r),
        ),
      ).then((r) => popularCollections = r),
      _fetchSection<api.HomePopularCurationsResponse>(
        emit,
        fetch: _repository.fetchHomePopularCurations,
        baseline: baseline?.popularCurations,
        apply: (current, r) =>
            current.copyWith(curations: _repository.mapPopularCurations(r)),
      ).then((r) => popularCurations = r),
    ]);

    // 3. Persist the combined result. Sections that failed this round fall
    //    back to the baseline so a transient error doesn't wipe the cache.
    await _repository.cacheAllHomeSections(
      feed: feed,
      recommended: recommended ?? baseline?.recommended,
      discover: discover ?? baseline?.discover,
      popularCollections: popularCollections ?? baseline?.popularCollections,
      popularCurations: popularCurations ?? baseline?.popularCurations,
    );

    // 4. Done revalidating — drop the refreshing indicator.
    final current = state;
    if (current is HomeLoaded && current.isRefreshing) {
      emit(current.copyWith(isRefreshing: false));
    }
  }

  Future<void> _onLoad(HomeLoad event, Emitter<HomeState> emit) async {
    // 1. Serve cache immediately for an instant paint. Cache failures are
    //    non-fatal — we skip straight to the fresh fetch.
    final baselineResult = await Result.guard(() async {
      final cached = await _repository.getCachedHomeSections();
      if (cached == null) return null;
      final spotlightArtworks = await _buildSpotlightArtworks(cached.feed);
      return (cached, spotlightArtworks);
    });

    CachedHomeSections? baseline;
    if (baselineResult case ResultSuccess(:final value) when value != null) {
      baseline = value.$1;
      emit(_mapCachedToLoaded(baseline, value.$2, isRefreshing: true));
    } else {
      emit(const HomeState.loading());
    }

    // 2. Revalidate against the network, emitting sections progressively.
    await _revalidate(emit, baseline: baseline);
  }

  Future<void> _onRefresh(HomeRefresh event, Emitter<HomeState> emit) async {
    // Mark refreshing up front so the pull-to-refresh indicator stays visible
    // until the revalidation completes.
    final current = state;
    if (current is HomeLoaded) emit(current.copyWith(isRefreshing: true));

    final baseline = await _repository.getCachedHomeSections();
    await _revalidate(emit, baseline: baseline);
  }
}
