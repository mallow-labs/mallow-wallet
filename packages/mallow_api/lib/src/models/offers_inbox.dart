import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';

part 'offers_inbox.freezed.dart';
part 'offers_inbox.g.dart';

/// Whether an inbox item is a marketplace offer or an auction bid. Drives the
/// row verb ("made an offer" vs "placed a bid").
enum OffersInboxKind {
  @JsonValue('offer')
  offer,
  @JsonValue('bid')
  bid,
}

/// Whether the item was received (an offer on / bid against the viewer's own
/// art) or placed (the viewer's own offer / bid on someone else's work).
enum OffersInboxDirection {
  @JsonValue('received')
  received,
  @JsonValue('placed')
  placed,
}

/// Live/complete state of an auction attached to a bid item. `complete` means
/// the auction ended but is still unsettled (settled auctions drop out of the
/// feed entirely) — the card shows "Auction complete" and hides "Bid again".
enum AuctionStatus {
  @JsonValue('live')
  live,
  @JsonValue('complete')
  complete,
}

/// Sort order for `POST /v2/offers/inbox`. `amount` sorts by the normalized
/// `usdValue` server-side (raw atomic units aren't comparable across
/// SOL/ETH/USDC).
enum OffersInboxSort {
  @JsonValue('latest')
  latest,
  @JsonValue('oldest')
  oldest,
  @JsonValue('amount')
  amount,
}

/// Request body for `POST /v2/offers/inbox`. [owners] is every wallet address
/// in the session, so the feed aggregates received + placed across all of them.
@freezed
sealed class GetOffersInboxRequest with _$GetOffersInboxRequest {
  const factory GetOffersInboxRequest({
    required List<String> owners,
    @Default(OffersInboxSort.latest) OffersInboxSort sort,
    @Default(0) int page,
    @JsonKey(includeIfNull: false) int? pageSize,
  }) = _GetOffersInboxRequest;

  factory GetOffersInboxRequest.fromJson(Map<String, dynamic> json) =>
      _$GetOffersInboxRequestFromJson(json);
}

/// One row in the `/v2/offers/inbox` feed: a single active offer or bid the
/// session is involved in, carrying enough artwork + actor context to render
/// and act without a follow-up fetch.
@freezed
sealed class OffersInboxItem with _$OffersInboxItem {
  const factory OffersInboxItem({
    required OffersInboxKind kind,
    required OffersInboxDirection direction,

    /// Artwork mint — groups consecutive rows under one header and deep-links.
    required String asset,
    required String artworkTitle,
    String? artworkImageUrl,

    /// Sensitive-content flag for the artwork. The card renders its thumbnail,
    /// so it has to blur behind the viewer's show-NSFW setting exactly as the
    /// artwork grids do. Absent (→ false) when the mint isn't indexed, or when
    /// talking to a backend deployed before the field existed.
    @Default(false) bool nsfw,
    int? editionNumber,
    String? creatorUsername,

    /// Who made the offer / placed the bid (counterparty for received, the
    /// viewer's own wallet for placed). Drives the avatar + profile link.
    required String actorAddress,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? actor,

    /// The session wallet (from the request `owners`) that makes this item
    /// received (art owner/seller) or placed (buyer/bidder) — the wallet the
    /// app re-points the signer to before accepting / cancelling.
    required String viewerAddress,

    /// RAW atomic units in [currencyMint]. Tolerates a JSON string (int64-safe
    /// wire) or number; format via `PriceFormatter.formatRawAmountWithSymbol`.
    @JsonKey(fromJson: _rawAmountFromJson) required double rawAmount,
    required String currencyMint,

    /// Normalized USD value used for `amount` sort. Null when the backend has
    /// no price basis for the currency.
    double? usdValue,
    DateTime? date,
    DateTime? endTime,
    String? txId,

    /// Present only for auction bids (`kind == bid`). The grouped per-auction
    /// bid breakdown the auction-bid card renders. Null for offers.
    AuctionInfo? auction,
  }) = _OffersInboxItem;

  factory OffersInboxItem.fromJson(Map<String, dynamic> json) => _$OffersInboxItemFromJson(json);
}

/// Grouped per-auction bid data attached to a `kind == bid` inbox item
/// (`auction` on [OffersInboxItem]). Drives the auction-bid card: Received
/// shows [recentBids] (last 3, newest first); Placed shows [yourBid] plus, when
/// outbid, [highestBid]. [isHighestBidder] flips the badge to "You are the
/// highest bidder" and hides "Bid again"; [status] flips the label to
/// "Auction complete" and also hides "Bid again". Wire shape: the backend's
/// own `AuctionInfo` on the offers-inbox read.
@freezed
sealed class AuctionInfo with _$AuctionInfo {
  const factory AuctionInfo({
    required AuctionStatus status,

    /// Always `false` in this feed (settled auctions are dropped from the
    /// index); kept as an explicit field so the contract is forward-compatible.
    @Default(false) bool settled,
    DateTime? endTime,

    /// The auction seller. A [recentBids] entry whose bidder matches this is
    /// the listing event (the indexer records it as a bid by the seller) —
    /// rendered as "listed" instead of "made a bid".
    String? sellerAddress,

    /// Placed cards only: the viewer currently holds the high bid. Always
    /// `false` for received cards.
    @Default(false) bool isHighestBidder,

    /// The current highest bid on the auction, or null when there are no bids.
    AuctionBidRef? highestBid,

    /// Placed cards only: the viewer's own most-recent bid. Null for received.
    AuctionBidRef? yourBid,

    /// Up to the last 3 bid events, newest first (both directions). Received
    /// cards render them directly; placed cards use them to find the bid the
    /// viewer outbid when they hold the high bid.
    @Default([]) List<AuctionBidRef> recentBids,
  }) = _AuctionInfo;

  factory AuctionInfo.fromJson(Map<String, dynamic> json) => _$AuctionInfoFromJson(json);
}

/// A single bid within [AuctionInfo] — bidder + amount + date.
@freezed
sealed class AuctionBidRef with _$AuctionBidRef {
  const factory AuctionBidRef({
    required String bidderAddress,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? bidder,

    /// RAW atomic units in [currencyMint]; tolerates a JSON string (int64-safe
    /// wire) or number. Format via `PriceFormatter.formatRawAmountWithSymbol`.
    @JsonKey(fromJson: _rawAmountFromJson) required double rawAmount,
    required String currencyMint,
    double? usdValue,
    DateTime? date,
    String? txId,
  }) = _AuctionBidRef;

  factory AuctionBidRef.fromJson(Map<String, dynamic> json) => _$AuctionBidRefFromJson(json);
}

/// Paged response shape for `/v2/offers/inbox`.
@freezed
sealed class OffersInboxPage with _$OffersInboxPage {
  const factory OffersInboxPage({
    @Default([]) List<OffersInboxItem> result,
    int? nextPage,
    int? total,

    /// How many offers the backend withheld from [result] because they came
    /// from an account the viewer has blocked.
    ///
    /// Blocked offers are filtered **with disclosure, never silently** — the
    /// client renders an expandable "N offers hidden from blocked accounts"
    /// row. Hiding money silently is how someone misses the highest bid on
    /// their own artwork.
    ///
    /// Defaults to 0 so a backend that predates the block filter (or a cached
    /// response) degrades to "nothing hidden" rather than throwing.
    @Default(0) int hiddenByBlockCount,
  }) = _OffersInboxPage;

  factory OffersInboxPage.fromJson(Map<String, dynamic> json) => _$OffersInboxPageFromJson(json);
}

/// Parse a raw atomic amount sent as either a JSON string (int64-safe) or a
/// number. Returns 0 for an unparseable/absent value rather than throwing — a
/// bad amount shouldn't drop the whole row.
double _rawAmountFromJson(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
