import 'package:freezed_annotation/freezed_annotation.dart';

import 'user.dart';

part 'login.freezed.dart';
part 'login.g.dart';

/// Content types for categorizing likes.
enum ContentType {
  @JsonValue('post')
  post,
  @JsonValue('broadcast')
  broadcast,
  @JsonValue('nft')
  nft,
  @JsonValue('collection')
  collection,
  @JsonValue('gumball')
  gumball,
  @JsonValue('comment')
  comment,
  @JsonValue('jellybean')
  jellybean,
  @JsonValue('store-product')
  storeProduct,
  @JsonValue('exhibition')
  exhibition,
  @JsonValue('user')
  user,
}

// LoginRequest has been replaced by the generated LoginBody from
// generated/openapi.models.swagger.dart. Use LoginBody for the
// Retrofit client request body.

/// Response from login endpoint containing user data and session info.
// Hand-rolled because the vendored spec models LoginUser / LoginUserDetails
// as empty objects (properties: {}). The generated LoginResult would drop all
// user fields on fromJson. Drop the hand-rolled model once the spec describes
// those objects properly.
@freezed
sealed class LoginResult with _$LoginResult {
  const factory LoginResult({
    /// The authenticated user
    required User user,

    /// Extended user details
    UserDetails? userDetails,

    /// Likes organized by content type (mint addresses)
    @Default({}) Map<ContentType, List<String>> likesByContentType,

    /// List of addresses the user is following
    @Default([]) List<String> following,

    /// Session expiration timestamp (ISO 8601)
    String? expiresAt,

    /// Number of gumball invites available
    @Default(0) int invitedGumballCount,
  }) = _LoginResult;

  factory LoginResult.fromJson(Map<String, dynamic> json) => _$LoginResultFromJson(json);
}
