import 'dart:convert';

import 'search_models.dart';

/// The kind of content a [RecentlyViewedItem] wraps. Mirrors the sections the
/// search sheet renders so a recently-viewed row is identical to its
/// search-result row.
enum RecentlyViewedType { user, artwork, collection, curation, token }

/// A piece of content the user has recently opened (artwork, profile,
/// collection, curation, or token).
///
/// Wraps the same UI result models the search sheet renders, so the
/// "Recently viewed" section can reuse the search-result row widgets and tap
/// navigation verbatim. Persisted as JSON in `PreferencesService`.
class RecentlyViewedItem {
  const RecentlyViewedItem({
    required this.type,
    this.user,
    this.artwork,
    this.collection,
    this.curation,
    this.token,
  });

  factory RecentlyViewedItem.user(SearchUserResult user) =>
      RecentlyViewedItem(type: RecentlyViewedType.user, user: user);

  factory RecentlyViewedItem.artwork(SearchArtworkResult artwork) =>
      RecentlyViewedItem(type: RecentlyViewedType.artwork, artwork: artwork);

  factory RecentlyViewedItem.collection(SearchCollectionResult collection) =>
      RecentlyViewedItem(
        type: RecentlyViewedType.collection,
        collection: collection,
      );

  factory RecentlyViewedItem.curation(SearchCurationResult curation) =>
      RecentlyViewedItem(type: RecentlyViewedType.curation, curation: curation);

  factory RecentlyViewedItem.token(SearchTokenResult token) =>
      RecentlyViewedItem(type: RecentlyViewedType.token, token: token);

  final RecentlyViewedType type;
  final SearchUserResult? user;
  final SearchArtworkResult? artwork;
  final SearchCollectionResult? collection;
  final SearchCurationResult? curation;
  final SearchTokenResult? token;

  /// Stable identity for de-duplication: re-viewing the same content moves the
  /// existing entry to the front of the list instead of adding a duplicate.
  String get dedupeKey => switch (type) {
    RecentlyViewedType.user =>
      'user:${(user!.address?.isNotEmpty ?? false) ? user!.address : user!.username}',
    RecentlyViewedType.artwork => 'artwork:${artwork!.mintAccount}',
    RecentlyViewedType.collection =>
      'collection:${collection!.slug ?? collection!.name}',
    RecentlyViewedType.curation => 'curation:${curation!.id}',
    RecentlyViewedType.token => 'token:${token!.mintAddress}',
  };

  Map<String, dynamic> toJson() => {
    'type': type.name,
    switch (type) {
      RecentlyViewedType.user => 'user',
      RecentlyViewedType.artwork => 'artwork',
      RecentlyViewedType.collection => 'collection',
      RecentlyViewedType.curation => 'curation',
      RecentlyViewedType.token => 'token',
    }: switch (type) {
      RecentlyViewedType.user => {
        'username': user!.username,
        'address': user!.address,
        'avatarUrl': user!.avatarUrl,
        'isVerified': user!.isVerified,
        'isAdmin': user!.isAdmin,
      },
      RecentlyViewedType.artwork => {
        'title': artwork!.title,
        'mintAccount': artwork!.mintAccount,
        'thumbnailUrl': artwork!.thumbnailUrl,
        'artistUsername': artwork!.artistUsername,
        'editionNumber': artwork!.editionNumber,
      },
      RecentlyViewedType.collection => {
        'name': collection!.name,
        'thumbnailUrl': collection!.thumbnailUrl,
        'curatorUsername': collection!.curatorUsername,
        'curatorAddress': collection!.curatorAddress,
        'slug': collection!.slug,
      },
      RecentlyViewedType.curation => {
        'id': curation!.id,
        'name': curation!.name,
        'artworkCount': curation!.artworkCount,
        'thumbnailUrls': curation!.thumbnailUrls,
        'ownerAddress': curation!.ownerAddress,
        'ownerUsername': curation!.ownerUsername,
      },
      RecentlyViewedType.token => {
        'mintAddress': token!.mintAddress,
        'name': token!.name,
        'symbol': token!.symbol,
        'iconUrl': token!.iconUrl,
        'usdPrice': token!.usdPrice,
        'priceChange24h': token!.priceChange24h,
      },
    },
  };

  /// Decodes a persisted item, or returns null if the payload is malformed or
  /// of an unknown type (forward-compatibility: a future type written by a
  /// newer build is silently skipped rather than crashing the list).
  static RecentlyViewedItem? fromJson(Map<String, dynamic> json) {
    final type = RecentlyViewedType.values.where((t) => t.name == json['type']);
    if (type.isEmpty) return null;
    switch (type.first) {
      case RecentlyViewedType.user:
        final d = json['user'] as Map<String, dynamic>;
        return RecentlyViewedItem.user(
          SearchUserResult(
            username: d['username'] as String,
            address: d['address'] as String?,
            avatarUrl: d['avatarUrl'] as String?,
            isVerified: d['isVerified'] as bool? ?? false,
            isAdmin: d['isAdmin'] as bool? ?? false,
          ),
        );
      case RecentlyViewedType.artwork:
        final d = json['artwork'] as Map<String, dynamic>;
        return RecentlyViewedItem.artwork(
          SearchArtworkResult(
            title: d['title'] as String,
            mintAccount: d['mintAccount'] as String,
            thumbnailUrl: d['thumbnailUrl'] as String?,
            artistUsername: d['artistUsername'] as String?,
            editionNumber: d['editionNumber'] as int?,
          ),
        );
      case RecentlyViewedType.collection:
        final d = json['collection'] as Map<String, dynamic>;
        return RecentlyViewedItem.collection(
          SearchCollectionResult(
            name: d['name'] as String,
            thumbnailUrl: d['thumbnailUrl'] as String?,
            curatorUsername: d['curatorUsername'] as String?,
            curatorAddress: d['curatorAddress'] as String?,
            slug: d['slug'] as String?,
          ),
        );
      case RecentlyViewedType.curation:
        final d = json['curation'] as Map<String, dynamic>;
        return RecentlyViewedItem.curation(
          SearchCurationResult(
            id: d['id'] as String,
            name: d['name'] as String,
            artworkCount: d['artworkCount'] as int? ?? 0,
            thumbnailUrls:
                (d['thumbnailUrls'] as List<dynamic>?)
                    ?.map((e) => e as String)
                    .toList() ??
                const [],
            ownerAddress: d['ownerAddress'] as String?,
            ownerUsername: d['ownerUsername'] as String?,
          ),
        );
      case RecentlyViewedType.token:
        final d = json['token'] as Map<String, dynamic>;
        return RecentlyViewedItem.token(
          SearchTokenResult(
            mintAddress: d['mintAddress'] as String,
            name: d['name'] as String,
            symbol: d['symbol'] as String,
            iconUrl: d['iconUrl'] as String?,
            usdPrice: (d['usdPrice'] as num?)?.toDouble(),
            priceChange24h: (d['priceChange24h'] as num?)?.toDouble(),
          ),
        );
    }
  }

  /// Canonical encoded form, used as the persisted string and as the basis for
  /// value equality (so identical re-reads from storage compare equal and
  /// don't trigger spurious landing rebuilds).
  String get encoded => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is RecentlyViewedItem && other.encoded == encoded;

  @override
  int get hashCode => encoded.hashCode;
}
