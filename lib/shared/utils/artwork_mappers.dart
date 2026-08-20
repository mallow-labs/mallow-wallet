import '../../features/artwork/services/artwork_bloc.dart';
import '../../features/portfolio/services/portfolio_bloc.dart';

/// Maps an [ArtworkDetails] (full artwork-detail payload) onto the
/// [PortfolioArtwork] shape consumed by the listing flows.
///
/// Used when the listing bloc is started with only a mint (entry from the
/// artwork detail screen) — no preselected `PortfolioArtwork` exists, so we
/// rebuild one from the detail fetch we already do.
///
/// `parentEdition` is preserved only as a non-null marker for
/// [PortfolioArtwork.isMasterEdition] — `ArtworkDetails` doesn't surface
/// the actual master mint, so we use the artwork's own mint as the marker
/// when the supply type indicates an edition print.
extension ArtworkDetailsToPortfolio on ArtworkDetails {
  PortfolioArtwork toPortfolioArtwork() {
    return PortfolioArtwork(
      mintAccount: mintAccount,
      title: title,
      imageUrl: imageUrl,
      artistName: artistName,
      artistUsername: artistUsername,
      collectionName: collectionName,
      supply: supply,
      maxSupply: maxSupply,
      editionNumber: editionNumber,
      parentEdition: supplyType == SupplyType.editionPrint ? mintAccount : null,
      animationUrl: animationUrl,
      updateAuth: updateAuthority,
      // Carried for the context menu's burn gate (webapp parity: burn is
      // hidden while listed), not for the listing flows themselves.
      listingType: listingType,
      nsfw: nsfw,
      // Carried so the context menu's Hide/Unhide row labels correctly.
      isHidden: isHidden,
    );
  }
}
