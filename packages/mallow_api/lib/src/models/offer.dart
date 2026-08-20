import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';

part 'offer.freezed.dart';
part 'offer.g.dart';

/// Sort order for `POST /v1/offers`. Mirrors the webapp's `OfferSort`.
enum OfferSort {
  @JsonValue('highest-offer')
  highestOffer,
  @JsonValue('latest')
  latest,
}

/// Type discriminator on an [OfferRender]. Mirrors `OfferType` in
/// `offer`.
enum OfferType {
  @JsonValue(0)
  nft,
  @JsonValue(1)
  collection,
  @JsonValue(2)
  editions,
}

/// Filter for `POST /v1/offers`. Combine [buyer] + [nftMint] +
/// `activeOnly: true` to detect whether a connected wallet already has a
/// live offer on a given mint (the `userOwnOffer` signal documented in
/// `docs/artwork_state.md`).
//
// Per-field `includeIfNull: false` — backend zod schema accepts missing
// keys but rejects explicit `null`.
@freezed
sealed class OfferFilter with _$OfferFilter {
  const factory OfferFilter({
    @JsonKey(includeIfNull: false) String? buyer,
    @JsonKey(includeIfNull: false) String? nftMint,
    @JsonKey(includeIfNull: false) String? collectionMint,
    @JsonKey(includeIfNull: false) bool? oneOfOneOnly,
    @JsonKey(includeIfNull: false) bool? activeOnly,
  }) = _OfferFilter;

  factory OfferFilter.fromJson(Map<String, dynamic> json) => _$OfferFilterFromJson(json);
}

/// Request body for `POST /v1/offers`.
@freezed
sealed class GetOffersRequest with _$GetOffersRequest {
  const factory GetOffersRequest({
    @Default(0) int page,
    @Default(OfferSort.latest) OfferSort sort,
    @JsonKey(includeIfNull: false) OfferFilter? filter,
    @JsonKey(includeIfNull: false) int? pageSize,
  }) = _GetOffersRequest;

  factory GetOffersRequest.fromJson(Map<String, dynamic> json) => _$GetOffersRequestFromJson(json);
}

/// One row in the `/v1/offers` response. Mirrors `OfferWithNftRender` from
/// `offer`. Stripped to the fields that
/// matter for the Flutter wallet's user-own-offer / list-of-offers reads;
/// add more here as new sheets need them.
@freezed
sealed class OfferRender with _$OfferRender {
  const factory OfferRender({
    required OfferType offerType,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? buyer,
    required String buyerAddress,
    required String asset,
    required String currencyMint,
    required double price,
    DateTime? endTime,
    @Default(false) bool oneOfOneOnly,
    DateTime? date,
    String? txId,
  }) = _OfferRender;

  factory OfferRender.fromJson(Map<String, dynamic> json) => _$OfferRenderFromJson(json);
}

/// Paged response shape for `/v1/offers` and friends.
@freezed
sealed class OffersPage with _$OffersPage {
  const factory OffersPage({@Default([]) List<OfferRender> result, int? nextPage, int? total}) =
      _OffersPage;

  factory OffersPage.fromJson(Map<String, dynamic> json) => _$OffersPageFromJson(json);
}
