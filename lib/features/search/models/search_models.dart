import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

// Decorative palette for filter pills — these four hues cycle through the
// listing/browse/category enum cases to give each pill a distinct accent.
// They're not in MallowColors because they're purely decorative (not
// semantic state colors) and the Dart enum constructor requires const
// expressions, which a ThemeExtension can't provide.
const _filterPillBlue = Color(0xFF6D85E4);
const _filterPillGreen = Color(0xFF6DE49E);
const _filterPillPurple = Color(0xFFC26DE4);
const _filterPillPink = Color(0xFFE46DAE);

/// Filter types available on the search landing page.
enum SearchFilterType {
  // Listing types
  auction('Auction', _filterPillBlue),
  buyNow('Buy now', _filterPillGreen),

  // Browse types
  oneOfOne('1/1s', _filterPillPurple),
  editions('Editions', _filterPillPink),
  curations('Curations', _filterPillBlue),
  exhibitions('Exhibitions', _filterPillGreen),

  // Categories (accent unused — these use background images)
  category3D('3D', _filterPillBlue),
  categoryAbstract('Abstract', _filterPillGreen),
  categoryAI('AI', _filterPillPurple),
  categoryAnimation('Animation', _filterPillPink),
  categoryArchitecture('Architecture', _filterPillBlue),
  categoryCollage('Collage', _filterPillGreen),
  categoryComic('Comic', _filterPillPurple),
  categoryDigitalArt('Digital Art', _filterPillPink),
  categoryGenerative('Generative', _filterPillBlue),
  categoryGlitch('Glitch', _filterPillGreen),
  categoryIllustration('Illustration', _filterPillPurple),
  categoryLandscape('Landscape', _filterPillPink),
  categoryMusic('Music', _filterPillBlue),
  categoryNude('Nude', _filterPillGreen),
  categoryPainting('Painting', _filterPillPurple),
  categoryPFP('PFP', _filterPillPink),
  categoryPhotography('Photography', _filterPillBlue),
  categoryPixelart('Pixelart', _filterPillGreen),
  categoryPoetry('Poetry', _filterPillPurple),
  categoryPortrait('Portrait', _filterPillPink),
  categoryPsychedelic('Psychedelic', _filterPillBlue),
  categorySculpture('Sculpture', _filterPillGreen),
  categoryShortFilm('Short Film', _filterPillPurple),
  categorySurrealism('Surrealism', _filterPillPink),
  categoryTextile('Textile', _filterPillBlue),
  categoryVideo('Video', _filterPillGreen);

  const SearchFilterType(this.label, this.accentColor);

  final String label;
  final Color accentColor;

  /// The tag string sent to the explore API for category filters.
  ///
  /// Backend tag matching is exact against lowercase hyphen-separated slugs
  /// ("abstract", "digital-art", "short-film") — sending the display label
  /// ("Abstract", "Digital Art") matches nothing and renders as an empty
  /// result set with no error.
  String? get categoryTag {
    if (!name.startsWith('category')) return null;
    return label.toLowerCase().replaceAll(' ', '-');
  }

  /// True when this drilldown lists artworks from `POST /v1/explore`.
  ///
  /// Only these drilldowns get the filter / sort / view-mode bar: their items
  /// are artworks, so they map to `PortfolioArtwork` and render through the
  /// portfolio's masonry / list / grid views. `curations` and `exhibitions`
  /// come from their own endpoints and stay plain rows.
  bool get isArtworkBrowse => switch (this) {
    curations || exhibitions => false,
    _ => true,
  };

  /// Applies this drilldown's own explore constraint on top of [base].
  ///
  /// The constraint is pinned, not merged: the header promises "Auction" or
  /// "3D", so it always wins over whatever the user picked in the filters
  /// sheet. The sheet hides the matching facet (see [pinsListingType],
  /// [pinsSupplyType], [pinsCategory]) so no control is a silent no-op.
  api.ExploreFilter pinTo(api.ExploreFilter base) => switch (this) {
    auction => base.copyWith(listingTypes: const ['auction']),
    buyNow => base.copyWith(listingTypes: const ['buy-now']),
    oneOfOne => base.copyWith(mode: api.ExploreMode.oneOfOne),
    editions => base.copyWith(mode: api.ExploreMode.editions),
    _ => switch (categoryTag) {
      final tag? => base.copyWith(tags: [tag]),
      _ => base,
    },
  };

  bool get pinsListingType => this == auction || this == buyNow;

  bool get pinsSupplyType => this == oneOfOne || this == editions;

  bool get pinsCategory => categoryTag != null;

  static const listingTypes = [auction, buyNow];
  static const browseTypes = [oneOfOne, editions, curations, exhibitions];
  static List<SearchFilterType> get categories =>
      values.where((v) => v.name.startsWith('category')).toList();
}

/// A single item in the filter results view.
class FilterResultItem {
  const FilterResultItem({
    required this.title,
    this.subtitle,
    this.thumbnailUrl,
    this.mintAccount,
    this.routePath,
    this.creatorUsername,
    this.creatorAddress,
    this.nsfw = false,
  });

  final String title;
  final String? subtitle;
  final String? thumbnailUrl;
  final String? mintAccount;
  final String? routePath;

  /// Creator handle for the artwork drilldown subtitle. Rendered via
  /// [UserHandleText] with [creatorAddress] as the truncated fallback.
  final String? creatorUsername;
  final String? creatorAddress;

  /// Moderation flag: artwork marked not-safe-for-work. The result thumb is
  /// blurred (with an eye-icon reveal) unless the viewer's show-NSFW setting
  /// is on.
  final bool nsfw;
}

/// UI model for a user search result.
class SearchUserResult {
  const SearchUserResult({
    required this.username,
    this.address,
    this.avatarUrl,
    this.isVerified = false,
    this.isAdmin = false,
  });

  final String username;
  final String? address;
  final String? avatarUrl;
  final bool isVerified;
  final bool isAdmin;
}

/// UI model for an artwork search result.
class SearchArtworkResult {
  const SearchArtworkResult({
    required this.title,
    required this.mintAccount,
    this.thumbnailUrl,
    this.artistUsername,
    this.editionNumber,
    this.playbackId,
    this.clipPlaybackId,
    this.nsfw = false,
  });

  final String title;
  final String mintAccount;
  final String? thumbnailUrl;
  final String? artistUsername;
  final int? editionNumber;
  final String? playbackId;
  final String? clipPlaybackId;

  /// Moderation flag: artwork marked not-safe-for-work. The result thumb is
  /// blurred unless the viewer's show-NSFW setting is on.
  final bool nsfw;
}

/// UI model for a collection search result (from /v1/search).
class SearchCollectionResult {
  const SearchCollectionResult({
    required this.name,
    this.thumbnailUrl,
    this.curatorUsername,
    this.curatorAddress,
    this.slug,
  });

  final String name;
  final String? thumbnailUrl;
  final String? curatorUsername;
  final String? curatorAddress;
  final String? slug;
}

/// UI model for a curation search result (from /v1/search/curations).
class SearchCurationResult {
  const SearchCurationResult({
    required this.id,
    required this.name,
    this.artworkCount = 0,
    this.thumbnailUrls = const [],
    this.ownerAddress,
    this.ownerUsername,
  });

  final String id;
  final String name;
  final int artworkCount;
  final List<String> thumbnailUrls;
  final String? ownerAddress;
  final String? ownerUsername;
}

/// UI model for a token search result.
class SearchTokenResult {
  const SearchTokenResult({
    required this.mintAddress,
    required this.name,
    required this.symbol,
    this.iconUrl,
    this.usdPrice,
    this.priceChange24h,
  });

  final String mintAddress;
  final String name;
  final String symbol;
  final String? iconUrl;
  final double? usdPrice;
  final double? priceChange24h;
}

/// Aggregated search results for all sections.
class SearchResults {
  const SearchResults({
    this.users = const [],
    this.artworks = const [],
    this.collections = const [],
    this.curations = const [],
    this.tokens = const [],
  });

  final List<SearchUserResult> users;
  final List<SearchArtworkResult> artworks;
  final List<SearchCollectionResult> collections;
  final List<SearchCurationResult> curations;
  final List<SearchTokenResult> tokens;

  bool get isEmpty =>
      users.isEmpty &&
      artworks.isEmpty &&
      collections.isEmpty &&
      curations.isEmpty &&
      tokens.isEmpty;
}
