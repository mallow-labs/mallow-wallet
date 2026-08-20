import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/mint/models/mint_file_types.dart';
import 'package:mallow_wallet/shared/pickers/picked_file_validation.dart';
import 'package:mallow_wallet/shared/utils/heic_import.dart';

/// The one gate every upload box in the app passes through — the mint slots,
/// the profile avatar / banner boxes and the auction physical photo alike. It
/// was two copies until the mint one silently drifted, so what these tests
/// really pin is that one set of rules decides what uploads and one set of
/// words explains a refusal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // What the profile boxes accept, HEIC appended exactly as every stills
  // caller appends it so camera-roll photos survive as far as the transcode.
  const profilePickable = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    ...kHeicExtensions,
  ];
  const profileSummary = 'a .jpeg, .gif, .webp or .png image';
  const profileMaxBytes = 20 * 1024 * 1024;

  final png = Uint8List.fromList(List.filled(64, 7));

  group('extension gate', () {
    test('refuses a name with no extension, whatever the name spells', () async {
      // `heic` is in every stills allowlist, so a dotless file called exactly
      // that used to satisfy the allowlist by matching itself — while
      // `isHeicFileName` (deliberately stricter, it gates a re-encode) skipped
      // it. Raw HEIF then uploaded under a name nothing can derive a mime type
      // from, and the backend's presign route — which gates on the declared
      // mime — answered with an opaque 400 in place of this message.
      expect(
        isHeicFileName('heic'),
        isFalse,
        reason: 'the transcode skips it, so the allowlist must not admit it',
      );

      for (final name in ['heic', '.png', 'photo.']) {
        final errors = <String>[];
        final result = await validatePickedFile(
          fileName: name,
          bytes: png,
          pickable: profilePickable,
          maxSizeBytes: profileMaxBytes,
          typeSummary: profileSummary,
          onError: errors.add,
        );
        expect(result, isNull, reason: '$name has no extension');
        expect(errors, ['File must be $profileSummary']);
      }
    });

    test(
      'accepts an allowed extension regardless of case or dots in the stem',
      () async {
        final errors = <String>[];
        final result = await validatePickedFile(
          fileName: 'my.holiday.photo.PNG',
          bytes: png,
          pickable: profilePickable,
          maxSizeBytes: profileMaxBytes,
          typeSummary: profileSummary,
          onError: errors.add,
        );

        expect(result?.fileName, 'my.holiday.photo.PNG');
        expect(result?.bytes, png);
        expect(errors, isEmpty);
      },
    );

    test('carries each surface\'s own rules rather than one flattened set', () {
      // The mint process-video slot and a profile avatar box disagree on every
      // axis — allowlist, cap and wording. Sharing the check must not cost
      // that: a file each one refuses has to be refused in that surface's own
      // words, because the words are what tell the user which box they are in.
      final videoErrors = <String>[];
      final videoRejected = rejectsNameOrSize(
        fileName: 'avatar.png',
        sizeBytes: png.lengthInBytes,
        pickable: kMintProcessVideoRules.pickable,
        maxSizeBytes: kMintProcessVideoRules.maxSizeBytes,
        typeSummary: kMintProcessVideoRules.summary,
        onError: videoErrors.add,
      );
      expect(videoRejected, isTrue);
      expect(videoErrors, ['File must be .mp4, .mov or .webm']);

      final profileErrors = <String>[];
      final profileRejected = rejectsNameOrSize(
        fileName: 'clip.mp4',
        sizeBytes: png.lengthInBytes,
        pickable: profilePickable,
        maxSizeBytes: profileMaxBytes,
        typeSummary: profileSummary,
        onError: profileErrors.add,
      );
      expect(profileRejected, isTrue);
      expect(profileErrors, ['File must be $profileSummary']);
    });

    test('names the caller\'s own cap in the size refusal', () {
      final errors = <String>[];
      final rejected = rejectsNameOrSize(
        fileName: 'huge.png',
        sizeBytes: profileMaxBytes + 1,
        pickable: profilePickable,
        maxSizeBytes: profileMaxBytes,
        typeSummary: profileSummary,
        onError: errors.add,
      );

      expect(rejected, isTrue);
      expect(errors, ['File must be 20MB or smaller']);
    });
  });

  group('unreadable picks', () {
    test('reports a failed read instead of dropping the pick', () async {
      // Both pickers hand back a handle; the read behind it can fail after the
      // user has already chosen a file. That must end in a message — a tap
      // that produces neither an asset nor an error reads as a dead drop zone.
      final errors = <String>[];
      final result = await validatePickedFile(
        fileName: 'photo.png',
        bytes: null,
        pickable: profilePickable,
        maxSizeBytes: profileMaxBytes,
        typeSummary: profileSummary,
        onError: errors.add,
      );

      expect(result, isNull);
      expect(errors, ['File is empty or unreadable']);
    });

    test(
      'turns a throwing read into that null rather than an escaping error',
      () async {
        // The real shapes are an Android content Uri whose provider throws and
        // an iOS security-scoped copy reaped before the read; a path to nowhere
        // stands in for both. Unguarded, the throw leaves the picker via the
        // drop zone's `onTap` as an unhandled async exception.
        final missing = XFile('${Directory.systemTemp.path}/never-written.png');

        await expectLater(readPickedBytes(missing), completion(isNull));
      },
    );

    test('reads the bytes back when the handle is good', () async {
      final dir = Directory.systemTemp.createTempSync('picked_file_validation');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/photo.png')..writeAsBytesSync(png);

      expect(await readPickedBytes(XFile(file.path)), png);
    });
  });
}
