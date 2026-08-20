import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart'
    show
        AuctionMetadata,
        BuyNowMetadata,
        ContentType,
        GroupedSale,
        ListingFees,
        ListingState,
        ListingType,
        MarketSource,
        MarketSourceX,
        RaffleMetadata,
        RewardsDescriptionPayload,
        SecondaryEditionsData,
        SupplyType;

import '../../../core/network/auth_service.dart';
import '../../../core/realtime/account_realtime_service.dart';
import '../../../core/result/result.dart';
import '../../../di.dart';
import 'artwork_edited_signal.dart';
import 'artwork_hidden_signal.dart';
import '../data/artwork_repository.dart';
import '../data/auction_live_repository.dart';
import '../data/market_account_repository.dart';
import '../models/artwork_curation.dart';

export 'package:mallow_api/mallow_api.dart'
    show
        AuctionLiveState,
        AuctionMetadata,
        BuyNowMetadata,
        EditionLiveState,
        EditionPurchaseStats,
        EditionSupplyInfo,
        GroupedSale,
        ListingFees,
        ListingState,
        ListingType,
        MarketSource,
        MarketSourceX,
        OfferRender,
        PhysicalDetailsPayload,
        RaffleLiveState,
        RaffleMetadata,
        RewardsDescriptionPayload,
        SecondaryEditionsData,
        SupplyType,
        SupplyTypeX;

export '../models/artwork_curation.dart' show ArtworkCuration;

part 'artwork_bloc.freezed.dart';

/// Model for artwork attributes
class ArtworkAttribute {
  const ArtworkAttribute({required this.traitType, required this.value});

  final String traitType;
  final String value;
}

/// A single proceeds-split entry from an NFT's royalty configuration.
class ArtworkRoyaltySplit {
  const ArtworkRoyaltySplit({
    required this.address,
    required this.sharePercent,
    this.username,
    this.displayName,
  });

  final String address;

  /// 0–100.
  final int sharePercent;

  /// Cached username from the API's embedded user object — when present,
  /// avoids a separate `getUserProfiles` lookup on the detail screen.
  final String? username;

  /// Fallback display name from the API, used when [username] is empty.
  final String? displayName;
}

/// Sentinel used by [ArtworkDetails.copyWith] to distinguish "leave the
/// nullable field as-is" (omitted) from "explicitly set it to null"
/// (e.g. clearing [ArtworkDetails.buyNowMetadata] when a listing is
/// cancelled).
const Object _unset = Object();

/// One durable optimistic mutation in [ArtworkBloc]'s journal.
///
/// [apply] rewrites the loaded [ArtworkDetails] to reflect a just-confirmed
/// action (cancel, price update, ownership claim/relinquish, 1/1 buy). It is
/// re-applied on **every** emit path — refresh, invalidation-driven refresh,
/// and existence-reconcile — so a stale pre-index read can never revert the
/// action. [isSatisfied] returns true once a freshly-fetched byMint payload
/// already reflects the mutation, at which point the overlay is redundant and
/// the entry is dropped (self-healing, independent of exactly when the indexer
/// acks). [signature] tags the entry to its tx for de-dup + logging.
@immutable
class _PendingMutation {
  const _PendingMutation({
    required this.signature,
    required this.apply,
    required this.isSatisfied,
  });

  final String signature;
  final ArtworkDetails Function(ArtworkDetails) apply;
  final bool Function(ArtworkDetails) isSatisfied;
}

/// Model for artwork details
class ArtworkDetails {
  const ArtworkDetails({
    required this.mintAccount,
    required this.title,
    required this.imageUrl,
    required this.description,
    required this.artistName,
    required this.artistAddress,
    this.artistUsername,
    this.artistAvatarUrl,
    this.collectionName,
    this.collectionMint,
    this.collectionImageUrl,
    this.attributes = const [],
    this.price,
    this.currency,
    this.listingType = ListingType.unlisted,
    this.listingState,
    this.buyNowMetadata,
    this.auctionMetadata,
    this.raffleMetadata,
    this.secondaryEditions,
    this.groupedSale,
    this.unclaimedRaffles = const [],
    this.redeemableTxId,
    this.rewardsInfo,
    this.offChainWhitelistDenied,
    this.isFlagged = false,
    this.creatorIsFlagged = false,
    this.lastSource,
    this.nsfw = false,
    this.highestOffer,
    this.offersCount,
    this.isFreePrint = false,
    this.isLiked = false,
    this.likeCount = 0,
    this.standard = 'Metaplex',
    this.ownerAddress,
    this.ownerAddresses = const [],
    this.artistAddresses = const [],
    this.supply,
    this.maxSupply,
    this.editionNumber,
    this.isMasterEdition,
    this.listingFees,
    this.supplyType = SupplyType.oneOfOne,
    this.isVerified = false,
    this.isAdmin = false,
    this.curations = const [],
    this.tags = const [],
    this.quantitySold,
    this.quantityTotal,
    this.animationUrl,
    this.playbackId,
    this.royaltyPercent,
    this.royaltySplits = const [],
    this.createdAt,
    this.updateAuthority,
    this.isMutable,
    this.mimeType,
    this.dimensions,
    this.fileSizeBytes,
    this.tokenStandard,
    this.metadataUrl,
    this.categories = const [],
    this.chain,
    this.isHidden = false,
  });

  final String mintAccount;
  final String title;
  final String imageUrl;
  final String? description;

  /// Original animation/video URL for animated or video NFTs.
  final String? animationUrl;

  /// Mux playback id for [animationUrl], set once transcoding finished. The
  /// detail screen's inline player prefers this HLS stream; [animationUrl]'s
  /// multi-megabyte original is left to the fullscreen viewer. Null on an
  /// artwork with no video, or one Mux has not finished transcoding.
  final String? playbackId;
  final String artistName;
  final String artistAddress;

  /// Bare handle (no leading `@`), populated from `item.creator.username`.
  final String? artistUsername;
  final String? artistAvatarUrl;
  final String? collectionName;
  final String? collectionMint;
  final String? collectionImageUrl;
  final List<ArtworkAttribute> attributes;

  /// Raw on-chain (atomic) listing amount, in [currency]'s smallest unit.
  /// Convert with [PriceFormatter.formatRawAmount] for display.
  final double? price;
  final String? currency;

  /// Marketplace listing discriminator. Drives the bottom-sheet dispatcher
  /// in [resolveArtworkActionState] and is documented in
  /// `docs/artwork_state.md`.
  final ListingType listingType;

  /// Server-derived listing lifecycle state (`none|pending|active|ended`).
  /// Authoritative over the client's `startsAt`/`endsAt` comparisons when
  /// present; null when the API omits it (falls back to time-based logic).
  final ListingState? listingState;

  /// Wire metadata for a buy-now listing. Non-null when [listingType] is
  /// [ListingType.buyNow]; carries price, supply caps, and the on-chain
  /// listing PDA.
  final BuyNowMetadata? buyNowMetadata;

  /// Wire metadata for an auction listing. Non-null when [listingType] is
  /// [ListingType.auction]; carries reserve / current bid / timing.
  final AuctionMetadata? auctionMetadata;

  /// Wire metadata for a raffle listing. Non-null when [listingType] is
  /// [ListingType.raffle]; carries ticket price, slot counts, draw state.
  final RaffleMetadata? raffleMetadata;

  /// Lowest-priced secondary listing for this master edition, when one
  /// exists. Drives the "Buy lowest secondary price" sub-CTA on
  /// [ArtworkBuyEditionSheet].
  final SecondaryEditionsData? secondaryEditions;

  /// Set when the artwork is part of a multi-edition grouped sale.
  /// Drives the "Select edition" dropdown.
  final GroupedSale? groupedSale;

  /// Raffles the connected wallet has unclaimed prizes / proceeds in.
  /// Routes the dispatcher to [ArtworkUnclaimedRaffleAction] when non-empty.
  final List<RaffleMetadata> unclaimedRaffles;

  /// Tx ID the user can use to redeem a physical-item-bearing purchase.
  /// Null until the post-purchase indexer surfaces it.
  final String? redeemableTxId;

  /// Seller-supplied physical-item + rewards details for the active
  /// listing, from `item.listingMetadata.rewardsDescription`. Drives the
  /// "Physical available" / "Rewards included" disclosures on the listed
  /// bottom sheets. Null when the listing has no extras.
  final RewardsDescriptionPayload? rewardsInfo;

  /// True when the listing advertises a physical item — either the
  /// `includesPhysical` flag or a populated `physicalDetails`.
  bool get hasPhysical =>
      rewardsInfo != null &&
      (rewardsInfo!.includesPhysical || rewardsInfo!.physicalDetails != null);

  /// True when the listing carries a non-empty rewards description.
  bool get hasRewards =>
      (rewardsInfo?.rewardsDescription?.trim().isNotEmpty ?? false);

  /// True when the connected wallet is excluded from the listing's
  /// off-chain whitelist (Merkle proof failed server-side).
  final bool? offChainWhitelistDenied;

  /// True when the NFT itself has been flagged. Hides the owner
  /// "List artwork" CTA per webapp parity.
  final bool isFlagged;

  /// True when the artwork's **creator** has been flagged
  /// (`item.creator.isFlagged`). Hides the owner "List artwork" CTA and
  /// nothing else — the webapp's `!creator?.isFlagged && !isFlagged` wraps
  /// only "List for sale" (`ActionBox`);
  /// Transfer sits outside it at `:200-217`.
  final bool creatorIsFlagged;

  /// Marketplace this artwork's listing / last sale came from. Null on a
  /// mallow-native artwork and on anything the indexer hasn't attributed;
  /// both are treated as mallow. A foreign source suppresses the action
  /// sheet entirely — see [MarketSourceX.isForeignMarketplace].
  final MarketSource? lastSource;

  /// Moderation flag: artwork marked not-safe-for-work. The detail media is
  /// blurred unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  /// Highest active offer in SOL (display units). Null when no offers exist.
  /// `userOwnOffer` (whether the connected wallet is the offer maker) is not
  /// available from `/byMint` — see `docs/artwork_state.md` data
  /// requirements.
  final double? highestOffer;

  /// Total active offers on this artwork.
  final int? offersCount;

  /// Free-print flag from `ArtworkResult.isFreePrint`.
  final bool isFreePrint;

  /// Backwards-compatible flag for "actively listed for sale". Derived from
  /// [listingType] so existing call sites (e.g. [ArtworkBuySheet]) keep
  /// working without bool plumbing.
  bool get isListed => listingType != ListingType.unlisted;

  final bool isLiked;
  final int likeCount;
  final String standard;

  /// The wallet that holds this mint (`NftDetail.ownerAddress`), and therefore
  /// the authority every owner-side transaction must be signed by — listing,
  /// burn, transfer, accept-offer. Also used for display + cast routing.
  ///
  /// For "is this artwork mine?" prefer membership in [ownerAddresses]: a
  /// single mallow user may hold it in a wallet outside the current session,
  /// and any linked wallet counts as "owner" for affordance purposes.
  final String? ownerAddress;

  /// Addresses that count as "the owner" for affordance gates: every holder of
  /// this mint (the API's `ownerAddresses`) followed by every wallet linked to
  /// the owner's mallow profile. Empty when the API returns only a bare
  /// address string. Mirrors the webapp's
  /// `nftPreview.owner.addresses.includes(userPubkey)` check.
  ///
  /// 🛑 Not an authority list — the profile links do not hold the piece and
  /// cannot sign for it. Signing resolves through [ownerAddress].
  final List<String> ownerAddresses;

  /// Every wallet linked to the artwork's primary artist. Used the same way
  /// as [ownerAddresses] for creator-relationship checks.
  final List<String> artistAddresses;

  final int? supply;
  final int? maxSupply;
  final int? editionNumber;

  /// Server-derived flag: true when this is a printable master edition NFT.
  /// Authoritative over the `supplyType` proxy when present; the DAS-derived
  /// `editionState.isPrintableMasterEdition` remains the highest-priority
  /// signal when a live websocket state is available.
  final bool? isMasterEdition;

  /// Server-derived fee + royalty info for the active listing. Non-null when
  /// a listing exists; null for unlisted NFTs. Amounts in raw token units.
  final ListingFees? listingFees;

  final SupplyType supplyType;
  final bool isVerified;

  /// Whether the artist has the `admin` role — tints the verified badge.
  final bool isAdmin;
  final List<ArtworkCuration> curations;
  final List<String> tags;
  final double? quantitySold;
  final double? quantityTotal;

  /// Whole-number seller-fee percentage as text, e.g. `"10"`.
  /// Null when not supplied by the API.
  final String? royaltyPercent;

  /// Per-creator proceeds splits. Empty when no royalties configured.
  final List<ArtworkRoyaltySplit> royaltySplits;

  /// Gap placeholders — currently null for all artworks until the backend
  /// or an on-chain fetch surfaces these fields.
  final DateTime? createdAt;
  final String? updateAuthority;
  final bool? isMutable;
  final String? mimeType;
  final ({int width, int height})? dimensions;
  final int? fileSizeBytes;

  /// Wire token-standard string from the API (e.g. `core`, `nft`, `pnft`).
  /// Mapped to a human label in the artwork-info widget.
  final String? tokenStandard;

  /// Off-chain JSON metadata URL surfaced as the `Metadata host` Details
  /// row (classified into arweave / IPFS / S3 / shdw-drive / custom).
  final String? metadataUrl;

  final List<String> categories;

  /// Wire chain identifier (`solana`, `ethereum`, `tezos`). Drives the
  /// label-set used in the Details tab — ETH/Tezos artworks render as
  /// `Contract address` + `Token ID` instead of `Mint address`, and the
  /// update-authority row is relabeled `Deployer address`.
  final String? chain;

  /// True when the requesting owner has hidden this artwork from their
  /// profile. Drives the detail-screen "..." menu's Hide/Unhide state.
  final bool isHidden;

  ArtworkDetails copyWith({
    bool? isLiked,
    int? likeCount,
    bool? isHidden,
    Object? price = _unset,
    Object? currency = _unset,
    Object? listingType = _unset,
    Object? buyNowMetadata = _unset,
    Object? auctionMetadata = _unset,
    Object? ownerAddress = _unset,
    List<String>? ownerAddresses,
  }) {
    return ArtworkDetails(
      mintAccount: mintAccount,
      title: title,
      imageUrl: imageUrl,
      description: description,
      artistName: artistName,
      artistAddress: artistAddress,
      artistUsername: artistUsername,
      artistAvatarUrl: artistAvatarUrl,
      collectionName: collectionName,
      collectionMint: collectionMint,
      collectionImageUrl: collectionImageUrl,
      attributes: attributes,
      price: identical(price, _unset) ? this.price : price as double?,
      currency: identical(currency, _unset)
          ? this.currency
          : currency as String?,
      listingType: identical(listingType, _unset)
          ? this.listingType
          : listingType as ListingType,
      listingState: listingState,
      buyNowMetadata: identical(buyNowMetadata, _unset)
          ? this.buyNowMetadata
          : buyNowMetadata as BuyNowMetadata?,
      auctionMetadata: identical(auctionMetadata, _unset)
          ? this.auctionMetadata
          : auctionMetadata as AuctionMetadata?,
      raffleMetadata: raffleMetadata,
      secondaryEditions: secondaryEditions,
      groupedSale: groupedSale,
      unclaimedRaffles: unclaimedRaffles,
      redeemableTxId: redeemableTxId,
      rewardsInfo: rewardsInfo,
      offChainWhitelistDenied: offChainWhitelistDenied,
      isFlagged: isFlagged,
      creatorIsFlagged: creatorIsFlagged,
      lastSource: lastSource,
      nsfw: nsfw,
      highestOffer: highestOffer,
      offersCount: offersCount,
      isFreePrint: isFreePrint,
      isLiked: isLiked ?? this.isLiked,
      likeCount: likeCount ?? this.likeCount,
      standard: standard,
      ownerAddress: identical(ownerAddress, _unset)
          ? this.ownerAddress
          : ownerAddress as String?,
      ownerAddresses: ownerAddresses ?? this.ownerAddresses,
      artistAddresses: artistAddresses,
      supply: supply,
      maxSupply: maxSupply,
      editionNumber: editionNumber,
      isMasterEdition: isMasterEdition,
      listingFees: listingFees,
      supplyType: supplyType,
      isVerified: isVerified,
      isAdmin: isAdmin,
      curations: curations,
      tags: tags,
      quantitySold: quantitySold,
      quantityTotal: quantityTotal,
      animationUrl: animationUrl,
      playbackId: playbackId,
      royaltyPercent: royaltyPercent,
      royaltySplits: royaltySplits,
      createdAt: createdAt,
      updateAuthority: updateAuthority,
      isMutable: isMutable,
      mimeType: mimeType,
      dimensions: dimensions,
      fileSizeBytes: fileSizeBytes,
      tokenStandard: tokenStandard,
      metadataUrl: metadataUrl,
      categories: categories,
      chain: chain,
      isHidden: isHidden ?? this.isHidden,
    );
  }
}

/// Events for artwork detail screen
@freezed
sealed class ArtworkEvent with _$ArtworkEvent {
  /// Load artwork details
  const factory ArtworkEvent.load({required String mintAccount}) = ArtworkLoad;

  /// Refresh artwork details
  const factory ArtworkEvent.refresh() = ArtworkRefresh;

  /// Toggle like status
  const factory ArtworkEvent.toggleLike() = ArtworkToggleLike;

  /// Optimistically flip the hidden state after a `/v0/hide` write returns
  /// (via the app-wide [ArtworkHiddenSignal]), so the "..." menu's Hide/Unhide
  /// row reflects the new state without a refetch.
  const factory ArtworkEvent.setHidden({required bool isHidden}) =
      ArtworkSetHidden;

  /// Optimistically apply a just-confirmed listing change so the bottom
  /// sheet can swap to the new price (or unlisted state) without waiting
  /// for the indexer round-trip. Recorded in the durable optimism journal
  /// (see [ArtworkBloc]) so it survives every refresh/reconcile until a fresh
  /// byMint read reflects it. [newPriceRaw] is the raw on-chain amount in the
  /// listing currency's smallest unit — pass it through unscaled (no display
  /// round-trip). [signature] tags the journal entry.
  const factory ArtworkEvent.optimisticListingUpdate({
    double? newPriceRaw,
    @Default(false) bool cancelled,
    @Default('') String signature,
  }) = ArtworkOptimisticListingUpdate;

  /// Optimistically mark the connected wallet [owner] as the artwork's owner
  /// and drop the (now-settled) listing, after it claimed an auction win or
  /// reclaimed a no-bid auction. Flips the bottom sheet to owner-unlisted
  /// ("List artwork") the instant the claim confirms, without waiting for the
  /// indexer/DAS to reflect the on-chain transfer. Also used for a 1/1 buy
  /// (the buyer takes ownership + the listing clears). Recorded in the durable
  /// optimism journal until a fresh byMint read reflects the new owner.
  const factory ArtworkEvent.optimisticClaimOwnership({
    required String owner,
    @Default('') String signature,
  }) = ArtworkOptimisticClaimOwnership;

  /// Optimistically hand ownership to [newOwner] and drop the (now-settled)
  /// auction, after the seller settled a won auction. The NFT leaves the
  /// seller for the winning bidder, so the seller becomes a plain viewer —
  /// flips the bottom sheet to the unlisted "Make offer" state the instant
  /// the settle confirms, instead of gating behind the indexer (which can
  /// briefly mis-resolve the stale-owner seller to an empty no-sheet state).
  /// The mirror of [ArtworkOptimisticClaimOwnership]. Recorded in the durable
  /// optimism journal until a fresh byMint read reflects the transfer.
  const factory ArtworkEvent.optimisticRelinquishOwnership({
    required String newOwner,
    @Default('') String signature,
  }) = ArtworkOptimisticRelinquishOwnership;

  /// Overlay live on-chain auction state (from the `/v2/ws/accounts` push or a
  /// `GET /v2/auctions/:mint` snapshot) onto the indexed [AuctionMetadata].
  /// On-chain wins, so the highest bid / bidder / countdown reflect the chain
  /// the instant a bid lands — without waiting for the byMint indexer cycle.
  /// [bidCount] is only set by the snapshot (the raw account doesn't carry it).
  const factory ArtworkEvent.auctionLiveUpdate({
    required String auctionAccount,
    double? currentBidAmount,
    String? currentBidder,
    DateTime? endsAt,
    int? bidCount,
  }) = ArtworkAuctionLiveUpdate;

  /// Overlay live on-chain listing state (from the `/v2/ws/accounts` push) onto
  /// the indexed [BuyNowMetadata] — price + end time. On-chain wins.
  const factory ArtworkEvent.listingLiveUpdate({
    required String listingAccount,
    double? price,
    DateTime? endsAt,
  }) = ArtworkListingLiveUpdate;

  /// Reconcile artwork *existence* state against the chain, from a one-shot
  /// read of the client-derived `Listing` / `AuctionConfig` PDAs (see
  /// [MarketAccountRepository]). Unlike the per-field overlays above, this can
  /// **synthesize** a listing/auction the `/byMint` indexer missed entirely
  /// (chain present, indexed unlisted) and **clear** one the chain no longer
  /// has (chain authoritatively absent, indexed still listed). [listing] /
  /// [auction] carry the chain-built metadata (non-null only when the account
  /// is present) so the handler stays pure.
  /// A chain write relevant to this mint landed at [slot] — either one of the
  /// user's own transactions (landed slot from `getSignatureStatuses`, via
  /// `TxLandedSlots`) or a server invalidation carrying its triggering tx's
  /// slot. Raises the bloc's floor slot: an `absent` read whose view slot is
  /// older than the floor predates a known write and must not clear state.
  /// The slot-precise replacement for the wall-clock local-action grace.
  const factory ArtworkEvent.chainActionLanded({required int slot}) =
      ArtworkChainActionLanded;

  /// [listingViewSlot] / [auctionViewSlot] carry the RPC view slot each read
  /// was evaluated at (null for tombstone-driven dispatches and legacy
  /// backends). An `absent` status is only trusted over live socket presence
  /// evidence when its view slot is >= the evidence's write slot.
  const factory ArtworkEvent.existenceReconcile({
    required OnChainReadStatus listingStatus,
    required OnChainReadStatus auctionStatus,
    ListingReconcileData? listing,
    AuctionReconcileData? auction,
    int? listingViewSlot,
    int? auctionViewSlot,
  }) = ArtworkExistenceReconcile;
}

/// Chain-built fixed-price listing state for [ArtworkExistenceReconcile].
/// A plain (non-freezed) holder so freezed treats it as an opaque field
/// rather than trying to synthesize a nested copyWith for the `mallow_api`
/// [BuyNowMetadata] it wraps (whose copyWith machinery isn't visible here).
@immutable
class ListingReconcileData {
  const ListingReconcileData({required this.metadata, this.currency});

  final BuyNowMetadata metadata;

  /// The listing's currency mint, seeded onto [ArtworkDetails.currency] when
  /// synthesizing a listing the indexer missed.
  final String? currency;
}

/// Chain-built auction state for [ArtworkExistenceReconcile]. Plain holder for
/// the same reason as [ListingReconcileData].
@immutable
class AuctionReconcileData {
  const AuctionReconcileData({required this.metadata, this.currency});

  final AuctionMetadata metadata;

  /// The auction's bid mint, seeded onto [ArtworkDetails.currency] when
  /// synthesizing an auction the indexer missed.
  final String? currency;
}

/// States for artwork detail screen
@freezed
sealed class ArtworkState with _$ArtworkState {
  /// Initial state
  const factory ArtworkState.initial() = ArtworkInitial;

  /// Loading state
  const factory ArtworkState.loading() = ArtworkLoading;

  /// Loaded state with artwork details.
  ///
  /// [revision] increments on every indexer-driven [ArtworkRefresh] so
  /// widgets keyed off it (the History / Offers paged sections) are rebuilt
  /// from scratch and refetch their first page. Like toggles and optimistic
  /// listing updates preserve the current revision so they don't force a
  /// needless refetch.
  const factory ArtworkState.loaded({
    required ArtworkDetails artwork,
    @Default(false) bool isTogglingLike,
    @Default(0) int revision,
  }) = ArtworkLoaded;

  /// Error state
  const factory ArtworkState.error({required String message}) = ArtworkError;
}

/// Bloc for artwork detail screen
@injectable
class ArtworkBloc extends Bloc<ArtworkEvent, ArtworkState> {
  ArtworkBloc(
    this._repository,
    this._authService,
    this._accountRealtime,
    this._auctionLive,
    this._marketAccounts,
  ) : super(const ArtworkState.initial()) {
    on<ArtworkLoad>(_onLoad);
    on<ArtworkRefresh>(_onRefresh);
    on<ArtworkToggleLike>(_onToggleLike);
    on<ArtworkSetHidden>(_onSetHidden);
    on<ArtworkOptimisticListingUpdate>(_onOptimisticListingUpdate);
    on<ArtworkOptimisticClaimOwnership>(_onOptimisticClaimOwnership);
    on<ArtworkOptimisticRelinquishOwnership>(_onOptimisticRelinquishOwnership);
    on<ArtworkChainActionLanded>(_onChainActionLanded);
    on<ArtworkAuctionLiveUpdate>(_onAuctionLiveUpdate);
    on<ArtworkListingLiveUpdate>(_onListingLiveUpdate);
    on<ArtworkExistenceReconcile>(_onExistenceReconcile);

    // An on-chain edit of this mint (via the mint/edit pipeline) mutates its
    // metadata after the detail view is already loaded — refetch when the
    // indexer acks so the thumbnail/name/description reflect the edit.
    // Guarded so unit tests that don't bootstrap DI simply skip it.
    if (sl.isRegistered<ArtworkEditedSignal>()) {
      _editedSignalSub = sl<ArtworkEditedSignal>().stream.listen((mint) {
        if (mint == _currentMintAccount) add(const ArtworkEvent.refresh());
      });
    }

    // Hide/unhide of this mint (from this screen's "..." menu or elsewhere)
    // flips the loaded artwork's hidden state so the menu row stays in sync.
    if (sl.isRegistered<ArtworkHiddenSignal>()) {
      _hiddenSignalSub = sl<ArtworkHiddenSignal>().stream.listen((change) {
        if (change.mintAccount == _currentMintAccount) {
          add(ArtworkEvent.setHidden(isHidden: change.isHidden));
        }
      });
    }
  }

  final ArtworkRepository _repository;
  final AuthService _authService;
  final AccountRealtimeService _accountRealtime;
  final AuctionLiveRepository _auctionLive;
  final MarketAccountRepository _marketAccounts;

  /// One-shot, user-facing failures. A reverted like restores the exact state
  /// that was on screen before the tap, so there is nothing for a
  /// `BlocListener` to diff on — the detail screen subscribes here instead.
  final StreamController<String> _transientErrors =
      StreamController<String>.broadcast();

  Stream<String> get transientErrors => _transientErrors.stream;

  String? _currentMintAccount;

  /// Client-derived `Listing` / `AuctionConfig` PDAs for the current mint.
  /// Watched live (in addition to any account the byMint payload names) so a
  /// listing/auction the indexer missed is still reconciled. Reset on load.
  String? _derivedListingPda;
  String? _derivedAuctionConfigPda;

  /// Bumped on each successful [ArtworkRefresh]; carried into every
  /// `loaded` emit so the History / Offers sections refetch only on a real
  /// indexer-driven refresh, not on like toggles or optimistic updates.
  int _revision = 0;

  /// Live `/v2/ws/accounts` subscriptions for this artwork's on-chain accounts
  /// (auction config + listing PDAs), keyed by the account pubkey we're
  /// watching so we only resubscribe when the set actually changes.
  final List<StreamSubscription<AccountUpdate>> _accountSubs = [];
  Set<String> _watchedAccounts = const {};

  /// Refetch trigger for post-edit metadata changes to this mint. See the
  /// subscription in the constructor.
  StreamSubscription<String>? _editedSignalSub;

  /// Optimistic hidden-state flip for this mint. See the constructor.
  StreamSubscription<ArtworkHiddenChange>? _hiddenSignalSub;

  /// Last applied live auction overlay (on-chain bid state), keyed by the
  /// auction account it belongs to. Re-applied on every byMint refresh so a
  /// lagging indexer payload doesn't visibly revert the live bid for a beat.
  ({
    String account,
    double? currentBidAmount,
    String? currentBidder,
    DateTime? endsAt,
    int bidCount,
  })?
  _auctionOverlay;

  /// Durable optimistic-mutation journal. Generalizes what
  /// [_auctionOverlay] does for live bids to every other optimistic mutation:
  /// each entry is re-applied on every emit path (refresh, invalidation
  /// refresh, existence-reconcile) and dropped only once a fresh byMint read
  /// reflects it — so no refresh/invalidation/reconcile can revert a
  /// just-confirmed action while its indexed state is still catching up.
  final List<_PendingMutation> _journal = [];

  /// Bumped on every optimistic write and on load. Captured before
  /// each async chain read in [_reconcileExistence]; a read whose epoch no
  /// longer matches on return is dropped, so a reconcile can't land its result
  /// on top of an optimistic write that happened while it was in flight.
  int _reconcileEpoch = 0;

  /// Wall-clock of the most recent optimistic write (grace window).
  /// Within [_localActionGrace] of it, existence-reconcile suppresses `absent`
  /// clears and contradicting `present` synthesizes — a missing/lingering
  /// account there is the RPC lagging the user's own write, not truth.
  DateTime? _lastLocalActionAt;

  static const _localActionGrace = Duration(seconds: 6);

  /// On-chain presence evidence from the account socket, per side. Set when a
  /// decoded (non-close) frame arrives for the listing / auction-config PDA —
  /// proof the account exists on-chain as of that frame's write [slot]. A
  /// cold-read `absent` is only a fact about the serving node's *view* slot,
  /// so it outranks this evidence only when provably newer: `viewSlot >=
  /// slot`. An absent read with an older (or unknown) view was served by an
  /// RPC node behind our own evidence (observed: a freshly-created listing
  /// 404s while the socket already pushed it) and must not clear state.
  /// Evidence is rescinded by the account's close tombstone (same ordered
  /// stream), when stream continuity breaks (synthetic reconnect, where a
  /// tombstone may have been missed and the re-read must decide), or on load.
  /// Never set from REST reads: a stale in-flight read completing after a
  /// tombstone must not resurrect evidence the tombstone already rescinded.
  ({String pubkey, int slot})? _listingPresence;
  ({String pubkey, int slot})? _auctionPresence;

  /// Highest slot at which a chain write relevant to this mint is known to
  /// have landed — the user's own confirmed txs (via `TxLandedSlots`) and
  /// server invalidations' triggering-tx slots, fed in by
  /// [ArtworkChainActionLanded]. An `absent` read with a view slot older than
  /// this floor predates a known write and must not clear state. Reset on
  /// load.
  int _chainFloorSlot = 0;

  /// Fold every pending optimistic mutation over [base]. Applied last
  /// on every emit path so nothing a refresh/reconcile returns reverts a
  /// just-confirmed action before its journal entry self-drops.
  ArtworkDetails _applyJournal(ArtworkDetails base) {
    var out = base;
    for (final entry in _journal) {
      out = entry.apply(out);
    }
    return out;
  }

  /// Record an optimistic mutation and bump the reconcile epoch + grace clock
  /// De-dups on [signature] so a re-emitted success can't stack a
  /// second copy of the same action.
  void _journalAdd(
    String signature,
    ArtworkDetails Function(ArtworkDetails) apply,
    bool Function(ArtworkDetails) isSatisfied,
  ) {
    if (signature.isNotEmpty) {
      _journal.removeWhere((e) => e.signature == signature);
    }
    _journal.add(
      _PendingMutation(
        signature: signature,
        apply: apply,
        isSatisfied: isSatisfied,
      ),
    );
    _reconcileEpoch++;
    _lastLocalActionAt = DateTime.now();
  }

  /// True when we are inside the post-local-action grace window.
  bool get _inLocalActionGrace {
    final at = _lastLocalActionAt;
    return at != null && DateTime.now().difference(at) < _localActionGrace;
  }

  /// Record a landed chain write's slot as the new floor (see
  /// [_chainFloorSlot]). Bookkeeping only — no state emit.
  void _onChainActionLanded(
    ArtworkChainActionLanded event,
    Emitter<ArtworkState> emit,
  ) {
    if (event.slot > _chainFloorSlot) _chainFloorSlot = event.slot;
  }

  /// Whether an `absent` cold read may clear the listing side, given the
  /// socket presence evidence (see [_listingPresence]) and the chain floor
  /// (see [_chainFloorSlot]). True when the read's [viewSlot] proves the
  /// absence postdates both any matching evidence's write slot AND the floor
  /// — the account really was closed after everything we know about. A null
  /// [viewSlot] (legacy backend / no envelope) cannot be ordered, so matching
  /// evidence suppresses it and only the floor-agnostic legacy rules apply.
  bool _absentOutranksListingEvidence(ArtworkDetails a, int? viewSlot) {
    if (viewSlot != null && viewSlot < _chainFloorSlot) return false;
    final evidence = _listingPresence;
    if (evidence == null) return true;
    final matches =
        evidence.pubkey == a.buyNowMetadata?.listingAccount ||
        evidence.pubkey == _derivedListingPda;
    if (!matches) return true;
    return viewSlot != null && viewSlot >= evidence.slot;
  }

  /// Auction-side counterpart of [_absentOutranksListingEvidence].
  bool _absentOutranksAuctionEvidence(ArtworkDetails a, int? viewSlot) {
    if (viewSlot != null && viewSlot < _chainFloorSlot) return false;
    final evidence = _auctionPresence;
    if (evidence == null) return true;
    final matches =
        evidence.pubkey == a.auctionMetadata?.auctionAccount ||
        evidence.pubkey == _derivedAuctionConfigPda;
    if (!matches) return true;
    return viewSlot != null && viewSlot >= evidence.slot;
  }

  Future<void> _onLoad(ArtworkLoad event, Emitter<ArtworkState> emit) async {
    _currentMintAccount = event.mintAccount;
    _revision = 0;
    _auctionOverlay = null;
    _derivedListingPda = null;
    _derivedAuctionConfigPda = null;
    _journal.clear();
    _reconcileEpoch++;
    _lastLocalActionAt = null;
    _listingPresence = null;
    _auctionPresence = null;
    _chainFloorSlot = 0;
    emit(const ArtworkState.loading());

    // Subscribe-first: derive the canonical Listing / AuctionConfig
    // PDAs and open their `/ws/accounts` subscriptions BEFORE the byMint fetch,
    // so a bid / list / cancel that lands during the fetch isn't dropped in the
    // gap (neither socket replays). The post-fetch prime + existence-reconcile
    // remain the backstop that catches up whatever changed before we loaded.
    unawaited(_subscribeDerivedPdasEarly(event.mintAccount));

    final result = await Result.guard(
      () => _repository.getArtworkDetail(event.mintAccount),
    );
    switch (result) {
      case ResultSuccess(:final value):
        debugPrint(
          '[LIST-DEBUG] ArtworkBloc LOAD byMint listingType='
          '${value.listingType} mint=${event.mintAccount} '
          '@${DateTime.now().toIso8601String()}',
        );
        final isLiked = _authService.isLiked(
          event.mintAccount,
          ContentType.nft,
        );
        final loaded = _applyJournal(value.copyWith(isLiked: isLiked));
        emit(ArtworkState.loaded(artwork: loaded, revision: _revision));
        _syncLiveOverlay(value);
        unawaited(_reconcileExistence(loaded));
      case ResultFailure(:final error):
        emit(
          ArtworkState.error(
            message: 'Failed to load artwork: ${error.message}',
          ),
        );
    }
  }

  Future<void> _onRefresh(
    ArtworkRefresh event,
    Emitter<ArtworkState> emit,
  ) async {
    if (_currentMintAccount == null) return;

    final currentState = state;

    final result = await Result.guard(
      () => _repository.getArtworkDetail(_currentMintAccount!),
    );
    switch (result) {
      case ResultSuccess(:final value):
        debugPrint(
          '[LIST-DEBUG] ArtworkBloc refresh byMint listingType='
          '${value.listingType} mint=$_currentMintAccount '
          '@${DateTime.now().toIso8601String()}',
        );
        final isLiked = _authService.isLiked(
          _currentMintAccount!,
          ContentType.nft,
        );
        _revision++;
        // Self-drop any journaled optimistic mutation the fresh byMint payload
        // now reflects — the overlay is redundant once server truth
        // agrees. Whatever is still pending is re-applied so a lagging refresh
        // (byMint not yet caught up past checkEntry) can't revert it.
        _journal.removeWhere((e) => e.isSatisfied(value));
        final refreshed = _applyJournal(
          _withAuctionOverlay(value.copyWith(isLiked: isLiked)),
        );
        emit(ArtworkState.loaded(artwork: refreshed, revision: _revision));
        // Re-prime the RPC-backed snapshot on auctions: the byMint payload
        // lags the chain on `currentBidder` right after a bid (the very
        // reason this overlay exists), and the WS push is not guaranteed to
        // have landed by the time a post-bid refresh fires. Priming here is
        // the deterministic backstop that makes the refresh reflect the bid
        // the user just placed — e.g. flipping the bid sheet to "You are the
        // highest bidder". No-op for non-auction artworks and closed
        // auctions (snapshot returns null).
        _syncLiveOverlay(value);
        unawaited(_reconcileExistence(refreshed));
      case ResultFailure(:final error):
        // On refresh error, keep current state if loaded
        if (currentState is ArtworkLoaded) {
          emit(currentState);
        } else {
          emit(
            ArtworkState.error(message: 'Failed to refresh: ${error.message}'),
          );
        }
    }
  }

  Future<void> _onToggleLike(
    ArtworkToggleLike event,
    Emitter<ArtworkState> emit,
  ) async {
    final currentState = state;
    if (currentState is! ArtworkLoaded) return;

    final wasLiked = currentState.artwork.isLiked;
    final previousCount = currentState.artwork.likeCount;

    // Optimistic update
    final optimisticArtwork = currentState.artwork.copyWith(
      isLiked: !wasLiked,
      likeCount: wasLiked ? previousCount - 1 : previousCount + 1,
    );
    emit(ArtworkState.loaded(artwork: optimisticArtwork, revision: _revision));

    try {
      if (wasLiked) {
        await _repository.unlikeArtwork(currentState.artwork.mintAccount);
      } else {
        await _repository.likeArtwork(currentState.artwork.mintAccount);
      }
    } catch (e) {
      debugPrint('[ArtworkBloc] Like toggle failed, reverting: $e');
      // Revert on error
      final reverted = currentState.artwork.copyWith(
        isLiked: wasLiked,
        likeCount: previousCount,
      );
      emit(ArtworkState.loaded(artwork: reverted, revision: _revision));
      // Reverting in silence reads as "the tap didn't register" — the webapp
      // raises "Failed to like" / "Failed to unlike" here and so do we.
      _transientErrors.add(wasLiked ? 'Failed to unlike' : 'Failed to like');
    }
  }

  void _onSetHidden(ArtworkSetHidden event, Emitter<ArtworkState> emit) {
    final currentState = state;
    if (currentState is! ArtworkLoaded) return;
    if (currentState.artwork.isHidden == event.isHidden) return;
    emit(
      ArtworkState.loaded(
        artwork: currentState.artwork.copyWith(isHidden: event.isHidden),
        revision: _revision,
      ),
    );
  }

  void _onOptimisticListingUpdate(
    ArtworkOptimisticListingUpdate event,
    Emitter<ArtworkState> emit,
  ) {
    final currentState = state;
    if (currentState is! ArtworkLoaded) return;
    if (event.cancelled) {
      // Cancel listing → unlisted. Journaled so a stale refresh can't bounce it
      // back to "Update listing"; self-drops once byMint reads unlisted.
      _journalAdd(
        event.signature,
        (a) => a.copyWith(
          listingType: ListingType.unlisted,
          buyNowMetadata: null,
          price: null,
        ),
        (v) => v.listingType == ListingType.unlisted,
      );
    } else {
      final newPrice = event.newPriceRaw;
      if (newPrice == null) return;
      // Update price. [newPrice] is a raw on-chain amount (no display
      // round-trip), so it works for SOL and non-9-decimal mints alike.
      _journalAdd(
        event.signature,
        (a) => a.copyWith(
          price: newPrice,
          buyNowMetadata: a.buyNowMetadata?.copyWith(amount: newPrice),
        ),
        (v) => v.buyNowMetadata?.amount == newPrice,
      );
    }
    emit(
      ArtworkState.loaded(
        artwork: _applyJournal(currentState.artwork),
        revision: _revision,
      ),
    );
  }

  void _onOptimisticClaimOwnership(
    ArtworkOptimisticClaimOwnership event,
    Emitter<ArtworkState> emit,
  ) {
    final current = state;
    if (current is! ArtworkLoaded) return;
    // The connected wallet just took possession of the NFT (auction winner
    // claimed, seller reclaimed a no-bid auction, or a 1/1 buy). Flip to owner
    // + unlisted so the resolver routes to the "List artwork" sheet
    // immediately. Drop the cached auction overlay so a lagging byMint refresh
    // can't re-apply the stale bid and bounce back to the claim sheet.
    // Journaled so the flip survives every refresh/reconcile until
    // byMint reports the new owner AND an unlisted state — dropping earlier
    // (owner updated but listing not yet cleared) would let the sold listing
    // resurface. Revision is preserved — not an indexer refresh, so the
    // History / Offers sections must not re-mount.
    _auctionOverlay = null;
    final owner = event.owner;
    _journalAdd(
      event.signature,
      (a) => a.copyWith(
        ownerAddress: owner,
        ownerAddresses: [owner],
        listingType: ListingType.unlisted,
        auctionMetadata: null,
        buyNowMetadata: null,
        price: null,
      ),
      (v) =>
          (v.ownerAddress == owner || v.ownerAddresses.contains(owner)) &&
          v.listingType == ListingType.unlisted,
    );
    emit(
      ArtworkState.loaded(
        artwork: _applyJournal(current.artwork),
        revision: _revision,
      ),
    );
  }

  void _onOptimisticRelinquishOwnership(
    ArtworkOptimisticRelinquishOwnership event,
    Emitter<ArtworkState> emit,
  ) {
    final current = state;
    if (current is! ArtworkLoaded) return;
    // The seller just settled a won auction (or accepted an offer): the NFT
    // transfers to the buyer, so the connected (seller) wallet is now a plain
    // viewer of an unlisted artwork — the resolver routes that to the "Make
    // offer" sheet. Hand ownership to the new owner and drop the auction/listing
    // + cached overlay. Journaled so a lagging byMint refresh can't
    // bounce it back to the settle sheet; self-drops once byMint reports the new
    // owner + unlisted. Revision is preserved — not an indexer refresh.
    _auctionOverlay = null;
    final newOwner = event.newOwner;
    _journalAdd(
      event.signature,
      (a) => a.copyWith(
        ownerAddress: newOwner,
        ownerAddresses: [newOwner],
        listingType: ListingType.unlisted,
        auctionMetadata: null,
        buyNowMetadata: null,
        price: null,
      ),
      (v) =>
          (v.ownerAddress == newOwner || v.ownerAddresses.contains(newOwner)) &&
          v.listingType == ListingType.unlisted,
    );
    emit(
      ArtworkState.loaded(
        artwork: _applyJournal(current.artwork),
        revision: _revision,
      ),
    );
  }

  // ── Live on-chain overlay (reconciliation) ───────────────────────────────
  //
  // The indexed `/byMint` payload can lag the chain — most visibly right after
  // the user places a bid. We reconcile by overlaying authoritative on-chain
  // state on top of it (on-chain wins), fed by two sources:
  //   1. `/v2/ws/accounts` pushes — the listener writes the decoded account the
  //      instant it changes, covering this user's bid AND other bidders'.
  //   2. a `GET /v2/auctions/:mint` snapshot primed on each load/refresh — an
  //      RPC-backed read that also carries `bidCount`, as a deterministic
  //      backstop independent of the indexer or the listener fan-out.
  // This mirrors the reference web client's `resolvedNftRender` overlay, but consumes the
  // backend's pre-parsed account stream instead of a client RPC subscription.

  /// Reconcile subscriptions + snapshot to the just-loaded [value]. Set
  /// [prime] false on refreshes — the byMint payload and the live WS push
  /// already cover the bid state, so a fresh snapshot would only duplicate it.
  void _syncLiveOverlay(ArtworkDetails value, {bool prime = true}) {
    _syncAccountSubscriptions(value);
    if (!prime) return;
    final mint = value.auctionMetadata != null ? value.mintAccount : null;
    if (mint != null) {
      unawaited(_primeLiveAuction(mint));
    }
  }

  /// Open/close `/v2/ws/accounts` subscriptions so we're watching exactly the
  /// auction-config + listing PDAs the current artwork exposes.
  void _syncAccountSubscriptions(ArtworkDetails value) {
    final keys = <String>{};
    final auctionAccount = value.auctionMetadata?.auctionAccount;
    if (auctionAccount != null && auctionAccount.isNotEmpty) {
      keys.add(auctionAccount);
    }
    final listingAccount = value.buyNowMetadata?.listingAccount;
    if (listingAccount != null && listingAccount.isNotEmpty) {
      keys.add(listingAccount);
    }
    // Also watch the client-derived PDAs (once known) so a listing/auction the
    // byMint payload omitted — because the indexer never saw it — still gets a
    // live frame the instant it changes on chain.
    final derivedListing = _derivedListingPda;
    if (derivedListing != null && derivedListing.isNotEmpty) {
      keys.add(derivedListing);
    }
    final derivedAuction = _derivedAuctionConfigPda;
    if (derivedAuction != null && derivedAuction.isNotEmpty) {
      keys.add(derivedAuction);
    }

    _resubscribe(keys);
  }

  /// (Re)open `/ws/accounts` subscriptions so we watch exactly [keys], reusing
  /// the existing subscriptions when the set is unchanged (so a resubscribe
  /// doesn't drop frames in the cancel→reopen gap).
  void _resubscribe(Set<String> keys) {
    if (setEquals(keys, _watchedAccounts)) return;
    debugPrint(
      '[LIST-DEBUG] ArtworkBloc account-subs RESUBSCRIBE '
      'old=$_watchedAccounts new=$keys @${DateTime.now().toIso8601String()}',
    );
    _cancelAccountSubscriptions();
    _watchedAccounts = keys;
    for (final key in keys) {
      _accountSubs.add(
        _accountRealtime.watchAccount(key).listen(_onAccountFrame),
      );
    }
  }

  /// Subscribe-first: derive the canonical Listing / AuctionConfig
  /// PDAs for [mint] and open their account subscriptions before the byMint
  /// fetch resolves, so an on-chain change during the fetch isn't dropped.
  /// Best-effort — derivation failure just leaves the post-fetch sync + prime
  /// to open them.
  Future<void> _subscribeDerivedPdasEarly(String mint) async {
    if (mint.isEmpty) return;
    try {
      final listingPda = await _marketAccounts.deriveListingPda(mint);
      final auctionPda = await _marketAccounts.deriveAuctionConfigPda(mint);
      if (isClosed || _currentMintAccount != mint) return;
      _derivedListingPda = listingPda;
      _derivedAuctionConfigPda = auctionPda;
      _resubscribe({
        if (listingPda.isNotEmpty) listingPda,
        if (auctionPda.isNotEmpty) auctionPda,
      });
    } catch (e) {
      debugPrint('[ArtworkBloc] early PDA subscribe failed for $mint: $e');
    }
  }

  void _cancelAccountSubscriptions() {
    for (final sub in _accountSubs) {
      sub.cancel();
    }
    _accountSubs.clear();
  }

  void _onAccountFrame(AccountUpdate update) {
    if (isClosed) return;
    if (update.isClosed) {
      // Account-close tombstone (auction settled / listing sold or cancelled).
      // The account is authoritatively gone — rescind its presence evidence
      // FIRST so the reconcile-driven clear below isn't suppressed by it.
      if (update.pubkey == _listingPresence?.pubkey) {
        _listingPresence = null;
      }
      if (update.pubkey == _auctionPresence?.pubkey) {
        _auctionPresence = null;
      }
      // Match the closed pubkey to the account we watch and clear it instantly
      // off the push — no on-chain re-read.
      _onAccountClosed(update.pubkey);
      return;
    }
    if (update.isSyntheticReconnect) {
      // The WS dropped and resumed; a bid/listing change may have landed
      // during the outage — including a close tombstone we never received, so
      // the presence evidence is no longer trustworthy. Drop it and let the
      // re-reads below decide. Re-prime the snapshot AND re-read the on-chain
      // accounts so both the per-field overlay and existence (synth/clear)
      // state catch up instead of waiting for the next write or a manual
      // refresh.
      _listingPresence = null;
      _auctionPresence = null;
      final mint = _currentMintAccount;
      if (mint != null) unawaited(_primeLiveAuction(mint));
      final cur = state;
      if (cur is ArtworkLoaded) unawaited(_reconcileExistence(cur.artwork));
      return;
    }
    if (update.isAuctionConfig) {
      // Decoded live frame — record on-chain presence at its write slot so an
      // absent cold read with an older view can't clear this side (see
      // [_auctionPresence]).
      _auctionPresence = (pubkey: update.pubkey, slot: update.slot);
      add(
        ArtworkEvent.auctionLiveUpdate(
          auctionAccount: update.pubkey,
          // Raw atomic units in the auction's bidMint — the same unit the
          // indexed byMint value and every price widget expect (a display
          // widget divides by the token's decimals). No SOL-specific scaling.
          currentBidAmount: update.highestBidAmount?.toDouble(),
          currentBidder: update.highestBidder,
          endsAt: update.endTime,
        ),
      );
    } else if (update.isListing) {
      // Decoded live frame — record on-chain presence at its write slot so an
      // absent cold read with an older view can't clear this side (see
      // [_listingPresence]).
      _listingPresence = (pubkey: update.pubkey, slot: update.slot);
      add(
        ArtworkEvent.listingLiveUpdate(
          listingAccount: update.pubkey,
          price: update.listingPrice?.toDouble(),
          endsAt: update.listingEndTime,
        ),
      );
    } else {
      // Neither watched discriminant — surface the drop so an accountType
      // rename/casing drift between the backend and these literals is visible
      // rather than silently freezing the overlay.
      debugPrint(
        '[ArtworkBloc] dropping unhandled account frame '
        '"${update.accountType}" for ${update.pubkey}',
      );
    }
  }

  /// A watched on-chain account was closed (auction settled, listing sold or
  /// cancelled) — the listener pushes a `{ closed: true }` tombstone with no
  /// decoded fields, so we identify which side closed by matching [pubkey]
  /// against the accounts we subscribe to: the indexed auction-config / listing
  /// accounts and their client-derived PDAs. (We only ever watch those two PDAs
  /// for this mint — offer accounts aren't subscribed here, so an offer
  /// tombstone never reaches this handler.) The matched side is cleared via the
  /// existing [ArtworkExistenceReconcile] `absent` path so the listingType
  /// guards and `_auctionOverlay` reset stay in one place; the unmatched side
  /// is left `unknown` (no-op).
  void _onAccountClosed(String pubkey) {
    final cur = state;
    if (cur is! ArtworkLoaded) return;
    final artwork = cur.artwork;

    final isAuction =
        pubkey == artwork.auctionMetadata?.auctionAccount ||
        pubkey == _derivedAuctionConfigPda;
    final isListing =
        pubkey == artwork.buyNowMetadata?.listingAccount ||
        pubkey == _derivedListingPda;

    if (!isAuction && !isListing) {
      // A tombstone for a pubkey we don't track — a stale subscription or a
      // key mismatch. Surface it rather than blindly clearing a live listing.
      debugPrint(
        '[ArtworkBloc] dropping close tombstone for unmatched pubkey $pubkey',
      );
      return;
    }

    debugPrint(
      '[LIST-DEBUG] ArtworkBloc account-closed pubkey=$pubkey '
      'isAuction=$isAuction isListing=$isListing '
      '@${DateTime.now().toIso8601String()}',
    );

    add(
      ArtworkEvent.existenceReconcile(
        listingStatus: isListing
            ? OnChainReadStatus.absent
            : OnChainReadStatus.unknown,
        auctionStatus: isAuction
            ? OnChainReadStatus.absent
            : OnChainReadStatus.unknown,
      ),
    );
  }

  /// Prime the overlay with a one-shot RPC-backed auction snapshot.
  Future<void> _primeLiveAuction(String mint) async {
    final state = await _auctionLive.getState(mint);
    if (state == null || isClosed || _currentMintAccount != mint) {
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc prime-snapshot SKIP mint=$mint '
        'reason=${state == null ? 'null-snapshot' : 'closed/stale-mint'} '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }
    add(
      ArtworkEvent.auctionLiveUpdate(
        auctionAccount: state.auctionAccount,
        // Raw atomic units in the auction's bidMint (see [_onAccountFrame]) —
        // the snapshot returns the on-chain amount; no SOL-specific scaling.
        currentBidAmount: state.currentBidAmount?.toDouble(),
        currentBidder: state.currentBidder,
        endsAt: state.endsAt,
        bidCount: state.bidCount,
      ),
    );
  }

  /// Monotonically overlay live on-chain auction fields onto [base]: bids only
  /// rise, end times only extend. A WS bid frame carries no [bidCount], so once
  /// a bid (amount + bidder) is applied we synthesize "has bids" (>= 1) to keep
  /// the `bidCount > 0` display gate consistent with the bid we just merged.
  AuctionMetadata _mergeAuctionOverlay(
    AuctionMetadata base, {
    double? currentBidAmount,
    String? currentBidder,
    DateTime? endsAt,
    int? bidCount,
  }) {
    final existingAmount = base.currentBidAmount;
    final takeBid =
        currentBidAmount != null &&
        (existingAmount == null || currentBidAmount > existingAmount);
    final newAmount = takeBid ? currentBidAmount : existingAmount;
    final newBidder = takeBid
        ? (currentBidder ?? base.currentBidder)
        : base.currentBidder;
    final newEndsAt =
        (endsAt != null &&
            (base.endsAt == null || endsAt.isAfter(base.endsAt!)))
        ? endsAt
        : base.endsAt;
    var newBidCount = (bidCount != null && bidCount > base.bidCount)
        ? bidCount
        : base.bidCount;
    if (newBidCount == 0 && newAmount != null && newBidder != null) {
      newBidCount = 1;
    }
    return base.copyWith(
      currentBidAmount: newAmount,
      currentBidder: newBidder,
      endsAt: newEndsAt,
      bidCount: newBidCount,
    );
  }

  /// Re-apply the cached live auction overlay onto a freshly-loaded [value]
  /// (same auction account only), so a lagging byMint refresh keeps the live
  /// bid instead of momentarily snapping back to the indexed value.
  ArtworkDetails _withAuctionOverlay(ArtworkDetails value) {
    final overlay = _auctionOverlay;
    final auction = value.auctionMetadata;
    if (overlay == null ||
        auction == null ||
        auction.auctionAccount != overlay.account) {
      return value;
    }
    return value.copyWith(
      auctionMetadata: _mergeAuctionOverlay(
        auction,
        currentBidAmount: overlay.currentBidAmount,
        currentBidder: overlay.currentBidder,
        endsAt: overlay.endsAt,
        bidCount: overlay.bidCount,
      ),
    );
  }

  void _onAuctionLiveUpdate(
    ArtworkAuctionLiveUpdate event,
    Emitter<ArtworkState> emit,
  ) {
    final current = state;
    if (current is! ArtworkLoaded) {
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc auction-live-update IGNORED (not loaded) '
        'account=${event.auctionAccount} @${DateTime.now().toIso8601String()}',
      );
      return;
    }
    final auction = current.artwork.auctionMetadata;
    if (auction == null) {
      // A live on-chain auction frame arrived but the indexer never gave us
      // auction metadata: rather than drop the frame, trigger an
      // authoritative existence read so the missed auction is synthesized into
      // a CTA. Gated to synth-eligible 1/1s; the reconcile self-gates too.
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc auction-live-update no-metadata → reconcile '
        'account=${event.auctionAccount} @${DateTime.now().toIso8601String()}',
      );
      if (_eligibleForExistenceRecon(current.artwork)) {
        unawaited(_reconcileExistence(current.artwork));
      }
      return;
    }
    // Ignore frames for a stale auction account (e.g. after a relist).
    final account = auction.auctionAccount;
    if (account != null &&
        account.isNotEmpty &&
        account != event.auctionAccount) {
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc auction-live-update IGNORED (stale account '
        'have=$account got=${event.auctionAccount}) '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }

    final merged = _mergeAuctionOverlay(
      auction,
      currentBidAmount: event.currentBidAmount,
      currentBidder: event.currentBidder,
      endsAt: event.endsAt,
      bidCount: event.bidCount,
    );
    // Cache even when the merge is a no-op vs the current overlay, so a later
    // byMint refresh still re-applies the on-chain bid.
    _auctionOverlay = (
      account: event.auctionAccount,
      currentBidAmount: merged.currentBidAmount,
      currentBidder: merged.currentBidder,
      endsAt: merged.endsAt,
      bidCount: merged.bidCount,
    );
    if (merged == auction) return;

    emit(
      ArtworkState.loaded(
        artwork: current.artwork.copyWith(auctionMetadata: merged),
        revision: _revision,
      ),
    );
  }

  void _onListingLiveUpdate(
    ArtworkListingLiveUpdate event,
    Emitter<ArtworkState> emit,
  ) {
    final current = state;
    if (current is! ArtworkLoaded) return;
    final listing = current.artwork.buyNowMetadata;
    if (listing == null) {
      // A live on-chain listing frame with no indexed listing metadata:
      // synthesize via an authoritative existence read instead of dropping the
      // frame, so an indexer-missed listing appears without a manual pull.
      if (_eligibleForExistenceRecon(current.artwork)) {
        unawaited(_reconcileExistence(current.artwork));
      }
      return;
    }
    final account = listing.listingAccount;
    if (account != null &&
        account.isNotEmpty &&
        account != event.listingAccount) {
      return;
    }

    // A 0 price is a transitional/cleared account state (e.g. mid-cancel or
    // relist), not a real "free" listing — keep the indexed price rather than
    // flashing "0".
    final eventPrice = event.price;
    final newPrice = (eventPrice != null && eventPrice > 0)
        ? eventPrice
        : listing.amount;
    final newEndsAt = event.endsAt ?? listing.endsAt;
    final merged = listing.copyWith(amount: newPrice, endsAt: newEndsAt);
    debugPrint(
      '[LIST-DEBUG] ArtworkBloc listing-live-update account=${event.listingAccount} '
      'in(price=${event.price} endsAt=${event.endsAt}) '
      'was(price=${listing.amount}) merged(price=$newPrice) '
      'changed=${merged != listing} @${DateTime.now().toIso8601String()}',
    );
    if (merged == listing) return;

    emit(
      ArtworkState.loaded(
        artwork: current.artwork.copyWith(
          price: newPrice,
          buyNowMetadata: merged,
        ),
        revision: _revision,
      ),
    );
  }

  // ── On-chain existence reconciliation (synthesize / clear) ───────────────
  //
  // The byMint indexer can be wrong about *whether* an artwork is listed at
  // all — it can miss a fresh listing/auction, or keep showing one after it's
  // cancelled/sold on chain. We treat the chain as source of truth by reading
  // the canonical Listing / AuctionConfig PDAs (derived client-side from the
  // mint) directly: a present account the indexer missed is synthesized into a
  // CTA; an authoritatively-absent account (404) the indexer still shows is
  // cleared. SYNTHESIZE/drift is scoped to plain 1/1s (see
  // [_eligibleForExistenceRecon]) — editions have a multi-print lifecycle this
  // present/absent signal can't safely model. CLEAR is broader (see
  // [_shouldReconcileExistence]): a *listed* edition's Listing PDA can still go
  // stale, and a close is unambiguous (the shared `["listing", mint]` PDA
  // closes only on delist or a 1/1 buy, never on a single edition-print buy).

  /// Whether [a] is a plain 1/1 whose listing/auction existence we fully
  /// reconcile (synthesize missed + drift + clear). Excludes editions, raffles,
  /// grouped sales, and external-marketplace listing types.
  bool _eligibleForExistenceRecon(ArtworkDetails a) {
    if (a.supplyType != SupplyType.oneOfOne) return false;
    if (a.isMasterEdition == true) return false;
    if (a.raffleMetadata != null) return false;
    if (a.groupedSale != null) return false;
    return a.listingType == ListingType.unlisted ||
        a.listingType == ListingType.buyNow ||
        a.listingType == ListingType.auction;
  }

  /// Whether to READ the chain for [a] at all. Supersets
  /// [_eligibleForExistenceRecon] with *listed* editions so a stale edition
  /// listing/auction still clears (the handler keeps synth/drift gated to
  /// 1/1s). Scoped to an already-listed state: we never read unlisted editions
  /// (nothing to verify — we don't synthesize them) and never risk clobbering a
  /// fresh list, since a brand-new listing only flips to `buyNow`/`auction`
  /// AFTER the indexer ack (by which point the on-chain account exists, so no
  /// false 404). Raffles / grouped sales are excluded — they have no canonical
  /// `["listing", mint]` PDA, so a 404 there is meaningless, not a delist.
  bool _shouldReconcileExistence(ArtworkDetails a) {
    if (_eligibleForExistenceRecon(a)) return true;
    if (a.raffleMetadata != null || a.groupedSale != null) return false;
    return a.listingType == ListingType.buyNow ||
        a.listingType == ListingType.auction;
  }

  /// Read the on-chain Listing / AuctionConfig accounts for [value] and
  /// dispatch an [ArtworkExistenceReconcile] with the pre-extracted chain
  /// state. Builds listing metadata whenever the listing is present (the
  /// handler decides drift-vs-synth) but auction metadata only when the
  /// indexer is unaware (known auctions reconcile via the [_primeLiveAuction]
  /// path), so the two auction sources never fight.
  Future<void> _reconcileExistence(ArtworkDetails value) async {
    if (!_shouldReconcileExistence(value)) return;
    final mint = value.mintAccount;
    if (mint.isEmpty) return;

    // Capture the reconcile epoch before the async reads. If an
    // optimistic write bumps it while the reads are in flight, the result is
    // stale relative to the user's latest action — drop it rather than let it
    // land on top. Subscriptions are still opened below (epoch-independent).
    final epoch = _reconcileEpoch;

    final listingRead = await _marketAccounts.readListing(mint);
    final auctionRead = await _marketAccounts.readAuctionConfig(mint);
    if (isClosed || _currentMintAccount != mint) return;

    // Subscribe to the derived PDAs regardless of epoch — watching the right
    // accounts is always safe and doesn't mutate resolved state.
    _derivedListingPda = listingRead.pda;
    _derivedAuctionConfigPda = auctionRead.pda;
    final curForSubs = state;
    if (curForSubs is ArtworkLoaded) {
      _syncAccountSubscriptions(curForSubs.artwork);
    }

    if (_reconcileEpoch != epoch) {
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc reconcile-existence DROPPED (epoch '
        '$epoch→$_reconcileEpoch, raced an optimistic write) mint=$mint '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }

    debugPrint(
      '[LIST-DEBUG] ArtworkBloc reconcile-existence read mint=$mint '
      'indexedListingType=${value.listingType} '
      'listingStatus=${listingRead.status} listingPda=${listingRead.pda} '
      'auctionStatus=${auctionRead.status} auctionPda=${auctionRead.pda} '
      '@${DateTime.now().toIso8601String()}',
    );

    // ── Listing ──
    var listingStatus = listingRead.status;
    ListingReconcileData? listingData;
    if (listingStatus == OnChainReadStatus.present) {
      final acct = listingRead.account!;
      if (acct.listingEditionsLimit != 0 || acct.listingBuyerSetsPrice) {
        // A master-edition (multi-print) or buyer-sets-price listing — not a
        // plain fixed-price 1/1. Treat as undetermined so we neither synth a
        // misleading "Buy" CTA nor clear a real edition listing.
        listingStatus = OnChainReadStatus.unknown;
      } else {
        listingData = ListingReconcileData(
          currency: acct.listingCurrencyMint,
          metadata: BuyNowMetadata(
            amount: acct.listingPrice?.toDouble(),
            currencyMint: acct.listingCurrencyMint,
            listingAccount: acct.pubkey,
            startsAt: acct.listingStartTime,
            endsAt: acct.listingEndTime,
          ),
        );
      }
    }

    // ── Auction (synthesize only) ──
    final auctionStatus = auctionRead.status;
    AuctionReconcileData? auctionData;
    if (auctionStatus == OnChainReadStatus.present &&
        value.auctionMetadata == null) {
      final acct = auctionRead.account!;
      final bid = acct.highestBidAmount?.toDouble();
      auctionData = AuctionReconcileData(
        currency: acct.bidMint,
        metadata: AuctionMetadata(
          auctionAccount: acct.pubkey,
          seller: acct.seller,
          bidMint: acct.bidMint,
          reservePrice: acct.reservePrice?.toDouble(),
          currentBidAmount: bid,
          currentBidder: acct.highestBidder,
          minBidIncrement: acct.minBidIncrement,
          minBidIncrementBps: acct.minBidIncrementBps,
          timeExtPeriod: acct.timeExtPeriod,
          timeExtDelta: acct.timeExtDelta,
          duration: acct.auctionDuration,
          mintAccount: mint,
          startsAt: acct.startTime,
          endsAt: acct.endTime,
          // A WS/account read carries no bidCount; synthesize "has bids" so the
          // `bidCount > 0` display gate matches the bid we just read.
          bidCount: bid != null ? 1 : 0,
        ),
      );
    }

    add(
      ArtworkEvent.existenceReconcile(
        listingStatus: listingStatus,
        auctionStatus: auctionStatus,
        listing: listingData,
        auction: auctionData,
        listingViewSlot: listingRead.viewSlot,
        auctionViewSlot: auctionRead.viewSlot,
      ),
    );
  }

  void _onExistenceReconcile(
    ArtworkExistenceReconcile event,
    Emitter<ArtworkState> emit,
  ) {
    final current = state;
    if (current is! ArtworkLoaded) return;
    var artwork = current.artwork;
    // Re-guard against the live state: a frame/optimistic update may have
    // changed eligibility (e.g. ownership claim) since the read was issued.
    // Eligibility gates SYNTHESIZE/drift ONLY — we can't safely *infer* a
    // non-1/1 (edition) listing from a read (multi-print supply, per-buyer
    // counts). A CLEAR is always safe: a closed Listing/AuctionConfig PDA is
    // gone for editions and 1/1s alike — an edition Listing closes only on
    // delist or a 1/1 buy, never on a single edition-print purchase (those
    // bump a separate BuyEditionHistory account) — so close-driven `absent`
    // clears run regardless of eligibility.
    final eligible = _eligibleForExistenceRecon(artwork);
    // Grace window: within [_localActionGrace] of an optimistic write, the RPC
    // is expected to lag the user's own change, so suppress `absent` clears and
    // contradicting `present` synthesizes (a missing/lingering account there is
    // lag, not truth). Price/end drift on an already-known listing is allowed —
    // it doesn't contradict the action's direction.
    final inGrace = _inLocalActionGrace;
    var changed = false;

    // ── Listing ──
    switch (event.listingStatus) {
      case OnChainReadStatus.present:
        if (!eligible) break;
        final data = event.listing;
        final chain = data?.metadata;
        if (chain != null) {
          if (artwork.listingType == ListingType.buyNow) {
            // Drift: reconcile price / end on the known listing (same account).
            final base = artwork.buyNowMetadata;
            final account = base?.listingAccount;
            if (base != null &&
                (account == null ||
                    account.isEmpty ||
                    account == chain.listingAccount)) {
              final price = (chain.amount != null && chain.amount! > 0)
                  ? chain.amount!
                  : base.amount;
              final ends = chain.endsAt ?? base.endsAt;
              final merged = base.copyWith(amount: price, endsAt: ends);
              if (merged != base) {
                artwork = artwork.copyWith(
                  price: price,
                  buyNowMetadata: merged,
                );
                changed = true;
              }
            }
          } else if (artwork.listingType == ListingType.unlisted && !inGrace) {
            // Synthesize: the indexer missed a real on-chain listing.
            artwork = artwork.copyWith(
              listingType: ListingType.buyNow,
              buyNowMetadata: chain,
              price: chain.amount,
              currency: data?.currency,
            );
            changed = true;
          }
        }
      case OnChainReadStatus.absent:
        if (artwork.listingType == ListingType.buyNow &&
            !inGrace &&
            _absentOutranksListingEvidence(artwork, event.listingViewSlot)) {
          // Clear: the indexer still shows a listing the chain no longer has.
          artwork = artwork.copyWith(
            listingType: ListingType.unlisted,
            buyNowMetadata: null,
            price: null,
          );
          changed = true;
        }
      case OnChainReadStatus.unknown:
        break;
    }

    // ── Auction ──
    switch (event.auctionStatus) {
      case OnChainReadStatus.present:
        if (!eligible) break;
        final data = event.auction;
        final chain = data?.metadata;
        // Synthesize only — known auctions reconcile via _primeLiveAuction.
        if (chain != null &&
            artwork.listingType == ListingType.unlisted &&
            !inGrace) {
          artwork = artwork.copyWith(
            listingType: ListingType.auction,
            auctionMetadata: chain,
            currency: data?.currency,
          );
          changed = true;
        }
      case OnChainReadStatus.absent:
        if (artwork.listingType == ListingType.auction &&
            !inGrace &&
            _absentOutranksAuctionEvidence(artwork, event.auctionViewSlot)) {
          // Clear: the indexer still shows an auction the chain no longer has.
          // Drop the cached overlay so a lagging byMint refresh can't revive it.
          _auctionOverlay = null;
          artwork = artwork.copyWith(
            listingType: ListingType.unlisted,
            auctionMetadata: null,
            price: null,
          );
          changed = true;
        }
      case OnChainReadStatus.unknown:
        break;
    }

    if (!changed) {
      debugPrint(
        '[LIST-DEBUG] ArtworkBloc existence-reconcile NO-OP '
        'listingStatus=${event.listingStatus} '
        'auctionStatus=${event.auctionStatus} '
        'listingType=${current.artwork.listingType} '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }
    debugPrint(
      '[LIST-DEBUG] ArtworkBloc existence-reconcile APPLIED '
      'listingStatus=${event.listingStatus} '
      'auctionStatus=${event.auctionStatus} '
      'fromType=${current.artwork.listingType} toType=${artwork.listingType} '
      '@${DateTime.now().toIso8601String()}',
    );
    // A journaled optimistic action always wins over reconcile output
    // — re-apply so, e.g., a stale `present` read can't resurrect a just-
    // cancelled listing the grace window didn't already suppress.
    // Existence reconciliation is not an indexer refresh — preserve the
    // revision so the History / Offers paged sections don't re-mount.
    emit(
      ArtworkState.loaded(artwork: _applyJournal(artwork), revision: _revision),
    );
  }

  @override
  Future<void> close() {
    _editedSignalSub?.cancel();
    _hiddenSignalSub?.cancel();
    _cancelAccountSubscriptions();
    unawaited(_transientErrors.close());
    return super.close();
  }
}
