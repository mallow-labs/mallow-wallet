import 'dart:convert';

import '../../portfolio/services/portfolio_bloc.dart';
import 'user_profile.dart';

/// Serialization wrapper for caching full profile data in Drift.
///
/// Keeps JSON serialization isolated — no changes needed to shared model
/// classes (PortfolioArtwork, ArtGroup).
class CachedProfileData {
  const CachedProfileData({
    required this.profile,
    required this.artworks,
    required this.groups,
    required this.youOwnArtworks,
    this.ownedArtworks = const [],
  });

  factory CachedProfileData.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return CachedProfileData(
      profile: UserProfile.fromJson(json['profile'] as Map<String, dynamic>),
      artworks: (json['artworks'] as List<dynamic>)
          .map((e) => _artworkFromJson(e as Map<String, dynamic>))
          .toList(),
      groups: (json['groups'] as List<dynamic>)
          .map((e) => _groupFromJson(e as Map<String, dynamic>))
          .toList(),
      youOwnArtworks: (json['youOwnArtworks'] as List<dynamic>)
          .map((e) => _artworkFromJson(e as Map<String, dynamic>))
          .toList(),
      ownedArtworks:
          (json['ownedArtworks'] as List<dynamic>?)
              ?.map((e) => _artworkFromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  final UserProfile profile;
  final List<PortfolioArtwork> artworks;
  final List<ArtGroup> groups;
  final List<PortfolioArtwork> youOwnArtworks;
  final List<PortfolioArtwork> ownedArtworks;

  String toJsonString() => jsonEncode({
    'profile': profile.toJson(),
    'artworks': artworks.map(_artworkToJson).toList(),
    'groups': groups.map(_groupToJson).toList(),
    'youOwnArtworks': youOwnArtworks.map(_artworkToJson).toList(),
    'ownedArtworks': ownedArtworks.map(_artworkToJson).toList(),
  });

  static Map<String, dynamic> _artworkToJson(PortfolioArtwork a) => {
    'mintAccount': a.mintAccount,
    'title': a.title,
    'imageUrl': a.imageUrl,
    'artistName': a.artistName,
    'collectionName': a.collectionName,
    'lastPrice': a.lastPrice,
    'aspectRatio': a.aspectRatio,
    'updateAuth': a.updateAuth,
    'playbackId': a.playbackId,
    'clipPlaybackId': a.clipPlaybackId,
    'nsfw': a.nsfw,
  };

  static PortfolioArtwork _artworkFromJson(Map<String, dynamic> json) =>
      PortfolioArtwork(
        mintAccount: json['mintAccount'] as String,
        title: json['title'] as String,
        imageUrl: json['imageUrl'] as String,
        artistName: json['artistName'] as String,
        collectionName: json['collectionName'] as String?,
        lastPrice: (json['lastPrice'] as num?)?.toDouble(),
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
        updateAuth: json['updateAuth'] as String?,
        playbackId: json['playbackId'] as String?,
        clipPlaybackId: json['clipPlaybackId'] as String?,
        nsfw: json['nsfw'] as bool? ?? false,
      );

  static Map<String, dynamic> _groupToJson(ArtGroup g) => {
    'id': g.id,
    'type': g.type.name,
    'name': g.name,
    'thumbnailUrl': g.thumbnailUrl,
    'artworkCount': g.artworkCount,
    'artistAddress': g.artistAddress,
    'collectionMint': g.collectionMint,
    'creatorName': g.creatorName,
  };

  static ArtGroup _groupFromJson(Map<String, dynamic> json) => ArtGroup(
    id: json['id'] as String,
    type: ArtGroupType.values.byName(json['type'] as String),
    name: json['name'] as String,
    thumbnailUrl: json['thumbnailUrl'] as String?,
    artworkCount: json['artworkCount'] as int,
    artistAddress: json['artistAddress'] as String?,
    collectionMint: json['collectionMint'] as String?,
    creatorName: json['creatorName'] as String?,
  );
}
