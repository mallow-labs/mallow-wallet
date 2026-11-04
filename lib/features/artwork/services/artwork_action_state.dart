import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../../core/config/store_build.dart';

import '../../../core/services/token_metadata_service.dart'
    show TokenMetadataStatus;
import '../../../shared/utils/chain.dart'
    show apiOwnerAddress, isEvmOrTezosArtwork;
import '../../../shared/utils/synthetic_master.dart';
import '../../market/services/edition_buy_routing.dart'
    show resolvePrintableMasterEdition;
import '../models/on_chain_asset.dart';
import '../widgets/sheets/artwork_auction_claim_sheet.dart';
import '../widgets/sheets/artwork_raffle_sheet.dart';
import '../widgets/sheets/artwork_unclaimed_raffle_sheet.dart';
import 'artwork_bloc.dart';

export '../widgets/sheets/artwork_auction_claim_sheet.dart'
    show AuctionEndedRole;
export '../widgets/sheets/artwork_raffle_sheet.dart'
    show RaffleGate, RaffleRole, RaffleSubState;
export '../widgets/sheets/artwork_unclaimed_raffle_sheet.dart'
    show UnclaimedRaffleClaim;

/// Discriminated state for the artwork detail screen's persistent
/// bottom-sheet slot. Mirrors the variants in
/// `lib/features/artwork/widgets/sheets/`.
sealed class ArtworkActionState {
  const ArtworkActionState();
}

/// Connect-wallet CTA. The dispatcher chooses [label] based on the
/// underlying listing type so the call to action matches the unlocked
/// behavior.
final class ArtworkConnectWalletAction extends ArtworkActionState {
  const ArtworkConnectWalletAction({required this.label, this.subtitle});
  final String label;
  final String? subtitle;
}

/// Import-wallet CTA: the session holds no wallet that can sign the Solana
/// transaction behind the CTA the artwork would otherwise show. A profile whose
/// only key is Tezos or Ethereum, with its Solana wallets linked watch-only, is
/// the usual case. [action] names what importing unlocks ("buy", "place bid").
final class ArtworkImportWalletAction extends ArtworkActionState {
  const ArtworkImportWalletAction({
    required this.action,
    required this.watchOnly,
  });

  /// Verb phrase for the subtitle, or null when the build hides commerce and
  /// the CTA must not name a paid action.
  final String? action;

  /// The session links a Solana wallet but holds no key for it (as opposed to
  /// linking no Solana wallet at all). Only changes the copy.
  final bool watchOnly;
}

/// Whether the session can sign a Solana transaction — the input that turns a
/// signing CTA into [ArtworkImportWalletAction].
enum ArtworkSolanaSigner {
  /// A signable Solana wallet is in the session, or the session isn't known yet.
  available,

  /// Solana wallets are linked, but every one is watch-only.
  watchOnly,

  /// No Solana wallet in the session at all.
  missing,
}

/// Why the Buy CTA must not be offered, or null when the listing is buyable.
///
/// Mirrors the webapp's `deriveCanBuyNow`'s `isActive` term
/// (`listingStateDerivation`, `useListingState`,
/// `listing`) plus one mobile-only case ([unknownCurrency]).
enum ArtworkBuyBlock {
  /// `buyNowMetadata.startsAt` is still in the future — webapp `hasItemStarted`
  /// is false, so `isActive` is false and Buy is hard-disabled.
  notStarted,

  /// `buyNowMetadata.endsAt` has passed — webapp `hasItemEnded`.
  ended,

  /// The listing currency isn't in the static registry and its DAS metadata is
  /// still in flight or failed, so the sheet is showing a shimmer or
  /// "Unknown token" instead of a price. The invariant: **never signable for
  /// an amount that was never displayed.**
  ///
  /// Applies to every buy path — 1/1, edition and auction alike. Transient by
  /// construction: it clears the moment the lookup lands
  /// (`TokenMetadataService`), and never fires at all for a registry mint.
  unknownCurrency,
}

/// Existing buy sheet — viewer × buyNow × (1/1 ∨ editionPrint).
final class ArtworkBuyAction extends ArtworkActionState {
  const ArtworkBuyAction({
    this.userOwnOffer = false,
    this.block,
    this.canMakeOffer = true,
  });

  final bool canMakeOffer;

  /// True when the connected wallet already has a live offer on this
  /// artwork — toggles the secondary "Make offer" CTA to "Cancel offer".
  final bool userOwnOffer;

  /// Non-null when Buy must render disabled with an explanation.
  final ArtworkBuyBlock? block;
}

/// Buys one ERC-721 or ERC-1155 copy through a fresh OpenSea quote.
final class ArtworkOpenSeaBuyAction extends ArtworkActionState {
  const ArtworkOpenSeaBuyAction({this.block});
  final ArtworkBuyBlock? block;
}

/// Buys the existing asset through a fresh Magic Eden quote.
final class ArtworkMagicEdenBuyAction extends ArtworkActionState {
  const ArtworkMagicEdenBuyAction({this.block});
  final ArtworkBuyBlock? block;
}

/// Edition buy sheet — viewer × buyNow × (limitedEdition ∨ openEdition).
final class ArtworkBuyEditionAction extends ArtworkActionState {
  const ArtworkBuyEditionAction({this.block});

  /// Non-null when "Buy edition" must render disabled with an explanation.
  final ArtworkBuyBlock? block;
}

/// Owner viewing their own unlisted artwork.
///
/// The two affordances are gated separately (they were one flag before, which
/// is how a flagged artwork lost its Send button and a sold-out master kept
/// its List button):
///   * [canSend] — `permissions.canTransfer`, the same predicate the context
///     menu's Transfer row uses.
///   * [canList] — `permissions.canList`, plus the artwork-level listing policy
///     (flagged / sold-out master) the webapp's `deriveCanList` applies.
final class ArtworkOwnerUnlistedAction extends ArtworkActionState {
  const ArtworkOwnerUnlistedAction({
    required this.canList,
    required this.canSend,
    this.canAcceptOffer = true,
  });

  final bool canList;
  final bool canSend;
  final bool canAcceptOffer;
}

/// Owner viewing their own active buy-now listing.
final class ArtworkOwnerListedAction extends ArtworkActionState {
  const ArtworkOwnerListedAction({this.canAcceptOffer = true});
  final bool canAcceptOffer;
}

/// Non-owner viewing an unlisted artwork — make-offer flow.
final class ArtworkUnlistedViewerAction extends ArtworkActionState {
  const ArtworkUnlistedViewerAction({
    this.userOwnOffer = false,
    this.canMakeOffer = true,
  });

  final bool canMakeOffer;

  /// True when the connected wallet already has a live offer on this
  /// artwork — toggles the primary "Make offer" CTA to "Cancel offer".
  final bool userOwnOffer;
}

/// Non-owner viewing an active auction.
final class ArtworkAuctionBidAction extends ArtworkActionState {
  const ArtworkAuctionBidAction({this.unknownCurrency = false});

  /// True when the auction's `bidMint` has no resolved metadata yet — the
  /// price header is a shimmer or "Unknown token", so "Place bid" must not be
  /// live. Same invariant as [ArtworkBuyBlock.unknownCurrency].
  final bool unknownCurrency;
}

/// Owner viewing their own active auction.
final class ArtworkAuctionOwnerAction extends ArtworkActionState {
  const ArtworkAuctionOwnerAction();
}

/// Refunded auction awaiting authorized recovery of the escrowed asset.
final class ArtworkAuctionRefundedAction extends ArtworkActionState {
  const ArtworkAuctionRefundedAction();
}

/// Auction has ended — settle / claim / reclaim depending on [role].
final class ArtworkAuctionClaimAction extends ArtworkActionState {
  const ArtworkAuctionClaimAction(this.role);
  final AuctionEndedRole role;
}

/// Raffle action sheet — sub-state varies by lifecycle phase.
final class ArtworkRaffleAction extends ArtworkActionState {
  const ArtworkRaffleAction({
    required this.role,
    required this.subState,
    this.raffle,
    this.gate = const RaffleGate(),
  });
  final RaffleRole role;
  final RaffleSubState subState;

  /// Indexed `raffleMetadata` with the live PDA snapshot overlaid, when one
  /// has loaded. The sheet renders from this rather than
  /// `artwork.raffleMetadata` so its numbers and the gate cannot disagree.
  final RaffleMetadata? raffle;

  /// Sold-out / wallet-limit / remaining-supply facts the sheet renders and
  /// gates its buy CTA on.
  final RaffleGate gate;
}

/// Connected wallet has an unclaimed raffle prize / proceeds. Mirrors the
/// webapp's `UnclaimedRaffleActionBox` and takes precedence over the regular
/// per-listing sheet so the user can complete the claim.
final class ArtworkUnclaimedRaffleAction extends ArtworkActionState {
  const ArtworkUnclaimedRaffleAction(this.raffle, this.claim);
  final RaffleMetadata raffle;

  /// Which of the three claims this wallet can complete.
  final UnclaimedRaffleClaim claim;
}

/// Listing types that run on the mallow web app today.
final class ArtworkExternalLinkAction extends ArtworkActionState {
  const ArtworkExternalLinkAction(this.listingType);
  final ListingType listingType;
}

/// No persistent sheet — the screen restores its full content area.
final class ArtworkNoAction extends ArtworkActionState {
  const ArtworkNoAction();
}

/// Resolve which sheet variant the artwork detail screen should pin to the
/// bottom. This function is the decision tree; the sheet widgets only render
/// the variant it picks.
///
/// [solanaSigner] is applied last: when the session cannot sign on Solana,
/// every CTA that would build a Solana transaction becomes
/// [ArtworkImportWalletAction]. Informational sheets (refunded auction, raffle
/// awaiting its draw, external-link listings) stay as resolved. Without this a
/// Tezos-only session saw Buy, and the tap sent its `tz1…` address as the
/// buyer of a Solana listing.
ArtworkActionState resolveArtworkActionState({
  required ArtworkDetails artwork,
  required String? currentAddress,
  required Set<String> creatorLinkedAddresses,
  required ArtworkPermissions? permissions,
  Set<String> sessionAddresses = const {},
  bool userOwnOffer = false,
  EditionLiveState? editionState,
  RaffleLiveState? raffleState,
  TokenMetadataStatus currencyStatus = TokenMetadataStatus.resolved,
  ArtworkSolanaSigner solanaSigner = ArtworkSolanaSigner.available,
  DateTime? now,
}) {
  final resolved = _resolveArtworkActionState(
    artwork: artwork,
    currentAddress: currentAddress,
    creatorLinkedAddresses: creatorLinkedAddresses,
    permissions: permissions,
    sessionAddresses: sessionAddresses,
    userOwnOffer: userOwnOffer,
    editionState: editionState,
    raffleState: raffleState,
    currencyStatus: currencyStatus,
    now: now,
  );
  if (solanaSigner == ArtworkSolanaSigner.available) return resolved;
  final action = _solanaSigningAction(resolved);
  if (action == null) return resolved;
  return ArtworkImportWalletAction(
    action: action.commerce && !showNftCommerce ? null : action.verb,
    watchOnly: solanaSigner == ArtworkSolanaSigner.watchOnly,
  );
}

/// What the CTA of [state] would sign on Solana, or null when [state] signs
/// nothing (or signs on another chain — OpenSea settles on Ethereum).
/// [commerce] marks the paid side that a store build must not name.
({String verb, bool commerce})? _solanaSigningAction(
  ArtworkActionState state,
) => switch (state) {
  ArtworkBuyAction() ||
  ArtworkMagicEdenBuyAction() ||
  ArtworkBuyEditionAction() => (verb: 'buy', commerce: true),
  ArtworkUnlistedViewerAction() => (verb: 'make an offer', commerce: true),
  ArtworkAuctionBidAction() => (verb: 'place a bid', commerce: true),
  ArtworkAuctionOwnerAction() => (verb: 'manage this auction', commerce: false),
  ArtworkAuctionClaimAction(:final role) => switch (role) {
    AuctionEndedRole.seller => (verb: 'settle this auction', commerce: false),
    AuctionEndedRole.winner => (verb: 'claim this artwork', commerce: false),
    AuctionEndedRole.observer => (verb: 'make an offer', commerce: true),
  },
  ArtworkOwnerListedAction() => (verb: 'manage this listing', commerce: false),
  ArtworkOwnerUnlistedAction(:final canList) =>
    canList
        ? (verb: 'list this artwork', commerce: true)
        : (verb: 'send this artwork', commerce: false),
  ArtworkRaffleAction(:final role, :final subState) => _raffleSigningAction(
    role,
    subState,
  ),
  ArtworkUnclaimedRaffleAction() => (verb: 'claim', commerce: false),
  ArtworkConnectWalletAction() ||
  ArtworkOpenSeaBuyAction() ||
  ArtworkAuctionRefundedAction() ||
  ArtworkExternalLinkAction() ||
  ArtworkImportWalletAction() ||
  ArtworkNoAction() => null,
};

/// The raffle sheet's CTA per role and phase, or null for the phases it
/// renders as status only — those keep the raffle sheet.
({String verb, bool commerce})? _raffleSigningAction(
  RaffleRole role,
  RaffleSubState subState,
) {
  if (subState == RaffleSubState.awaitingDraw) return null;
  return switch (role) {
    RaffleRole.buyer || RaffleRole.observer =>
      subState == RaffleSubState.selling
          ? (verb: 'buy tickets', commerce: true)
          : null,
    RaffleRole.winner =>
      subState == RaffleSubState.drawnUnclaimed
          ? (verb: 'claim your prize', commerce: false)
          : null,
    RaffleRole.owner => (verb: 'manage this raffle', commerce: false),
  };
}

ArtworkActionState _resolveArtworkActionState({
  required ArtworkDetails artwork,
  required String? currentAddress,
  required Set<String> creatorLinkedAddresses,
  required ArtworkPermissions? permissions,

  /// Every address in scope for the current session — the active Profile's
  /// linked wallets or the active Account's held wallets
  /// (`SessionManager.sessionAddresses`). An artwork owned by ANY of them
  /// resolves to the owner view, not just the active signing wallet. Scoped to
  /// the current Profile/Account, not device-wide.
  Set<String> sessionAddresses = const {},
  bool userOwnOffer = false,

  /// Live DAS-derived edition state from
  /// `MarketListingRepository.getEditionState`. When present its
  /// `isPrintableMasterEdition` overrides the `supplyType` proxy used
  /// otherwise.
  EditionLiveState? editionState,

  /// Live raffle PDA snapshot from `RaffleRepository.getState`. Authoritative
  /// over the indexed `raffleMetadata` for `sold` / `winner` / claim flags —
  /// exactly the fields the indexer lags on, and exactly the ones that decide
  /// awaiting-draw vs expired-unsold and therefore whether a creator is
  /// offered their reclaim.
  RaffleLiveState? raffleState,

  /// Whether the listing / bid currency's symbol + decimals are known
  /// (`TokenMetadataService.statusOf`). Anything but
  /// [TokenMetadataStatus.resolved] disables the buy / bid CTA — see
  /// [ArtworkBuyBlock.unknownCurrency].
  ///
  /// Defaults to resolved: registry currencies (every listing the app has ever
  /// been able to price) resolve synchronously, and the default keeps callers
  /// that don't price anything — the raffle max-ticket derivation, the whole
  /// existing test corpus — on the pre-existing path.
  TokenMetadataStatus currencyStatus = TokenMetadataStatus.resolved,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final listingType = artwork.listingType;
  final canTrade =
      (permissions?.tokenStandard != TokenStandard.cnftV2 &&
          artwork.tokenStandard != 'cnft-v2') ||
      (permissions?.canTrade ?? false);

  // The edition marketplace acts on a selected real print. This database-only
  // container has no account and must never enter an asset transaction path.
  if (isSyntheticSolanaMaster(artwork.mintAccount)) {
    return const ArtworkNoAction();
  }

  // OpenSea settles on Ethereum; all remaining marketplace builders below
  // are Solana-only. Cross-chain transfer stays in the artwork menu.
  if (artwork.chain == 'ethereum' &&
      artwork.lastSource == MarketSource.opensea &&
      listingType == ListingType.buyNow &&
      (artwork.tokenStandard == 'erc721' ||
          artwork.tokenStandard == 'erc1155')) {
    final owners = {
      artwork.ownerAddress,
      ...artwork.ownerAddresses,
    }.whereType<String>().map((a) => a.toLowerCase()).toSet();
    final mine = {
      ?currentAddress,
      ...sessionAddresses,
    }.map((a) => a.toLowerCase());
    if (mine.any(owners.contains)) return const ArtworkNoAction();
    if (currentAddress == null) {
      return ArtworkConnectWalletAction(
        label: showNftCommerce ? 'Sign in to buy' : 'Sign in to view',
      );
    }
    return ArtworkOpenSeaBuyAction(
      block: _buyBlock(artwork, clock, TokenMetadataStatus.resolved),
    );
  }

  if (isEvmOrTezosArtwork(
    mintAccount: artwork.mintAccount,
    chain: artwork.chain,
  )) {
    return const ArtworkNoAction();
  }

  if (listingType == ListingType.buyNow &&
      artwork.lastSource == MarketSource.magicEden) {
    final relationship = artworkRelationshipOf(
      currentAddress: currentAddress ?? '',
      sessionAddresses: sessionAddresses,
      artwork: artwork,
      creatorLinkedAddresses: creatorLinkedAddresses,
    );
    if (relationship == ArtworkRelationship.owner) {
      return const ArtworkNoAction();
    }
    if (currentAddress == null) {
      return ArtworkConnectWalletAction(
        label: showNftCommerce ? 'Sign in to buy' : 'Sign in to view',
      );
    }
    // The purchase review resolves its own currency and exact amounts.
    return ArtworkMagicEdenBuyAction(
      block: _buyBlock(artwork, clock, TokenMetadataStatus.resolved),
    );
  }

  // The remaining actions target Mallow programs and cannot manage external
  // listings. Historical provenance on an unlisted asset must still allow its
  // owner to create a new Mallow listing.
  if (listingType != ListingType.unlisted &&
      artwork.lastSource.isForeignMarketplace) {
    return const ArtworkNoAction();
  }

  // The indexer marks refunded auctions unlisted while retaining terminal
  // metadata until the escrow account is recovered or closed.
  if ((listingType == ListingType.auction ||
          listingType == ListingType.unlisted) &&
      artwork.auctionMetadata?.refunded == true) {
    return const ArtworkAuctionRefundedAction();
  }

  // Disconnected — connect-wallet variant for whatever listing type is live.
  if (currentAddress == null) {
    if (listingType == ListingType.unlisted && !canTrade)
      return const ArtworkNoAction();
    return ArtworkConnectWalletAction(
      label: _connectLabel(listingType, artwork.auctionMetadata, clock),
    );
  }

  // Unclaimed raffle prizes/proceeds take precedence — mirrors the
  // webapp's `UnclaimedRaffleActionBox` rendering above the main panel.
  final unclaimed = _claimableUnclaimedRaffle(
    artwork,
    currentAddress,
    sessionAddresses,
  );
  if (unclaimed != null) {
    return ArtworkUnclaimedRaffleAction(unclaimed.$1, unclaimed.$2);
  }

  // External-app listings — Flutter only links out for now. `jellybean` belongs
  // here for the same reason as the other three: the sale runs on the web app
  // and mobile has no in-app surface for it. Omitting it fell through to the
  // owner / viewer arms below, which offered List artwork and Accept offer on a
  // Jellybean artwork — actions the webapp refuses outright
  // (`canAcceptOffer`).
  if (listingType == ListingType.gumball ||
      listingType == ListingType.airdrop ||
      listingType == ListingType.store ||
      listingType == ListingType.jellybean) {
    return ArtworkExternalLinkAction(listingType);
  }

  final relationship = artworkRelationshipOf(
    currentAddress: currentAddress,
    sessionAddresses: sessionAddresses,
    artwork: artwork,
    creatorLinkedAddresses: creatorLinkedAddresses,
  );

  if (listingType == ListingType.raffle) {
    final raffle = _mergeRaffleLive(artwork.raffleMetadata, raffleState);
    final subState = _raffleSubState(raffle, clock);
    final userState = raffle?.raffleUserState;
    final mine = _sessionAddresses(currentAddress, sessionAddresses);
    final RaffleRole role;
    // Prefer server-derived user flags; fall back to address matching.
    //
    // The address fallback checks `raffleMetadata.creator` **before** the
    // indexed NFT owner: a live raffle escrows the prize, so the creator is
    // usually not the owner of record and would otherwise be classified a
    // buyer — shown "Buy tickets" on their own raffle and, at the end, no
    // reclaim path at all. The webapp resolves the creator the same way
    // (`raffleStateDerivation`).
    if (userState?.isUserOwner ??
        (_isMine(raffle?.creator, mine) ||
            relationship == ArtworkRelationship.owner)) {
      role = RaffleRole.owner;
    } else if (userState?.isUserWinner ?? _isMine(raffle?.winner, mine)) {
      role = RaffleRole.winner;
    } else {
      role = RaffleRole.buyer;
    }
    return ArtworkRaffleAction(
      role: role,
      subState: subState,
      raffle: raffle,
      gate: _raffleGate(
        raffle,
        isOwner: role == RaffleRole.owner,
        isSelling: subState == RaffleSubState.selling,
        mine: mine,
      ),
    );
  }

  if (listingType == ListingType.auction) {
    final auction = artwork.auctionMetadata;
    if (_auctionEnded(auction, clock)) {
      final AuctionEndedRole role;
      if (relationship == ArtworkRelationship.owner) {
        role = AuctionEndedRole.seller;
      } else if (auction?.currentBidder != null &&
          auction!.currentBidder == currentAddress) {
        role = AuctionEndedRole.winner;
      } else {
        role = AuctionEndedRole.observer;
      }
      return ArtworkAuctionClaimAction(role);
    }
    if (relationship == ArtworkRelationship.owner) {
      return const ArtworkAuctionOwnerAction();
    }
    return ArtworkAuctionBidAction(
      unknownCurrency: currencyStatus != TokenMetadataStatus.resolved,
    );
  }

  if (listingType == ListingType.buyNow) {
    if (relationship == ArtworkRelationship.owner) {
      return ArtworkOwnerListedAction(
        canAcceptOffer:
            canTrade &&
            permissions?.tokenStandard != TokenStandard.cnft &&
            permissions?.tokenStandard != TokenStandard.cnftV2 &&
            artwork.tokenStandard != 'cnft' &&
            artwork.tokenStandard != 'cnft-v2',
      );
    }
    final printsEdition = _isEditionMaster(artwork, editionState);
    final block = _buyBlock(artwork, clock, currencyStatus);
    if (printsEdition) {
      return ArtworkBuyEditionAction(block: block);
    }
    return ArtworkBuyAction(
      userOwnOffer: userOwnOffer,
      block: block,
      canMakeOffer: canTrade,
    );
  }

  // Remaining: ListingType.unlisted (collections collapse here too — they
  // don't get an action sheet).
  if (artwork.supplyType == SupplyType.collection) {
    return const ArtworkNoAction();
  }
  if (relationship == ArtworkRelationship.owner) {
    // Send and List are gated separately. `canTransfer` is the same predicate
    // the context menu's Transfer row uses; gating Send on `canList` (as this
    // did) gave the screen's most prominent affordance the weakest predicate
    // on the page, and dropping the whole sheet on `isFlagged` took Send and
    // Accept-offer down with List — leaving an owner unable to move their own
    // flagged artwork out of the app. The webapp gates only the listing CTA
    // (`ActionBox`: `!creator?.isFlagged &&
    // !isFlagged` wraps "List for sale"; Transfer is outside it).
    //
    // `creatorIsFlagged` is the second half of that `&&`. It gates the List
    // CTA and *only* the List CTA — letting it reach `canSend` would rebuild
    // the exact inversion that stranded an owner's flagged artwork in the app.
    final canSend = permissions?.canTransfer ?? false;
    // `showNftCommerce` first: listing is the paid side, and a store build
    // that hides commerce must not offer it. Forcing it here rather than in
    // the sheet keeps the `!canList && !canSend → no sheet` rule intact: an
    // owner who also cannot send gets no sheet at all, which on a store build
    // also drops the highest-offer summary panel that sheet carries. Accepted
    // — the detail page's Offers tab still lists the offers for any viewer,
    // and the Accept CTA is hidden on that build anyway.
    final canList =
        showNftCommerce &&
        canTrade &&
        (permissions?.canList ?? false) &&
        !artwork.isFlagged &&
        !artwork.creatorIsFlagged &&
        !_isSoldOutMaster(artwork);
    if (!canList && !canSend) return const ArtworkNoAction();
    return ArtworkOwnerUnlistedAction(
      canList: canList,
      canSend: canSend,
      canAcceptOffer: canTrade,
    );
  }
  if (!canTrade && !userOwnOffer) {
    return const ArtworkNoAction();
  }
  // TODO: show make offer when edition offers are live
  if (_isEditionMaster(artwork, editionState)) {
    return const ArtworkNoAction();
  }
  return ArtworkUnlistedViewerAction(
    userOwnOffer: userOwnOffer,
    canMakeOffer: canTrade,
  );
}

/// Why (if at all) a buy-now listing must not be bought right now.
///
/// The sale-window half ports the webapp's `hasItemStarted` / `hasItemEnded`
/// buy-now arms (`listing`), which feed
/// `isActive` (`useListingState`) and hard-disable Buy through
/// `deriveCanBuyNow` (`listingStateDerivation`). Mobile only ever
/// has the off-chain `buyNowMetadata`, so the on-chain `listing.startTime` /
/// `endTime` arms of those helpers don't apply here. Neither backend validates
/// the window, so without this the transaction builds and reverts on-chain.
ArtworkBuyBlock? _buyBlock(
  ArtworkDetails artwork,
  DateTime now,
  TokenMetadataStatus currencyStatus,
) {
  final buyNow = artwork.buyNowMetadata;
  final startsAt = buyNow?.startsAt;
  // `startsAt == null` means "no schedule" → started, per `hasItemStarted`.
  if (startsAt != null && startsAt.isAfter(now)) {
    return ArtworkBuyBlock.notStarted;
  }
  final endsAt = buyNow?.endsAt;
  if (endsAt != null && !endsAt.isAfter(now)) return ArtworkBuyBlock.ended;
  // Applies to every supply type: the amount on screen is a shimmer or
  // "Unknown token", so nothing here is safe to sign yet.
  if (currencyStatus != TokenMetadataStatus.resolved) {
    return ArtworkBuyBlock.unknownCurrency;
  }
  // No currency gate beyond that. Both v2 buy builders settle in the listing's
  // own currency — an SPL-denominated 1/1, a secondary `edition-print` resale
  // and a master-edition print all spend the buyer's balance of that token
  // directly. `swapQuote` is only for paying with a *different* token, which
  // mobile never does.
  return null;
}

/// A master edition whose prints are exhausted can't be listed — the webapp's
/// `deriveCanList` returns false on `isSoldOut`
/// (`listingStateDerivation`, pinned by
/// `listingStateDerivation.test`).
///
/// The webapp's `!isSingle(supplyType)` covers `limited-edition` and
/// `open-edition` (`supplyType`);
/// `collection` never reaches here (it returns [ArtworkNoAction] above). One
/// deliberate narrowing: the webapp's raw `supply === maxSupply` also reports
/// sold-out when both are absent, which is every open edition — mobile requires
/// both to be present, so an open edition (no `maxSupply`) is never sold out.
bool _isSoldOutMaster(ArtworkDetails artwork) {
  if (artwork.supplyType != SupplyType.limitedEdition &&
      artwork.supplyType != SupplyType.openEdition) {
    return false;
  }
  final supply = artwork.supply;
  final maxSupply = artwork.maxSupply;
  if (supply == null || maxSupply == null) return false;
  return supply >= maxSupply;
}

/// The all-ones system-program pubkey the rafffle program writes into
/// `winner` before the draw. The webapp screens for the same sentinel
/// (`raffleStateDerivation`: `!raffle.winner.equals(PublicKey.default)`).
const _defaultPubkey = '11111111111111111111111111111111';

/// Overlay the live raffle PDA snapshot onto the indexed metadata.
///
/// Only the fields the account actually owns are taken; identity fields
/// (`raffleAccount`, `creator`, `mintAccount`) stay on the indexed row, and the
/// merge is skipped outright when the snapshot describes a different raffle.
RaffleMetadata? _mergeRaffleLive(RaffleMetadata? meta, RaffleLiveState? live) {
  if (meta == null || live == null) return meta;
  if (live.raffleAccount != meta.raffleAccount) return meta;
  final winner = live.winner;
  return meta.copyWith(
    supply: live.supply,
    sold: live.sold,
    // `0` is the program's "no per-wallet cap" encoding, not a cap of zero.
    ticketLimit: live.ticketLimit > 0 ? live.ticketLimit : meta.ticketLimit,
    winner: (winner == null || winner.isEmpty || winner == _defaultPubkey)
        ? null
        : winner,
    isPrizeClaimed: live.isPrizeClaimed,
    isClaimed: live.isClaimed,
    isExpired: live.isExpired,
    endsAt: live.endTime ?? meta.endsAt,
    priceRaw: live.ticketPrice > 0
        ? live.ticketPrice.toDouble()
        : meta.priceRaw,
    countByEntrant: live.countByEntrant ?? meta.countByEntrant,
  );
}

/// Map the raffle's lifecycle fields to a [RaffleSubState]. Port of the
/// webapp's `deriveRaffleState`
/// (`raffleStateDerivation`, wrapped
/// by `useRaffleState`), with one value per terminal phase:
///
///   - sale window still open → [RaffleSubState.selling]
///   - closed, no winner, tickets sold **or sold unknown (null)** →
///     [RaffleSubState.awaitingDraw]
///   - closed, no winner, **concretely nothing sold** →
///     [RaffleSubState.endedCancelled]
///     (webapp `isRaffleExpired`)
///   - winner set, prize unclaimed → [RaffleSubState.drawnUnclaimed]
///   - winner set, prize claimed → [RaffleSubState.drawnClaimed]
///
/// The two additions over the previous version are the ones that mattered: a
/// drawn-and-claimed raffle used to fall through to `selling` (live "Buy
/// tickets" on a finished raffle), and expired-unsold was only reached via the
/// server's `isExpired` flag, which left the creator's reclaim path dark
/// whenever the flag was absent.
RaffleSubState _raffleSubState(RaffleMetadata? raffle, DateTime now) {
  if (raffle == null) return RaffleSubState.selling;

  // A drawn winner is terminal whatever the clock says — the draw only runs
  // after the window closes, and it is the one signal that cannot be stale in
  // the "still selling" direction. Taken first so a raffle whose `endsAt`
  // never indexed still resolves to a drawn state (the webapp gets there by
  // `moment(undefined) == now`, which makes a missing `endsAt` read as ended;
  // that is the wrong default for a *live* raffle, so mobile splits the two).
  if (raffle.winner != null) {
    return (raffle.isPrizeClaimed ?? false)
        ? RaffleSubState.drawnClaimed
        : RaffleSubState.drawnUnclaimed;
  }

  // Webapp `deriveIsActive` (`raffleStateDerivation`): on the
  // metadata-only path this is `now < endsAt`.
  final endsAt = raffle.endsAt;
  if (endsAt == null || endsAt.isAfter(now)) return RaffleSubState.selling;

  // Closed, no winner. Tickets sold → the draw hasn't run
  // (`raffleStateDerivation`). Nothing sold → expired, and the prize
  // goes back to the creator.
  // `isExpired` is the server's own flag for the same condition.
  //
  // A **null** `sold` is unknown, not zero: the indexed row lags exactly here,
  // and the live PDA overlay that would settle it (`_mergeRaffleLive`, whose
  // `sold` is always concrete) resolves asynchronously. Reading null as 0 would
  // hand the creator a "Reclaim NFT" CTA whose `claimPrize` reverts on-chain
  // once tickets turn out to have sold. The webapp gates the same arm on strict
  // `(numberSold ?? sold) === 0` (`raffleStateDerivation`), which does
  // not fire on null — so only a concrete zero is cancelled-eligible, and the
  // unknown window falls back to awaiting-draw.
  final sold = raffle.sold;
  return ((sold != null && sold <= 0) || (raffle.isExpired ?? false))
      ? RaffleSubState.endedCancelled
      : RaffleSubState.awaitingDraw;
}

/// Per-wallet ticket ceiling. Port of `raffleWalletLimit`
/// (`nft`): the program caps any
/// one wallet at 40% of supply (floored); a configured `ticketLimit` narrows
/// it further but never widens it.
int _raffleWalletLimit(int? ticketLimit, int? supply) {
  final supplyCap = supply == null ? 0 : (supply * 0.4).floor();
  if (ticketLimit != null && ticketLimit > 0) {
    return ticketLimit < supplyCap ? ticketLimit : supplyCap;
  }
  return supplyCap;
}

/// Sold-out / wallet-limit / remaining-supply facts for the raffle sheet.
/// Port of the same block in `deriveRaffleState`
/// (`raffleStateDerivation`).
///
/// [isSelling] stands in for the webapp's `isActive` — the sub-state machine
/// above already resolved the clock, so the two cannot disagree.
RaffleGate _raffleGate(
  RaffleMetadata? raffle, {
  required bool isOwner,
  required bool isSelling,
  required Set<String> mine,
}) {
  if (raffle == null) return const RaffleGate();
  final supply = raffle.supply;
  final sold = raffle.sold ?? 0;
  // Webapp: `sold >= (supply ?? 0)` — a raffle reporting no supply is
  // "sold out", and `canBuyTicket` requires a supply anyway.
  final isSoldOut = sold >= (supply ?? 0);
  final walletLimit = _raffleWalletLimit(raffle.ticketLimit, supply);
  // `countByEntrant` summed across the session's wallets, matching the
  // webapp's `userAddresses.reduce(...)` (`raffleStateDerivation`).
  final counts = raffle.countByEntrant;
  var userTickets = 0;
  if (counts != null) {
    for (final address in mine) {
      userTickets += counts[address] ?? 0;
    }
  }
  return RaffleGate(
    canBuyTickets:
        supply != null &&
        userTickets < walletLimit &&
        !isOwner &&
        isSelling &&
        !isSoldOut,
    isSoldOut: isSoldOut,
    walletLimit: walletLimit,
    userTickets: userTickets,
    ticketsRemaining: supply == null ? null : (supply - sold).clamp(0, supply),
  );
}

/// The first raffle in `artwork.unclaimedRaffles` that **this** wallet can
/// actually claim, with which claim it is.
///
/// `/v1/artwork/byMint` returns every unclaimed raffle for the mint with no
/// user scoping at all (`raffleMetadataHelper`
/// — the query is `{isInitialized, mintAccount, isClaimed: {$ne: true}}`,
/// Redis-cached for 300 s). The previous `unclaimedRaffles.isNotEmpty` test
/// therefore replaced "Buy tickets" with "Claim proceeds" for *every* signed-in
/// visitor of a live raffle.
///
/// Ports the webapp's filter (`ArtworkContent`):
/// signed-in only, exclude the raffle the main sheet is already showing, and
/// keep it only if the viewer is the creator or the unpaid winner. One
/// deliberate narrowing: the webapp additionally keeps any awaiting-draw
/// raffle because its box renders *above* the main action box and is purely
/// informational. Mobile has a single sheet slot, so an inert "awaiting draw"
/// panel would displace the live listing's CTA — exactly the bug being fixed.
(RaffleMetadata, UnclaimedRaffleClaim)? _claimableUnclaimedRaffle(
  ArtworkDetails artwork,
  String currentAddress,
  Set<String> sessionAddresses,
) {
  if (artwork.unclaimedRaffles.isEmpty) return null;
  final mine = _sessionAddresses(currentAddress, sessionAddresses);
  final shown = artwork.raffleMetadata?.raffleAccount;
  for (final raffle in artwork.unclaimedRaffles) {
    if (shown != null && raffle.raffleAccount == shown) continue;
    final prizeClaimed = raffle.isPrizeClaimed ?? false;
    final proceedsClaimed = raffle.isClaimed ?? false;
    final hasWinner = raffle.winner != null;
    if (_isMine(raffle.winner, mine) && !prizeClaimed) {
      return (raffle, UnclaimedRaffleClaim.prize);
    }
    if (_isMine(raffle.creator, mine)) {
      // Creator: proceeds on a drawn raffle, prize reclaim on an expiry with
      // no tickets sold (`UnclaimedRaffleActionBox`).
      if (hasWinner && !proceedsClaimed) {
        return (raffle, UnclaimedRaffleClaim.proceeds);
      }
      if (!hasWinner && (raffle.sold ?? 0) <= 0 && !prizeClaimed) {
        return (raffle, UnclaimedRaffleClaim.reclaim);
      }
    }
  }
  return null;
}

/// Every address in scope for the session, normalised and de-duplicated.
Set<String> _sessionAddresses(String currentAddress, Set<String> session) =>
    <String>{
      currentAddress,
      ...session,
    }.where((a) => a.isNotEmpty).map(apiOwnerAddress).toSet();

bool _isMine(String? address, Set<String> mine) =>
    address != null &&
    address.isNotEmpty &&
    mine.contains(apiOwnerAddress(address));

/// How the current session relates to an artwork: it holds it ([owner]), it
/// minted / earns royalties on it ([creator]), or neither ([viewer]).
enum ArtworkRelationship { owner, creator, viewer }

/// Classify the current session against [artwork].
///
/// Public only so the [ArtworkRelationship.creator] branch is directly
/// testable: the dispatcher above keys every decision off
/// [ArtworkRelationship.owner], so creator and viewer produce identical
/// action states and a test driven through [resolveArtworkActionState] cannot
/// observe the creator classification at all.
@visibleForTesting
ArtworkRelationship artworkRelationshipOf({
  required String currentAddress,
  required Set<String> sessionAddresses,
  required ArtworkDetails artwork,
  required Set<String> creatorLinkedAddresses,
}) {
  // Ownership uses the full linked-addresses list because (a) when an NFT
  // is listed the on-chain owner becomes the marketplace escrow but the
  // API still tracks the seller, and (b) one mallow user may have several
  // linked wallets — any of them counts as "owner". Mirrors the webapp's
  // `nftPreview.owner.addresses.includes(userPubkey)` check.
  //
  // The user side is likewise every address in scope for the current session
  // ([sessionAddresses] — the active Profile's linked wallets or Account's
  // held wallets), not just the active signing wallet: an artwork held by any
  // of them shows the owner view, not a "Make offer" sheet. Empty entries are
  // dropped so a missing/empty owner field never false-matches.
  //
  // Both sides go through [apiOwnerAddress]: the API stores and returns EVM
  // addresses lowercased while local wallets hold the EIP-55 checksummed form,
  // so a raw compare never matches for EVM — the owner of an Ethereum artwork
  // would be classified as a viewer and offered "Make offer" on their own
  // piece instead of list / transfer / hide. Solana and Tezos addresses are
  // case-sensitive and pass through unchanged.
  final mine = <String>{
    currentAddress,
    ...sessionAddresses,
  }.where((a) => a.isNotEmpty).map(apiOwnerAddress).toSet();
  if (artwork.ownerAddresses.map(apiOwnerAddress).any(mine.contains)) {
    return ArtworkRelationship.owner;
  }
  final owner = artwork.ownerAddress;
  if (owner != null && mine.contains(apiOwnerAddress(owner))) {
    return ArtworkRelationship.owner;
  }
  // For active auctions the seller lives on `auctionMetadata.seller` and
  // is more authoritative than the indexed owner.
  final seller = artwork.auctionMetadata?.seller;
  if (seller != null && mine.contains(apiOwnerAddress(seller))) {
    return ArtworkRelationship.owner;
  }

  // The creator side resolves against the same [mine] set as the owner branch
  // above, for the same two reasons: a session spans several wallets, and the
  // piece may have been minted from one of them while another is active — so
  // comparing against the active signing wallet alone misclassifies its own
  // creator as a viewer. The [apiOwnerAddress] normalisation matters here too:
  // an EVM creator/update-authority/royalty-split address comes back lowercased
  // from the API while the local wallet holds the EIP-55 checksummed form.
  if (artwork.artistAddresses.map(apiOwnerAddress).any(mine.contains)) {
    return ArtworkRelationship.creator;
  }
  if (mine.contains(apiOwnerAddress(artwork.artistAddress))) {
    return ArtworkRelationship.creator;
  }
  final updateAuthority = artwork.updateAuthority;
  if (updateAuthority != null &&
      mine.contains(apiOwnerAddress(updateAuthority))) {
    return ArtworkRelationship.creator;
  }
  if (artwork.royaltySplits.any(
    (s) => mine.contains(apiOwnerAddress(s.address)),
  )) {
    return ArtworkRelationship.creator;
  }
  if (creatorLinkedAddresses.map(apiOwnerAddress).any(mine.contains)) {
    return ArtworkRelationship.creator;
  }
  return ArtworkRelationship.viewer;
}

/// True when an auction is over. Purely a clock comparison against `endsAt` —
/// nothing changes on-chain at the end instant, so the server-derived
/// [ListingState] does NOT flip when an auction closes (it can sit on `active`
/// indefinitely past `endsAt`). Mirrors the reference web client's `hasItemEnded`, which
/// is likewise time-only. An auction with no `endsAt` (on-bid, no clock yet)
/// is never ended.
bool _auctionEnded(AuctionMetadata? auction, DateTime now) {
  final endsAt = auction?.endsAt;
  if (endsAt == null) return false;
  return !endsAt.isAfter(now);
}

/// True for printable master editions.
///
/// Delegates to [resolvePrintableMasterEdition] — the same helper `MarketBloc`
/// routes the buy builder with — so the sheet the user sees and the
/// transaction that gets built provably agree. This was a byte-for-byte
/// duplicate of that function.
bool _isEditionMaster(ArtworkDetails artwork, EditionLiveState? editionState) =>
    resolvePrintableMasterEdition(
      supplyType: artwork.supplyType,
      isMasterEdition: artwork.isMasterEdition,
      editionState: editionState,
    );

/// The connect-wallet CTA names the action signing in would unlock. Where that
/// action is not offered by this build — the paid side behind
/// `kShowNftCommerce`, or raffle entry behind `kShowRaffleEntry` — the label
/// falls back to the ended-auction wording, "Sign in to view", rather than
/// promise a purchase the sheet behind it will not offer.
String _connectLabel(
  ListingType listingType,
  AuctionMetadata? auction,
  DateTime now,
) {
  const view = 'Sign in to view';
  switch (listingType) {
    case ListingType.unlisted:
      return showNftCommerce ? 'Sign in to make offer' : view;
    case ListingType.buyNow:
      return showNftCommerce ? 'Sign in to buy' : view;
    case ListingType.auction:
      return _auctionEnded(auction, now) || !showNftCommerce
          ? view
          : 'Sign in to place bid';
    case ListingType.raffle:
      return kShowRaffleEntry && showNftCommerce
          ? 'Sign in to buy tickets'
          : view;
    case ListingType.gumball:
    case ListingType.airdrop:
    case ListingType.store:
    case ListingType.jellybean:
      return showNftCommerce ? 'Sign in to participate' : view;
  }
}
