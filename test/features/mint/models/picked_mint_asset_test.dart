import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/mint/models/picked_mint_asset.dart';

PickedMintAsset _make({required String mimeType, String fileName = 'file'}) =>
    PickedMintAsset(
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: 1,
      bytes: Uint8List(0),
    );

void main() {
  group('PickedMintAsset.needsThumbnail', () {
    test('video/* requires thumbnail', () {
      expect(_make(mimeType: 'video/mp4').needsThumbnail, isTrue);
      expect(_make(mimeType: 'video/webm').needsThumbnail, isTrue);
      expect(_make(mimeType: 'VIDEO/MP4').needsThumbnail, isTrue);
    });

    test('application/pdf requires thumbnail', () {
      expect(_make(mimeType: 'application/pdf').needsThumbnail, isTrue);
    });

    test('text/html requires thumbnail', () {
      expect(_make(mimeType: 'text/html').needsThumbnail, isTrue);
    });

    test('application/x-html requires thumbnail', () {
      expect(_make(mimeType: 'application/x-html').needsThumbnail, isTrue);
    });

    test('model/gltf-binary requires thumbnail', () {
      expect(_make(mimeType: 'model/gltf-binary').needsThumbnail, isTrue);
    });

    test('.glb extension requires thumbnail regardless of mime', () {
      expect(
        _make(
          mimeType: 'application/octet-stream',
          fileName: 'model.glb',
        ).needsThumbnail,
        isTrue,
      );
      expect(
        _make(
          mimeType: 'application/octet-stream',
          fileName: 'MODEL.GLB',
        ).needsThumbnail,
        isTrue,
      );
    });

    test('image/* does NOT require thumbnail', () {
      expect(_make(mimeType: 'image/jpeg').needsThumbnail, isFalse);
      expect(_make(mimeType: 'image/png').needsThumbnail, isFalse);
      expect(_make(mimeType: 'image/gif').needsThumbnail, isFalse);
    });

    test('audio/* does NOT require thumbnail', () {
      expect(_make(mimeType: 'audio/mpeg').needsThumbnail, isFalse);
    });
  });

  group('PickedMintAsset.isImage', () {
    test('image/* is image', () {
      expect(_make(mimeType: 'image/png').isImage, isTrue);
      expect(_make(mimeType: 'IMAGE/JPEG').isImage, isTrue);
    });

    test('video/* is not image', () {
      expect(_make(mimeType: 'video/mp4').isImage, isFalse);
    });
  });

  group('PickedMintAsset.isVideo', () {
    test('video/* is video', () {
      expect(_make(mimeType: 'video/mp4').isVideo, isTrue);
    });

    test('image/* is not video', () {
      expect(_make(mimeType: 'image/png').isVideo, isFalse);
    });
  });
}
