// Single source of truth for the "Direct all proceeds to creators"
// (`disablePrimarySplit`) gate and the primary/secondary-market
// classification that drives it. The listing blocs and MarketBloc share
// the webapp royalty and sale-classification rules through these helpers.
//
// Parity sources, all on the webapp side:
//   - `assets` — `isSecondaryMarket`
//   - `umi` — `getRoyalties`
//   - `ProceedsInfo`
//     and `AcceptNftOfferModal` — `showDirectProceedsOption`

import '../../../core/network/das_api_service.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/models/on_chain_asset.dart';
import '../../artwork/services/artwork_bloc.dart'
    show ArtworkDetails, ArtworkRoyaltySplit;
import 'marketplace_config_service.dart';
import '../../sell/services/trade_eligibility.dart';

/// Whether the asset trades on the secondary market, per token standard.
/// Ported from the webapp's `isSecondaryMarket`, which matches what the
/// programs settle:
///   - Nft → `primarySaleHappened`.
///   - pNFT → always secondary. Token Metadata refuses to flip
///     `primarySaleHappened` on a programmable NFT, so the marketplace and
///     auction programs settle every pNFT sale at the secondary rate and split.
///   - cNFT (Bubblegum v1 and v2) → always secondary. The marketplace program
///     sells every compressed leaf at the secondary rate, whatever the leaf's
///     `primarySaleHappened` says.
///   - Core → `owner != collection.updateAuthority` when the parent
///     collection asset is supplied, else `owner != asset.updateAuthority`.
///   - CoreCollection → always false (primary).
///
/// [collection] is the fetched parent-collection asset; supply it only for
/// Core or Bubblegum v2 assets that carry a `collectionKey`. Non-Solana standards (EVM/Tezos)
/// never reach the Solana listing flows and default to primary (false).
bool isSecondaryMarketOf(DigitalAsset asset, {DigitalAsset? collection}) {
  switch (asset.tokenStandard) {
    case TokenStandard.nft:
      return asset.primarySaleHappened;
    case TokenStandard.pnft:
    case TokenStandard.cnft:
    case TokenStandard.cnftV2:
      return true;
    case TokenStandard.core:
      if (collection != null) {
        return asset.owner != collection.updateAuthority;
      }
      return asset.owner != asset.updateAuthority;
    case TokenStandard.coreCollection:
    case TokenStandard.objkt:
    case TokenStandard.native:
    case TokenStandard.erc20:
    case TokenStandard.erc721:
    case TokenStandard.erc1155:
      return false;
  }
}

/// Whether the "Direct all proceeds to creators" toggle should be offered.
/// Mirrors `ProceedsInfo` / `AcceptNftOfferModal`: only on a
/// primary sale with creator shares where the seller isn't the first creator
/// (the split would otherwise be a no-op for the seller).
///
/// Named `…Of` to avoid shadowing the same-named `showDirectProceedsOption`
/// getter on the listing-bloc states that delegate to it.
bool showDirectProceedsOptionOf({
  required bool isSecondary,
  required String? seller,
  required List<ArtworkRoyaltySplit> shares,
}) {
  return !isSecondary && shares.isNotEmpty && shares.first.address != seller;
}

/// Resolved royalty economics: the effective creator shares and the fee/
/// royalty basis points used by the proceeds breakdown.
typedef ResolvedRoyalties = ({
  int royaltyBps,
  List<ArtworkRoyaltySplit> shares,
});

/// On-chain royalty resolution, faithful port of `getRoyalties`
/// (`umi`). For a Core asset with no own royalties plugin whose update
/// authority is delegated to its collection, falls back to the collection's
/// royalties plugin — hence the optional [collection] parameter, which the
/// caller fetches. Token-metadata standards read their own creators.
///
/// This is the on-chain (DAS-derived) counterpart to the API-served
/// [ArtworkDetails.royaltySplits] the listing blocs use today. Consumed by
/// `MarketBloc`'s direct-proceeds gate and by `ArtworkPermissionService`, which
/// hands `royaltyBps` to the artwork Details tab as its on-chain royalty
/// fallback (a Core/pNFT asset's royalty can live only in the plugin).
ResolvedRoyalties resolveOnChainRoyalties(
  DigitalAsset asset, {
  DigitalAsset? collection,
}) {
  switch (asset.tokenStandard) {
    case TokenStandard.core:
      final hasOwnPlugin = asset.royaltiesPluginCreators.isNotEmpty;
      // Fall back to the collection's royalties plugin only when the asset
      // carries none of its own and the parent is a CoreCollection.
      if (!hasOwnPlugin &&
          collection != null &&
          collection.tokenStandard == TokenStandard.coreCollection) {
        return (
          royaltyBps: collection.royaltiesPluginBasisPoints ?? 0,
          shares: _fromOnChainCreators(collection.royaltiesPluginCreators),
        );
      }
      return (
        royaltyBps: asset.royaltiesPluginBasisPoints ?? 0,
        shares: _fromOnChainCreators(asset.royaltiesPluginCreators),
      );
    case TokenStandard.coreCollection:
      return (
        royaltyBps: asset.royaltiesPluginBasisPoints ?? 0,
        shares: _fromOnChainCreators(asset.royaltiesPluginCreators),
      );
    case TokenStandard.cnftV2:
      if (asset.sellerFeeBasisPoints != 65535 &&
          asset.tokenMetadataCreators.isNotEmpty) {
        return (
          royaltyBps: asset.sellerFeeBasisPoints ?? 0,
          shares: _fromOnChainCreators(asset.tokenMetadataCreators),
        );
      }
      if (collection != null &&
          collection.id == asset.collectionKey &&
          collection.tokenStandard == TokenStandard.coreCollection) {
        return (
          royaltyBps: collection.royaltiesPluginBasisPoints ?? 0,
          shares: _fromOnChainCreators(collection.royaltiesPluginCreators),
        );
      }
      return (royaltyBps: 0, shares: const []);
    case TokenStandard.nft:
    case TokenStandard.pnft:
    case TokenStandard.cnft:
      return (
        royaltyBps: asset.sellerFeeBasisPoints ?? 0,
        shares: _fromOnChainCreators(asset.tokenMetadataCreators),
      );
    case TokenStandard.objkt:
    case TokenStandard.native:
    case TokenStandard.erc20:
    case TokenStandard.erc721:
    case TokenStandard.erc1155:
      return (royaltyBps: 0, shares: const []);
  }
}

List<ArtworkRoyaltySplit> _fromOnChainCreators(List<OnChainCreator> creators) =>
    creators
        .map(
          (c) => ArtworkRoyaltySplit(address: c.address, sharePercent: c.share),
        )
        .toList(growable: false);

/// Effective listing fees + royalty, resolving the source precedence: prefer
/// the backend's server-derived `listingFees` when present (it folds the
/// primary/secondary classification and any discount-token rebate into one
/// effective `feeBps`), else fall back to the on-chain marketplace config +
/// DAS-derived royalty. Extracted from the two listing blocs' identical
/// `_onStarted` logic.
typedef ResolvedListingEconomics = ({
  List<ArtworkRoyaltySplit> royaltyShares,
  int royaltyBps,
  int primaryFeeBps,
  int secondaryFeeBps,
});

ResolvedListingEconomics resolveListingEconomics({
  required ArtworkDetails? detail,
  required MarketplaceFees fees,
}) {
  var royaltyShares = const <ArtworkRoyaltySplit>[];
  var royaltyBps = 0;
  if (detail != null) {
    royaltyShares = detail.royaltySplits;
    // `royaltyPercent` is a whole-percent string like "10" — convert to bps.
    final pct = double.tryParse(detail.royaltyPercent ?? '');
    if (pct != null && (pct * 100).round() != 65535) {
      royaltyBps = (pct * 100).round();
    }
  }

  final apiFees = detail?.listingFees;
  final apiFeeBps = apiFees?.feeBps;
  return (
    royaltyShares: royaltyShares,
    royaltyBps: apiFees?.royaltyBps == 65535
        ? royaltyBps
        : (apiFees?.royaltyBps ?? royaltyBps),
    primaryFeeBps: apiFeeBps ?? fees.primaryBps,
    secondaryFeeBps: apiFeeBps ?? fees.secondaryBps,
  );
}

/// Everything the review step needs about a mint, resolved from DAS + the
/// artwork API + the on-chain marketplace config in one pass. Shared by both
/// listing blocs and by their `_onStarted` and select-artwork handlers.
typedef ListingContextData = ({
  DigitalAsset? asset,
  TradeEligibility tradeEligibility,
  ArtworkDetails? detail,
  bool isSecondaryMarket,
  bool isVerifiedSeller,
  String? updateAuthority,
  List<ArtworkRoyaltySplit> royaltyShares,
  int royaltyBps,
  int primaryFeeBps,
  int secondaryFeeBps,
});

/// Fetch and resolve the listing context for [mint]. All network calls
/// degrade gracefully: a rejected DAS/detail future resolves to null (hidden
/// options / empty breakdown), with incomplete v2 or unknown eligibility reported
/// as unverified. Handlers are attached at
/// future creation — never after an intervening `await` — so a rejection
/// during the marketplace-config round-trip can't escape to the zone's
/// uncaught-error handler.
Future<ListingContextData> resolveListingContext({
  required String mint,
  required String sellerPubkey,
  String? expectedTokenStandard,
  required DasApiService dasApi,
  required ArtworkRepository artworkRepo,
  required MarketplaceConfigService marketplaceConfig,
}) async {
  final assetFuture = Future<DigitalAsset>.sync(
    () => dasApi.getAsset(mint),
  ).then<DigitalAsset?>((a) => a, onError: (Object _) => null);
  final detailFuture = Future<ArtworkDetails>.sync(
    () => artworkRepo.getArtworkDetail(mint),
  ).then<ArtworkDetails?>((d) => d, onError: (Object _) => null);
  // Start the dependent parent read as soon as DAS resolves; it overlaps the
  // independent artwork/config reads and is reused for eligibility and royalties.
  final collectionFuture = assetFuture.then<DigitalAsset?>((asset) async {
    if (asset != null &&
        (asset.tokenStandard == TokenStandard.core ||
            asset.tokenStandard == TokenStandard.cnftV2) &&
        asset.collectionKey != null) {
      try {
        return await dasApi.getAsset(asset.collectionKey!);
      } catch (_) {
        return null;
      }
    }
    return null;
  });

  final fees = await marketplaceConfig.get();
  final asset = await assetFuture;
  final detail = await detailFuture;
  final collection = await collectionFuture;

  final isSecondary = asset != null
      ? isSecondaryMarketOf(asset, collection: collection)
      : false;
  // Verified-seller gate stays on the update-authority predicate (webapp's
  // separate "verified update authority" arm, ListingContext) — only
  // isSecondaryMarket moved to the primarySaleHappened/owner semantics.
  final isVerifiedSeller =
      asset?.updateAuthority != null && asset!.updateAuthority == sellerPubkey;

  final econ = resolveListingEconomics(detail: detail, fees: fees);

  final tradeEligibility = resolveTradeEligibility(
    asset: asset,
    collection: collection,
    expectedTokenStandard: detail?.tokenStandard == 'cnft-v2'
        ? 'cnft-v2'
        : expectedTokenStandard ?? detail?.tokenStandard,
  );
  final v2Royalties = asset?.tokenStandard == TokenStandard.cnftV2
      ? resolveOnChainRoyalties(asset!, collection: collection)
      : null;

  return (
    asset: asset,
    tradeEligibility: tradeEligibility,
    detail: detail,
    isSecondaryMarket: isSecondary,
    isVerifiedSeller: isVerifiedSeller,
    updateAuthority: asset?.updateAuthority ?? detail?.updateAuthority,
    royaltyShares: v2Royalties?.shares ?? econ.royaltyShares,
    royaltyBps: v2Royalties?.royaltyBps ?? econ.royaltyBps,
    primaryFeeBps: econ.primaryFeeBps,
    secondaryFeeBps: econ.secondaryFeeBps,
  );
}
