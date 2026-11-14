import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/config/environment.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../shared/utils/user_display.dart';
import '../../moderation/services/moderation_filter.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../models/search_models.dart';

/// How many artworks a full page of `POST /v1/explore` holds. A page this
/// long has a successor.
const kExplorePageSize = 40;

/// One fetch of an artwork drilldown, after blocked and reported content was
/// dropped from it.
class ArtworkResultsPage {
  const ArtworkResultsPage({
    required this.artworks,
    required this.page,
    required this.hasMore,
  });

  final List<PortfolioArtwork> artworks;

  /// The last page read. Usually the one asked for; later when the pages in
  /// between were filtered empty (see [fetchPastFilteredPages]). The next
  /// fetch asks for the one after it.
  final int page;

  /// Whether the server has a further page. Never derived from
  /// [artworks.length]: filtering shortens a page without ending the list.
  final bool hasMore;
}

/// Repository for search across users, artworks, collections, and tokens.
///
/// Everything it returns except tokens is other people's content, so every
/// result passes through [ModerationFilter] here, on the API shape, where the
/// addresses the filter needs are still present.
@lazySingleton
class SearchRepository {
  SearchRepository(
    this._api,
    this._dio, {
    // Tests pass a filter over fake stores. Kept out of the generated
    // construction, which uses the app's.
    @ignoreParam ModerationFilter Function()? moderation,
  }) : _moderation = moderation ?? ModerationFilter.current;

  final api.MallowApiClient _api;
  final Dio _dio;
  final ModerationFilter Function() _moderation;

  static String get _jupiterSearchUrl =>
      '${Config.jupiterBaseUrl}/tokens/v2/search';

  // ---------------------------------------------------------------------------
  // Text search
  // ---------------------------------------------------------------------------

  /// Searches all endpoints in parallel, publishing accumulated results as
  /// each finishes. A failed endpoint does not discard other sections.
  Future<SearchResults> search(
    String query, {
    void Function(SearchResults)? onUpdate,
  }) async {
    _MallowResults? mallow;
    var curations = <SearchCurationResult>[];
    var tokens = <SearchTokenResult>[];
    final pending = SearchSource.values.toSet();

    SearchResults snapshot() => SearchResults(
      users: mallow?.users ?? const [],
      artworks: mallow?.artworks ?? const [],
      collections: mallow?.collections ?? const [],
      curations: curations,
      tokens: tokens,
      pendingSources: Set.unmodifiable(pending),
    );

    void completed(SearchSource source) {
      pending.remove(source);
      // The final snapshot is returned to the caller below.
      if (pending.isNotEmpty) onUpdate?.call(snapshot());
    }

    await Future.wait([
      _searchMallow(query).then((value) {
        mallow = value;
        completed(SearchSource.mallow);
      }),
      _searchCurations(query).then((value) {
        curations = value;
        completed(SearchSource.curations);
      }),
      _searchTokens(query).then((value) {
        tokens = value;
        completed(SearchSource.tokens);
      }),
    ]);
    return snapshot();
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
  /// own constraint is pinned on top of it by [ArtworkDrilldownTarget.pinTo],
  /// so the header's promise ("Auction", "3D", "#tag") holds whatever the user
  /// picked.
  ///
  /// [sort] is applied server-side rather than over the loaded pages — sorting
  /// only what page 0 returned would reorder a window, not the result set, and
  /// silently disagree with itself as the user scrolls.
  ///
  /// Edition prints are always hidden, as on the webapp's explore page: one
  /// edition's prints would otherwise fill the list with copies of the same
  /// artwork, and the edition itself already stands in for them. The flag
  /// is set after [ArtworkDrilldownTarget.pinTo], so neither the target nor
  /// the user's filter can turn it off.
  ///
  /// The viewer's blocks are applied here, and a page they empty is skipped
  /// rather than returned (see
  /// [fetchPastFilteredPages]). [ArtworkResultsPage.page] is therefore the
  /// last page read, which the caller pages on from.
  ///
  /// Wrapped in [Result.guard] for the same reason as [fetchFilterResults].
  Future<Result<ArtworkResultsPage, AppFailure>> fetchArtworkResults(
    ArtworkDrilldownTarget target, {
    int page = 0,
    api.ExploreFilter? filter,
    api.ExploreSort sort = api.ExploreSort.recentActivity,
  }) {
    return Result.guard(() async {
      final pinned = target
          .pinTo(filter ?? const api.ExploreFilter())
          .copyWith(hidePrints: true);
      var lastRead = page;
      final result = await fetchPastFilteredPages<PortfolioArtwork>(
        page: page,
        startOfList: page == 0,
        fetch: (current) async {
          lastRead = current;
          final response = await _api.explore(
            api.ExploreRequest(page: current, sort: sort, filter: pinned),
          );
          final raw = response.result;
          final artworks = _mapPreviews(raw, source: 'explore');
          return FilteredPage(
            items: artworks.visible,
            // From the raw length: a page shortened by the filter (or by an
            // item that failed to parse) still has a successor.
            nextPage: raw.length >= kExplorePageSize ? current + 1 : null,
            filteredOut: artworks.filteredOut,
          );
        },
      );
      return ArtworkResultsPage(
        artworks: result.items,
        page: lastRead,
        hasMore: result.nextPage != null,
      );
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
    final moderation = _moderation();
    return response.result.curations
        .where(
          (c) => !moderation.hidesCuration(
            id: c.id,
            slug: c.slug,
            owner: c.owner?.address,
          ),
        )
        .map((c) {
          return FilterResultItem(
            title: c.name,
            subtitle: c.owner?.username ?? c.owner?.displayName,
            thumbnailUrl: c.previewImageUrls.isNotEmpty
                ? c.previewImageUrls.first
                : null,
          );
        })
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Exhibition artworks
  // ---------------------------------------------------------------------------

  /// Fetch artworks for a specific exhibition by slug.
  Future<List<PortfolioArtwork>> fetchExhibitionArtworks(String slug) async {
    final response = await _api.getExhibition(slug);
    return _mapPreviews(response.result.artworks, source: 'exhibition').visible;
  }

  // --- Mappers ---

  /// Map raw `NftPreview`-shaped maps to [PortfolioArtwork], dropping any that
  /// fail to parse and any the viewer blocked or reported. [source] only
  /// labels the log line.
  ({List<PortfolioArtwork> visible, int filteredOut}) _mapPreviews(
    List<Map<String, dynamic>> items, {
    required String source,
  }) {
    final moderation = _moderation();
    var filteredOut = 0;
    final visible = items
        .map((json) {
          try {
            final preview = api.NftPreview.fromJson(json);
            if (moderation.hidesPreview(preview)) {
              filteredOut++;
              return null;
            }
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
    return (visible: visible, filteredOut: filteredOut);
  }

  // ---------------------------------------------------------------------------
  // Private search helpers
  // ---------------------------------------------------------------------------

  Future<_MallowResults?> _searchMallow(String query) async {
    try {
      final response = await _api.search({'query': query});
      final data = response.result;
      final moderation = _moderation();
      return _MallowResults(
        users: data.users
            .where((u) => !moderation.hidesAddress(u.address))
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
        // The search shape carries no creator address, so an artwork is
        // matched by its mint: reported, or seen earlier with a creator who
        // is hidden now.
        artworks: data.artworks
            .where((a) => !moderation.hidesMint(a.mintAccount))
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
            .where((c) => !moderation.hidesAddress(c.curatorAddress))
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
      final moderation = _moderation();
      return response.result.curations
          .where(
            (c) => !moderation.hidesCuration(id: c.id, owner: c.ownerAddress),
          )
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
