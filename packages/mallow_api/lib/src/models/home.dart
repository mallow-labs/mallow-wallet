import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';
import 'artwork.dart';
import 'user.dart';

part 'home.freezed.dart';
part 'home.g.dart';

/// Home feed response from GET /home.
///
/// The backend composes featured + curated + spotlight + creators
/// in a single call via Promise.all.
@freezed
sealed class HomeFeedResponse with _$HomeFeedResponse {
  const factory HomeFeedResponse({
    @JsonKey(fromJson: _itemRendersFromJson) @Default([]) List<ItemRender> featured,
    @Default([]) List<User> creators,
    @JsonKey(fromJson: _itemRendersFromJson) @Default([]) List<ItemRender> smores,
    CuratedSection? curated,
    SpotlightResult? spotlight,
  }) = _HomeFeedResponse;

  factory HomeFeedResponse.fromJson(Map<String, dynamic> json) => _$HomeFeedResponseFromJson(json);
}

/// A curated section with title and items.
@freezed
sealed class CuratedSection with _$CuratedSection {
  // `title` defaults to empty rather than being required: the backend can omit
  // it, and a null here previously crashed the entire /home parse
  // (`type 'Null' is not a subtype of type 'String'`).
  const factory CuratedSection({
    @Default('') String title,
    @JsonKey(fromJson: _itemRendersFromJson) @Default([]) List<ItemRender> items,
  }) = _CuratedSection;

  factory CuratedSection.fromJson(Map<String, dynamic> json) => _$CuratedSectionFromJson(json);
}

/// Daily spotlight result.
///
/// The API returns `{ contentType, creator: { user, userDetails }, render }`.
/// We flatten `creator.user` into [SpotlightCreator] and parse `render`
/// based on `contentType` (same approach as [ItemRender]).
@JsonSerializable()
class SpotlightResult {
  const SpotlightResult({this.contentType, this.creator, this.nftPreview, this.collectionRender});

  final String? contentType;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final SpotlightCreator? creator;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final NftPreview? nftPreview;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final CollectionRender? collectionRender;

  /// Convenience: primary image URL from either render type.
  String? get imageUrl => nftPreview?.imageUrl ?? collectionRender?.imageUrl;

  /// Convenience: display name from either render type.
  String? get name => nftPreview?.name ?? collectionRender?.name;

  factory SpotlightResult.fromJson(Map<String, dynamic> json) {
    final contentType = json['contentType'] as String?;

    // Parse creator from nested { user: {...} } structure.
    SpotlightCreator? creator;
    final creatorJson = json['creator'];
    if (creatorJson is Map<String, dynamic>) {
      final userJson = creatorJson['user'] as Map<String, dynamic>?;
      if (userJson != null) {
        creator = SpotlightCreator.fromJson(userJson);
      } else {
        // Fallback: flat creator object
        creator = SpotlightCreator.fromJson(creatorJson);
      }
    }

    // Parse render based on contentType (same as ItemRender).
    final render = json['render'] as Map<String, dynamic>?;
    NftPreview? nftPreview;
    CollectionRender? collectionRender;

    if (render != null) {
      switch (contentType) {
        case 'collection':
          collectionRender = CollectionRender.fromJson(render);
        default:
          try {
            nftPreview = NftPreview.fromJson(render);
          } catch (_) {}
      }
    }

    return SpotlightResult(
      contentType: contentType,
      creator: creator,
      nftPreview: nftPreview,
      collectionRender: collectionRender,
    );
  }

  Map<String, dynamic> toJson() => {if (contentType != null) 'contentType': contentType};
}

/// Creator info within a spotlight result.
@freezed
sealed class SpotlightCreator with _$SpotlightCreator {
  const factory SpotlightCreator({
    @Default([]) List<String> addresses,
    String? username,
    String? displayName,
    String? imageUrl,
    String? bannerUrl,
  }) = _SpotlightCreator;

  factory SpotlightCreator.fromJson(Map<String, dynamic> json) => _$SpotlightCreatorFromJson(json);
}

/// Parse a list of feed items, dropping any whose contentType we don't render
/// (no usable `nftPreview`/`collectionRender`). Keeps unknown/unimplemented
/// types — and items that failed to parse — out of the UI. See
/// [ItemRender.fromJson].
List<ItemRender> _itemRendersFromJson(List<dynamic>? json) {
  if (json == null) return const [];
  final items = <ItemRender>[];
  for (final raw in json) {
    if (raw is Map<String, dynamic>) {
      final item = ItemRender.fromJson(raw);
      if (item.nftPreview != null || item.collectionRender != null) {
        items.add(item);
      }
    }
  }
  return items;
}

/// Parse a list of NFT previews, dropping any entry that fails to parse
/// (e.g. a backend payload missing the required `name`/`mintAccount`). A single
/// malformed preview must not crash the whole /home parse.
List<NftPreview> _nftPreviewsFromJson(List<dynamic>? json) {
  if (json == null) return const [];
  final previews = <NftPreview>[];
  for (final item in json) {
    if (item is Map<String, dynamic>) {
      try {
        previews.add(NftPreview.fromJson(item));
      } catch (_) {}
    }
  }
  return previews;
}

/// Full collection data with preview images (richer than CollectionPreview).
@freezed
sealed class CollectionRender with _$CollectionRender {
  const factory CollectionRender({
    String? slug,
    String? name,
    String? description,
    String? imageUrl,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? creator,
    @JsonKey(fromJson: _nftPreviewsFromJson) @Default([]) List<NftPreview> nftPreviews,
    int? itemCount,
    double? floor,
    double? usdVolume,
  }) = _CollectionRender;

  factory CollectionRender.fromJson(Map<String, dynamic> json) => _$CollectionRenderFromJson(json);
}

/// Response from GET /v1/mobile/home/recommended
@freezed
sealed class HomeRecommendedResponse with _$HomeRecommendedResponse {
  const factory HomeRecommendedResponse({@Default([]) List<HomeRecommendedCuration> curations}) =
      _HomeRecommendedResponse;

  factory HomeRecommendedResponse.fromJson(Map<String, dynamic> json) =>
      _$HomeRecommendedResponseFromJson(json);
}

/// A single curation within the recommended-for-you response.
@freezed
sealed class HomeRecommendedCuration with _$HomeRecommendedCuration {
  const factory HomeRecommendedCuration({
    required String name,
    HomePopularCurationOwner? owner,
    @JsonKey(fromJson: _itemRendersFromJson) @Default([]) List<ItemRender> artworks,
    @Default([]) List<String> artistUsernames,
  }) = _HomeRecommendedCuration;

  factory HomeRecommendedCuration.fromJson(Map<String, dynamic> json) =>
      _$HomeRecommendedCurationFromJson(json);
}

/// Response from GET /v1/mobile/home/popular-curations
@freezed
sealed class HomePopularCurationsResponse with _$HomePopularCurationsResponse {
  const factory HomePopularCurationsResponse({
    @Default([]) List<HomePopularCurationItem> curations,
  }) = _HomePopularCurationsResponse;

  factory HomePopularCurationsResponse.fromJson(Map<String, dynamic> json) =>
      _$HomePopularCurationsResponseFromJson(json);
}

/// A curation entry in the popular-curations response.
@freezed
sealed class HomePopularCurationItem with _$HomePopularCurationItem {
  const factory HomePopularCurationItem({
    required String name,
    // `id` and `slug` were added after the initial mobile release. Defaulted
    // to empty so older cached payloads still parse — the Flutter UI falls
    // back to name when id is empty.
    @Default('') String id,
    @Default('') String slug,
    HomePopularCurationOwner? owner,
    @Default([]) List<String> previewImageUrls,
  }) = _HomePopularCurationItem;

  factory HomePopularCurationItem.fromJson(Map<String, dynamic> json) =>
      _$HomePopularCurationItemFromJson(json);
}

/// Owner info within a popular-curations entry.
@freezed
sealed class HomePopularCurationOwner with _$HomePopularCurationOwner {
  const factory HomePopularCurationOwner({
    required String address,
    String? username,
    String? displayName,
    String? imageUrl,
  }) = _HomePopularCurationOwner;

  factory HomePopularCurationOwner.fromJson(Map<String, dynamic> json) =>
      _$HomePopularCurationOwnerFromJson(json);
}

/// Response from GET /v1/mobile/home/discover
@freezed
sealed class HomeDiscoverResponse with _$HomeDiscoverResponse {
  const factory HomeDiscoverResponse({@Default([]) List<HomeDiscoverArtist> artists}) =
      _HomeDiscoverResponse;

  factory HomeDiscoverResponse.fromJson(Map<String, dynamic> json) =>
      _$HomeDiscoverResponseFromJson(json);
}

/// An artist entry in the discover response.
@freezed
sealed class HomeDiscoverArtist with _$HomeDiscoverArtist {
  const factory HomeDiscoverArtist({
    required String address,
    String? username,
    String? displayName,
    String? imageUrl,
    String? featuredArtworkUrl,
  }) = _HomeDiscoverArtist;

  factory HomeDiscoverArtist.fromJson(Map<String, dynamic> json) =>
      _$HomeDiscoverArtistFromJson(json);
}

/// Response from GET /v1/mobile/home/popular-collections
@freezed
sealed class HomePopularCollectionsResponse with _$HomePopularCollectionsResponse {
  const factory HomePopularCollectionsResponse({
    @Default([]) List<HomePopularCollectionItem> collections,
  }) = _HomePopularCollectionsResponse;

  factory HomePopularCollectionsResponse.fromJson(Map<String, dynamic> json) =>
      _$HomePopularCollectionsResponseFromJson(json);
}

/// A collection entry in the popular-collections response.
@freezed
sealed class HomePopularCollectionItem with _$HomePopularCollectionItem {
  const factory HomePopularCollectionItem({
    required String slug,
    required String name,
    String? imageUrl,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? creator,
  }) = _HomePopularCollectionItem;

  factory HomePopularCollectionItem.fromJson(Map<String, dynamic> json) =>
      _$HomePopularCollectionItemFromJson(json);
}

/// An item in the home feed (NFT, collection, etc.).
///
/// Uses `contentType` to discriminate the render data.
/// The `render` field in the JSON is parsed based on `contentType`.
@JsonSerializable()
class ItemRender {
  const ItemRender({
    required this.contentType,
    this.nftPreview,
    this.collectionRender,
    this.creatorUsername,
    this.creatorAddress,
  });

  final String contentType;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final NftPreview? nftPreview;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final CollectionRender? collectionRender;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? creatorUsername;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? creatorAddress;

  /// Convenience: primary image URL from either render type.
  String? get imageUrl => nftPreview?.imageUrl ?? collectionRender?.imageUrl;

  /// Convenience: display name from either render type.
  String? get name => nftPreview?.name ?? collectionRender?.name;

  /// Convenience: mint account (NFTs only).
  String? get mintAccount => nftPreview?.mintAccount;

  factory ItemRender.fromJson(Map<String, dynamic> json) {
    final contentType = json['contentType'] as String? ?? 'unknown';
    final render = json['render'] as Map<String, dynamic>?;

    NftPreview? nftPreview;
    CollectionRender? collectionRender;

    if (render != null) {
      // Only build a render for contentTypes we actually implement. Unknown /
      // unimplemented types (e.g. `gumball` and `jellybean`, not ready yet) get
      // no render and are filtered out of the feed by [_itemRendersFromJson] —
      // better a missing card than a crash or a blank tile.
      switch (contentType) {
        case 'nft':
          // Guard against malformed payloads (e.g. missing required
          // `name`/`mintAccount`) so one bad item drops instead of crashing
          // the whole feed.
          try {
            nftPreview = NftPreview.fromJson(render);
          } catch (_) {}
        case 'collection':
          try {
            collectionRender = CollectionRender.fromJson(render);
          } catch (_) {}
      }
    }

    // Extract creator username and address from raw render JSON.
    String? creatorUsername;
    String? creatorAddress;
    if (render != null) {
      final creator = render['creator'];
      if (creator is Map<String, dynamic>) {
        creatorUsername = creator['username'] as String?;
        final addresses = creator['addresses'] as List?;
        creatorAddress = addresses?.firstOrNull as String?;
        creatorAddress ??= creator['primaryAddress'] as String?;
      }
    }

    return ItemRender(
      contentType: contentType,
      nftPreview: nftPreview,
      collectionRender: collectionRender,
      creatorUsername: creatorUsername,
      creatorAddress: creatorAddress,
    );
  }

  Map<String, dynamic> toJson() => {
    'contentType': contentType,
    if (nftPreview != null) 'render': nftPreview!.toJson(),
    if (collectionRender != null) 'render': collectionRender!.toJson(),
  };
}
