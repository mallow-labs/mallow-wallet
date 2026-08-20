import 'package:mallow_api/mallow_api.dart';

import '../../artwork/models/on_chain_asset.dart';

/// Pure port of the webapp's "can this user list this artwork?" gate.
///
/// Source of truth: `ListArtwork`
/// ```ts
/// if (user == null || nftPreview?.isFlagged || nftPreview?.creator?.isFlagged) return false;
/// return (
///   (onChainAsset != null && (listingData?.hasVerifiedSale || hasVerifiedCreator)) ||
///   (hasCompleteProfile(user) && isApprovedCreator(user))
/// );
/// ```
/// Everything in this file is widget-free and IO-free so the matrix can be
/// unit-tested directly; loading the inputs is
/// `listing_eligibility_service.dart`'s job.

/// Role strings that grant primary-listing rights.
///
/// Mirrors `isApprovedCreator` / `isAdmin`
/// (`user`), whose `Role` enum values are
/// `admin` and `primaryLister` (`user`).
const _approvedCreatorRoles = {'primaryLister', 'admin'};

/// Why the listing flow is closed. Ordered exactly like the webapp's
/// `VerifyToList` body branches
/// (`VerifyToList`), which
/// are mutually exclusive and evaluated top-down.
enum ListingBlockReason {
  /// The artwork or its creator is flagged. No CTA — the copy points at
  /// discord.
  flagged,

  /// The signed-in user has neither the `primaryLister` nor the `admin`
  /// role. CTA: the application form.
  notApprovedCreator,

  /// Approved creator whose profile is missing a username, a profile
  /// picture, or a verified twitter. CTA: edit profile.
  incompleteProfile,

  /// Webapp's final `else` branch. Unreachable in practice — reaching it
  /// requires `isApprovedCreator(user) && hasCompleteProfile(user)`, which
  /// already satisfies `canList` — but ported so the branch ladder stays a
  /// faithful copy rather than a re-derivation.
  twitterNotVerified,
}

/// The artwork-side inputs to the gate. `null` at the call site means "no
/// artwork in context yet", in which case only the user-side disjunct of the
/// webapp predicate can be evaluated.
class ArtworkListingFacts {
  const ArtworkListingFacts({
    required this.isFlagged,
    required this.creatorIsFlagged,
    required this.hasVerifiedSale,
    required this.hasOnChainAsset,
    required this.hasVerifiedCreator,
  });

  /// `nftPreview.isFlagged` from `GET /v0/listingData/{mint}`.
  final bool isFlagged;

  /// `nftPreview.creator.isFlagged` from the same response.
  final bool creatorIsFlagged;

  /// `hasVerifiedSale` from the same response — a sale for this mint has
  /// already been indexed, so the listing is secondary.
  final bool hasVerifiedSale;

  /// Whether the DAS `getAsset` read succeeded. The webapp requires a loaded
  /// on-chain asset before it will honour either secondary-market signal.
  final bool hasOnChainAsset;

  /// See [computeHasVerifiedCreator].
  final bool hasVerifiedCreator;
}

/// Evaluates the gate. Returns `null` when the user may list, otherwise the
/// reason the `VerifyToList` UI should render.
///
/// [artwork] is `null` when the flow was entered without a mint (the global
/// action menu's "Sell"). There is no webapp equivalent of that entry point —
/// the webapp only lists from `/list/:mint` — so the artwork-dependent
/// disjunct is simply unavailable and only `hasCompleteProfile && isApprovedCreator`
/// can pass. The flag check then falls back to the signed-in user's own
/// `isFlagged`, which is the same person the creator check would have covered.
ListingBlockReason? evaluateListingEligibility({
  required User? user,
  ArtworkListingFacts? artwork,
}) {
  final flagged = artwork != null
      ? (artwork.isFlagged || artwork.creatorIsFlagged)
      : (user?.isFlagged ?? false);
  final approved = isApprovedCreator(user);
  final complete = hasCompleteProfile(user);

  final secondaryPass =
      artwork != null &&
      artwork.hasOnChainAsset &&
      (artwork.hasVerifiedSale || artwork.hasVerifiedCreator);

  if (user != null && !flagged && (secondaryPass || (approved && complete))) {
    return null;
  }

  // Same ladder, same order, as VerifyToList's body. A signed-out user falls
  // through to `notApprovedCreator` (roles of a null user are empty), which is
  // also the branch the webapp's own `isApprovedCreator(user)` would take.
  if (flagged) return ListingBlockReason.flagged;
  if (!approved) return ListingBlockReason.notApprovedCreator;
  if (!complete) return ListingBlockReason.incompleteProfile;
  return ListingBlockReason.twitterNotVerified;
}

/// `isApprovedCreator(user) || isAdmin(user)` — `user`.
bool isApprovedCreator(User? user) =>
    user != null && user.roles.any(_approvedCreatorRoles.contains);

/// `hasCompleteProfile` — `user`.
bool hasCompleteProfile(User? user) =>
    user != null &&
    (user.username?.isNotEmpty ?? false) &&
    (user.imageUrl?.isNotEmpty ?? false) &&
    user.isTwitterVerified;

/// `hasVerifiedCreator` — `ListArtwork`:
/// the artwork's mallow creator is an approved creator, is twitter-verified,
/// and one of their addresses is a verified creator of the on-chain asset.
bool computeHasVerifiedCreator({
  required ApiUserRef? creator,
  required DigitalAsset? asset,
  DigitalAsset? collectionAsset,
}) {
  if (creator == null || asset == null) return false;
  if (!creator.roles.any(_approvedCreatorRoles.contains)) return false;
  if (creator.isTwitterVerified != true) return false;

  // The renderer ships `addresses`; the bare-string legacy form of the field
  // only populates `address`, so fall back to it rather than reading nothing.
  final addresses = creator.addresses.isNotEmpty
      ? creator.addresses
      : [if (creator.effectiveAddress != null) creator.effectiveAddress!];

  return addresses.any(
    (a) => isVerifiedCreatorAddress(
      asset: asset,
      collectionAsset: collectionAsset,
      creator: a,
    ),
  );
}

/// `isVerifiedCreator` — `assets`.
///
/// Token-metadata standards match the update authority or a `verified`
/// creator entry. Core assets defer to their collection when one was loaded,
/// and otherwise compare the asset's own update authority.
bool isVerifiedCreatorAddress({
  required DigitalAsset asset,
  required DigitalAsset? collectionAsset,
  required String creator,
}) {
  switch (asset.tokenStandard) {
    case TokenStandard.nft:
    case TokenStandard.pnft:
    case TokenStandard.cnft:
      return asset.updateAuthority == creator ||
          asset.tokenMetadataCreators.any(
            (c) => c.verified && c.address == creator,
          );
    case TokenStandard.core:
      if (collectionAsset != null) {
        return isVerifiedCreatorAddress(
          asset: collectionAsset,
          collectionAsset: null,
          creator: creator,
        );
      }
      return asset.updateAuthority == creator;
    case TokenStandard.coreCollection:
      return asset.updateAuthority == creator;
    // The webapp's switch has no other arms — mallow listings are Solana-only,
    // and every other standard (EVM / Tezos / fungible) never reaches here.
    // ignore: no_default_cases
    default:
      return false;
  }
}
