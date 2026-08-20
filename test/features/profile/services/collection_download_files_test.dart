import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/profile/services/collection_download_service.dart';
import 'package:path/path.dart' as p;

/// A [DownloadDestination.files] batch is exported by handing its temp files to
/// the OS share sheet, and that call can return before the receiver has read
/// them: iOS gives `UIActivityViewController` a file URL to the batch itself
/// and resolves on `completionWithItemsHandler`, so an AirDrop may still be
/// transferring. Deleting the batch on return hands the target a truncated or
/// missing file and surfaces no error anywhere — so cleanup is deferred, and
/// the next batch does the reclaiming.
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('mallow-dl-batch-test');
  });

  tearDown(() async {
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  group('CollectionDownloadService files batch lifetime', () {
    test(
      'releaseFiles keeps the file the share sheet may still be reading',
      () async {
        final service = CollectionDownloadService();
        final batch = await service.prepareBatchDir(tempRoot);
        final shared = File(p.join(batch.path, 'Art.png'))
          ..writeAsStringSync('bytes');

        await service.releaseFiles();

        expect(
          shared.existsSync(),
          isTrue,
          reason:
              'the share sheet holds this path after share() returns — an eager '
              'delete truncates in-flight AirDrops and third-party shares',
        );
        expect(service.savedFilePaths, isEmpty);
        service.dispose();
      },
    );

    test('the next files batch reclaims the previous one', () async {
      final first = CollectionDownloadService();
      final firstBatch = await first.prepareBatchDir(tempRoot);
      // Asserted on instead of the directory itself: two batches created in the
      // same millisecond get the same name, and a recreated-empty directory is
      // just as reclaimed as a deleted one.
      final orphan = File(p.join(firstBatch.path, 'Art.png'))
        ..writeAsStringSync('bytes');
      await first.releaseFiles();
      first.dispose();

      final second = CollectionDownloadService();
      final secondBatch = await second.prepareBatchDir(tempRoot);

      expect(
        orphan.existsSync(),
        isFalse,
        reason: 'deferred cleanup must not let temp batches accumulate',
      );
      expect(secondBatch.existsSync(), isTrue);
      second.dispose();
    });

    test('the sweep spares in-flight photo-library temp files', () async {
      // _downloadOne writes `mallow-dl-<mint>.<ext>` next to the batch dirs and
      // deletes them itself; sweeping by prefix alone would delete one mid-save.
      final inFlight = File(p.join(tempRoot.path, 'mallow-dl-someMint.jpg'))
        ..writeAsStringSync('bytes');

      final service = CollectionDownloadService();
      await service.prepareBatchDir(tempRoot);

      expect(inFlight.existsSync(), isTrue);
      service.dispose();
    });
  });
}
