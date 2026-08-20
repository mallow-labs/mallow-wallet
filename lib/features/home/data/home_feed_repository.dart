import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/session/session_manager.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/user_display.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../services/home_bloc.dart';

/// Combined cache of all home screen sections.
class CachedHomeSections {
  const CachedHomeSections({
    required this.feed,
    this.recommended,
    this.discover,
    this.popularCollections,
    this.popularCurations,
  });

  final api.HomeFeedResponse feed;
  final api.HomeRecommendedResponse? recommended;
  final api.HomeDiscoverResponse? discover;
  final api.HomePopularCollectionsResponse? popularCollections;
  final api.HomePopularCurationsResponse? popularCurations;
}

/// Repository for fetching and caching home feed data.
///
/// Implements cache-first pattern (following ActivityRepository):
/// 1. Emit cached data immediately for instant display
/// 2. Fetch fresh data from API in background
/// 3. Cache fresh data to Drift DB
@lazySingleton
class HomeFeedRepository {
  HomeFeedRepository(this._api, this._apiV2, this._database, this._session);

  final api.MallowApiClient _api;
  final api.MallowApiV2Client _apiV2;
  final MallowDatabase _database;
  final SessionManager _session;

  static const _staleTtl = Duration(minutes: 5);

  /// Fetch home feed from the API.
  Future<api.HomeFeedResponse> fetchHomeFeed() async {
    final response = await _api.getHomeFeed();
    return response.result;
  }

  /// Fetch recommended-for-you curations, personalised to the active session's
  /// wallets.
  ///
  /// Sources the addresses from [SessionManager.sessionWallets] — the active
  /// Account's held wallets (or, in Profile mode, the active Profile's linked
  /// wallets), matching the offers inbox. They are comma-joined into the single
  /// `addresses` query param the public `GET /v2/home/recommended` read expects
  /// (the backend unions each address's followed-set before the "Recently
  /// Listed" query). No auth/login required.
  Future<api.HomeRecommendedResponse> fetchHomeRecommended() async {
    final response = await _apiV2.getHomeRecommended(
      addresses: _session.apiOwnerAddresses.join(','),
    );
    return response.result;
  }

  /// Fetch artists for the Discover section.
  Future<api.HomeDiscoverResponse> fetchHomeDiscover() async {
    final response = await _api.getHomeDiscover();
    return response.result;
  }

  /// Fetch popular collections.
  Future<api.HomePopularCollectionsResponse>
  fetchHomePopularCollections() async {
    final response = await _api.getHomePopularCollections();
    return response.result;
  }

  /// Fetch popular curations.
  Future<api.HomePopularCurationsResponse> fetchHomePopularCurations() async {
    final response = await _api.getHomePopularCurations();
    return response.result;
  }

  /// Get all cached home sections from the local database.
  ///
  /// Returns null if no cache exists. Individual supplementary sections
  /// (recommended, discover, popularCollections) may be null if they
  /// weren't present when the cache was written.
  Future<CachedHomeSections?> getCachedHomeSections() async {
    final cached = await _database.getHomeFeedCache();
    if (cached == null) return null;

    try {
      final json = jsonDecode(cached.jsonData) as Map<String, dynamic>;

      // Support both combined format and legacy feed-only format
      if (json.containsKey('feed')) {
        return CachedHomeSections(
          feed: api.HomeFeedResponse.fromJson(
            json['feed'] as Map<String, dynamic>,
          ),
          recommended: json['recommended'] != null
              ? api.HomeRecommendedResponse.fromJson(
                  json['recommended'] as Map<String, dynamic>,
                )
              : null,
          discover: json['discover'] != null
              ? api.HomeDiscoverResponse.fromJson(
                  json['discover'] as Map<String, dynamic>,
                )
              : null,
          popularCollections: json['popularCollections'] != null
              ? api.HomePopularCollectionsResponse.fromJson(
                  json['popularCollections'] as Map<String, dynamic>,
                )
              : null,
          popularCurations: json['popularCurations'] != null
              ? api.HomePopularCurationsResponse.fromJson(
                  json['popularCurations'] as Map<String, dynamic>,
                )
              : null,
        );
      }

      // Legacy: jsonData is just a HomeFeedResponse
      return CachedHomeSections(feed: api.HomeFeedResponse.fromJson(json));
    } catch (_) {
      return null;
    }
  }

  /// Cache all home sections to the local database.
  Future<void> cacheAllHomeSections({
    required api.HomeFeedResponse feed,
    api.HomeRecommendedResponse? recommended,
    api.HomeDiscoverResponse? discover,
    api.HomePopularCollectionsResponse? popularCollections,
    api.HomePopularCurationsResponse? popularCurations,
  }) async {
    final now = CacheFreshness.nowEpochSeconds();
    final combined = jsonEncode({
      'feed': feed.toJson(),
      if (recommended != null) 'recommended': recommended.toJson(),
      if (discover != null) 'discover': discover.toJson(),
      if (popularCollections != null)
        'popularCollections': popularCollections.toJson(),
      if (popularCurations != null)
        'popularCurations': popularCurations.toJson(),
    });

    await _database.upsertHomeFeedCache(
      CachedHomeFeedCompanion(
        id: const Value('default'),
        jsonData: Value(combined),
        cachedAt: Value(now),
      ),
    );
  }

  /// Check if the cache is stale (older than the stale TTL).
  Future<bool> isCacheStale() async {
    final cached = await _database.getHomeFeedCache();
    if (cached == null) return true;
    return CacheFreshness.isStale(
      CacheFreshness.fromEpochSeconds(cached.cachedAt),
      _staleTtl,
    );
  }

  /// Clear the home feed cache.
  Future<void> clearCache() async {
    await _database.deleteHomeFeedCache();
  }

  /// Map API [SpotlightResult] to UI [SpotlightArtwork].
  SpotlightArtwork? mapSpotlight(api.SpotlightResult? spotlight) {
    if (spotlight == null) return null;

    return SpotlightArtwork(
      mintAccount: spotlight.nftPreview?.mintAccount ?? '',
      title: spotlight.name ?? '',
      imageUrl: spotlight.imageUrl ?? '',
      playbackId: spotlight.nftPreview?.playbackId,
      clipPlaybackId: spotlight.nftPreview?.clipPlaybackId,
      nsfw: spotlight.nftPreview?.nsfw ?? false,
      artistName:
          spotlight.creator?.username ?? spotlight.creator?.displayName ?? '',
      artistAddress: spotlight.creator?.addresses.firstOrNull ?? '',
      collectionName: spotlight.nftPreview?.collectionName,
    );
  }

  /// Map [HomePopularCurationsResponse] to UI [Curation] list.
  List<Curation> mapPopularCurations(
    api.HomePopularCurationsResponse response,
  ) {
    return response.curations.where((c) => c.previewImageUrls.isNotEmpty).map((
      c,
    ) {
      final owner = c.owner;
      final ownerLabel = (owner?.username?.isNotEmpty ?? false)
          ? owner!.username!
          : truncateAddress(owner?.address ?? '');
      return Curation(
        // Server adds id/slug; older cached payloads pre-dating the field
        // addition fall back to name so the card still renders (the detail
        // fetch will 404 in that case until the cache refreshes).
        id: c.id.isNotEmpty ? c.id : c.name,
        name: c.name,
        curatorName: ownerLabel,
        curatorAddress: owner?.address ?? '',
        imageUrls: c.previewImageUrls,
      );
    }).toList();
  }

  /// Extract up to 30 trending NFTs from the home feed for use as spotlight
  /// fallback when the user owns no artworks.
  List<SpotlightArtwork> mapTrendingForSpotlight(api.HomeFeedResponse feed) {
    final artworks = <SpotlightArtwork>[];
    for (final item in [...feed.featured, ...feed.smores]) {
      final nft = item.nftPreview;
      if (nft != null && nft.imageUrl != null && nft.imageUrl!.isNotEmpty) {
        artworks.add(
          SpotlightArtwork(
            mintAccount: nft.mintAccount,
            title: nft.name,
            imageUrl: nft.imageUrl!,
            playbackId: nft.playbackId,
            clipPlaybackId: nft.clipPlaybackId,
            nsfw: nft.nsfw ?? false,
            artistName: formatDisplayLabel(
              displayName: nft.creator?.displayName,
              username: nft.creator?.username,
              address: nft.creator?.effectiveAddress,
            ),
            artistAddress: nft.creator?.effectiveAddress ?? '',
            collectionName: nft.collectionName,
          ),
        );
      }
      if (artworks.length >= 30) break;
    }
    return artworks;
  }

  /// Map API creators to UI [ArtistPreview] list.
  List<ArtistPreview> mapCreators(List<api.User> creators) {
    return creators
        .map(
          (user) => ArtistPreview(
            address: user.primaryAddress ?? '',
            username: user.username ?? user.displayName ?? 'Unknown',
            displayName: user.displayName,
            avatarUrl: user.imageUrl,
            featuredArtworkUrl: user.bannerUrl ?? user.imageUrl ?? '',
          ),
        )
        .toList();
  }

  /// Map featured NFTs with buy-now listings to [FeaturedListing] list.
  List<FeaturedListing> mapFeaturedListings(api.HomeFeedResponse feed) {
    final listings = <FeaturedListing>[];
    for (final item in feed.featured) {
      final nft = item.nftPreview;
      if (nft == null || nft.imageUrl == null || nft.imageUrl!.isEmpty) {
        continue;
      }
      // Price priority: buyNow → auction (currentBid or reserve) → lastSale
      // Matches the reference web client useListingState priority chain.
      // Prices are raw on-chain amounts (lamports for SOL); PriceFormatter
      // applies the correct decimal divisor at display time.
      final auction = nft.auctionMetadata;
      final auctionPrice = auction != null
          ? ((auction.currentBidAmount ?? 0) > 0
                ? auction.currentBidAmount
                : auction.reservePrice)
          : null;
      final price =
          nft.buyNowMetadata?.amount ?? auctionPrice ?? nft.lastSale?.price;
      final currencyMint =
          nft.buyNowMetadata?.currencyMint ??
          (auctionPrice != null ? auction?.bidMint : null) ??
          nft.lastSale?.currencyMint;
      listings.add(
        FeaturedListing(
          mintAccount: nft.mintAccount,
          title: formatArtworkName(
            name: nft.name,
            editionNumber: nft.editionNumber,
          ),
          artistName: formatDisplayLabel(
            displayName: nft.creator?.displayName,
            username: nft.creator?.username,
            address: nft.creator?.effectiveAddress,
          ),
          artistUsername: nft.creator?.username ?? '',
          artistAddress: nft.creator?.effectiveAddress ?? '',
          imageUrl: nft.imageUrl!,
          collectionName: nft.collectionName,
          priceRawAmount: price,
          currencyMint: currencyMint,
          buyerSetsPrice: nft.buyNowMetadata?.buyerSetsPrice ?? false,
          playbackId: nft.playbackId,
          clipPlaybackId: nft.clipPlaybackId,
          nsfw: nft.nsfw ?? false,
        ),
      );
      if (listings.length >= 20) break;
    }
    return listings;
  }

  /// Map [HomeRecommendedResponse] to UI [RecommendedCategory] list.
  List<RecommendedCategory> mapRecommendedCategories(
    api.HomeRecommendedResponse response,
  ) {
    return response.curations.map((curation) {
      final imageUrls = curation.artworks
          .map((item) => item.imageUrl)
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toList();
      final artworks = curation.artworks
          .where(
            (item) =>
                item.mintAccount != null &&
                item.imageUrl != null &&
                item.imageUrl!.isNotEmpty,
          )
          .map(
            (item) => PortfolioArtwork(
              mintAccount: item.mintAccount!,
              title: item.name ?? '',
              imageUrl: item.imageUrl!,
              playbackId: item.nftPreview?.playbackId,
              clipPlaybackId: item.nftPreview?.clipPlaybackId,
              // Rendered by CurationScreen's cards, which prefer the creator
              // username and fall back to the creator address.
              artistName: formatUsernameOrAddress(
                username: item.nftPreview?.creator?.username,
                address: item.nftPreview?.creator?.effectiveAddress,
              ),
              artistUsername: item.nftPreview?.creator?.username,
              collectionName: item.nftPreview?.collectionName,
              aspectRatio: item.nftPreview?.aspectRatio ?? 1.0,
              lastPrice: item.nftPreview?.lastSale?.price,
              listingType: item.nftPreview?.listingType,
              supply: item.nftPreview?.supply,
              maxSupply: item.nftPreview?.maxSupply,
              editionNumber: item.nftPreview?.editionNumber,
              parentEdition: item.nftPreview?.parentEdition,
              auctionMetadata: item.nftPreview?.auctionMetadata,
              buyNowMetadata: item.nftPreview?.buyNowMetadata,
              updateAuth: item.nftPreview?.updateAuth,
              nsfw: item.nftPreview?.nsfw ?? false,
            ),
          )
          .toList();
      return RecommendedCategory(
        label: curation.name,
        imageUrls: imageUrls,
        artistUsernames: curation.artistUsernames,
        artworks: artworks,
      );
    }).toList();
  }

  /// Map [HomeDiscoverResponse] to UI [ArtistPreview] list.
  List<ArtistPreview> mapDiscoverArtists(api.HomeDiscoverResponse response) {
    return response.artists
        .map(
          (artist) => ArtistPreview(
            address: artist.address,
            username: artist.username ?? artist.displayName ?? 'Unknown',
            displayName: artist.displayName,
            avatarUrl: artist.imageUrl,
            featuredArtworkUrl: artist.featuredArtworkUrl ?? '',
          ),
        )
        .toList();
  }

  /// Map [HomePopularCollectionsResponse] to UI [PopularCollection] list.
  List<PopularCollection> mapPopularCollections(
    api.HomePopularCollectionsResponse response,
  ) {
    return response.collections
        .where((c) => c.imageUrl != null && c.imageUrl!.isNotEmpty)
        .map(
          (c) => PopularCollection(
            id: c.slug,
            name: c.name,
            artistName: formatDisplayLabel(
              displayName: c.creator?.displayName,
              username: c.creator?.username,
              address: c.creator?.effectiveAddress,
            ),
            artistAddress: c.creator?.effectiveAddress ?? '',
            imageUrl: c.imageUrl!,
          ),
        )
        .toList();
  }
}
