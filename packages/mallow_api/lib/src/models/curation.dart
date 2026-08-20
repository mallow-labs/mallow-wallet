import 'package:freezed_annotation/freezed_annotation.dart';

import 'artwork.dart';

part 'curation.freezed.dart';
part 'curation.g.dart';

/// A single curation belonging to the authenticated user.
@freezed
sealed class CurationItem with _$CurationItem {
  const factory CurationItem({
    required String id,
    required String name,
    @Default(0) int artworkCount,
    @Default([]) List<String> thumbnailUrls,

    /// Visibility — `private` / `public` / `featured`. Private items are only
    /// returned for the authenticated owner with a valid signed-login session.
    @Default('public') String visibility,

    /// Whether this curation contains the artwork passed as `mintAccount`
    /// to GET /v1/curations. Always false when no mint was passed.
    @Default(false) bool containsArtwork,
  }) = _CurationItem;

  factory CurationItem.fromJson(Map<String, dynamic> json) => _$CurationItemFromJson(json);
}

/// Response from GET /v1/curations.
///
/// Returns `{ result: [...] }`.
@freezed
sealed class CurationListResponse with _$CurationListResponse {
  const factory CurationListResponse({required List<CurationItem> result}) = _CurationListResponse;

  factory CurationListResponse.fromJson(Map<String, dynamic> json) =>
      _$CurationListResponseFromJson(json);
}

/// Request body for POST /v1/curations.
@freezed
sealed class CreateCurationRequest with _$CreateCurationRequest {
  const factory CreateCurationRequest({required String name}) = _CreateCurationRequest;

  factory CreateCurationRequest.fromJson(Map<String, dynamic> json) =>
      _$CreateCurationRequestFromJson(json);
}

/// Request body for PATCH /v1/curations/:id. Omitted fields are left
/// unchanged. `visibility` is one of `private` / `public` / `featured`
/// (featured is admin-only).
@freezed
sealed class PatchCurationRequest with _$PatchCurationRequest {
  const factory PatchCurationRequest({
    @JsonKey(includeIfNull: false) String? name,
    @JsonKey(includeIfNull: false) String? visibility,
  }) = _PatchCurationRequest;

  factory PatchCurationRequest.fromJson(Map<String, dynamic> json) =>
      _$PatchCurationRequestFromJson(json);
}

/// Request body for POST /v1/curations/:id/artworks.
@freezed
sealed class AddArtworkToCurationRequest with _$AddArtworkToCurationRequest {
  const factory AddArtworkToCurationRequest({required String mintAccount}) =
      _AddArtworkToCurationRequest;

  factory AddArtworkToCurationRequest.fromJson(Map<String, dynamic> json) =>
      _$AddArtworkToCurationRequestFromJson(json);
}

/// Owner info on a [CurationDetail].
@freezed
sealed class CurationOwner with _$CurationOwner {
  const factory CurationOwner({
    required String address,
    String? username,
    String? displayName,
    String? imageUrl,
  }) = _CurationOwner;

  factory CurationOwner.fromJson(Map<String, dynamic> json) => _$CurationOwnerFromJson(json);
}

/// Response from GET /v1/curations/:id.
///
/// Backend gates private curations to the owner via signed-login; non-public
/// curations return 404 to anonymous and non-owner callers.
@freezed
sealed class CurationDetail with _$CurationDetail {
  const factory CurationDetail({
    required String id,
    required String name,
    required String slug,

    /// 8 uppercase letters, the token in `mallow.art/c/<SLUG>` share links.
    /// Null for curations created before the slug backfill ran.
    String? shareSlug,
    required String visibility,
    @Default(false) bool isPublic,
    required CurationOwner owner,
    @Default([]) List<NftPreview> artworks,
  }) = _CurationDetail;

  factory CurationDetail.fromJson(Map<String, dynamic> json) => _$CurationDetailFromJson(json);
}
