import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/heic_import.dart';

/// The rename half of the HEIC import path.
///
/// It matters because the mime type of an uploaded file is derived from its
/// *name*, not its bytes. A `.heic` name left on transcoded JPEG bytes would
/// pin `image/heic` into `properties.files[].type` — a mime the indexer has
/// no category for — while the file itself is a perfectly ordinary JPEG.
void main() {
  group('isHeicFileName', () {
    test('matches both Apple HEIF extensions, case-insensitively', () {
      expect(isHeicFileName('IMG_0042.heic'), isTrue);
      expect(isHeicFileName('IMG_0042.HEIC'), isTrue);
      expect(isHeicFileName('scan.heif'), isTrue);
      expect(isHeicFileName('scan.HeIf'), isTrue);
    });

    test('does not match formats that need no conversion', () {
      expect(isHeicFileName('photo.jpg'), isFalse);
      expect(isHeicFileName('render.png'), isFalse);
      expect(isHeicFileName('clip.mov'), isFalse);
    });

    test('does not match a name that merely contains the word', () {
      expect(isHeicFileName('my-heic-photos.png'), isFalse);
    });

    test('needs a real extension — it gates a re-encode, not just a check', () {
      expect(isHeicFileName('heic'), isFalse);
      expect(isHeicFileName('.heic'), isFalse);
    });
  });

  group('heicNameAsJpeg', () {
    test('replaces the extension', () {
      expect(heicNameAsJpeg('IMG_0042.heic'), 'IMG_0042.jpg');
      expect(heicNameAsJpeg('scan.HEIF'), 'scan.jpg');
    });

    test('only the last extension — a dotted stem is preserved', () {
      expect(heicNameAsJpeg('my.photo.v2.heic'), 'my.photo.v2.jpg');
    });

    test('a name with no extension gains one rather than losing its stem', () {
      expect(heicNameAsJpeg('photo'), 'photo.jpg');
    });
  });
}
