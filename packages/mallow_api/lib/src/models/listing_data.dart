import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';

part 'listing_data.freezed.dart';
part 'listing_data.g.dart';

/// Response of `GET /v0/listingData/{mint}`
/// (`listingData`).
///
/// The route also returns the full `nftPreview` render, but only the two
/// facts the listing-eligibility gate reads are modelled here — everything
/// else about the artwork already comes from `/v1/artwork/byMint`.
@freezed
sealed class ListingData with _$ListingData {
  const factory ListingData({
    ListingDataNftPreview? nftPreview,

    /// True when a sale (or prize claim) for this mint has already been
    /// indexed — the webapp's "secondary listing" signal. Server-side:
    /// `listingData`.
    @Default(false) bool hasVerifiedSale,
  }) = _ListingData;

  factory ListingData.fromJson(Map<String, dynamic> json) => _$ListingDataFromJson(json);
}

/// The slice of the `/v0/listingData` `nftPreview` the eligibility gate uses.
@freezed
sealed class ListingDataNftPreview with _$ListingDataNftPreview {
  const factory ListingDataNftPreview({
    /// mallow user for the artwork's `overrideCreator ?? updateAuth`.
    /// Absent when no mallow account owns that address.
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? creator,

    /// Moderation flag on the artwork itself.
    @Default(false) bool isFlagged,
  }) = _ListingDataNftPreview;

  factory ListingDataNftPreview.fromJson(Map<String, dynamic> json) =>
      _$ListingDataNftPreviewFromJson(json);
}
