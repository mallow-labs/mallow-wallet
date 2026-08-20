import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/mint/models/token_metadata.dart';

/// Spec-lock for the port of `tokenMetadata`.
///
/// Why this matters more than a shape check: the indexer derives an
/// artwork's `mediaType`, `videoUrl`, `htmlUrl`, `modelUrl` and `pdfUrl`
/// exclusively from `properties.category` + `properties.files`
/// (`assetHelper`), and both mallow gateways are
/// extensionless so its filename-extension fallback never fires. The JSON is
/// pinned to IPFS before the mint tx is built, so getting these two fields
/// wrong is permanent: a video indexes as a still forever, and a `.glb` /
/// `.html` artwork disappears entirely. Every assertion below is one of those
/// permanent-loss cases.
void main() {
  const image = MintMetadataFile(uri: 'ipfs://image.png', type: 'image/png');
  const video = MintMetadataFile(uri: 'ipfs://video.mp4', type: 'video/mp4');

  group('mintFileCategoryForMimeType', () {
    test('maps every whitelisted family to the wire value the indexer '
        'compares against', () {
      expect(mintFileCategoryForMimeType('image/png')?.wireValue, 'image');
      expect(mintFileCategoryForMimeType('image/svg+xml')?.wireValue, 'image');
      expect(mintFileCategoryForMimeType('video/mp4')?.wireValue, 'video');
      expect(
        mintFileCategoryForMimeType('video/quicktime')?.wireValue,
        'video',
      );
      expect(mintFileCategoryForMimeType('audio/mpeg')?.wireValue, 'audio');
      expect(mintFileCategoryForMimeType('text/html')?.wireValue, 'html');
      expect(
        mintFileCategoryForMimeType('application/pdf')?.wireValue,
        'document',
      );
    });

    test('a glb model serializes as "vr", not "model" — the enum name and '
        'the wire value differ and the indexer only accepts the wire '
        'value', () {
      expect(
        mintFileCategoryForMimeType('model/gltf-binary'),
        MintFileCategory.model,
      );
      expect(MintFileCategory.model.wireValue, 'vr');
    });

    test('falls back on the mime type prefix, which only fires where the '
        'webapp would emit no category at all', () {
      expect(
        mintFileCategoryForMimeType('video/x-matroska'),
        MintFileCategory.video,
      );
      expect(mintFileCategoryForMimeType('image/heic'), MintFileCategory.image);
      expect(mintFileCategoryForMimeType('application/zip'), isNull);
    });

    test('is case and whitespace insensitive so a picker-supplied mime '
        'never silently degrades the category', () {
      expect(
        mintFileCategoryForMimeType(' Video/MP4 '),
        MintFileCategory.video,
      );
    });
  });

  group('buildTokenMetadataJson', () {
    test('an image-only mint gets category=image, a files entry, and no '
        'animation_url', () {
      final json = buildTokenMetadataJson(
        assets: const [image],
        name: 'My NFT',
        description: 'desc',
        attributes: const [],
        tags: const [],
      );

      expect(json['name'], 'My NFT');
      expect(json['description'], 'desc');
      expect(json['image'], 'ipfs://image.png');
      final props = json['properties'] as Map<String, dynamic>;
      expect(props['category'], 'image');
      expect(props['files'], [
        {'uri': 'ipfs://image.png', 'type': 'image/png'},
      ]);
      expect(json.containsKey('animation_url'), isFalse);
      expect(json.containsKey('video'), isFalse);
    });

    test('a video mint carries the video in animation_url AND video, keeps '
        'the thumbnail as image, and declares the video mime in '
        'properties.files', () {
      final json = buildTokenMetadataJson(
        // Primary asset first — this ordering is what selects the category.
        assets: const [video, image],
        name: 'Video NFT',
        description: '',
        attributes: const [],
        tags: const [],
      );

      final props = json['properties'] as Map<String, dynamic>;
      expect(props['category'], 'video');
      expect(json['animation_url'], 'ipfs://video.mp4');
      expect(json['video'], 'ipfs://video.mp4');
      // The still is the cover, not the primary.
      expect(json['image'], 'ipfs://image.png');
      expect(props['files'], [
        {'uri': 'ipfs://video.mp4', 'type': 'video/mp4'},
        {'uri': 'ipfs://image.png', 'type': 'image/png'},
      ]);
    });

    test('a glb mint gets category=vr + animation_url but NOT video — the '
        'indexer keys modelUrl off the model/ mime in files', () {
      final json = buildTokenMetadataJson(
        assets: const [
          MintMetadataFile(uri: 'ipfs://scene.glb', type: 'model/gltf-binary'),
          image,
        ],
        name: 'Model',
        description: '',
        attributes: const [],
        tags: const [],
      );

      expect((json['properties'] as Map)['category'], 'vr');
      expect(json['animation_url'], 'ipfs://scene.glb');
      expect(json.containsKey('video'), isFalse);
      // `contains` on a List<Map> compares by identity — Map has no value
      // equality — so match the element with a deep matcher instead.
      expect(
        (json['properties'] as Map)['files'],
        anyElement(
          equals({'uri': 'ipfs://scene.glb', 'type': 'model/gltf-binary'}),
        ),
      );
    });

    test('an html mint gets category=html + animation_url so the artwork '
        'renders as an iframe instead of vanishing', () {
      final json = buildTokenMetadataJson(
        assets: const [
          MintMetadataFile(uri: 'ipfs://gen.html', type: 'text/html'),
          image,
        ],
        name: 'Generative',
        description: '',
        attributes: const [],
        tags: const [],
      );

      expect((json['properties'] as Map)['category'], 'html');
      expect(json['animation_url'], 'ipfs://gen.html');
      expect(json.containsKey('video'), isFalse);
    });

    test('an audio mint gets category=audio + animation_url and no video '
        'key', () {
      final json = buildTokenMetadataJson(
        assets: const [
          MintMetadataFile(uri: 'ipfs://track.mp3', type: 'audio/mpeg'),
          image,
        ],
        name: 'Track',
        description: '',
        attributes: const [],
        tags: const [],
      );

      expect((json['properties'] as Map)['category'], 'audio');
      expect(json['animation_url'], 'ipfs://track.mp3');
      expect(json.containsKey('video'), isFalse);
    });

    test('never emits seller_fee_basis_points or properties.creators — the '
        'webapp writes neither, and emitting them made every mobile-minted '
        "artwork fail the webapp's requiresMetadataUpdate equality check", () {
      final json = buildTokenMetadataJson(
        assets: const [image],
        name: 'X',
        description: '',
        attributes: const [],
        tags: const [],
      );

      expect(json.containsKey('seller_fee_basis_points'), isFalse);
      expect((json['properties'] as Map).containsKey('creators'), isFalse);
      expect((json['properties'] as Map).keys.toSet(), {'category', 'files'});
    });

    test('optional keys are omitted when absent and present when supplied', () {
      final bare = buildTokenMetadataJson(
        assets: const [image],
        name: 'X',
        description: '',
        attributes: const [],
        tags: const ['art'],
      );
      expect(bare.containsKey('external_url'), isFalse);
      expect(bare.containsKey('banner'), isFalse);
      expect(bare.containsKey('processVideo'), isFalse);
      expect(bare.containsKey('nsfw'), isFalse);

      final full = buildTokenMetadataJson(
        assets: const [image],
        name: 'X',
        description: '',
        attributes: const [],
        tags: const ['nsfw'],
        nsfw: true,
        externalUrl: 'https://example.com',
        banner: 'ipfs://banner.png',
        processVideoUri: 'ipfs://proc.mp4',
      );
      expect(full['external_url'], 'https://example.com');
      expect(full['banner'], 'ipfs://banner.png');
      expect(full['processVideo'], 'ipfs://proc.mp4');
      expect(full['nsfw'], true);
    });

    test('attribute and file ordering round-trip untouched', () {
      final attrs = [
        {'trait_type': 'z', 'value': '1'},
        {'trait_type': 'a', 'value': '2'},
      ];
      final json = buildTokenMetadataJson(
        assets: const [
          image,
          MintMetadataFile(uri: 'ipfs://b.jpg', type: 'image/jpeg'),
        ],
        name: 'X',
        description: '',
        attributes: attrs,
        tags: const [],
      );

      expect(json['attributes'], attrs);
      expect((json['properties'] as Map)['files'], [
        {'uri': 'ipfs://image.png', 'type': 'image/png'},
        {'uri': 'ipfs://b.jpg', 'type': 'image/jpeg'},
      ]);
    });

    test('degrades instead of throwing on an empty asset list — the same '
        'builder runs while an edit is still prefilling and while the '
        'confirm sheet simulates cost', () {
      final json = buildTokenMetadataJson(
        assets: const [],
        name: 'X',
        description: '',
        attributes: const [],
        tags: const [],
      );

      expect(json['image'], isNull);
      expect((json['properties'] as Map).containsKey('category'), isFalse);
      expect((json['properties'] as Map)['files'], isEmpty);
    });
  });
}
