import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/observability/app_logger.dart';
import '../../../core/utils/asset_url.dart';
import '../../../core/utils/mallow_image.dart';
import '../../portfolio/services/portfolio_bloc.dart';

/// Where a download batch lands on the device.
///
/// [photos] saves into the photo library via `gal` (the original behavior);
/// [files] downloads into a temp batch directory whose paths are exposed on
/// [CollectionDownloadService.savedFilePaths] so the caller can hand them to
/// the share sheet. Raw `dart:io` writes into a user-picked folder are NOT
/// viable here: a directory picker returns an iOS path without security-scoped
/// access and an Android path that scoped storage rejects — hence the
/// temp-then-export contract.
enum DownloadDestination { photos, files }

/// Snapshot of the in-flight download batch. Emitted on the progress stream
/// after each artwork completes (success or failure).
class CollectionDownloadProgress {
  const CollectionDownloadProgress({
    required this.completed,
    required this.failed,
    required this.total,
    this.cancelled = false,
  });

  final int completed;
  final int failed;
  final int total;
  final bool cancelled;

  int get attempted => completed + failed;
  bool get isDone => cancelled || attempted >= total;
}

/// Saves every artwork in a list to the device photo library, streaming
/// each file to disk via [Dio.download] and capping concurrency so memory
/// stays bounded on large collections.
///
/// One service instance == one batch. Construct via DI per-batch — its
/// `_cancelled` flag is intentionally non-resettable to keep the contract
/// simple.
@injectable
class CollectionDownloadService {
  CollectionDownloadService()
    : _dio = Dio(
        // Without these a stalled gateway holds a single artwork open forever:
        // there are up to five source candidates per artwork and the batch only
        // notices a cancel between them, so one dead socket froze the whole
        // progress sheet. `receiveTimeout` is per-chunk, not per-download, so a
        // slow-but-alive gateway serving a large original is not cut off.
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

  static const String _tag = 'CollectionDownload';

  /// Ceiling on one photo-library write. PhotoKit does not always call its
  /// completion handler — a limited-access library that has just shown the
  /// system "Select More Photos" alert is the case seen in the wild — and there
  /// is no cancel channel into the platform call, so the only way a hung save
  /// cannot wedge the batch is to stop waiting on it.
  static const Duration _galTimeout = Duration(seconds: 45);

  final Dio _dio;
  final _controller = StreamController<CollectionDownloadProgress>.broadcast();
  bool _cancelled = false;
  final CancelToken _cancelToken = CancelToken();
  final List<String> _savedFilePaths = [];
  Directory? _batchDir;

  static const int _maxConcurrent = 4;
  static const String _batchDirPrefix = 'mallow-dl-';

  Stream<CollectionDownloadProgress> get progress => _controller.stream;

  CollectionDownloadProgress? _lastProgress;

  /// The most recent snapshot, or null before the batch starts. Lets a caller
  /// that has stopped awaiting the batch — the cancel path does, so the
  /// non-cancellable photo-library write cannot delay the result message —
  /// still report how far it got.
  CollectionDownloadProgress? get lastProgress => _lastProgress;

  /// Paths of files written by a [DownloadDestination.files] batch, in
  /// completion order. Empty for photo-library batches. The files live in a
  /// temp directory — call [releaseFiles] once they've been exported.
  List<String> get savedFilePaths => List.unmodifiable(_savedFilePaths);

  /// Creates this batch's temp directory under [tempRoot], first reclaiming
  /// the directories earlier files batches left behind (see [releaseFiles] for
  /// why they outlive their own run). Sweeping on the way in rather than on the
  /// way out keeps at most one batch's bytes on disk at a time.
  @visibleForTesting
  Future<Directory> prepareBatchDir(Directory tempRoot) async {
    await _sweepBatchDirs(tempRoot);
    final dir = await Directory(
      p.join(
        tempRoot.path,
        '$_batchDirPrefix${DateTime.now().millisecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    _batchDir = dir;
    return dir;
  }

  /// Deletes every batch *directory* under [tempRoot]. Directories only:
  /// [_downloadOne]'s photo-library temp files share the prefix, own their own
  /// deletion, and one may be in flight.
  Future<void> _sweepBatchDirs(Directory tempRoot) async {
    try {
      await for (final entity in tempRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (!p.basename(entity.path).startsWith(_batchDirPrefix)) continue;
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      AppLogger.warn(_tag, 'could not reclaim old batch directories: $e');
    }
  }

  /// Releases the [DownloadDestination.files] batch. It deliberately does
  /// **not** delete the files: they have just been handed to the OS share
  /// sheet, and that call returning is not a "the receiver has read them"
  /// signal. iOS hands `UIActivityViewController` a file URL pointing at *this*
  /// path and resolves on `completionWithItemsHandler`, so an AirDrop can still
  /// be transferring — deleting here truncates it with no error anywhere.
  /// (Android is incidentally safe: share_plus copies into its own cache before
  /// building the FileProvider URI. Do not lean on that.)
  ///
  /// Reclaimed by the next files batch ([prepareBatchDir]) and by the OS
  /// purging the app's temp directory, so nothing accumulates past one batch —
  /// the same deferred shape share_plus uses for its own Android share cache.
  /// Safe to call repeatedly.
  Future<void> releaseFiles() async {
    _batchDir = null;
    _savedFilePaths.clear();
  }

  /// True once [cancel] has been called. Lets a caller abandon work it owns
  /// itself — resolving the artwork list, for one — instead of only the chunk
  /// loop below reacting to the flag.
  bool get isCancelled => _cancelled;

  /// Stop the batch: no new chunks start, and every request already in flight
  /// is aborted through the shared [CancelToken].
  ///
  /// The token matters as much as the flag. The flag is only read between
  /// chunks and between an artwork's source candidates, so on its own it does
  /// nothing to a request that is already open — and these requests reach
  /// arbitrary IPFS/Arweave gateways, where "already open" routinely means
  /// stalled. Cancel used to leave up to four of those running and the progress
  /// sheet waiting on them, which read as a frozen screen.
  void cancel() {
    _cancelled = true;
    if (!_cancelToken.isCancelled) _cancelToken.cancel('batch cancelled');
  }

  /// Download every image-bearing artwork in [artworks]. With the default
  /// [DownloadDestination.photos] they land in the photo library album named
  /// [albumName]; with [DownloadDestination.files] they are written to a temp
  /// batch directory (see [savedFilePaths]) and [albumName] is unused.
  /// Returns the final progress snapshot.
  ///
  /// Failures are tolerated per file — one bad URL never aborts the batch.
  /// Non-image media (no `imageUrl`) is silently skipped.
  Future<CollectionDownloadProgress> downloadAll({
    required List<PortfolioArtwork> artworks,
    required String albumName,
    DownloadDestination destination = DownloadDestination.photos,
  }) async {
    final eligible = artworks.where((a) => a.imageUrl.isNotEmpty).toList();
    final total = eligible.length;
    var completed = 0;
    var failed = 0;

    _emit(completed: completed, failed: failed, total: total);

    if (total == 0) {
      const snap = CollectionDownloadProgress(
        completed: 0,
        failed: 0,
        total: 0,
      );
      _publish(snap);
      return snap;
    }

    if (destination == DownloadDestination.photos) {
      // Timed for the same reason as the save itself: this is a platform call
      // that can sit behind a system permission sheet, and a batch that never
      // gets past it leaves the caller's progress sheet with nothing to close
      // it. A prompt the user never answers is a denial as far as this batch
      // is concerned.
      final hasAccess = await Gal.requestAccess(
        toAlbum: true,
      ).timeout(_galTimeout, onTimeout: () => false);
      if (!hasAccess) {
        throw const DownloadAccessDeniedException();
      }
    }

    // On Android the album becomes a MediaStore directory segment
    // (Pictures/<album>), so a '/' in names like "mallow / Foo" would nest
    // directories with stray spaces. iOS albums are plain labels and keep
    // the original.
    final effectiveAlbum = Platform.isAndroid
        ? albumName.replaceAll(' / ', ' - ').replaceAll('/', '-')
        : albumName;

    final tempDir = await getTemporaryDirectory();
    if (destination == DownloadDestination.files) {
      await prepareBatchDir(tempDir);
    }
    // File names are allocated up front (synchronously) so concurrent
    // downloads can't race the duplicate-name counter.
    final fileNames = destination == DownloadDestination.files
        ? _allocateFileNames(eligible)
        : null;

    for (var i = 0; i < eligible.length; i += _maxConcurrent) {
      if (_cancelled) break;
      final chunk = eligible.skip(i).take(_maxConcurrent).toList();
      await Future.wait(
        chunk.map((art) async {
          if (_cancelled) return;
          final ok = fileNames != null
              ? await _downloadOneToFile(art, fileNames[art.mintAccount]!)
              : await _downloadOne(art, tempDir, effectiveAlbum);
          if (ok) {
            completed++;
          } else {
            failed++;
          }
          _emit(completed: completed, failed: failed, total: total);
        }),
      );
    }

    final snap = CollectionDownloadProgress(
      completed: completed,
      failed: failed,
      total: total,
      cancelled: _cancelled,
    );
    _publish(snap);
    return snap;
  }

  Future<bool> _downloadOne(
    PortfolioArtwork artwork,
    Directory tempDir,
    String albumName,
  ) async {
    final extGuess = _guessExtension(artwork.imageUrl);
    final tempPath = p.join(
      tempDir.path,
      'mallow-dl-${artwork.mintAccount}$extGuess',
    );
    var tempFile = File(tempPath);
    try {
      final saved = await _fetchToPath(artwork, tempPath);
      if (saved == null) return false;
      tempFile = File(saved);
      await _putImageInAlbum(saved, albumName);
      return true;
    } catch (e) {
      AppLogger.error(_tag, 'saving to the photo library failed', e);
      return false;
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  /// Saves [path] into the [albumName] album, falling back to a plain
  /// library save when the album cannot be used.
  ///
  /// The fallback is what makes a *limited* photo library work. `gal` counts
  /// `.limited` as access (`hasAccess` is true for it), so the batch proceeds —
  /// but a limited library exposes no user albums and refuses to create one, so
  /// every album save failed and the whole batch reported "N failed". A plain
  /// save is permitted under limited access, which is the right outcome: the
  /// artwork lands in Photos, just not grouped.
  ///
  /// Retrying is safe specifically because `gal` builds the asset inside the
  /// album's `performChanges` block — if the album step fails, the change set
  /// rolls back and nothing was written, so the fallback cannot duplicate the
  /// image. A *timeout* is therefore not retried: it says nothing about whether
  /// the write landed.
  Future<void> _putImageInAlbum(String path, String albumName) async {
    try {
      await Gal.putImage(path, album: albumName).timeout(_galTimeout);
    } on GalException catch (e) {
      AppLogger.warn(_tag, 'album save failed (${e.type.code}), saving loose');
      await Gal.putImage(path).timeout(_galTimeout);
    }
  }

  /// Ordered source URLs for [artwork]'s image, most-preferred first.
  ///
  /// The raw `imageUrl` is NOT fetchable on its own: it is whatever the API
  /// stored, which is routinely an `ipfs://` URI (no HTTP scheme — Dio fails
  /// before a request is made) or an `arweave.net` link that 403s for some
  /// clients. Every rendering path resolves it via [MallowImage] / [AssetUrl];
  /// downloads must do the same. The images service's `/original/` route leads
  /// — it serves the mint-time bytes from R2 and redirects to a live gateway on
  /// a miss — then the asset's own gateway ladder.
  @visibleForTesting
  static List<String> sourceCandidates(PortfolioArtwork artwork) {
    final raw = artwork.imageUrl;
    final original = MallowImage.originalUrl(raw);
    final ladder = AssetUrl.assetSourceCandidates(raw, chain: artwork.chain);
    return [original, ...ladder.where((c) => c != original)];
  }

  /// Streams the first reachable source for [artwork] to [path], returning the
  /// file's final path — [path] itself, or a re-extensioned sibling when the
  /// response says the bytes are not what the URL implied. `null` when every
  /// source failed.
  ///
  /// Each failure is logged with its URL. A silent `false` here is what made a
  /// failed download impossible to diagnose from the "N failed" snackbar alone.
  Future<String?> _fetchToPath(PortfolioArtwork artwork, String path) async {
    Object? lastError;
    for (final url in sourceCandidates(artwork)) {
      if (_cancelled) return null;
      try {
        final response = await _dio.download(
          url,
          path,
          cancelToken: _cancelToken,
          options: Options(responseType: ResponseType.bytes),
        );
        return _withContentTypeExtension(path, response);
      } catch (e) {
        // A cancel is not a failed source: walking on to the next candidate
        // would re-issue a request the user just stopped, and every remaining
        // candidate would then fail the same way and be logged as an error.
        if (e is DioException && CancelToken.isCancel(e)) return null;
        lastError = e;
        AppLogger.warn(_tag, 'source failed, trying the next one — $url: $e');
      }
    }
    if (_cancelled) return null;
    // Release-visible, but URL-free: the candidates above carry the artwork's
    // storage location, which AppLogger.error must not put in platform logs.
    AppLogger.error(_tag, 'every source failed for an artwork', lastError);
    return null;
  }

  /// Renames the file at [path] to match the response's `Content-Type` when the
  /// two disagree, returning the path it ended up at.
  ///
  /// The extension is otherwise guessed from the URL, and content-addressed
  /// sources have none to guess from — `ipfs://<CID>` falls back to `.jpg`,
  /// which lands an animated GIF in the photo library as a still JPEG on
  /// Android (MediaStore takes the mime from the extension) and gives a
  /// user-visible file the wrong name in the Files export. A rename failure is
  /// not fatal: the bytes are already on disk under the guessed name.
  Future<String> _withContentTypeExtension(
    String path,
    Response<dynamic> response,
  ) async {
    final contentType = response.headers
        .value(Headers.contentTypeHeader)
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    final ext = _extensionByMime[contentType];
    if (ext == null || ext == p.extension(path).toLowerCase()) return path;
    final renamed = p.setExtension(p.withoutExtension(path), ext);
    try {
      await File(path).rename(renamed);
      return renamed;
    } catch (e) {
      AppLogger.warn(_tag, 'could not re-extension $path to $ext: $e');
      return path;
    }
  }

  /// Extensions for the image types artwork originals actually arrive as. A
  /// deliberately short, explicit map — the `mime` package's reverse lookup
  /// answers `.jpe` for `image/jpeg`, which is not a name to hand a user.
  static const Map<String, String> _extensionByMime = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/avif': '.avif',
    'image/heic': '.heic',
    'image/svg+xml': '.svg',
  };

  /// Streams one artwork into the batch directory under its pre-allocated
  /// user-facing file name. On success the file is kept and its path
  /// recorded; on failure any partial file is removed.
  Future<bool> _downloadOneToFile(
    PortfolioArtwork artwork,
    String fileName,
  ) async {
    final path = p.join(_batchDir!.path, fileName);
    final saved = await _fetchToPath(artwork, path);
    if (saved != null) {
      _savedFilePaths.add(saved);
      return true;
    }
    final file = File(path);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    return false;
  }

  /// User-facing file names for a files-destination batch, keyed by mint.
  /// Names come from the artwork title (sanitized), deduplicated with a
  /// ` (2)`-style counter, falling back to the mint when the title is empty.
  Map<String, String> _allocateFileNames(List<PortfolioArtwork> artworks) {
    final used = <String>{};
    final names = <String, String>{};
    for (final art in artworks) {
      final ext = _guessExtension(art.imageUrl);
      var base = art.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
      if (base.isEmpty) base = art.mintAccount;
      if (base.length > 60) base = base.substring(0, 60).trim();
      var name = '$base$ext';
      var counter = 2;
      while (!used.add(name)) {
        name = '$base (${counter++})$ext';
      }
      names[art.mintAccount] = name;
    }
    return names;
  }

  String _guessExtension(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final ext = p.extension(path).toLowerCase();
    if (ext.isEmpty || ext.length > 5) return '.jpg';
    return ext;
  }

  void _emit({
    required int completed,
    required int failed,
    required int total,
  }) {
    _publish(
      CollectionDownloadProgress(
        completed: completed,
        failed: failed,
        total: total,
        cancelled: _cancelled,
      ),
    );
  }

  /// Records [snap] as [lastProgress] and puts it on the stream. Every emit
  /// goes through here so a batch still draining after the caller has torn the
  /// service down cannot add to a closed controller.
  void _publish(CollectionDownloadProgress snap) {
    _lastProgress = snap;
    if (_controller.isClosed) return;
    _controller.add(snap);
  }

  void dispose() {
    _dio.close(force: true);
    _controller.close();
  }
}

/// Thrown by [CollectionDownloadService.downloadAll] when the photo-library
/// permission prompt is refused. Public so callers can report the real cause —
/// as a plain batch failure it surfaces as "N failed", which reads as a
/// download problem rather than a permission one.
class DownloadAccessDeniedException implements Exception {
  const DownloadAccessDeniedException();
  @override
  String toString() => 'Photo library access was denied.';
}
