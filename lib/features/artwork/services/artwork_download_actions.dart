import 'package:flutter/widgets.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/observability/app_logger.dart';
import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/services/collection_download_service.dart';
import '../widgets/download_destination_sheet.dart';
import 'active_wallet_verification.dart';

/// Asks where to save, verifies the active wallet, then saves [artwork]
/// either to the device photo library under [albumName] or — via the OS
/// share sheet — to a user-picked location in the Files app.
///
/// Verification matches hide/unhide — see [ensureActiveWalletVerified] for the
/// branch table. The download is aborted when it fails, including when the user
/// dismisses the interactive prompt this tap has earned.
///
/// The "Download to device" option is only shown for owned/created artworks
/// signed by a signable wallet (see `ArtworkPermissions.canDownload`), so the
/// active wallet is expected to sign here.
Future<void> downloadArtworkWithVerify(
  BuildContext context,
  PortfolioArtwork artwork, {
  String albumName = 'mallow',
}) async {
  final destination = await showDownloadDestinationSheet(context);
  if (destination == null) return;
  final verifyError = await ensureActiveWalletVerified();
  if (verifyError != null) {
    // Fail loud — a silent abort here reads as "nothing happened".
    if (context.mounted) AppSnackBar.show(context, verifyError);
    return;
  }
  if (!context.mounted) return;

  final service = sl<CollectionDownloadService>();
  try {
    final result = await service.downloadAll(
      artworks: [artwork],
      albumName: albumName,
      destination: destination,
    );
    if (!context.mounted) return;
    if (destination == DownloadDestination.files) {
      await _exportToFiles(context, service);
    } else {
      AppSnackBar.show(
        context,
        result.completed > 0 ? 'Saved to device' : 'Download failed',
      );
    }
  } on DownloadAccessDeniedException {
    if (context.mounted) {
      AppSnackBar.show(context, 'Photo library access is required to save');
    }
  } catch (e) {
    AppLogger.error('ArtworkDownload', 'download failed', e);
    if (context.mounted) AppSnackBar.show(context, 'Download failed');
  } finally {
    // Releases the batch without deleting it — the file just handed to the
    // share sheet has to outlive this call (an iOS AirDrop reads it after
    // `share` resolves). Do not turn this back into an eager delete; see
    // [CollectionDownloadService.releaseFiles].
    await service.releaseFiles();
    service.dispose();
  }
}

/// Hands the downloaded temp file to the OS share sheet, where iOS "Save to
/// Files" is the save destination. This matches the bulk path in
/// `runBulkArtworkDownload` — a writable folder picker isn't viable on
/// either platform (see [DownloadDestination]), and the one package that
/// offered a cross-platform save dialog (`file_picker`) linked CoreLocation.
///
/// The [ShareResult] only names the activity the user picked — Android reports
/// the chooser's result and an iOS action reports whatever it likes — so it is
/// neither a "saved" confirmation worth showing nor a signal that the receiver
/// has finished reading the file. The temp file therefore has to stay on disk
/// past this call; see [CollectionDownloadService.releaseFiles].
Future<void> _exportToFiles(
  BuildContext context,
  CollectionDownloadService service,
) async {
  final path = service.savedFilePaths.isNotEmpty
      ? service.savedFilePaths.first
      : null;
  if (path == null) {
    AppSnackBar.show(context, 'Download failed');
    return;
  }
  try {
    await SharePlus.instance.share(
      ShareParams(
        // Explicit mime type — share targets (AirDrop, Files) behave better
        // with one than with extension guessing.
        files: [
          XFile(
            path,
            mimeType: lookupMimeType(path) ?? 'application/octet-stream',
          ),
        ],
      ),
    );
  } catch (_) {
    if (context.mounted) AppSnackBar.show(context, 'Export failed');
  }
}
