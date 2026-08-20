import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/config/environment.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../shared/utils/user_display.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../models/search_models.dart';

/// Repository for search across users, artworks, collections, and tokens.
@lazySingleton
class SearchRepository {
  SearchRepository(this._api, this._dio);

  final api.MallowApiClient _api;
  final Dio _dio;

  static String get _jupiterSearchUrl =>
      '${Config.jupiterBaseUrl}/tokens/v2/search';

  // ---------------------------------------------------------------------------
  // Text search
  // ---------------------------------------------------------------------------

  /// Search for [query] across all sections in parallel.
  ///
  /// Returns a [SearchResults] with whatever sections succeeded.
  /// Individual section failures are swallowed so a single broken endpoint
  /// doesn't clear the entire result.
  Future<SearchResults> search(String query) async {
    final results = await Future.wait([
      _searchMallow(query),
      _searchCurations(query),
      _searchTokens(query),
    ]);

    final mallowResults = results[0] as _MallowResults?;
    final curations = results[1] as List<SearchCurationResult>;
    final tokens = results[2] as List<SearchTokenResult>;

    return SearchResults(
      users: mallowResults?.users ?? [],
      artworks: mallowResults?.artworks ?? [],
      collections: mallowResults?.collections ?? [],
      curations: curations,
      tokens: tokens,
    );
  }

  // ---------------------------------------------------------------------------
  // Explore / filter results
  // ---------------------------------------------------------------------------

  /// Fetch the non-artwork drilldowns: `curations` and `exhibitions`.
  ///
  /// Returns a [Result] wrapping the mapped [FilterResultItem]s on success, or
  /// an [AppFailure] when the underlying request fails. Both come from their
  /// own endpoints with their own untyped response shapes. Artwork drilldowns
  /// go through [fetchArtworkResults] instead — see
  /// [SearchFilterType.isArtworkBrowse]. A single [Result.guard] wraps the
  /// dispatch so callers can distinguish "no results" from "request failed" —
  /// the browse tabs previously swallowed transport errors to an empty list,
  /// rendering a network failure as an indistinguishable blank screen.
  Future<Result<List<FilterResultItem>, AppFailure>> fetchFilterResults(
    SearchFilterType filterType, {
    int page = 0,
  }) {
    return Result.guard(() async {
      switch (filterType) {
        case SearchFilterType.curations:
          return _exploreCurations();
        case SearchFilterType.exhibitions:
          return _exploreExhibitions(page: page);
        default:
          return <FilterResultItem>[];
      }
    });
  }

  /// Fetch one page of an artwork drilldown from `POST /v1/explore`.
  ///
  /// [filter] is the user's selection from the filters sheet; the drilldown's
  /// own constraint is pinned on top of it by [SearchFilterType.pinTo], so the
  /// header's promise ("Auction", "3D") holds whatever the user picked.
  ///
  /// [sort] is applied server-side rather than over the loaded pages — sorting
  /// only what page 0 returned would reorder a window, not the result set, and
  /// silently disagree with itself as the user scrolls.
  ///
  /// Wrapped in [Result.guard] for the same reason as [fetchFilterResults].
  Future<Result<List<PortfolioArtwork>, AppFailure>> fetchArtworkResults(
    SearchFilterType filterType, {
    int page = 0,
    api.ExploreFilter? filter,
    api.ExploreSort sort = api.ExploreSort.recentActivity,
  }) {
    return Result.guard(() async {
      final response = await _api.explore(
        api.ExploreRequest(
          page: page,
          sort: sort,
          filter: filterType.pinTo(filter ?? const api.ExploreFilter()),
        ),
      );
      return _mapPreviews(response.result, source: 'explore');
    });
  }

  // --- Main explore helpers ---

  Future<List<FilterResultItem>> _exploreExhibitions({int page = 0}) async {
    final response = await _api.exploreExhibitions(
      api.ExhibitionsExploreRequest(page: page),
    );
    return response.result.map((item) {
      return FilterResultItem(
        title: item['title'] as String? ?? '',
        thumbnailUrl:
            item['menuBannerUrl'] as String? ?? item['bgUrl'] as String?,
        mintAccount: item['slug'] as String?,
      );
    }).toList();
  }

  Future<List<FilterResultItem>> _exploreCurations() async {
    final response = await _api.getHomePopularCurations();
    return response.result.curations.map((c) {
      return FilterResultItem(
        title: c.name,
        subtitle: c.owner?.username ?? c.owner?.displayName,
        thumbnailUrl: c.previewImageUrls.isNotEmpty
            ? c.previewImageUrls.first
            : null,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Exhibition artworks
  // ---------------------------------------------------------------------------

  /// Fetch artworks for a specific exhibition by slug.
  Future<List<PortfolioArtwork>> fetchExhibitionArtworks(String slug) async {
    final response = await _api.getExhibition(slug);
    return _mapPreviews(response.result.artworks, source: 'exhibition');
  }

  // --- Mappers ---

  /// Map raw `NftPreview`-shaped maps to [PortfolioArtwork], dropping any that
  /// fail to parse. [source] only labels the log line.
  List<PortfolioArtwork> _mapPreviews(
    List<Map<String, dynamic>> items, {
    required String source,
  }) {
    return items
        .map((json) {
          try {
            final preview = api.NftPreview.fromJson(json);
            return PortfolioArtwork(
              mintAccount: preview.mintAccount,
              title: preview.name,
              imageUrl: preview.imageUrl ?? '',
              playbackId: preview.playbackId,
              clipPlaybackId: preview.clipPlaybackId,
              // Rendered by cards that prefer the creator username and fall
              // back to the creator address.
              artistName: formatUsernameOrAddress(
                username: preview.creator?.username,
                address: preview.creator?.effectiveAddress,
              ),
              artistUsername: preview.creator?.username,
              collectionName: preview.collectionName,
              aspectRatio: preview.aspectRatio ?? 1.0,
              lastPrice: preview.lastSale?.price,
              listingType: preview.listingType,
              supply: preview.supply,
              maxSupply: preview.maxSupply,
              editionNumber: preview.editionNumber,
              parentEdition: preview.parentEdition,
              auctionMetadata: preview.auctionMetadata,
              buyNowMetadata: preview.buyNowMetadata,
              updateAuth: preview.updateAuth,
              nsfw: preview.nsfw ?? false,
            );
          } catch (e) {
            // Dropped items must at least be visible in logs — silently
            // shrinking the list is indistinguishable from a sparse page.
            debugPrint('[SearchRepository] $source artwork parse failed: $e');
            return null;
          }
        })
        .whereType<PortfolioArtwork>()
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Private search helpers
  // ---------------------------------------------------------------------------

  Future<_MallowResults?> _searchMallow(String query) async {
    try {
      final response = await _api.search({'query': query});
      final data = response.result;
      return _MallowResults(
        users: data.users
            .map(
              (u) => SearchUserResult(
                username: u.username,
                address: u.address,
                avatarUrl: u.avatarUrl,
                isVerified: u.isVerified,
                isAdmin: u.isAdmin,
              ),
            )
            .toList(),
        artworks: data.artworks
            .map(
              (a) => SearchArtworkResult(
                title: a.title,
                mintAccount: a.mintAccount,
                thumbnailUrl: a.thumbnailUrl,
                artistUsername: a.artistUsername,
                editionNumber: a.editionNumber,
                playbackId: a.playbackId,
                clipPlaybackId: a.clipPlaybackId,
                nsfw: a.nsfw ?? false,
              ),
            )
            .toList(),
        collections: data.collections
            .map(
              (c) => SearchCollectionResult(
                name: c.name,
                thumbnailUrl: c.thumbnailUrl,
                curatorUsername: c.curatorUsername,
                curatorAddress: c.curatorAddress,
                slug: c.slug,
              ),
            )
            .toList(),
      );
    } catch (e) {
      debugPrint('[SearchRepository] mallow search failed: $e');
      return null;
    }
  }

  Future<List<SearchCurationResult>> _searchCurations(String query) async {
    try {
      final response = await _api.searchCurations({'query': query});
      return response.result.curations
          .map(
            (c) => SearchCurationResult(
              id: c.id,
              name: c.name,
              artworkCount: c.artworkCount,
              thumbnailUrls: c.thumbnailUrls,
              ownerAddress: c.ownerAddress,
              ownerUsername: c.ownerUsername,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('[SearchRepository] Curation search failed: $e');
      return [];
    }
  }

  Future<List<SearchTokenResult>> _searchTokens(String query) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        _jupiterSearchUrl,
        queryParameters: {'query': query, 'limit': 10},
      );
      final data = response.data;
      if (data == null) return [];
      return data
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final stats24h = item['stats24h'] as Map<String, dynamic>?;
            return SearchTokenResult(
              mintAddress: item['id'] as String? ?? '',
              name: item['name'] as String? ?? '',
              symbol: item['symbol'] as String? ?? '',
              iconUrl: item['icon'] as String?,
              usdPrice: (item['usdPrice'] as num?)?.toDouble(),
              priceChange24h: (stats24h?['priceChange'] as num?)?.toDouble(),
            );
          })
          .where((t) => t.mintAddress.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[SearchRepository] Jupiter token search failed: $e');
      return [];
    }
  }
}

class _MallowResults {
  const _MallowResults({
    required this.users,
    required this.artworks,
    required this.collections,
  });

  final List<SearchUserResult> users;
  final List<SearchArtworkResult> artworks;
  final List<SearchCollectionResult> collections;
}
