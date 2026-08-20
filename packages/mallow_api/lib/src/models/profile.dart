import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

/// Tab options for the POST /v1/profile endpoint.
enum ApiProfileTab {
  @JsonValue('pinned')
  pinned,
  @JsonValue('bidding-on')
  biddingOn,
  @JsonValue('offers')
  offers,
  @JsonValue('listed')
  listed,
  @JsonValue('created')
  created,
  @JsonValue('collections')
  collections,
  @JsonValue('collected')
  collected,
  @JsonValue('talk-board-posts')
  talkBoardPosts,
  @JsonValue('activity')
  activity,
  @JsonValue('liked')
  liked,
}

/// Sort options for profile/explore endpoints.
enum ExploreSort {
  @JsonValue('recently-listed')
  recentlyListed,
  @JsonValue('recently-sold')
  recentlySold,
  @JsonValue('trending')
  trending,
  @JsonValue('ending-soon')
  endingSoon,
  @JsonValue('most-liked')
  mostLiked,
  @JsonValue('most-liked-24h')
  mostLiked24H,
  @JsonValue('alphabetical')
  alphabetical,
  @JsonValue('lowest-price')
  lowestPrice,
  @JsonValue('recent-activity')
  recentActivity,
}

/// Mode/type filter for explore.
enum ExploreMode {
  @JsonValue('all')
  all,
  @JsonValue('1/1')
  oneOfOne,
  @JsonValue('editions')
  editions,
  @JsonValue('collection')
  collection,
  @JsonValue('following')
  following,
  @JsonValue('gumballs')
  gumballs,
}

/// Filter options for explore/profile results.
@freezed
sealed class ExploreFilter with _$ExploreFilter {
  const factory ExploreFilter({
    @Default(ExploreMode.all) ExploreMode mode,
    @Default([]) List<String> listingTypes,
    PriceRange? priceRange,
    @Default([]) List<String> artists,
    @Default([]) List<String> collections,
    String? search,
    @Default([]) List<String> mediaTypes,
    @Default(false) bool hidePrints,
    @Default([]) List<String> tags,
  }) = _ExploreFilter;

  factory ExploreFilter.fromJson(Map<String, dynamic> json) => _$ExploreFilterFromJson(json);
}

/// Price range filter.
@freezed
sealed class PriceRange with _$PriceRange {
  const factory PriceRange({double? min, double? max}) = _PriceRange;

  factory PriceRange.fromJson(Map<String, dynamic> json) => _$PriceRangeFromJson(json);
}

/// Request body for POST /v1/profile.
@freezed
sealed class ProfileRequest with _$ProfileRequest {
  const factory ProfileRequest({
    @Default(0) int page,
    required ApiProfileTab tab,
    @Default(ExploreSort.recentlyListed) ExploreSort sort,
    ExploreFilter? filter,
    required List<String> profileUserAddresses,
    int? pageSize,
  }) = _ProfileRequest;

  factory ProfileRequest.fromJson(Map<String, dynamic> json) => _$ProfileRequestFromJson(json);
}

/// Response from POST /v1/profile.
///
/// The `result` field contains items whose type depends on the tab:
/// - Artwork tabs → NftPreviewRender
/// - Collections tab → CollectionRender
/// Parse appropriately in the repository layer.
@JsonSerializable()
class ProfileResponse {
  const ProfileResponse({this.result = const [], this.total = 0, this.nextPage});

  final List<Map<String, dynamic>> result;
  final int total;
  final int? nextPage;

  factory ProfileResponse.fromJson(Map<String, dynamic> json) => _$ProfileResponseFromJson(json);

  Map<String, dynamic> toJson() => _$ProfileResponseToJson(this);
}

/// Request body for POST /v1/followers and /v1/following.
@freezed
sealed class FollowListRequest with _$FollowListRequest {
  const factory FollowListRequest({
    @Default(0) int page,
    required List<String> profileUserAddresses,
  }) = _FollowListRequest;

  factory FollowListRequest.fromJson(Map<String, dynamic> json) =>
      _$FollowListRequestFromJson(json);
}

/// Response from POST /v1/followers and /v1/following.
@JsonSerializable()
class FollowListResponse {
  const FollowListResponse({this.result = const [], this.total = 0, this.nextPage});

  final List<Map<String, dynamic>> result;
  final int total;
  final int? nextPage;

  factory FollowListResponse.fromJson(Map<String, dynamic> json) =>
      _$FollowListResponseFromJson(json);

  Map<String, dynamic> toJson() => _$FollowListResponseToJson(this);
}
