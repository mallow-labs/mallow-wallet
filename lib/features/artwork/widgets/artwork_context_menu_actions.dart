import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/new_curation_sheet.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../curations/data/curation_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../services/artwork_download_actions.dart';
import '../services/artwork_hide_actions.dart';
import 'add_to_curation_sheet.dart';
import 'artwork_context_menu_sheet.dart';
import 'burn_artwork_flow.dart';
import 'transfer_artwork_flow.dart';

/// Shows the artwork context menu for [artwork] (long-press on any artwork
/// card / mosaic cell) and runs the default handling for the returned action:
/// cast, add-to-curation, download, view, transfer and burn.
///
/// This is the generic surface-agnostic handler. Screens that need extra
/// behaviour (curation removal, screen-local list mutation on uncheck, sync
/// token, etc.) keep their own `_showArtworkContextMenu` and only share the
/// sheet itself via [showArtworkContextMenu].
///
/// Optimistic removal after a confirmed transfer or burn is handled globally:
/// the flows fire [ArtworkRemovalSignal] and every mounted owned-art view drops
/// the item — so callers don't wire per-screen removal here (a transfer to one
/// of the viewer's own session wallets is correctly kept, which a per-call-site
/// `onRemoved` couldn't know). See `refreshMyArtAfterRemoval`.
Future<void> showAndHandleArtworkContextMenu(
  BuildContext context, {
  required PortfolioArtwork artwork,

  /// Pass false on surfaces that can't supply the artwork's real hidden state
  /// (e.g. home spotlight / featured listings build synthetic artworks with
  /// [PortfolioArtwork.isHidden] always false) so the Hide row is suppressed
  /// rather than mislabeled. See [showArtworkContextMenu].
  bool showHide = true,
}) async {
  final action = await showArtworkContextMenu(
    context,
    artwork: artwork,
    showHide: showHide,
  );
  if (!context.mounted || action == null) return;
  final item = CastQueueItemFromArtwork.fromPortfolioArtwork(artwork);
  switch (action) {
    case ArtworkContextMenuAction.castToScreen:
      unawaited(castArtworkWithVerify(item));
    case ArtworkContextMenuAction.addToCastQueue:
      addArtworksToCastQueue([item]);
      AppSnackBar.show(context, 'Added to cast');
    case ArtworkContextMenuAction.addToCuration:
      await runAddToCurationFlow(context, artwork: artwork);
    case ArtworkContextMenuAction.download:
      await downloadArtworkWithVerify(context, artwork);
    case ArtworkContextMenuAction.hideArtwork:
      await toggleArtworkHidden(
        context,
        mintAccount: artwork.mintAccount,
        currentlyHidden: artwork.isHidden,
      );
    case ArtworkContextMenuAction.viewArtwork:
      await context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
    case ArtworkContextMenuAction.transfer:
      final transferred = await runTransferArtworkFlow(
        context,
        artwork: artwork,
      );
      if (transferred && context.mounted) {
        AppSnackBar.show(context, 'Artwork transferred');
      }
    case ArtworkContextMenuAction.burn:
      final burned = await runBurnArtworkFlow(context, artwork: artwork);
      if (burned && context.mounted) {
        AppSnackBar.show(context, 'NFT burned');
      }
    default:
      break;
  }
}

/// Fetches the viewer's curations (with per-curation membership for
/// [artwork]) and opens the add-to-curation sheet. Profile-gated like all
/// social actions.
Future<void> runAddToCurationFlow(
  BuildContext context, {
  required PortfolioArtwork artwork,
}) async {
  if (!await requireProfile(context)) return;
  if (!context.mounted) return;
  final repo = sl<CurationRepository>();
  List<UserCuration> curations;
  try {
    curations = await repo.getCurations(mintAccount: artwork.mintAccount);
  } catch (_) {
    curations = [];
  }
  if (!context.mounted) return;
  await showAddToCurationSheet(
    context,
    artworkTitle: formatArtworkName(
      name: artwork.title,
      editionNumber: artwork.editionNumber,
    ),
    artworkImageUrl: artwork.imageUrl,
    artistUsername: artwork.artistUsername ?? artwork.artistName,
    curations: curations,
    onToggleCuration: (curationId, isSelected) {
      if (isSelected) {
        repo.addArtwork(curationId, artwork.mintAccount);
      } else {
        repo.removeArtwork(curationId, artwork.mintAccount);
      }
    },
    onCreateNew: () async {
      final result = await showNewCurationSheet(context);
      if (result == null) return null;
      try {
        final created = await repo.createCuration(
          result.name,
          isPrivate: result.isPrivate,
        );
        await repo.addArtwork(created.id, artwork.mintAccount);
        return created;
      } catch (_) {
        return null;
      }
    },
  );
}
