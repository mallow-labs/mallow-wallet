import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/services/collection_download_service.dart';
import '../widgets/download_destination_sheet.dart';

/// Full bulk-download UX shared by the collection and curation option
/// sheets: destination chooser → modal progress sheet → (files destination)
/// OS share sheet → result snackbar.
///
/// [resolveArtworks] returns the already-gated list — ownership filtering
/// happens before this. It is a callback, not a list, because the callers'
/// screens are paged: a group of 90 has 20 artworks in `state.items` until the
/// user scrolls, and passing that prefix downloaded 20 and reported success.
/// Callers with a genuinely complete list in hand ignore the argument and
/// return theirs; paged ones pass a `drainPages` walk. It runs behind the
/// progress sheet, so the walk is visible rather than a frozen tap, and it is
/// handed an `isCancelled` probe so Cancel stops the walk between pages
/// instead of only taking effect once every page has been fetched.
Future<void> runBulkArtworkDownload(
  BuildContext context, {
  required Future<List<PortfolioArtwork>> Function(bool Function() isCancelled)
  resolveArtworks,
  required String albumName,
}) async {
  final destination = await showDownloadDestinationSheet(context);
  if (destination == null || !context.mounted) return;
  final toFiles = destination == DownloadDestination.files;
  final service = sl<CollectionDownloadService>();

  Future<CollectionDownloadProgress> resolveThenDownload() async {
    final artworks = await resolveArtworks(() => service.isCancelled);
    if (artworks.isEmpty || service.isCancelled) {
      return CollectionDownloadProgress(
        completed: 0,
        failed: 0,
        total: artworks.length,
        cancelled: service.isCancelled,
      );
    }
    return service.downloadAll(
      artworks: artworks,
      albumName: albumName,
      destination: destination,
    );
  }

  // The handler is attached here, not after the sheet closes: a batch that
  // throws before then (a refused photo-library prompt does, immediately) would
  // otherwise complete with no error listener and be reported as an unhandled
  // async error. [batchError] carries the cause through to the snackbar.
  Object? batchError;
  final future = resolveThenDownload().catchError((Object e) {
    batchError = e;
    return const CollectionDownloadProgress(completed: 0, failed: 0, total: 0);
  });

  await showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (sheetCtx) => PopScope(
      canPop: false,
      child: DownloadProgressSheet(
        title: toFiles ? 'Downloading' : 'Saving to Photos',
        progressStream: service.progress,
        future: future,
        onCancel: service.cancel,
      ),
    ),
  );

  // Cancel closes the sheet on the tap rather than when the batch unwinds, so
  // the batch may still be draining here. It is not awaited: the download side
  // stops at once (the requests are cancelled outright) but the photo-library
  // write in flight has no cancel channel and only its timeout to end it, and
  // holding the result message behind that would land a "Cancelled" toast up to
  // a minute after the sheet closed. Counts come from the last snapshot, and
  // cleanup rides along behind the drain so nothing is torn down mid-write.
  if (service.isCancelled) {
    final snap = service.lastProgress;
    unawaited(
      future.whenComplete(() async {
        await service.releaseFiles();
        service.dispose();
      }),
    );
    if (!context.mounted) return;
    AppSnackBar.show(
      context,
      snap == null
          ? 'Cancelled'
          : 'Cancelled at ${snap.attempted}/${snap.total}',
    );
    return;
  }

  // Past the cancel branch the batch ran to the end, so `result.cancelled` is
  // necessarily false and is not re-tested below.
  final result = await future;
  // Files destination: the batch sits in a temp dir — hand it to the OS
  // share sheet (iOS "Save to Files" keeps individual images; a writable
  // folder picker isn't viable, see DownloadDestination) then clean up.
  if (toFiles && result.completed > 0) {
    try {
      await SharePlus.instance.share(
        ShareParams(
          // Explicit mime type — share targets (AirDrop, Files) behave
          // better with one than with extension guessing.
          files: service.savedFilePaths
              .map(
                (path) => XFile(
                  path,
                  mimeType: lookupMimeType(path) ?? 'application/octet-stream',
                ),
              )
              .toList(),
        ),
      );
    } catch (_) {
      if (context.mounted) AppSnackBar.show(context, 'Export failed');
    }
  }
  await service.releaseFiles();
  service.dispose();
  if (!context.mounted) return;
  final failure = batchError;
  if (failure != null) {
    AppSnackBar.show(
      context,
      failure is DownloadAccessDeniedException
          ? 'Photo library access is required to save'
          : 'Download failed',
    );
  } else if (result.total == 0) {
    AppSnackBar.show(context, 'Nothing to download');
  } else if (result.failed > 0) {
    AppSnackBar.show(
      context,
      'Downloaded ${result.completed}/${result.total} — ${result.failed} failed',
    );
  } else if (!toFiles) {
    AppSnackBar.show(context, 'Saved ${result.completed} artworks');
  }
}

/// Modal progress sheet for the bulk download flow. Closes itself when the
/// underlying `future` resolves, or on Cancel — which stops the batch and
/// closes immediately rather than waiting for it to drain.
///
/// Non-dismissible — a download in progress shouldn't be swiped away
/// accidentally; the user must use the Cancel button, which is therefore the
/// only way out and has to work even when the batch does not finish.
@visibleForTesting
class DownloadProgressSheet extends StatefulWidget {
  const DownloadProgressSheet({
    required this.title,
    required this.progressStream,
    required this.future,
    required this.onCancel,
    super.key,
  });

  final String title;
  final Stream<CollectionDownloadProgress> progressStream;
  final Future<CollectionDownloadProgress> future;
  final VoidCallback onCancel;

  @override
  State<DownloadProgressSheet> createState() => _DownloadProgressSheetState();
}

class _DownloadProgressSheetState extends State<DownloadProgressSheet> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.future.whenComplete(() {
      if (!mounted || _closed) return;
      _closed = true;
      Navigator.of(context).pop();
    });
  }

  /// Stops the batch and closes the sheet in the same gesture.
  ///
  /// Closing here rather than waiting for the batch to unwind is the point: the
  /// sheet is non-dismissible and had no exit but the future resolving, so
  /// anything that stopped the batch from finishing — a stalled gateway, a
  /// photo-library write parked behind a system permission sheet — left Cancel
  /// looking dead and the app needing a force-quit. Cancel is now a promise
  /// about the UI, which the service alone cannot make.
  void _cancel() {
    if (_closed) return;
    _closed = true;
    widget.onCancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The loader carries the "still working" signal: a large
                  // original can spend tens of seconds on one gateway, during
                  // which the counter and the bar do not move at all.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: MallowTheme.editorialSection.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: MallowTheme.spacingSm),
                      const MallowLoader(size: 24),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  StreamBuilder<CollectionDownloadProgress>(
                    stream: widget.progressStream,
                    builder: (context, snap) {
                      // No snapshot yet means the artwork list is still being
                      // walked — the count isn't knowable, so the bar runs
                      // indeterminate rather than sitting at a fake 0 / N.
                      final p = snap.data;
                      final completed = p?.completed ?? 0;
                      final failed = p?.failed ?? 0;
                      final total = p?.total ?? 0;
                      final attempted = completed + failed;
                      final ratio = total == 0 ? 0.0 : attempted / total;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            p == null ? 'Preparing…' : '$attempted / $total',
                            style: MallowTheme.uiBody.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: MallowTheme.spacingSm),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              MallowTheme.radiusFull,
                            ),
                            child: LinearProgressIndicator(
                              value: p == null ? null : ratio.clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: colors.divider,
                              valueColor: AlwaysStoppedAnimation(
                                colors.textPrimary,
                              ),
                            ),
                          ),
                          if (failed > 0) ...[
                            const SizedBox(height: MallowTheme.spacingSm),
                            Text(
                              '$failed failed',
                              style: MallowTheme.uiCaption.copyWith(
                                color: colors.error,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  MallowButton(
                    label: 'Cancel',
                    variant: MallowButtonVariant.secondary,
                    isFullWidth: true,
                    onPressed: _closed ? null : _cancel,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
