import 'package:freezed_annotation/freezed_annotation.dart';

import 'api_user_ref.dart';
import 'listing.dart';
import 'unlockable_content.dart';

part 'artwork.freezed.dart';
part 'artwork.g.dart';

/// Handles `highestOffer` being either a scalar amount or an offer object
/// of shape `{ price, currencyMint, buyer, ... }`.
double? _highestOfferFromJson(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is Map<String, dynamic>) {
    final price = value['price'];
    if (price is num) return price.toDouble();
  }
  return null;
}

/// Server-derived lifecycle state for an NFT's listing. Authoritative
/// alternative to the client's `startsAt`/`endsAt` time comparisons.
/// Backend enum: ships on `NftPreviewRender` and public `Artwork`.
enum ListingState {
  /// Fallback for any present-but-unrecognized server value. This is a
  /// server-owned vocabulary expected to grow: without the
  /// `@JsonKey(unknownEnumValue: ...)` on each `listingState` field an
  /// unknown value would throw `ArgumentError` and abort the whole
  /// artwork parse (`NftPreview`/`NftDetail.fromJson`). Treated as "no
  /// authoritative state" — `_auctionEnded` falls through to the `endsAt`
  /// time comparison, same as `none`/null.
  unknown,
  @JsonValue('none')
  none,
  @JsonValue('pending')
  pending,
  @JsonValue('active')
  active,
  @JsonValue('ended')
  ended,
}

/// Which marketplace the artwork's listing / most recent sale came from.
///
/// Wire field: `lastSource` on the nft render — a nullable string column
/// server-side, typed `NftPreviewRender.lastSource?: Maybe<MarketSource>` and
/// selected by `/v1/artwork/byMint`. Values mirror the server's own
/// `marketSource` enum.
enum MarketSource {
  @JsonValue('mallow')
  mallow,
  @JsonValue('magic-eden')
  magicEden,
  @JsonValue('exchange-art')
  exchangeArt,
  @JsonValue('formfunction')
  formfunction,
  @JsonValue('objkt')
  objkt,
  @JsonValue('opensea')
  opensea,

  /// Both a real wire value and the forward-compat fallback for any
  /// present-but-unrecognized source (paired with
  /// `@JsonKey(unknownEnumValue: MarketSource.unknown)`, same pattern as
  /// [ListingState.unknown]) — without it a newly-added marketplace would
  /// throw `ArgumentError` and abort the whole artwork parse.
  @JsonValue('unknown')
  unknown,
}

extension MarketSourceX on MarketSource? {
  /// True when the listing lives on a marketplace whose program mallow's tx
  /// builders cannot drive — every buy / bid / update-listing / cancel-listing
  /// / claim builder targets `mallow_market`, `mallow-auction` or `rafffle`.
  ///
  /// Null and [MarketSource.unknown] both mean "mallow", matching the webapp's
  /// null-defaulting (`UpdateListingModal`:
  /// `nftRender.lastSource ?? MarketSource.mallow`). The field is sparsely
  /// populated, so defaulting the other way would suppress every legitimate
  /// CTA. The webapp refuses foreign sources at
  /// `useCancelListing` ("Unsupported market source").
  bool get isForeignMarketplace =>
      this != null && this != MarketSource.mallow && this != MarketSource.unknown;
}

/// Listing type for an NFT on the marketplace.
enum ListingType {
  @JsonValue('unlisted')
  unlisted,
  @JsonValue('buy-now')
  buyNow,
  @JsonValue('auction')
  auction,
  @JsonValue('raffle')
  raffle,
  @JsonValue('store')
  store,
  @JsonValue('gumball')
  gumball,
  @JsonValue('airdrop')
  airdrop,
  @JsonValue('jellybean')
  jellybean,
}

/// On-chain asset metadata (mime type, dimensions, file size) returned
/// alongside the NFT detail. Matches the webapp's shared `AssetMetadata`
/// shape.
@freezed
sealed class AssetMetadata with _$AssetMetadata {
  const factory AssetMetadata({
    int? fileSize,
    String? mimeType,
    int? width,
    int? height,
    double? aspectRatio,
    int? duration,
  }) = _AssetMetadata;

  factory AssetMetadata.fromJson(Map<String, dynamic> json) => _$AssetMetadataFromJson(json);
}

/// Coerce a Metaplex attribute field to a String. The metadata standard
/// leaves `attributes[]` free-form and the API mirrors the off-chain JSON
/// verbatim, so generative collections routinely send numbers (`"value": 6`)
/// or bools. A raw cast throws inside `NftDetail.fromJson`, which aborts the
/// ENTIRE artwork parse — one numeric trait blanks the whole detail screen.
String? _attributeStringFromAny(Object? value) => value?.toString();

/// [_attributeStringFromAny] for the non-nullable `trait_type`, which a
/// collection may also omit entirely — absent becomes `''` rather than a
/// null-cast throw.
String _traitTypeFromAny(Object? value) => _attributeStringFromAny(value) ?? '';

/// A single trait/attribute on an NFT.
@freezed
sealed class NftAttribute with _$NftAttribute {
  const factory NftAttribute({
    @JsonKey(name: 'trait_type', fromJson: _traitTypeFromAny) required String traitType,
    @JsonKey(fromJson: _attributeStringFromAny) String? value,
  }) = _NftAttribute;

  factory NftAttribute.fromJson(Map<String, dynamic> json) => _$NftAttributeFromJson(json);
}

/// Royalty split for an NFT.
///
/// The API returns `{ user: { address, username, displayName, ... }, bps }`
/// where `bps` is basis points. We flatten the embedded user fields onto
/// this model so callers don't have to walk through a nested object.
@freezed
sealed class Royalty with _$Royalty {
  const Royalty._();

  const factory Royalty({
    String? address,
    String? username,
    String? displayName,
    @Default(0) int bps,
  }) = _Royalty;

  factory Royalty.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    final userMap = user is Map<String, dynamic> ? user : null;
    return Royalty(
      address: userMap?['address'] as String?,
      username: userMap?['username'] as String?,
      displayName: userMap?['displayName'] as String?,
      bps: (json['bps'] as num?)?.toInt() ?? 0,
    );
  }

  /// Round-trip the wire shape (`{ user: {...}, bps }`). Hand-written so
  /// `NftDetail.toJson` can serialize a list of [Royalty]; we don't rely
  /// on this for outbound requests, but freezed/json_serializable still
  /// needs a callable `toJson` on the type.
  Map<String, dynamic> toJson() => {
    'user': {
      if (address != null) 'address': address,
      if (username != null) 'username': username,
      if (displayName != null) 'displayName': displayName,
    },
    'bps': bps,
  };
}

/// Last sale information for an NFT.
@freezed
sealed class LastSale with _$LastSale {
  const factory LastSale({
    double? price,
    DateTime? date,
    String? txId,
    double? usdPrice,
    String? currencyMint,
  }) = _LastSale;

  factory LastSale.fromJson(Map<String, dynamic> json) => _$LastSaleFromJson(json);
}

/// Metadata for a buy-now listing.
@freezed
sealed class BuyNowMetadata with _$BuyNowMetadata {
  const factory BuyNowMetadata({
    double? amount,
    String? currencyMint,
    String? listingAccount,
    DateTime? date,
    DateTime? startsAt,
    @Default(false) bool buyerSetsPrice,
    @Default(0) int editionsLimit,
    @Default(1) int quantity,
    @Default(1) int quantityLeft,
    DateTime? endsAt,
  }) = _BuyNowMetadata;

  factory BuyNowMetadata.fromJson(Map<String, dynamic> json) => _$BuyNowMetadataFromJson(json);
}

/// Metadata for an auction listing.
@freezed
sealed class AuctionMetadata with _$AuctionMetadata {
  const factory AuctionMetadata({
    double? reservePrice,
    double? currentBidAmount,

    /// Address of the wallet that placed the highest bid. Null when no bids
    /// have landed yet. Mirrors webapp `BaseAuctionMetadata.currentBidder`.
    String? currentBidder,

    /// Recent bidders for the bid-history strip. Index 0 is the most recent.
    @Default([]) List<String> bidders,

    /// Profile-picture URLs paired by index with [bidders]. May contain nulls
    /// where a bidder has no avatar set.
    @Default([]) List<String?> bidderPfps,

    /// Absolute min-bid increment in raw amount (alternative to bps).
    int? minBidIncrement,
    int? minBidIncrementBps,
    @Default(0) int bidCount,
    String? bidMint,
    String? auctionAccount,
    String? seller,
    int? duration,
    int? timeExtPeriod,
    int? timeExtDelta,
    String? mintAccount,
    DateTime? startsAt,
    DateTime? endsAt,
  }) = _AuctionMetadata;

  factory AuctionMetadata.fromJson(Map<String, dynamic> json) => _$AuctionMetadataFromJson(json);
}

/// Server-derived user-aware raffle state. Populated by the backend when the
/// request carries `requestorAddresses`; degrades to safe no-user defaults
/// (all false) for anonymous/cached calls.
/// Backend type: the shared `RaffleState` enum.
///
/// Only the role flags below are consumed today (see
/// `artwork_action_state.dart`). The backend also ships ticket-limit,
/// claim/cancel-eligibility, and ticket-count fields (`canBuyTicket`,
/// `isNftClaimable`, `isProceedsClaimable`, `canCancel`, `userTickets`,
/// `winnerTickets`, `walletLimit`); they were dropped here rather
/// than parsed-but-ignored, to avoid implying coverage the client doesn't
/// have. Re-add them alongside the gating logic when the raffle flow is
/// productionized — note they default to `false`/null on cached/anonymous
/// responses, so any consumer must treat null as "fall back to client
/// derivation", exactly as the role flags do.
@freezed
sealed class RaffleUserState with _$RaffleUserState {
  const factory RaffleUserState({
    /// True when the requesting wallet is the raffle creator/owner.
    bool? isUserOwner,

    /// True when the requesting wallet is the drawn winner.
    bool? isUserWinner,
  }) = _RaffleUserState;

  factory RaffleUserState.fromJson(Map<String, dynamic> json) => _$RaffleUserStateFromJson(json);
}

/// Metadata for a raffle listing. Backend type: `RaffleMetadata` in
/// `nft`. The "Created" suffix in the
/// webapp split is collapsed here — raffle-pre-creation fields and
/// raffle-after-draw fields all live in one model with optional types.
@freezed
sealed class RaffleMetadata with _$RaffleMetadata {
  const factory RaffleMetadata({
    required String mintAccount,
    required String creator,
    required String raffleAccount,
    required String entrantsAccount,
    bool? isInitialized,

    /// Lifecycle: when the sale window closes. `endsAt < now` + no winner =
    /// awaiting draw.
    DateTime? endsAt,

    /// Ticket price in **raw base units** of [currencyMint] (lamports for SOL),
    /// NOT display units — the column is a `BigInt` server-side and the
    /// renderer passes it straight through
    /// (`raffleMetadataRenderer`). The webapp feeds it to
    /// `PriceDisplay`/`formatPrice`, which divides by `10 ** token.decimals`
    /// (`UnclaimedRaffleActionBox`,
    /// `tokens`).
    ///
    /// Named `priceRaw` deliberately: it was documented as display units and
    /// rendered as such, which turned a 0.1 SOL ticket into "100000000 SOL" and
    /// made the balance check demand 1e17 lamports. Divide by the token's
    /// decimals (`MallowToken.rawToDisplay`) before showing it.
    @JsonKey(name: 'price') double? priceRaw,

    /// Total tickets available.
    int? supply,

    /// Tickets sold.
    int? sold,

    /// Per-wallet ticket cap, when configured.
    int? ticketLimit,

    /// Allowlist creator addresses, when configured.
    List<String>? wlCreators,

    /// Mint of the currency tickets are priced in.
    String? currencyMint,

    /// Recent ticket buyers (addresses).
    List<String>? entrants,

    /// Per-buyer ticket counts. Used to render "Your tickets: N" + the
    /// winner's ticket count.
    Map<String, int>? countByEntrant,

    /// Set after the draw runs.
    String? winner,
    bool? isPrizeClaimed,
    bool? isClaimed,

    /// True when the raffle ended with no tickets sold.
    bool? isExpired,

    /// Server-derived user-aware state. Non-null on authenticated responses;
    /// null on anonymous/cached responses (client falls back to address matching).
    RaffleUserState? raffleUserState,
  }) = _RaffleMetadata;

  factory RaffleMetadata.fromJson(Map<String, dynamic> json) => _$RaffleMetadataFromJson(json);
}

/// Lowest-priced secondary listing for a master edition. Backend type:
/// `SecondaryEditionsData` in `artworkResult`.
@freezed
sealed class SecondaryEditionsData with _$SecondaryEditionsData {
  const factory SecondaryEditionsData({
    @Default(0) int listedCount,
    SecondaryEditionListing? lowestPriceListing,
  }) = _SecondaryEditionsData;

  factory SecondaryEditionsData.fromJson(Map<String, dynamic> json) =>
      _$SecondaryEditionsDataFromJson(json);
}

@freezed
sealed class SecondaryEditionListing with _$SecondaryEditionListing {
  const factory SecondaryEditionListing({
    required String mintAccount,
    required double amount,
    required String currencyMint,

    /// Marketplace source — wire string e.g. `"mallow"`, `"exchange-art"`.
    String? source,
    String? tokenStandard,
  }) = _SecondaryEditionListing;

  factory SecondaryEditionListing.fromJson(Map<String, dynamic> json) =>
      _$SecondaryEditionListingFromJson(json);
}

/// A grouped sale wraps multiple master editions sold together. Backend
/// type: `GroupedSale` in `groupedSale`.
@freezed
sealed class GroupedSale with _$GroupedSale {
  const factory GroupedSale({
    String? groupId,
    String? seller,
    String? name,
    @Default([]) List<GroupedSaleListing> listings,
    String? previewImageUrl,
  }) = _GroupedSale;

  factory GroupedSale.fromJson(Map<String, dynamic> json) => _$GroupedSaleFromJson(json);
}

@freezed
sealed class GroupedSaleListing with _$GroupedSaleListing {
  const factory GroupedSaleListing({
    required GroupedSaleAsset asset,
    required GroupedSalePrice price,
    bool? includesPhysical,
  }) = _GroupedSaleListing;

  factory GroupedSaleListing.fromJson(Map<String, dynamic> json) =>
      _$GroupedSaleListingFromJson(json);
}

@freezed
sealed class GroupedSaleAsset with _$GroupedSaleAsset {
  const factory GroupedSaleAsset({
    required String mintAccount,
    required String name,
    required String imageUrl,
    double? aspectRatio,
    String? tokenStandard,
  }) = _GroupedSaleAsset;

  factory GroupedSaleAsset.fromJson(Map<String, dynamic> json) => _$GroupedSaleAssetFromJson(json);
}

/// `Price` shape from `price`. Mirrors
/// the webapp's two-field price object distinct from the listing-level
/// `amount + currencyMint` pair on [BuyNowMetadata].
@freezed
sealed class GroupedSalePrice with _$GroupedSalePrice {
  const factory GroupedSalePrice({required double amount, required String currencyMint}) =
      _GroupedSalePrice;

  factory GroupedSalePrice.fromJson(Map<String, dynamic> json) => _$GroupedSalePriceFromJson(json);
}

/// Server-derived fee and royalty info for an active listing. Populated on
/// `NftPreviewRender` and public `Artwork` responses. Amounts are
/// in the listing's currency smallest unit so callers apply decimals for display.
@freezed
sealed class ListingFees with _$ListingFees {
  const factory ListingFees({
    /// Effective marketplace fee in basis points (after discount-token rebate,
    /// primary/secondary classification handled server-side).
    int? feeBps,

    /// Creator royalty in basis points.
    int? royaltyBps,

    /// Estimated marketplace fee in raw token units.
    double? estimatedFeeAmount,

    /// Estimated royalty amount in raw token units.
    double? estimatedRoyaltyAmount,
  }) = _ListingFees;

  factory ListingFees.fromJson(Map<String, dynamic> json) => _$ListingFeesFromJson(json);
}

/// Preview-level NFT data (used in lists/grids).
@freezed
sealed class NftPreview with _$NftPreview {
  const factory NftPreview({
    required String mintAccount,
    required String name,
    String? imageUrl,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? creator,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? owner,
    String? chain,
    ListingType? listingType,
    @JsonKey(unknownEnumValue: ListingState.unknown) ListingState? listingState,

    /// Marketplace this artwork's listing / last sale came from. See
    /// [MarketSourceX.isForeignMarketplace].
    @JsonKey(unknownEnumValue: MarketSource.unknown) MarketSource? lastSource,
    double? aspectRatio,
    int? likes,
    LastSale? lastSale,
    BuyNowMetadata? buyNowMetadata,
    AuctionMetadata? auctionMetadata,

    /// Raffle lifecycle for a `listingType == raffle` tile. Card surfaces need
    /// [RaffleMetadata.endsAt] and [RaffleMetadata.sold] to tell a live raffle
    /// from one whose window closed — draw-pending when tickets sold, expired
    /// when none did (the reference web client `CardStatusContent`). Without it
    /// every raffle tile badges "Live raffle" forever.
    RaffleMetadata? raffleMetadata,
    int? supply,
    int? maxSupply,
    int? editionNumber,
    String? parentEdition,
    bool? isMasterEdition,
    ListingFees? listingFees,
    String? collectionName,
    String? updateAuth,

    /// Moderation flag: artwork marked not-safe-for-work. Tiles blur it
    /// unless the viewer's show-NSFW setting is on.
    bool? nsfw,

    /// Mux playback ids for inline video preview. Present when the artwork's
    /// media is a video that finished transcoding. [clipPlaybackId] is a short
    /// preview loop preferred over [playbackId] for autoplay cards.
    String? playbackId,
    String? clipPlaybackId,

    /// True when the requesting owner has hidden this artwork from their
    /// profile. Only meaningful when the viewer owns the artwork; the badge
    /// and hide/unhide menu state read from this.
    @Default(false) bool isOwnerHidden,

    /// True when the requesting **creator** (`updateAuth`) has hidden this
    /// artwork from their profile — the other half of `/v0/hide`, which sets
    /// the creator flag rather than the owner one whenever the caller minted
    /// the piece. The backend only emits it to the creator, so it needs no
    /// further client-side gate; fold it into the same hidden treatment as
    /// [isOwnerHidden].
    @Default(false) bool isCreatorHidden,
  }) = _NftPreview;

  factory NftPreview.fromJson(Map<String, dynamic> json) => _$NftPreviewFromJson(json);
}

/// Full NFT detail data (all preview fields plus description, attributes, royalties).
@freezed
sealed class NftDetail with _$NftDetail {
  const factory NftDetail({
    required String mintAccount,
    required String name,
    String? imageUrl,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? creator,
    @JsonKey(fromJson: apiUserRefFromAny, toJson: apiUserRefToAny) ApiUserRef? owner,

    /// The wallet that actually holds this mint (`nft.owner` on the index,
    /// refreshed by `/v1/artwork/byMint`'s owner-update job). This is the
    /// authority every owner-side transaction must be signed by, and it stays
    /// the seller while the piece is listed (escrow never replaces it).
    ///
    /// 🛑 It is NOT derivable from [owner], which is the holder's *mallow
    /// profile*: `UserRenderer.renderSingle` drops the per-artwork address and
    /// emits the profile's whole `addresses` list, so a profile with two
    /// wallets on this chain collapses to whichever one was linked first.
    String? ownerAddress,

    /// Every address holding a copy of this mint — the `NftOwner` rows (edition
    /// prints, ERC-1155 balances) plus [ownerAddress]. Holders, not profile
    /// links; see [ownerAddress].
    @Default([]) List<String> ownerAddresses,
    String? chain,
    ListingType? listingType,
    @JsonKey(unknownEnumValue: ListingState.unknown) ListingState? listingState,

    /// Marketplace this artwork's listing / last sale came from. See
    /// [MarketSourceX.isForeignMarketplace].
    @JsonKey(unknownEnumValue: MarketSource.unknown) MarketSource? lastSource,
    double? aspectRatio,
    int? likes,
    LastSale? lastSale,
    BuyNowMetadata? buyNowMetadata,
    AuctionMetadata? auctionMetadata,
    RaffleMetadata? raffleMetadata,
    String? description,
    @Default([]) List<NftAttribute> attributes,
    @Default([]) List<Royalty> royalties,
    int? supply,
    int? maxSupply,
    int? editionNumber,
    String? parentEdition,
    bool? isMasterEdition,
    @Default([]) List<String> tags,

    /// Original video source for video artworks. Full quality, straight off the
    /// gateways — so the detail screen reaches for it only in fullscreen, or
    /// when [playbackId] is absent.
    String? videoUrl,

    /// Mux playback id for [videoUrl], present once transcoding is `ready`.
    /// The detail screen's inline player streams this HLS asset rather than
    /// pulling the multi-megabyte original on every open. No `clipPlaybackId`
    /// here: that short loop is a card affordance, and a detail view showing
    /// the whole piece must not silently truncate it.
    String? playbackId,
    bool? isImmutable,
    String? tokenStandard,
    String? updateAuth,
    AssetMetadata? assetMetadata,
    int? sellerFeeBasisPoints,

    /// Off-chain JSON metadata URL (arweave / IPFS gateway / s3 /
    /// shdw-drive / custom). Optional — older or partially-indexed assets
    /// may not have it populated.
    String? metadataUrl,

    /// Lowest-priced secondary listing for this master edition, when one
    /// exists. Drives the "Buy lowest secondary price" sub-CTA on the
    /// edition sheet.
    SecondaryEditionsData? secondaryEditions,

    /// Set when the artwork is part of a multi-edition grouped sale.
    /// Drives the "Select edition" dropdown on the edition sheet.
    GroupedSale? groupedSale,

    /// True when the NFT itself has been flagged. Hides the owner
    /// "List artwork" CTA per webapp parity.
    bool? isFlagged,

    /// Moderation flag: artwork marked not-safe-for-work. The detail media
    /// blurs it unless the viewer's show-NSFW setting is on.
    bool? nsfw,

    /// Server-derived fee + royalty info for the active listing. Non-null
    /// when a listing exists; null for unlisted NFTs.
    ListingFees? listingFees,

    /// Off-chain listing metadata. Carries the seller's
    /// `rewardsDescription` (physical-item + rewards disclosures) when the
    /// listing was created with extras. Null for unlisted NFTs.
    ListingMetadata? listingMetadata,

    /// True when the requesting owner has hidden this artwork from their
    /// profile. Drives the detail-screen "..." menu's Hide/Unhide state.
    @Default(false) bool isOwnerHidden,

    /// True when the requesting **creator** (`updateAuth`) has hidden this
    /// artwork from their profile. `/v0/hide` sets this flag instead of
    /// [isOwnerHidden] whenever the caller minted the piece, so a creator who
    /// no longer owns it only ever gets this one. The backend emits it solely
    /// to the creator, so it needs no further client-side gate.
    @Default(false) bool isCreatorHidden,

    /// Unlockable (exclusive) content records attached to this artwork.
    /// Must be round-tripped on edit: the v2 edit route reads an empty
    /// `unlockableContentIds` as an explicit clear and emits
    /// `RemoveExternalPluginAdapter`.
    @Default(<UnlockableContentPreview>[]) List<UnlockableContentPreview> unlockableContent,
  }) = _NftDetail;

  factory NftDetail.fromJson(Map<String, dynamic> json) => _$NftDetailFromJson(json);
}

/// Off-chain marketplace metadata attached to a listing in the `/byMint`
/// response. Only [rewardsDescription] is consumed by the app today (drives
/// the "Physical available" / "Rewards included" disclosures); the wire
/// object also carries LUT / group-id plumbing the app doesn't need.
@freezed
sealed class ListingMetadata with _$ListingMetadata {
  const factory ListingMetadata({
    /// Seller-supplied physical-item + rewards details. Same shape as the
    /// `POST /v0/rewardsDescription` body, so [RewardsDescriptionPayload]
    /// is reused for parsing.
    RewardsDescriptionPayload? rewardsDescription,
  }) = _ListingMetadata;

  factory ListingMetadata.fromJson(Map<String, dynamic> json) => _$ListingMetadataFromJson(json);
}

/// Preview-level collection data.
@freezed
sealed class CollectionPreview with _$CollectionPreview {
  const factory CollectionPreview({
    String? slug,
    String? name,
    String? imageUrl,
    int? itemCount,
    @Default([]) List<String> tags,
    String? chain,
    String? creatorAddress,
  }) = _CollectionPreview;

  factory CollectionPreview.fromJson(Map<String, dynamic> json) =>
      _$CollectionPreviewFromJson(json);
}

/// Creator/owner details returned alongside artwork.
///
/// Named [ArtworkCreatorDetails] to avoid conflict with the login
/// [UserDetails] model in user.dart.
@freezed
sealed class ArtworkCreatorDetails with _$ArtworkCreatorDetails {
  const factory ArtworkCreatorDetails({
    String? address,
    String? username,
    String? displayName,
    String? avatarUrl,
    bool? isVerified,
  }) = _ArtworkCreatorDetails;

  factory ArtworkCreatorDetails.fromJson(Map<String, dynamic> json) =>
      _$ArtworkCreatorDetailsFromJson(json);
}

/// A curation that the artwork appears in. Backend caps the list at 20,
/// ordered by curation `createdAt` desc: `public`/`featured` curations
/// plus the signed-in viewer's own private ones (appended after the
/// public list). `imageUrl` is the curation's first artwork image.
@freezed
sealed class ArtworkCurationPreview with _$ArtworkCurationPreview {
  const factory ArtworkCurationPreview({
    required String id,
    required String name,
    required String slug,
    String? imageUrl,
    String? creatorAddress,
  }) = _ArtworkCurationPreview;

  factory ArtworkCurationPreview.fromJson(Map<String, dynamic> json) =>
      _$ArtworkCurationPreviewFromJson(json);
}

/// Full artwork result returned by GET /v1/artwork/byMint/:mintAccount.
@freezed
sealed class ArtworkResult with _$ArtworkResult {
  const factory ArtworkResult({
    required NftDetail item,
    CollectionPreview? collection,
    ArtworkCreatorDetails? userDetails,
    @JsonKey(fromJson: _highestOfferFromJson) double? highestOffer,
    int? offersCount,
    bool? isFreePrint,
    @Default([]) List<ArtworkCurationPreview> curations,

    /// Raffles the connected wallet has unclaimed prizes / proceeds in.
    /// Mirrors `ArtworkResultV1.unclaimedRaffles`.
    @Default([]) List<RaffleMetadata> unclaimedRaffles,

    /// Tx ID the user can use to redeem a physical-item-bearing purchase.
    /// Surfaces the post-purchase "Redeem physical item" CTA.
    String? redeemableTxId,

    /// True when the connected wallet is excluded from the listing's
    /// off-chain whitelist (Merkle proof failed server-side).
    bool? offChainWhitelistDenied,
  }) = _ArtworkResult;

  factory ArtworkResult.fromJson(Map<String, dynamic> json) => _$ArtworkResultFromJson(json);
}

/// Request body for POST /v0/like and /v0/unlike.
class LikeRequest {
  const LikeRequest({required this.mint});

  final String mint;

  Map<String, dynamic> toJson() => {'mint': mint};
}

/// Request body for `POST /v1/artwork/byOwner/:owner`.
///
/// Mirrors `SearchUserNftsRequest` from the server's shared types. Used to
/// scope what counts as "owned" — e.g. for the auction picker we set
/// [nonPrintableOnly] so master editions with remaining supply are excluded.
@freezed
sealed class SearchUserNftsRequest with _$SearchUserNftsRequest {
  const factory SearchUserNftsRequest({
    /// Master editions only (1/1s + edition masters).
    bool? masterOnly,

    /// Excludes master editions that still have prints to mint. Leaves 1/1s
    /// and already-minted edition prints — the set listable for auction.
    bool? nonPrintableOnly,

    /// Master editions that still have prints to mint.
    bool? printableOnly,

    /// Excludes frozen NFTs (staked, escrowed, etc.).
    bool? nonFrozenOnly,

    /// Keep frozen NFTs (listed/staked/delegated) in the results. byOwner drops
    /// them by default for the action pickers; the portfolio "Artworks" tab sets
    /// this so everything the wallet owns is shown.
    bool? includeFrozen,

    /// Restrict to NFTs in these listing states.
    List<ListingType>? listingTypes,
    List<String>? tokenStandards,
    @Default(0) int page,
    int? pageSize,
  }) = _SearchUserNftsRequest;

  factory SearchUserNftsRequest.fromJson(Map<String, dynamic> json) =>
      _$SearchUserNftsRequestFromJson(json);
}

/// Response from `POST /v1/artwork/byOwner/:owner`.
///
/// `result` items are `NftPreviewRender`s; parse with [NftPreview.fromJson]
/// in the repository layer to mirror the profile flow.
@JsonSerializable()
class ArtworksByOwnerResponse {
  const ArtworksByOwnerResponse({this.result = const [], this.total = 0, this.nextPage});

  final List<Map<String, dynamic>> result;
  final int total;
  final int? nextPage;

  factory ArtworksByOwnerResponse.fromJson(Map<String, dynamic> json) =>
      _$ArtworksByOwnerResponseFromJson(json);

  Map<String, dynamic> toJson() => _$ArtworksByOwnerResponseToJson(this);
}
