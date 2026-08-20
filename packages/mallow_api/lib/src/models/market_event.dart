import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';
import 'artwork.dart' show ListingType;

part 'market_event.freezed.dart';
part 'market_event.g.dart';

/// Mode for the events query — selects which slice of an asset's history
/// the server returns. Mirrors `EventMode` in
/// `marketEvent`.
enum EventMode {
  @JsonValue('current-listing')
  currentListing,
  @JsonValue('provenance')
  provenance,
  @JsonValue('collection')
  collection,
  @JsonValue('all')
  all,
}

/// Discriminator for individual events within a [MarketActivityEvent.type] field.
/// Numeric encoding mirrors the webapp's `MarketEventType`.
enum MarketEventType {
  @JsonValue(-1)
  ignore,
  @JsonValue(0)
  list,
  @JsonValue(1)
  delist,
  @JsonValue(2)
  sale,
  @JsonValue(3)
  acceptBid,
  @JsonValue(4)
  updatePrice,
  @JsonValue(5)
  mint,
  @JsonValue(7)
  bid,
  @JsonValue(8)
  buyTicket,
  @JsonValue(9)
  claimProceeds,
  @JsonValue(10)
  claimPrize,
  @JsonValue(11)
  cancelBid,
  @JsonValue(12)
  edit,
  @JsonValue(13)
  gumballAdd,
  @JsonValue(14)
  gumballRemove,
  @JsonValue(15)
  gumballDraw,
  @JsonValue(16)
  gumballRequest,
  @JsonValue(17)
  initAirdrop,
  @JsonValue(18)
  jellybeanAdd,
  @JsonValue(19)
  jellybeanRemove,
  @JsonValue(20)
  jellybeanDraw,
  @JsonValue(21)
  candyMachineDraw,
}

/// Request body for `POST /v0/events/byMint/:mintAccount`.
@freezed
sealed class EventsByMintRequest with _$EventsByMintRequest {
  const factory EventsByMintRequest({
    @Default(0) int page,
    int? pageSize,
    @Default(EventMode.provenance) EventMode mode,
  }) = _EventsByMintRequest;

  factory EventsByMintRequest.fromJson(Map<String, dynamic> json) =>
      _$EventsByMintRequestFromJson(json);
}

/// Per-event extras the indexer writes alongside a marketplace entry
/// (`MarketplaceEntryMetadataSchema`, projected by `EventSelect` in
/// `marketplaceEntry`).
///
/// [editionNumber] is what lets a buy-now sale row name *which* print changed
/// hands. The entry is written against the print's own mint, so on a master
/// edition's provenance list every sale would otherwise read "collected" with
/// nothing distinguishing edition #2 from edition #200.
@freezed
sealed class MarketEventMetadata with _$MarketEventMetadata {
  const factory MarketEventMetadata({
    /// Mint of the master edition, when the event is about a print.
    String? parentEdition,

    /// Print number of the edition the event is about.
    int? editionNumber,
  }) = _MarketEventMetadata;

  factory MarketEventMetadata.fromJson(Map<String, dynamic> json) =>
      _$MarketEventMetadataFromJson(json);
}

/// One row of marketplace activity. The byMint endpoint renders
/// `MarketEventV1` (`marketEvent`): the
/// resolved profile (username, imageUrl) lives in the single `user` field,
/// while `buyer` / `seller` leak through from the raw DB doc as bare address
/// strings. Collection-scoped renders instead resolve `buyer` / `seller`
/// into full user objects, so all three fields are parsed leniently.
@freezed
sealed class MarketActivityEvent with _$MarketActivityEvent {
  const factory MarketActivityEvent({
    required String txId,
    required String mintAccount,
    required MarketEventType type,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? user,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? buyer,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? seller,
    double? price,
    String? currencyMint,
    int? quantity,
    DateTime? date,
    ListingType? listingType,
    double? usdPrice,
    String? source,
    String? chain,

    /// "Set your own price" listing: the buyer named the amount, so the
    /// recorded `price` is that one buyer's figure, not a price the seller
    /// asked. The webapp prints the word `SYOP` in place of the number on
    /// list/update/bid rows and suppresses the price block entirely on the
    /// resulting sale (`ProvenanceEvents 205-213`) — a SYOP amount
    /// rendered as a plain price reads as an asking price that never existed.
    bool? buyerSetsPrice,

    /// Indexer-written extras; see [MarketEventMetadata].
    MarketEventMetadata? metadata,
  }) = _MarketActivityEvent;

  factory MarketActivityEvent.fromJson(Map<String, dynamic> json) =>
      _$MarketActivityEventFromJson(json);
}

/// Paged response shape for `/v0/events/*` routes.
@freezed
sealed class MarketActivityEventsPage with _$MarketActivityEventsPage {
  const factory MarketActivityEventsPage({
    @Default([]) List<MarketActivityEvent> result,
    int? nextPage,
    int? total,
  }) = _MarketActivityEventsPage;

  factory MarketActivityEventsPage.fromJson(Map<String, dynamic> json) =>
      _$MarketActivityEventsPageFromJson(json);
}
