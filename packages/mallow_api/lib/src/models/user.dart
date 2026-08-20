import 'package:freezed_annotation/freezed_annotation.dart';

part 'user.freezed.dart';
part 'user.g.dart';

/// Blockchain address with chain information.
/// Used for linked addresses in user profiles.
@freezed
sealed class UserAddress with _$UserAddress {
  const factory UserAddress({required String address, required String chain}) = _UserAddress;

  factory UserAddress.fromJson(Map<String, dynamic> json) => _$UserAddressFromJson(json);
}

/// Social media link information.
@freezed
sealed class Social with _$Social {
  const factory Social({String? twitter, String? discord, String? instagram, String? website}) =
      _Social;

  factory Social.fromJson(Map<String, dynamic> json) => _$SocialFromJson(json);
}

/// Core user model returned by authentication.
///
/// Matches the actual mallow API /v0/login response structure.
@freezed
sealed class User with _$User {
  const User._();

  const factory User({
    /// All wallet addresses (simple strings)
    @Default([]) List<String> addresses,

    /// Username (handle)
    String? username,

    /// Display name
    String? displayName,

    /// Profile image URL
    String? imageUrl,

    /// Banner image URL
    String? bannerUrl,

    /// Tip/donation address
    String? tipAddress,

    /// Whether user is flagged
    @Default(false) bool isFlagged,

    /// Token mints listed by user
    @Default([]) List<String> listingTokenMints,

    /// Follower count
    @Default(0) int followerCount,

    /// Following count
    @Default(0) int followingCount,

    /// Posts count
    @Default(0) int postsCount,

    /// Post likes count
    @Default(0) int postLikesCount,

    /// Post comments count
    @Default(0) int postCommentsCount,

    /// Muted channels
    @Default([]) List<String> channelsMuted,

    /// Left channels
    @Default([]) List<String> channelsLeft,

    /// User roles (e.g., "artist", "collector")
    @Default([]) List<String> roles,

    /// Twitter verification status
    @Default(false) bool isTwitterVerified,

    /// User perks
    @Default([]) List<String> perks,

    /// Requested link addresses
    @Default([]) List<String> requestedLinkAddresses,

    /// NSFW content setting
    @Default(false) bool showNsfw,

    /// Whether NSFW setting toggle is disabled
    @Default(false) bool disableNsfwSetting,

    /// Disabled chains
    @Default([]) List<String> disabledChains,

    /// Pending wallet approvals
    @Default([]) List<dynamic> pendingWalletApprovals,
  }) = _User;

  /// Convenience getter for the primary wallet address.
  String? get primaryAddress => addresses.isNotEmpty ? addresses.first : null;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}

/// Extended user details for profile display.
///
/// Matches the actual mallow API /v0/login response structure.
@freezed
sealed class UserDetails with _$UserDetails {
  const factory UserDetails({
    /// Pinned artwork mint accounts
    @Default([]) List<String> pinnedMintAccounts,

    /// Number of likes given
    @Default(0) int likes,

    /// Number of pinned items
    @Default(0) int pinned,

    /// Number of created artworks
    @Default(0) int createdCount,

    /// Number of collected artworks
    @Default(0) int collectedCount,

    /// Number of unique holders of the artworks this user has created.
    @Default(0) int collectorsCount,

    /// Twitter social account
    SocialAccount? twitter,

    /// Discord social account
    SocialAccount? discord,

    /// Instagram social account
    SocialAccount? instagram,

    /// Website URL
    String? website,

    /// Bio text
    String? bio,

    /// Email address
    String? email,

    /// Marketing updates preference
    @Default(true) bool marketingUpdates,

    /// Email notifications disabled
    @Default(false) bool disableEmailNotifications,
  }) = _UserDetails;

  factory UserDetails.fromJson(Map<String, dynamic> json) => _$UserDetailsFromJson(json);
}

/// A single social media account (e.g., Twitter, Discord).
@freezed
sealed class SocialAccount with _$SocialAccount {
  const factory SocialAccount({String? username, String? userId, @Default(false) bool verified}) =
      _SocialAccount;

  factory SocialAccount.fromJson(Map<String, dynamic> json) => _$SocialAccountFromJson(json);
}

/// Public user preview returned by GET /v1/user/:address.
///
/// A subset of the full User model with basic profile info.
@freezed
sealed class UserPreview with _$UserPreview {
  const UserPreview._();

  const factory UserPreview({
    @Default([]) List<String> addresses,
    String? username,
    String? displayName,
    String? imageUrl,
    String? bannerUrl,
    SocialAccount? twitter,
    String? bio,
    String? website,
    @Default([]) List<String> roles,
  }) = _UserPreview;

  /// Convenience getter for the primary address.
  String? get primaryAddress => addresses.isNotEmpty ? addresses.first : null;

  factory UserPreview.fromJson(Map<String, dynamic> json) => _$UserPreviewFromJson(json);
}

/// Request body for POST /v0/userWithDetails.
@freezed
sealed class UserWithDetailsRequest with _$UserWithDetailsRequest {
  const factory UserWithDetailsRequest({required UserWithDetailsUser user}) =
      _UserWithDetailsRequest;

  factory UserWithDetailsRequest.fromJson(Map<String, dynamic> json) =>
      _$UserWithDetailsRequestFromJson(json);
}

/// User identifier for the userWithDetails request.
@freezed
sealed class UserWithDetailsUser with _$UserWithDetailsUser {
  const factory UserWithDetailsUser({List<String>? addresses, String? username}) =
      _UserWithDetailsUser;

  factory UserWithDetailsUser.fromJson(Map<String, dynamic> json) =>
      _$UserWithDetailsUserFromJson(json);
}

/// Response from POST /v0/userWithDetails.
@freezed
sealed class UserWithDetailsResult with _$UserWithDetailsResult {
  const factory UserWithDetailsResult({
    required User user,
    UserDetails? userDetails,
    @Default(false) bool isArtwork,
  }) = _UserWithDetailsResult;

  factory UserWithDetailsResult.fromJson(Map<String, dynamic> json) =>
      _$UserWithDetailsResultFromJson(json);
}

/// Follow list user (from POST /v1/followers and /v1/following).
@freezed
sealed class FollowUser with _$FollowUser {
  const factory FollowUser({
    @Default([]) List<String> addresses,
    String? username,
    String? imageUrl,
    @Default(0) int followerCount,
    @Default(false) bool isFollower,
    @Default(false) bool isFollowing,
  }) = _FollowUser;

  factory FollowUser.fromJson(Map<String, dynamic> json) => _$FollowUserFromJson(json);
}

/// Request body for POST /v0/follow and /v0/unfollow.
class FollowRequest {
  const FollowRequest({required this.address});

  final String address;

  Map<String, dynamic> toJson() => {'address': address};
}
