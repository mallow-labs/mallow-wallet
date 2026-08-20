import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/heic_import.dart';
import 'package:mallow_wallet/features/mint/models/mint_file_types.dart';
import 'package:mallow_wallet/features/mint/models/token_metadata.dart';

/// Spec-lock for the port of the webapp's upload whitelists
/// (`fileType` + the `useAssetDropzone` flags in
/// `CreateContext`).
///
/// Two things are being defended, and neither is "the list has N entries":
///
/// 1. **Parity of what can be minted.** A format the webapp accepts but the
///    app rejects is a creator who cannot mint their own artwork from their
///    phone — the class of bug this file was written to fix, where `.svg`,
///    `.avif` and `.pdf` were unpickable for a year.
/// 2. **Every accepted format must classify.** `properties.category` in the
///    metadata JSON is derived from the file's mime type, the JSON is pinned
///    to IPFS *before* the mint tx is built, and the indexer derives every
///    render from that category. Widening a picker without a mime mapping
///    therefore mints a permanently unrenderable artwork rather than showing
///    an error — silent and unfixable.
void main() {
  group('slot whitelists match the webapp dropzones', () {
    test(
      'main artwork takes stills, video, models, HTML and PDF — not audio',
      () {
        expect(
          kMintMainAssetRules.extensions,
          containsAll(<String>[
            ...kMintImageExtensions,
            ...kMintVideoExtensions,
            'glb',
            'html',
            'pdf',
          ]),
        );
        // `assetDropzoneData` passes allowVideo/allowModel/allowHtml/allowPdf
        // but not allowAudio.
        expect(kMintMainAssetRules.extensions, isNot(contains('mp3')));
      },
    );

    test('thumbnail takes stills only — it stands in for the main asset', () {
      expect(kMintThumbnailRules.extensions, kMintImageExtensions);
      expect(kMintThumbnailRules.extensions, isNot(contains('mp4')));
      expect(kMintThumbnailRules.extensions, isNot(contains('pdf')));
    });

    test('process video takes every supported container and no stills', () {
      expect(kMintProcessVideoRules.extensions, kMintVideoExtensions);
      expect(kMintProcessVideoRules.allowsStills, isFalse);
    });

    test('unlockable content adds audio, at the 500mb cap', () {
      expect(
        kMintUnlockableRules.extensions,
        containsAll(<String>[...kMintAudioExtensions, 'pdf', 'glb', 'html']),
      );
      expect(kMintUnlockableRules.maxSizeBytes, 500 * 1024 * 1024);
    });

    test('collection image and banner take stills only, at the 30mb cap', () {
      expect(kMintCollectionRules.extensions, kMintImageExtensions);
      expect(kMintCollectionRules.maxSizeBytes, 30 * 1024 * 1024);
    });

    test('the formats the app used to reject are now accepted', () {
      // The four formats an internal QA pass found the app was wrongly rejecting.
      expect(kMintMainAssetRules.extensions, contains('svg'));
      expect(kMintMainAssetRules.extensions, contains('avif'));
      expect(kMintMainAssetRules.extensions, contains('pdf'));
      expect(kMintMainAssetRules.extensions, contains('mov'));
    });
  });

  group('every accepted extension survives to a metadata category', () {
    const slots = <String, MintAcceptRules>{
      'main artwork': kMintMainAssetRules,
      'thumbnail': kMintThumbnailRules,
      'process video': kMintProcessVideoRules,
      'unlockable content': kMintUnlockableRules,
      'collection': kMintCollectionRules,
    };

    slots.forEach((name, rules) {
      test('$name maps every extension to a classifiable mime type', () {
        for (final ext in rules.extensions) {
          final mimeType = mintMimeTypeForFileName('artwork.$ext');
          expect(
            mimeType,
            isNot('application/octet-stream'),
            reason:
                '.$ext has no mime mapping, so the pinned metadata JSON '
                'would carry no properties.category',
          );
          expect(
            mintFileCategoryForMimeType(mimeType),
            isNotNull,
            reason:
                '.$ext resolves to $mimeType, which the metadata builder '
                'cannot classify',
          );
        }
      });
    });

    test('apng is the case the mime package alone gets wrong', () {
      expect(mintMimeTypeForFileName('loop.apng'), 'image/apng');
      expect(mintFileCategoryForMimeType('image/apng'), MintFileCategory.image);
    });

    test('svg and avif classify as images, so they need no thumbnail', () {
      expect(
        mintFileCategoryForMimeType(mintMimeTypeForFileName('a.svg')),
        MintFileCategory.image,
      );
      expect(
        mintFileCategoryForMimeType(mintMimeTypeForFileName('a.avif')),
        MintFileCategory.image,
      );
    });

    test('pdf classifies as a document, which is what forces a thumbnail', () {
      expect(
        mintFileCategoryForMimeType(mintMimeTypeForFileName('a.pdf')),
        MintFileCategory.document,
      );
    });
  });

  group('HEIC is importable but never mintable as HEIC', () {
    test('stills slots let the picker return HEIC so it can be converted', () {
      expect(kMintMainAssetRules.pickable, containsAll(kHeicExtensions));
      expect(kMintThumbnailRules.pickable, containsAll(kHeicExtensions));
      expect(kMintCollectionRules.pickable, containsAll(kHeicExtensions));
    });

    test('the video-only slot does not — there is nothing to convert', () {
      expect(kMintProcessVideoRules.pickable, kMintVideoExtensions);
    });

    test('HEIC is absent from the kept extensions of every slot', () {
      for (final rules in <MintAcceptRules>[
        kMintMainAssetRules,
        kMintThumbnailRules,
        kMintProcessVideoRules,
        kMintUnlockableRules,
        kMintCollectionRules,
      ]) {
        for (final ext in kHeicExtensions) {
          expect(
            rules.extensions,
            isNot(contains(ext)),
            reason:
                'HEIC is not on the platform whitelist — it may only '
                'reach PickedMintAsset as the JPEG it was converted to',
          );
        }
      }
    });
  });

  group('captions advertise what the picker actually takes', () {
    test('caption is derived from the same value as the rejection message', () {
      expect(
        kMintProcessVideoRules.caption,
        '100mb max  •  .mp4, .mov or .webm',
      );
      expect(kMintCollectionRules.caption, startsWith('30mb max  •  '));
      expect(kMintUnlockableRules.caption, startsWith('500mb max  •  '));
    });

    test('the main-artwork caption no longer omits pdf', () {
      expect(kMintMainAssetRules.caption, contains('.pdf'));
    });
  });
}
