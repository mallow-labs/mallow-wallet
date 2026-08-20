import 'package:freezed_annotation/freezed_annotation.dart';

part 'market.freezed.dart';
part 'market.g.dart';

@freezed
sealed class GetBuyEditionTxsRequest with _$GetBuyEditionTxsRequest {
  const factory GetBuyEditionTxsRequest({
    required String masterEditionMintAccount,
    @Default(1) int quantity,
    @Default(false) bool payWithCream,

    /// Per-print price cap in the listing currency's atomic units. Omitted for
    /// fixed-price listings (the builder uses `listing.price`); **required** for
    /// a SYOP (`buyerSetsPrice`) listing, whose on-chain price is 0 — webapp
    /// `useBuyNow` sends the buyer's entered amount here for the same
    /// reason.
    int? maxPrice,
  }) = _GetBuyEditionTxsRequest;

  factory GetBuyEditionTxsRequest.fromJson(Map<String, dynamic> json) =>
      _$GetBuyEditionTxsRequestFromJson(json);
}

/// One element of the `getBuyEditionTxs` response array — the backend
/// returns one entry per edition being printed (`quantity` items).
@freezed
sealed class BuyEditionTx with _$BuyEditionTx {
  const factory BuyEditionTx({required String mintAccount, required String tx}) = _BuyEditionTx;

  factory BuyEditionTx.fromJson(Map<String, dynamic> json) => _$BuyEditionTxFromJson(json);
}

@freezed
sealed class GetBidTxRequest with _$GetBidTxRequest {
  const factory GetBidTxRequest({
    required String mintAccount,
    required int bidAmount,
    int? targetPriorityFeeLamports,
  }) = _GetBidTxRequest;

  factory GetBidTxRequest.fromJson(Map<String, dynamic> json) => _$GetBidTxRequestFromJson(json);
}

@freezed
sealed class BidTxResponse with _$BidTxResponse {
  const factory BidTxResponse({required String tx}) = _BidTxResponse;

  factory BidTxResponse.fromJson(Map<String, dynamic> json) => _$BidTxResponseFromJson(json);
}

// --- Phase 3: offer tx builders ---

/// Request body for `POST /v1/artwork/getMakeOfferTx`. Mirrors the webapp's
/// `useMakeOffer`. `price` is a raw on-chain integer scaled by
/// `currencyMint`'s decimals.
@freezed
sealed class GetMakeOfferTxRequest with _$GetMakeOfferTxRequest {
  const factory GetMakeOfferTxRequest({
    required String buyer,
    required String mint,
    required int price,
    required int targetPriorityFeeLamports,
    String? currencyMint,

    /// Unix seconds. 0 / null = no expiry.
    int? endTime,

    /// True for offers on 1/1s; false for collection / edition offers.
    @Default(true) bool oneOfOneOnly,
  }) = _GetMakeOfferTxRequest;

  factory GetMakeOfferTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetMakeOfferTxRequestFromJson(json);
}

@freezed
sealed class MakeOfferTxResponse with _$MakeOfferTxResponse {
  const factory MakeOfferTxResponse({required String tx}) = _MakeOfferTxResponse;

  factory MakeOfferTxResponse.fromJson(Map<String, dynamic> json) =>
      _$MakeOfferTxResponseFromJson(json);
}

@freezed
sealed class GetCancelOfferTxRequest with _$GetCancelOfferTxRequest {
  const factory GetCancelOfferTxRequest({
    required String buyer,
    required String mint,
    required int targetPriorityFeeLamports,
  }) = _GetCancelOfferTxRequest;

  factory GetCancelOfferTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetCancelOfferTxRequestFromJson(json);
}

@freezed
sealed class CancelOfferTxResponse with _$CancelOfferTxResponse {
  const factory CancelOfferTxResponse({required String tx}) = _CancelOfferTxResponse;

  factory CancelOfferTxResponse.fromJson(Map<String, dynamic> json) =>
      _$CancelOfferTxResponseFromJson(json);
}

// --- Phase 4: listing cancel + update tx builders ---

@freezed
sealed class GetCancelListingTxRequest with _$GetCancelListingTxRequest {
  const factory GetCancelListingTxRequest({
    required String seller,
    required String mint,
    required int targetPriorityFeeLamports,
  }) = _GetCancelListingTxRequest;

  factory GetCancelListingTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetCancelListingTxRequestFromJson(json);
}

@freezed
sealed class CancelListingTxResponse with _$CancelListingTxResponse {
  const factory CancelListingTxResponse({required String tx}) = _CancelListingTxResponse;

  factory CancelListingTxResponse.fromJson(Map<String, dynamic> json) =>
      _$CancelListingTxResponseFromJson(json);
}

/// Request body for `POST /v1/artwork/getUpdateListingTx`. The on-chain
/// `updateListing` ix is **price-only** — currency, end time, and
/// buyer-sets-price flags can't be mutated without delisting + relisting.
@freezed
sealed class GetUpdateListingTxRequest with _$GetUpdateListingTxRequest {
  const factory GetUpdateListingTxRequest({
    required String seller,
    required String mint,
    required int newPrice,
    required int targetPriorityFeeLamports,
  }) = _GetUpdateListingTxRequest;

  factory GetUpdateListingTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetUpdateListingTxRequestFromJson(json);
}

@freezed
sealed class UpdateListingTxResponse with _$UpdateListingTxResponse {
  const factory UpdateListingTxResponse({required String tx}) = _UpdateListingTxResponse;

  factory UpdateListingTxResponse.fromJson(Map<String, dynamic> json) =>
      _$UpdateListingTxResponseFromJson(json);
}

// --- Phase 5: auction cancel + settle tx builders ---
//
// The settle ix covers BOTH seller-payout AND winner-NFT-transfer in a
// single call — the wallet just calls `getSettleAuctionTx` with
// `caller = req.loginAddress` and the program does the right thing
// based on whether the caller is the seller or the high bidder. There's
// no separate winner-claim route. `cancelAuction` doubles as
// reclaim-no-bids (program permits it after `endsAt` when bidCount == 0).

@freezed
sealed class GetCancelAuctionTxRequest with _$GetCancelAuctionTxRequest {
  const factory GetCancelAuctionTxRequest({
    required String seller,
    required String mint,
    required int targetPriorityFeeLamports,
  }) = _GetCancelAuctionTxRequest;

  factory GetCancelAuctionTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetCancelAuctionTxRequestFromJson(json);
}

@freezed
sealed class CancelAuctionTxResponse with _$CancelAuctionTxResponse {
  const factory CancelAuctionTxResponse({required String tx}) = _CancelAuctionTxResponse;

  factory CancelAuctionTxResponse.fromJson(Map<String, dynamic> json) =>
      _$CancelAuctionTxResponseFromJson(json);
}

@freezed
sealed class GetSettleAuctionTxRequest with _$GetSettleAuctionTxRequest {
  const factory GetSettleAuctionTxRequest({
    required String caller,
    required String mint,
    required int targetPriorityFeeLamports,
  }) = _GetSettleAuctionTxRequest;

  factory GetSettleAuctionTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetSettleAuctionTxRequestFromJson(json);
}

@freezed
sealed class SettleAuctionTxResponse with _$SettleAuctionTxResponse {
  const factory SettleAuctionTxResponse({required String tx}) = _SettleAuctionTxResponse;

  factory SettleAuctionTxResponse.fromJson(Map<String, dynamic> json) =>
      _$SettleAuctionTxResponseFromJson(json);
}
