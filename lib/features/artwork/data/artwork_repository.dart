import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/user_display.dart';
import '../services/artwork_bloc.dart';

/// Repository for fetching artwork details and managing likes.
@lazySingleton
class ArtworkRepository {
  ArtworkRepository(this._api);

  final api.MallowApiClient _api;

  /// Fetch full artwork details by mint account.
  Future<ArtworkDetails> getArtworkDetail(String mintAccount) async {
    final response = await _api.getArtworkByMint(mintAccount);
    final result = response.result;
    return _mapToArtworkDetails(result);
  }

  /// Like an artwork by mint account (requires auth session).
  Future<void> likeArtwork(String mintAccount) async {
    await _api.like({'mint': mintAccount});
  }

  /// Unlike an artwork by mint account (requires auth session).
  Future<void> unlikeArtwork(String mintAccount) async {
    await _api.unlike({'mint': mintAccount});
  }

  /// Ask the indexer to re-pull on-chain metadata for an artwork mint.
  Future<void> syncArtwork(String mintAccount) async {
    await _api.updateArtworkMetadata({'mintAccount': mintAccount});
  }

  /// Map API [ArtworkResult] to the UI [ArtworkDetails] model.
  ArtworkDetails _mapToArtworkDetails(api.ArtworkResult result) {
    final item = result.item;
    final collection = result.collection;
    final buyNow = item.buyNowMetadata;
    final auction = item.auctionMetadata;

    final listingType = item.listingType ?? api.ListingType.unlisted;
    final isBuyNow = listingType == api.ListingType.buyNow && buyNow != null;

    final supplyType = _determineSupplyType(item);

    double? quantitySold;
    double? quantityTotal;
    if (buyNow != null) {
      quantityTotal = buyNow.quantity.toDouble();
      quantitySold = (buyNow.quantity - buyNow.quantityLeft).toDouble();
    } else if (item.maxSupply != null) {
      quantityTotal = item.maxSupply!.toDouble();
    }

    // Artist identity lives on `item.creator` (a `User`). The sibling
    // `result.userDetails` is shaped as `UserDetails` (bio / socials /
    // counts) and never carries username, displayName, or address.
    final creator = item.creator;
    final artistUsername = creator?.username;
    final artistDisplayName = creator?.displayName;
    final artistAddress = creator?.effectiveAddress ?? '';
    final artistName = formatDisplayLabel(
      displayName: artistDisplayName,
      username: artistUsername,
      address: artistAddress,
    );

    final asset = item.assetMetadata;
    final dimensions = (asset?.width != null && asset?.height != null)
        ? (width: asset!.width!, height: asset.height!)
        : null;

    return ArtworkDetails(
      mintAccount: item.mintAccount,
      title: item.name,
      imageUrl: item.imageUrl ?? '',
      description: item.description,
      artistName: artistName,
      artistAddress: artistAddress,
      artistUsername: artistUsername,
      artistAvatarUrl: creator?.avatarUrl,
      collectionName: collection?.name,
      collectionMint: collection?.slug,
      collectionImageUrl: collection?.imageUrl,
      attributes: item.attributes
          .map(
            (a) =>
                ArtworkAttribute(traitType: a.traitType, value: a.value ?? ''),
          )
          .toList(),
      price: isBuyNow ? buyNow.amount : null,
      currency: isBuyNow ? buyNow.currencyMint : null,
      listingType: listingType,
      listingState: item.listingState,
      buyNowMetadata: buyNow,
      auctionMetadata: auction,
      raffleMetadata: item.raffleMetadata,
      secondaryEditions: item.secondaryEditions,
      groupedSale: item.groupedSale,
      unclaimedRaffles: result.unclaimedRaffles,
      redeemableTxId: result.redeemableTxId,
      rewardsInfo: item.listingMetadata?.rewardsDescription,
      offChainWhitelistDenied: result.offChainWhitelistDenied,
      isFlagged: item.isFlagged ?? false,
      creatorIsFlagged: creator?.isFlagged ?? false,
      lastSource: item.lastSource,
      nsfw: item.nsfw ?? false,
      highestOffer: result.highestOffer,
      offersCount: result.offersCount,
      isFreePrint: result.isFreePrint ?? false,
      likeCount: item.likes ?? 0,
      // The holding wallet, NOT the owner profile's first linked address:
      // `item.owner` is a *user* render whose `addresses` list is the whole
      // profile, so `effectiveAddress` picks whichever wallet was linked first
      // — a coin flip for a profile with two wallets on the artwork's chain,
      // and the signer every owner-side tx would then be built for. It only
      // survives as the fallback for payloads that predate `ownerAddress`.
      ownerAddress: item.ownerAddress ?? item.owner?.effectiveAddress,
      // Holders first (the wire list), then the owner profile's linked wallets:
      // the relationship gates match on either, while the authority resolvers
      // scan in order and must reach a real holder before a mere profile link.
      ownerAddresses: {
        ...item.ownerAddresses.where((a) => a.isNotEmpty),
        ..._allAddresses(item.owner),
      }.toList(growable: false),
      artistAddresses: _allAddresses(item.creator),
      supply: item.supply,
      maxSupply: item.maxSupply,
      editionNumber: item.editionNumber,
      isMasterEdition: item.isMasterEdition,
      listingFees: item.listingFees,
      supplyType: supplyType,
      isVerified: creator?.isTwitterVerified ?? false,
      isAdmin: creator?.roles.contains('admin') ?? false,
      curations: result.curations
          .map(
            (c) => ArtworkCuration(
              id: c.id,
              name: c.name,
              slug: c.slug,
              imageUrl: c.imageUrl,
              creatorAddress: c.creatorAddress,
            ),
          )
          .toList(),
      tags: item.tags,
      quantitySold: quantitySold,
      quantityTotal: quantityTotal,
      animationUrl: item.videoUrl,
      playbackId: item.playbackId,
      royaltySplits: item.royalties
          .where((r) => (r.address ?? '').isNotEmpty)
          .map(
            (r) => ArtworkRoyaltySplit(
              address: r.address!,
              sharePercent: (r.bps / 100).round(),
              username: r.username,
              displayName: r.displayName,
            ),
          )
          .toList(),
      royaltyPercent: _royaltyPercentFromApi(item),
      mimeType: asset?.mimeType,
      dimensions: dimensions,
      fileSizeBytes: asset?.fileSize,
      isMutable: item.isImmutable == null ? null : !item.isImmutable!,
      updateAuthority: item.updateAuth,
      tokenStandard: item.tokenStandard,
      metadataUrl: item.metadataUrl,
      chain: item.chain,
      // Either flag means "the viewer has hidden this from their own
      // profile": /v0/hide writes the creator one when the caller minted the
      // piece and the owner one otherwise, so a creator who has since sold it
      // only ever gets `isCreatorHidden`. Both are emitted only to the wallet
      // that set them.
      isHidden: item.isOwnerHidden || item.isCreatorHidden,
    );
  }

  /// The overall seller-fee percentage, read from the API's top-level
  /// `sellerFeeBasisPoints` (the Metaplex convention, and the only field the
  /// webapp's Royalties row reads — `ArtworkDetails`).
  ///
  /// Returns null when the index reports 0 or nothing, which the Details tab
  /// resolves against the chain before falling back to `0%`
  /// ([ArtworkPermissions.onChainRoyaltyBps]) — the webapp's
  /// `sellerFeeBasisPoints === 0 && onChainAsset != null` branch.
  ///
  /// It deliberately does NOT fall back to `royalties[].bps`: those are each
  /// creator's *share* of the royalty (they sum to 10000 — the webapp renders
  /// them under "Proceeds splits"), not the royalty rate. Using them made a
  /// single-creator artwork with no indexed seller fee read "Royalties 100%".
  String? _royaltyPercentFromApi(api.NftDetail item) {
    final sellerFeeBps = item.sellerFeeBasisPoints;
    if (sellerFeeBps != null && sellerFeeBps > 0) {
      return _formatBpsPercent(sellerFeeBps);
    }
    return null;
  }

  /// Format a bps value as a percent string with up to 2 decimals
  /// (matches the webapp's `round(bps / 100, 2)`). Trailing zeros are
  /// stripped so whole percentages render as `"5"`, not `"5.00"`.
  String _formatBpsPercent(int bps) =>
      stripTrailingZeros((bps / 100).toStringAsFixed(2));

  /// Every wallet linked to [ref], deduplicated. Includes the explicit
  /// `address`, `primaryAddress`, and the full `addresses` list — so a
  /// mallow user with multiple linked wallets can be matched against any
  /// of them. Returns an empty list when [ref] is null or carries no
  /// address-shaped fields.
  List<String> _allAddresses(api.ApiUserRef? ref) {
    if (ref == null) return const [];
    final out = <String>{};
    final a = ref.address;
    if (a != null && a.isNotEmpty) out.add(a);
    final p = ref.primaryAddress;
    if (p != null && p.isNotEmpty) out.add(p);
    for (final addr in ref.addresses) {
      if (addr.isNotEmpty) out.add(addr);
    }
    return out.toList(growable: false);
  }

  api.SupplyType _determineSupplyType(api.NftDetail item) {
    if (item.parentEdition != null) return api.SupplyType.editionPrint;
    // Webapp parity (ArtworkDetails): keyed off `maxSupply`
    // alone. Metaplex's `MaxSupply::Some(0)` (open edition) serializes
    // to `null` over this API; `supply` may be 0 with no prints minted
    // yet, so we cannot use it as a tiebreaker.
    final max = item.maxSupply;
    if (max == null) return api.SupplyType.openEdition;
    if (max <= 1) return api.SupplyType.oneOfOne;
    return api.SupplyType.limitedEdition;
  }
}
