import 'package:mallow_api/mallow_api.dart' show ListingType;

/// Why an accept-offer was refused. Ordered most-specific-first by
/// [acceptOfferRefusal]; each value maps to its own user-facing [message] so a
/// refusal never surfaces as the generic `Request failed (400)`.
enum AcceptOfferRefusal {
  /// The signing wallet is not the asset's on-chain owner.
  notOwner,

  /// The offer was placed by the signing wallet itself.
  ownOffer,

  /// A mallow auction on this asset already carries a bid.
  auctionHasBids,

  /// The asset is listed in a form that has no accept-offer path (auction
  /// without bids, raffle, gumball, airdrop, store, jellybean).
  listingNotAcceptable,

  /// The token is frozen and there is no mallow listing to delist in the same
  /// transaction.
  frozen,
}

extension AcceptOfferRefusalX on AcceptOfferRefusal {
  /// User-facing copy. Reuses the webapp's wording where it has some
  /// (`useAcceptOffer`).
  String get message => switch (this) {
    AcceptOfferRefusal.notOwner => "You don't own this artwork",
    AcceptOfferRefusal.ownOffer => 'Cannot accept your own offer',
    AcceptOfferRefusal.auctionHasBids =>
      'This auction already has a bid — cancel the auction before accepting '
          'an offer',
    AcceptOfferRefusal.listingNotAcceptable =>
      'Offers cannot be accepted on this listing',
    AcceptOfferRefusal.frozen => 'This artwork is frozen',
  };
}

/// Pre-flight eligibility for accepting an offer. Returns `null` when the
/// accept may proceed, otherwise the first refusal that applies.
///
/// Port of the webapp's `canAcceptOffer`
/// (`canAcceptOffer`) merged with the
/// click-time invariants its only caller pairs it with
/// (`useAcceptOffer`) — the button predicate alone does not cover
/// own-offer or frozen.
///
/// **Deliberately not ported:** the `exchangeArtMetadata` branches of
/// `canAcceptOffer`. Its only call site
/// (`useListingState`) never passes that
/// argument, so those branches are dead code in the webapp. Porting them would
/// have made an Exchange-Art auction *with* bids acceptable.
///
/// The backend's accept-offer builder re-checks DAS ownership and that the
/// offer's buyer matches, but checks
/// **neither** [isOwnOffer] nor [isFrozen] — those two are the gaps this
/// closes. [notOwner] is kept anyway so a non-owner gets the reason instead of
/// the backend's opaque 400.
///
/// Every parameter is a definite value: a caller whose on-chain read came back
/// undetermined must pass the permissive value (`isFrozen: false`,
/// `auctionCurrentBidder: null`) so a flaky network cannot manufacture a
/// refusal.
AcceptOfferRefusal? acceptOfferRefusal({
  /// The signing wallet owns the asset on-chain. Webapp:
  /// `userTokenAccountHook.isUserOwned`.
  required bool isUserOwner,

  /// The offer's buyer is the signing wallet.
  required bool isOwnOffer,

  /// Current highest bidder on the mallow auction PDA, or null when there is
  /// no auction / no bid. Webapp: `auctionMetadata.currentBidder`, where
  /// **any** non-null value (including `''`) counts as a real bidder.
  required String? auctionCurrentBidder,
  required ListingType listingType,

  /// The token's on-chain frozen bit.
  required bool isFrozen,

  /// A mallow `Listing` PDA exists for the asset, so the accept tx can delist
  /// and accept in one instruction sequence and the freeze is expected.
  /// Webapp: `isUserOwnedUnfrozen || listing != null`.
  required bool hasMallowListing,
}) {
  if (!isUserOwner) return AcceptOfferRefusal.notOwner;
  if (isOwnOffer) return AcceptOfferRefusal.ownOffer;
  if (auctionCurrentBidder != null) return AcceptOfferRefusal.auctionHasBids;
  if (listingType != ListingType.unlisted &&
      listingType != ListingType.buyNow) {
    return AcceptOfferRefusal.listingNotAcceptable;
  }
  if (isFrozen && !hasMallowListing) return AcceptOfferRefusal.frozen;
  return null;
}
