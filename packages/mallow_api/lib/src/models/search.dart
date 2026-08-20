import 'package:freezed_annotation/freezed_annotation.dart';

part 'search.freezed.dart';
part 'search.g.dart';

/// Response from POST /v1/search.
@Freezed(toJson: false)
sealed class SearchResponse with _$SearchResponse {
  const factory SearchResponse({
    @Default([]) @JsonKey(name: 'usersWithDetails') List<SearchUserItem> users,
    @Default([]) @JsonKey(name: 'items') List<SearchArtworkItem> artworks,
    @Default([]) List<SearchCollectionItem> collections,
  }) = _SearchResponse;

  factory SearchResponse.fromJson(Map<String, dynamic> json) => _$SearchResponseFromJson(json);
}

/// A user result from the search endpoint.
///
/// The backend returns `{ user: { addresses, username, imageUrl, isTwitterVerified, … }, userDetails: { … } }`.
@freezed
sealed class SearchUserItem with _$SearchUserItem {
  const factory SearchUserItem({
    required String username,
    String? address,
    String? avatarUrl,
    @Default(false) bool isVerified,
    @Default(false) bool isAdmin,
  }) = _SearchUserItem;

  factory SearchUserItem.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>? ?? json;
    final roles = (user['roles'] as List<dynamic>?)?.cast<String>() ?? const [];
    // `UserRenderer.renderSingle` emits `addresses` (plural) and whitelists the
    // fields it renders, so a singular `address` is never on the wire. See
    // [UserSearchItem], which keeps the whole list. This one collapses to the
    // first entry: it only feeds the display label, the identicon seed and the
    // by-address profile route for users with no username.
    final addresses = user['addresses'] as List<dynamic>?;
    return SearchUserItem(
      username: user['username'] as String? ?? '',
      address: addresses?.firstOrNull as String?,
      avatarUrl: user['imageUrl'] as String?,
      isVerified: user['isTwitterVerified'] as bool? ?? false,
      isAdmin: roles.contains('admin'),
    );
  }
}

/// An artwork result from the search endpoint.
///
/// The backend returns `{ name, mintAccount, imageUrl, creator: { username, … }, … }`.
@freezed
sealed class SearchArtworkItem with _$SearchArtworkItem {
  const factory SearchArtworkItem({
    required String title,
    required String mintAccount,
    String? thumbnailUrl,
    String? artistUsername,
    int? editionNumber,
    String? playbackId,
    String? clipPlaybackId,
    bool? nsfw,
  }) = _SearchArtworkItem;

  factory SearchArtworkItem.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'] as Map<String, dynamic>?;
    return SearchArtworkItem(
      title: json['name'] as String? ?? '',
      mintAccount: json['mintAccount'] as String? ?? '',
      thumbnailUrl: json['imageUrl'] as String?,
      artistUsername: creator?['username'] as String?,
      editionNumber: (json['editionNumber'] as num?)?.toInt(),
      playbackId: json['playbackId'] as String?,
      clipPlaybackId: json['clipPlaybackId'] as String?,
      nsfw: json['nsfw'] as bool?,
    );
  }
}

/// A collection/curation result from the search endpoint.
///
/// The backend returns
/// `{ name, imageUrl, creatorAddress, creator: { username, … }, slug, … }`.
@freezed
sealed class SearchCollectionItem with _$SearchCollectionItem {
  const factory SearchCollectionItem({
    required String name,
    String? thumbnailUrl,
    String? curatorUsername,
    String? curatorAddress,
    String? slug,
  }) = _SearchCollectionItem;

  factory SearchCollectionItem.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'] as Map<String, dynamic>?;
    return SearchCollectionItem(
      name: json['name'] as String? ?? '',
      thumbnailUrl: json['imageUrl'] as String?,
      curatorUsername: creator?['username'] as String?,
      // The creator address is a top-level field on the collection render.
      // `creator` is the rendered user, which carries `addresses` (plural) and
      // is only present when the creator has a mallow profile.
      curatorAddress: json['creatorAddress'] as String?,
      slug: json['slug'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// POST /v1/search/curations
// ---------------------------------------------------------------------------

/// Response from POST /v1/search/curations.
///
/// Plain Dart class (no freezed) to avoid a build_runner cycle for the
/// mallow_api package — only `fromJson` is needed.
class CurationSearchResponse {
  const CurationSearchResponse({this.curations = const []});

  final List<CurationSearchItem> curations;

  factory CurationSearchResponse.fromJson(Map<String, dynamic> json) {
    return CurationSearchResponse(
      curations:
          (json['curations'] as List<dynamic>?)
              ?.map((e) => CurationSearchItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// A single curation from POST /v1/search/curations.
class CurationSearchItem {
  const CurationSearchItem({
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

  factory CurationSearchItem.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'] as Map<String, dynamic>?;
    final user = owner?['user'] as Map<String, dynamic>?;
    return CurationSearchItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      artworkCount: json['artworkCount'] as int? ?? 0,
      thumbnailUrls:
          (json['thumbnailUrls'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      ownerAddress: owner?['address'] as String?,
      ownerUsername: user?['username'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// POST /v1/search/users
// ---------------------------------------------------------------------------

/// Response from POST /v1/search/users.
///
/// Plain Dart class (no freezed) for the same reason as [CurationSearchResponse]:
/// only `fromJson` is needed.
class UserSearchResponse {
  const UserSearchResponse({this.users = const []});

  final List<UserSearchItem> users;

  factory UserSearchResponse.fromJson(Map<String, dynamic> json) {
    return UserSearchResponse(
      users:
          (json['usersWithDetails'] as List<dynamic>?)
              ?.map((e) => UserSearchItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// A single user from POST /v1/search/users.
///
/// Wire shape is `{ user: { addresses, username, … }, userDetails: { … } }`;
/// only the `user` half is read.
///
/// Unlike [SearchUserItem] this keeps the whole `addresses` list. The backend's
/// `UserRenderer.renderSingle` emits **`addresses` (plural)** and nothing else —
/// a profile links a wallet per chain, often several — and the recipient search
/// has to pick the ones that match the chain being sent on. Reading a singular
/// `address` here would always yield null.
class UserSearchItem {
  const UserSearchItem({this.addresses = const [], this.username, this.displayName, this.imageUrl});

  final List<String> addresses;
  final String? username;
  final String? displayName;
  final String? imageUrl;

  factory UserSearchItem.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>? ?? json;
    return UserSearchItem(
      addresses:
          (user['addresses'] as List<dynamic>?)?.map((e) => e as String).toList() ?? const [],
      username: user['username'] as String?,
      displayName: user['displayName'] as String?,
      imageUrl: user['imageUrl'] as String?,
    );
  }
}
