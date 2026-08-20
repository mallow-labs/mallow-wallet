/// Data model for a user profile.
class UserProfile {
  const UserProfile({
    required this.address,
    required this.username,
    required this.handle,
    required this.role,
    required this.bio,
    required this.avatarUrl,
    required this.followerCount,
    required this.collectorCount,
    required this.ownedArtworkCount,
    this.followingCount = 0,
    this.roles = const [],
    this.displayName,
    this.createdArtworkCount = 0,
    this.collectedArtworkCount = 0,
    this.bannerUrl,
    this.isVerified = false,
    this.ownedArtworkThumbnailUrl,
    this.ownedArtworkThumbnailUrls = const [],
    this.twitterUrl,
    this.instagramUrl,
    this.websiteUrl,
    this.youtubeUrl,
    this.linkedAddresses = const [],
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    address: json['address'] as String,
    username: json['username'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String?,
    role: json['role'] as String,
    roles:
        (json['roles'] as List<dynamic>?)?.map((e) => e as String).toList() ??
        const [],
    bio: json['bio'] as String,
    avatarUrl: json['avatarUrl'] as String,
    followerCount: json['followerCount'] as int,
    followingCount: json['followingCount'] as int? ?? 0,
    collectorCount: json['collectorCount'] as int,
    ownedArtworkCount: json['ownedArtworkCount'] as int,
    createdArtworkCount: json['createdArtworkCount'] as int? ?? 0,
    collectedArtworkCount: json['collectedArtworkCount'] as int? ?? 0,
    bannerUrl: json['bannerUrl'] as String?,
    isVerified: json['isVerified'] as bool? ?? false,
    ownedArtworkThumbnailUrl: json['ownedArtworkThumbnailUrl'] as String?,
    ownedArtworkThumbnailUrls:
        (json['ownedArtworkThumbnailUrls'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        const [],
    twitterUrl: json['twitterUrl'] as String?,
    instagramUrl: json['instagramUrl'] as String?,
    websiteUrl: json['websiteUrl'] as String?,
    youtubeUrl: json['youtubeUrl'] as String?,
    linkedAddresses:
        (json['linkedAddresses'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        const [],
  );

  final String address;
  final String username;
  final String handle;

  /// Optional real-name display label from the backend. Preferred over
  /// [username] when rendering the prominent profile name; falls back to
  /// [username] (and then the truncated [address]) when absent.
  final String? displayName;
  final String role;
  final List<String> roles;
  final String bio;
  final String? bannerUrl;
  final String avatarUrl;
  final int followerCount;

  /// Number of profiles this user follows. Rendered next to [followerCount]
  /// in the profile header (webapp `CreatorMarketplaceDetails` parity).
  final int followingCount;

  /// Number of unique holders of the artworks this user has created.
  /// Sourced from `UserDetails.collectorsCount` on the API.
  final int collectorCount;
  final int ownedArtworkCount;

  /// Number of artworks the viewed user has created (mirrors `UserDetails.createdCount`).
  final int createdArtworkCount;

  /// Number of artworks the viewed user has collected (mirrors `UserDetails.collectedCount`).
  final int collectedArtworkCount;
  final bool isVerified;
  final String? ownedArtworkThumbnailUrl;

  /// Up to 4 thumbnail URLs for the 2x2 grid in the "You own" section.
  final List<String> ownedArtworkThumbnailUrls;
  final String? twitterUrl;
  final String? instagramUrl;
  final String? websiteUrl;
  final String? youtubeUrl;

  /// All wallet addresses linked to this user's profile.
  final List<String> linkedAddresses;

  /// Same profile with [followerCount] shifted by [delta], floored at zero.
  ///
  /// Follow/unfollow must move the number the user is looking at, not just the
  /// button label — the webapp (`useFollowUser`) adjusts `followerCount`
  /// optimistically and puts it back if the request fails, and a header that
  /// says "Following" over an unchanged count reads as a no-op.
  UserProfile withFollowerDelta(int delta) => UserProfile(
    address: address,
    username: username,
    handle: handle,
    role: role,
    bio: bio,
    avatarUrl: avatarUrl,
    followerCount: (followerCount + delta).clamp(0, 1 << 31),
    followingCount: followingCount,
    collectorCount: collectorCount,
    ownedArtworkCount: ownedArtworkCount,
    roles: roles,
    displayName: displayName,
    createdArtworkCount: createdArtworkCount,
    collectedArtworkCount: collectedArtworkCount,
    bannerUrl: bannerUrl,
    isVerified: isVerified,
    ownedArtworkThumbnailUrl: ownedArtworkThumbnailUrl,
    ownedArtworkThumbnailUrls: ownedArtworkThumbnailUrls,
    twitterUrl: twitterUrl,
    instagramUrl: instagramUrl,
    websiteUrl: websiteUrl,
    youtubeUrl: youtubeUrl,
    linkedAddresses: linkedAddresses,
  );

  Map<String, dynamic> toJson() => {
    'address': address,
    'username': username,
    'handle': handle,
    'displayName': displayName,
    'role': role,
    'roles': roles,
    'bio': bio,
    'avatarUrl': avatarUrl,
    'followerCount': followerCount,
    'followingCount': followingCount,
    'collectorCount': collectorCount,
    'ownedArtworkCount': ownedArtworkCount,
    'createdArtworkCount': createdArtworkCount,
    'collectedArtworkCount': collectedArtworkCount,
    'bannerUrl': bannerUrl,
    'isVerified': isVerified,
    'ownedArtworkThumbnailUrl': ownedArtworkThumbnailUrl,
    'ownedArtworkThumbnailUrls': ownedArtworkThumbnailUrls,
    'twitterUrl': twitterUrl,
    'instagramUrl': instagramUrl,
    'websiteUrl': websiteUrl,
    'youtubeUrl': youtubeUrl,
    'linkedAddresses': linkedAddresses,
  };
}
