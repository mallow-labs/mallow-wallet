import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../shared/utils/user_display.dart';
import '../../artwork/widgets/add_to_curation_sheet.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../services/curations_refresh_signal.dart';

/// Repository for managing user curations (create, list, add/remove artworks).
@lazySingleton
class CurationRepository {
  CurationRepository(this._api);

  final api.MallowApiClient _api;

  /// Fetch curations mapped to [UserCuration].
  ///
  /// With no [ownerAddress], returns the authenticated user's own curations
  /// (private items included only when the wallet has a valid signed-login
  /// session). Pass [ownerAddress] to list another user's public/featured
  /// curations. Pass [mintAccount] to mark curations that already contain that
  /// artwork as selected (via the backend's `containsArtwork` flag).
  Future<List<UserCuration>> getCurations({
    String? mintAccount,
    String? ownerAddress,
  }) async {
    final response = await _api.getCurations(
      mintAccount: mintAccount,
      owner: ownerAddress,
    );
    return response.result
        .map(
          (c) => UserCuration(
            id: c.id,
            name: c.name,
            artworkCount: c.artworkCount,
            thumbnailUrls: c.thumbnailUrls,
            isSelected: c.containsArtwork,
            visibility: c.visibility,
          ),
        )
        .toList();
  }

  /// Map [UserCuration]s into curation [ArtGroup]s so they slot into the same
  /// groups list as collections. [creatorName] is shown as the subtitle.
  ///
  /// The curation id goes into [ArtGroup.id] (bare, no `curation:` prefix),
  /// which [CurationScreen] uses to fetch the artwork list via
  /// [getCurationById].
  static List<ArtGroup> curationsToGroups(
    List<UserCuration> curations, {
    required String creatorName,
  }) {
    return curations
        .map(
          (c) => ArtGroup(
            id: c.id,
            type: ArtGroupType.curation,
            name: c.name,
            thumbnailUrl: c.thumbnailUrls.firstOrNull,
            artworkCount: c.artworkCount,
            creatorName: creatorName,
          ),
        )
        .toList();
  }

  /// Create a new curation with [name]. Returns the newly created [UserCuration].
  ///
  /// The backend creates curations as `private`; the app's default is
  /// public, so unless [isPrivate] the visibility is patched to `public`
  /// right after creation.
  Future<UserCuration> createCuration(
    String name, {
    bool isPrivate = false,
  }) async {
    final response = await _api.createCuration(
      api.CreateCurationRequest(name: name),
    );
    final c = response.result;
    if (!isPrivate) {
      await _api.patchCuration(
        c.id,
        const api.PatchCurationRequest(visibility: 'public'),
      );
    }
    notifyCurationsRefresh();
    return UserCuration(
      id: c.id,
      name: c.name,
      artworkCount: c.artworkCount,
      thumbnailUrls: c.thumbnailUrls,
    );
  }

  /// Update the curation's [name] and/or visibility. Pass [isPrivate] only
  /// when the user actually toggled it — visibility can also be `featured`,
  /// which an unconditional public/private patch would clobber.
  Future<void> updateCuration(
    String curationId, {
    String? name,
    bool? isPrivate,
  }) async {
    await _api.patchCuration(
      curationId,
      api.PatchCurationRequest(
        name: name,
        visibility: isPrivate == null
            ? null
            : (isPrivate ? 'private' : 'public'),
      ),
    );
    notifyCurationsRefresh();
  }

  /// Delete the curation with [curationId]. Owner-only.
  Future<void> deleteCuration(String curationId) async {
    await _api.deleteCuration(curationId);
    notifyCurationsRefresh();
  }

  /// Add [mintAccount] to the curation with [curationId].
  Future<void> addArtwork(String curationId, String mintAccount) async {
    await _api.addArtworkToCuration(
      curationId,
      api.AddArtworkToCurationRequest(mintAccount: mintAccount),
    );
    notifyCurationsRefresh();
  }

  /// Remove [mintAccount] from the curation with [curationId].
  Future<void> removeArtwork(String curationId, String mintAccount) async {
    await _api.removeArtworkFromCuration(curationId, mintAccount);
    notifyCurationsRefresh();
  }

  /// Fetch a single curation by id along with its artworks.
  ///
  /// Backend gates private curations to the owner — non-public curations
  /// return 404 for anonymous and non-owner callers, which surfaces here as
  /// a thrown error to be handled by the caller.
  Future<CurationDetailResult> getCurationById(String id) async {
    final response = await _api.getCurationById(id);
    final detail = response.result;
    final artworks = detail.artworks
        .map(
          (preview) => PortfolioArtwork(
            mintAccount: preview.mintAccount,
            title: preview.name,
            imageUrl: preview.imageUrl ?? '',
            playbackId: preview.playbackId,
            clipPlaybackId: preview.clipPlaybackId,
            artistName: formatUsernameOrAddress(
              username: preview.creator?.username,
              address: preview.creator?.effectiveAddress,
            ),
            artistUsername: preview.creator?.username,
            aspectRatio: preview.aspectRatio ?? 1.0,
            lastPrice: preview.lastSale?.price,
            collectionName: preview.collectionName,
            listingType: preview.listingType,
            supply: preview.supply,
            maxSupply: preview.maxSupply,
            editionNumber: preview.editionNumber,
            parentEdition: preview.parentEdition,
            auctionMetadata: preview.auctionMetadata,
            buyNowMetadata: preview.buyNowMetadata,
            raffleMetadata: preview.raffleMetadata,
            updateAuth: preview.updateAuth,
            nsfw: preview.nsfw ?? false,
            // Needed by the detailed card's sold-out derivation, which is
            // chain-dependent (`PortfolioArtwork._editionsAvailable`).
            chain: preview.chain,
          ),
        )
        .toList();
    return CurationDetailResult(detail: detail, artworks: artworks);
  }
}

/// Result of fetching a curation by id — full backend detail plus the
/// artwork list mapped into the UI's [PortfolioArtwork] shape.
class CurationDetailResult {
  const CurationDetailResult({required this.detail, required this.artworks});

  final api.CurationDetail detail;
  final List<PortfolioArtwork> artworks;
}
