import 'package:freezed_annotation/freezed_annotation.dart';

part 'listing.freezed.dart';
part 'listing.g.dart';

/// Request payload for `POST /v1/artwork/getCreateAuctionTx`.
///
/// Mirrors `MallowAuction.CreateAuctionArgs` from the webapp's SDK so
/// the on-chain instruction the backend builds matches what the webapp would
/// have built client-side. All amount fields are raw on-chain integers.
@freezed
sealed class GetCreateAuctionTxRequest with _$GetCreateAuctionTxRequest {
  const factory GetCreateAuctionTxRequest({
    required String mint,
    required String seller,

    /// Reserve starting bid as a raw on-chain amount (already scaled by
    /// `bidMint`'s decimals, e.g. 0.01 SOL = 10_000_000).
    required int reservePrice,

    /// Auction duration in seconds.
    required int duration,

    /// Minimum bid increment. When [absoluteIncrement] is true this is a raw
    /// on-chain amount; otherwise it's basis points * 100 (e.g. 500 = 5%, 10
    /// = 0.1%).
    required int minBidIncrement,
    required bool absoluteIncrement,

    /// 0 = starts on first bid, -1 = immediate, >0 = scheduled unix seconds.
    @Default(0) int startTime,

    /// Time-extension period in seconds (window before end during which a bid
    /// extends the auction).
    @Default(900) int timeExtPeriod,

    /// How many seconds each in-window bid extends the auction by.
    @Default(900) int timeExtDelta,
    @Default(false) bool disablePrimarySplit,

    /// Bid currency mint. Null defaults to SOL on the backend.
    String? bidMint,

    /// Optional memo (e.g. `"rewards:<id>"` to attach off-chain rewards).
    String? memo,
    int? targetPriorityFeeLamports,
  }) = _GetCreateAuctionTxRequest;

  factory GetCreateAuctionTxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetCreateAuctionTxRequestFromJson(json);
}

/// Response from `POST /v1/artwork/getCreateAuctionTx` — base64-encoded
/// unsigned transaction the wallet must sign and broadcast.
@freezed
sealed class CreateAuctionTxResponse with _$CreateAuctionTxResponse {
  const factory CreateAuctionTxResponse({required String tx}) = _CreateAuctionTxResponse;

  factory CreateAuctionTxResponse.fromJson(Map<String, dynamic> json) =>
      _$CreateAuctionTxResponseFromJson(json);
}

/// Off-chain physical-artwork details persisted alongside a listing.
/// Mirrors `rewardsDescription`.
@freezed
sealed class PhysicalDetailsPayload with _$PhysicalDetailsPayload {
  const factory PhysicalDetailsPayload({
    required String description,
    String? imageUrl,
    int? unlockPrice,
  }) = _PhysicalDetailsPayload;

  factory PhysicalDetailsPayload.fromJson(Map<String, dynamic> json) =>
      _$PhysicalDetailsPayloadFromJson(json);
}

/// Request body for `POST /v0/rewardsDescription`.
@freezed
sealed class PostRewardsDescriptionRequest with _$PostRewardsDescriptionRequest {
  const factory PostRewardsDescriptionRequest({
    required RewardsDescriptionPayload rewardsDescription,
  }) = _PostRewardsDescriptionRequest;

  factory PostRewardsDescriptionRequest.fromJson(Map<String, dynamic> json) =>
      _$PostRewardsDescriptionRequestFromJson(json);
}

@freezed
sealed class RewardsDescriptionPayload with _$RewardsDescriptionPayload {
  const factory RewardsDescriptionPayload({
    String? rewardsDescription,
    @Default(false) bool includesPhysical,
    PhysicalDetailsPayload? physicalDetails,
    @Default(false) bool askForShippingAddress,
  }) = _RewardsDescriptionPayload;

  factory RewardsDescriptionPayload.fromJson(Map<String, dynamic> json) =>
      _$RewardsDescriptionPayloadFromJson(json);
}
