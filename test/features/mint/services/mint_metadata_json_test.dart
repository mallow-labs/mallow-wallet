import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/mint/models/picked_mint_asset.dart';
import 'package:mallow_wallet/features/mint/services/mint_bloc.dart';

/// `MintState.toMetadataJson()` is the exact blob pinned to IPFS and pointed
/// at by the on-chain `uri`. It is written once, before the tx is built, and
/// is immutable in practice — so each case below is a permanent-loss scenario,
/// not a formatting preference.
void main() {
  PickedMintAsset asset(String fileName, String mimeType, String url) =>
      PickedMintAsset(
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: 1,
        bytes: Uint8List(0),
        ipfsUrl: url,
      );

  Map<String, dynamic> propsOf(Map<String, dynamic> json) =>
      json['properties'] as Map<String, dynamic>;

  group('fresh mint', () {
    test('a 1/1 image mint declares itself as an image and lists the file, '
        'so the indexer has a files entry to derive the render from', () {
      final state = MintState(
        name: 'Art',
        description: 'd',
        mainAsset: asset('art.png', 'image/png', 'ipfs://art.png'),
      );

      final json = state.toMetadataJson();
      expect(propsOf(json)['category'], 'image');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://art.png', 'type': 'image/png'},
      ]);
      expect(json['image'], 'ipfs://art.png');
      expect(json.containsKey('animation_url'), isFalse);
    });

    test(
      'a video mint emits category=video, animation_url and a video/ '
      'files entry — without them the artwork indexes as a still forever',
      () {
        final state = MintState(
          name: 'Clip',
          description: 'd',
          mainAsset: asset('clip.mp4', 'video/mp4', 'ipfs://clip.mp4'),
          thumbnail: asset('still.png', 'image/png', 'ipfs://still.png'),
        );

        final json = state.toMetadataJson();
        expect(propsOf(json)['category'], 'video');
        expect(json['animation_url'], 'ipfs://clip.mp4');
        expect(json['video'], 'ipfs://clip.mp4');
        // The still is the cover image, the video is the primary asset.
        expect(json['image'], 'ipfs://still.png');
        expect(propsOf(json)['files'], [
          {'uri': 'ipfs://clip.mp4', 'type': 'video/mp4'},
          {'uri': 'ipfs://still.png', 'type': 'image/png'},
        ]);
      },
    );

    test('a glb mint keeps the model in files and animation_url, so the '
        'artwork is more than its thumbnail', () {
      final state = MintState(
        name: 'Scene',
        description: 'd',
        mainAsset: asset('scene.glb', 'model/gltf-binary', 'ipfs://scene.glb'),
        thumbnail: asset('still.png', 'image/png', 'ipfs://still.png'),
      );

      final json = state.toMetadataJson();
      expect(propsOf(json)['category'], 'vr');
      expect(json['animation_url'], 'ipfs://scene.glb');
      expect(json.containsKey('video'), isFalse);
      // `contains` on a List<Map> compares by identity — Map has no value
      // equality — so match the element with a deep matcher instead.
      expect(
        propsOf(json)['files'],
        anyElement(
          equals({'uri': 'ipfs://scene.glb', 'type': 'model/gltf-binary'}),
        ),
      );
    });

    test('the process video is listed in files and mirrored to processVideo, '
        'and never becomes the primary asset', () {
      final state = MintState(
        name: 'Art',
        description: 'd',
        mainAsset: asset('art.png', 'image/png', 'ipfs://art.png'),
        processVideo: asset('proc.mp4', 'video/mp4', 'ipfs://proc.mp4'),
      );

      final json = state.toMetadataJson();
      expect(propsOf(json)['category'], 'image');
      expect(json['processVideo'], 'ipfs://proc.mp4');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://art.png', 'type': 'image/png'},
        {'uri': 'ipfs://proc.mp4', 'type': 'video/mp4'},
      ]);
    });

    test('a collection mint lists [image, banner] — webapp MintCollection '
        'parity, and the banner must be a files entry as well as a key', () {
      final state = MintState(
        mintType: MintCreateType.collection,
        name: 'Coll',
        description: 'd',
        mainAsset: asset('cover.png', 'image/png', 'ipfs://cover.png'),
        banner: asset('banner.jpg', 'image/jpeg', 'ipfs://banner.jpg'),
      );

      final json = state.toMetadataJson();
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://cover.png', 'type': 'image/png'},
        {'uri': 'ipfs://banner.jpg', 'type': 'image/jpeg'},
      ]);
      expect(json['banner'], 'ipfs://banner.jpg');
    });
  });

  group('edit mode (nothing re-picked)', () {
    // In edit mode `mainAsset` is null unless the user picks a new file, so
    // every derived field has to come off the prefilled existing URLs.
    MintState videoEdit({Map<String, String> fileTypes = const {}}) =>
        MintState(
          editMintAccount: 'mint',
          name: 'Clip',
          description: 'd',
          existingImageUrl: 'ipfs://clip.mp4',
          existingThumbnailUrl: 'ipfs://still.png',
          existingMainAssetIsVideo: true,
          existingFileTypesByUri: fileTypes,
        );

    test('preserves animation_url and the video files entry using the mime '
        "from the artwork's own properties.files", () {
      final json = videoEdit(
        fileTypes: const {
          'ipfs://clip.mp4': 'video/quicktime',
          'ipfs://still.png': 'image/png',
        },
      ).toMetadataJson();

      expect(json['animation_url'], 'ipfs://clip.mp4');
      expect(json['video'], 'ipfs://clip.mp4');
      expect(propsOf(json)['category'], 'video');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://clip.mp4', 'type': 'video/quicktime'},
        {'uri': 'ipfs://still.png', 'type': 'image/png'},
      ]);
      expect(json['image'], 'ipfs://still.png');
    });

    test('still classifies the asset as a video when the pre-edit JSON had '
        'no properties.files at all — the case for every artwork minted from '
        'mobile before this shape existed', () {
      final json = videoEdit().toMetadataJson();

      expect(propsOf(json)['category'], 'video');
      expect(json['animation_url'], 'ipfs://clip.mp4');
      expect((propsOf(json)['files'] as List).first, {
        'uri': 'ipfs://clip.mp4',
        'type': 'video/mp4',
      });
    });

    test('an image artwork stays an image and keeps its files entry', () {
      final json = const MintState(
        editMintAccount: 'mint',
        name: 'Art',
        description: 'd',
        existingImageUrl: 'ipfs://art.png',
        existingFileTypesByUri: {'ipfs://art.png': 'image/jpeg'},
      ).toMetadataJson();

      expect(propsOf(json)['category'], 'image');
      expect(json.containsKey('animation_url'), isFalse);
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://art.png', 'type': 'image/jpeg'},
      ]);
    });

    test('preserves the existing process video in files as well as the '
        'processVideo key', () {
      final json = const MintState(
        editMintAccount: 'mint',
        name: 'Art',
        description: 'd',
        existingImageUrl: 'ipfs://art.png',
        existingProcessVideoUrl: 'ipfs://proc.mp4',
        existingFileTypesByUri: {
          'ipfs://art.png': 'image/png',
          'ipfs://proc.mp4': 'video/mp4',
        },
      ).toMetadataJson();

      expect(json['processVideo'], 'ipfs://proc.mp4');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://art.png', 'type': 'image/png'},
        {'uri': 'ipfs://proc.mp4', 'type': 'video/mp4'},
      ]);
    });

    test('the chain-side nftMetadata keeps `video` populated too, so an edit '
        "doesn't blank it on-chain either", () {
      final meta = videoEdit(
        fileTypes: const {'ipfs://clip.mp4': 'video/mp4'},
      ).toNftMetadata();

      expect(meta.extendedMetadata.video, 'ipfs://clip.mp4');
    });
  });

  group('edit mode (main asset re-picked)', () {
    test('swapping the video without re-picking the cover keeps the existing '
        'thumbnail — otherwise the pinned JSON has no image at all and the '
        'artwork loses its card image permanently', () {
      final state = MintState(
        editMintAccount: 'mint',
        name: 'Clip',
        description: 'd',
        existingImageUrl: 'ipfs://old.mp4',
        existingThumbnailUrl: 'ipfs://still.png',
        existingMainAssetIsVideo: true,
        existingFileTypesByUri: const {'ipfs://still.png': 'image/png'},
        mainAsset: asset('new.mp4', 'video/mp4', 'ipfs://new.mp4'),
      );

      final json = state.toMetadataJson();
      expect(json['image'], 'ipfs://still.png');
      expect(json['animation_url'], 'ipfs://new.mp4');
      expect(propsOf(json)['category'], 'video');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://new.mp4', 'type': 'video/mp4'},
        {'uri': 'ipfs://still.png', 'type': 'image/png'},
      ]);
      // The chain-side payload has to agree — it feeds the same edit request.
      expect(state.toNftMetadata().extendedMetadata.image, 'ipfs://still.png');
    });

    test('replacing a video with a still image drops the old cover — the new '
        'primary is its own image, so carrying it would pin a stale file', () {
      // Mirrors `_onPickMainAsset`, which clears a *picked* thumbnail the same
      // way once the new primary no longer needs one.
      final json = MintState(
        editMintAccount: 'mint',
        name: 'Clip',
        description: 'd',
        existingImageUrl: 'ipfs://old.mp4',
        existingThumbnailUrl: 'ipfs://still.png',
        existingMainAssetIsVideo: true,
        mainAsset: asset('new.png', 'image/png', 'ipfs://new.png'),
      ).toMetadataJson();

      expect(json['image'], 'ipfs://new.png');
      expect(propsOf(json)['category'], 'image');
      expect(propsOf(json)['files'], [
        {'uri': 'ipfs://new.png', 'type': 'image/png'},
      ]);
    });

    test('re-picking only the process video leaves the cover alone', () {
      final json = MintState(
        editMintAccount: 'mint',
        name: 'Clip',
        description: 'd',
        existingImageUrl: 'ipfs://clip.mp4',
        existingThumbnailUrl: 'ipfs://still.png',
        existingMainAssetIsVideo: true,
        existingFileTypesByUri: const {'ipfs://still.png': 'image/png'},
        processVideo: asset('proc.mp4', 'video/mp4', 'ipfs://proc.mp4'),
      ).toMetadataJson();

      expect(json['image'], 'ipfs://still.png');
      expect(json['processVideo'], 'ipfs://proc.mp4');
    });
  });
}
