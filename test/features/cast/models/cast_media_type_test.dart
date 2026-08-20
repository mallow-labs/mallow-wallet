import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/cast/models/cast_media_type.dart';

/// Pins the synchronous media-type heuristics used to decide how an artwork is
/// cast to a TV/AirPlay target. Misclassification sends a still image to a
/// video player (or vice versa), so the extension parsing, CDN-URL unwrapping,
/// and animation-over-image precedence all matter.
void main() {
  // These suites assert URL *shapes*, which only exist once the build declares
  // the hosts that produce them. Placeholder hosts on purpose: the rule under
  // test is the transform, never one deployment's domain.
  setUp(() {
    Config.debugOverrides.addAll({
      'IMAGE_CDN_BASE_URL': 'https://images.example.com',
    });
  });

  tearDown(Config.debugOverrides.clear);

  group('resolveSync — extension classification', () {
    test('classifies video extensions', () {
      for (final url in [
        'https://x.com/a.mp4',
        'https://x.com/a.mov',
        'https://x.com/a.webm',
        'https://x.com/a.m4v',
      ]) {
        expect(
          ArtworkMediaResolver.resolveSync(imageUrl: url),
          CastMediaType.video,
          reason: url,
        );
      }
    });

    test('classifies animated extensions (gif, webp)', () {
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: 'https://x.com/a.gif'),
        CastMediaType.animated,
      );
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: 'https://x.com/a.webp'),
        CastMediaType.animated,
      );
    });

    test('classifies static extensions', () {
      for (final url in [
        'https://x.com/a.jpg',
        'https://x.com/a.jpeg',
        'https://x.com/a.png',
        'https://x.com/a.avif',
        'https://x.com/a.svg',
      ]) {
        expect(
          ArtworkMediaResolver.resolveSync(imageUrl: url),
          CastMediaType.staticImage,
          reason: url,
        );
      }
    });

    test('is case-insensitive on the extension', () {
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: 'https://x.com/A.MP4'),
        CastMediaType.video,
      );
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: 'https://x.com/A.GIF'),
        CastMediaType.animated,
      );
    });

    test('ignores query string and fragment when reading the extension', () {
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://x.com/a.mp4?token=abc&w=100',
        ),
        CastMediaType.video,
      );
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: 'https://x.com/a.png#frag'),
        CastMediaType.staticImage,
      );
    });

    test('a dot in the query does not get mistaken for an extension', () {
      // The path has no extension; the ".png" lives in the query string.
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://x.com/img?file=a.png',
        ),
        CastMediaType.unknown,
      );
    });

    test('extensionless and empty URLs are unknown', () {
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://ipfs.io/ipfs/Qm123',
        ),
        CastMediaType.unknown,
      );
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: ''),
        CastMediaType.unknown,
      );
    });
  });

  group('resolveSync — animationUrl precedence', () {
    test('a recognized animationUrl wins over the imageUrl', () {
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://x.com/a.png',
          animationUrl: 'https://x.com/a.mp4',
        ),
        CastMediaType.video,
      );
    });

    test('falls back to imageUrl when animationUrl is unrecognized', () {
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://x.com/a.png',
          animationUrl: 'https://ipfs.io/ipfs/Qm123',
        ),
        CastMediaType.staticImage,
      );
    });

    test('an empty animationUrl is ignored', () {
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://x.com/a.gif',
          animationUrl: '',
        ),
        CastMediaType.animated,
      );
    });
  });

  group('resolveSync — mallow CDN unwrapping', () {
    test('recovers the original extension from a CDN-resized image URL', () {
      // CDN format: https://images.example.com/{size}x{size}/{fit}/{encodedUrl}
      const original = 'https://arweave.net/abc123.mp4';
      final cdn =
          'https://images.example.com/800x800/cover/${Uri.encodeComponent(original)}';
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: cdn),
        CastMediaType.video,
      );
    });

    test('CDN URL wrapping a gif resolves to animated', () {
      const original = 'https://arweave.net/abc123.gif';
      final cdn =
          'https://images.example.com/400x400/contain/${Uri.encodeComponent(original)}';
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: cdn),
        CastMediaType.animated,
      );
    });

    test('CDN URL wrapping an extensionless origin is unknown', () {
      const original = 'https://arweave.net/abc123';
      final cdn =
          'https://images.example.com/400x400/contain/${Uri.encodeComponent(original)}';
      expect(
        ArtworkMediaResolver.resolveSync(imageUrl: cdn),
        CastMediaType.unknown,
      );
    });

    test('malformed CDN URL (too few segments) is treated literally', () {
      // No encoded-URL segment → falls through to classifying the URL itself,
      // which has no extension.
      expect(
        ArtworkMediaResolver.resolveSync(
          imageUrl: 'https://images.example.com/800x800',
        ),
        CastMediaType.unknown,
      );
    });
  });

  group('bestCastUrl', () {
    test('returns animationUrl for video/animated when present', () {
      expect(
        ArtworkMediaResolver.bestCastUrl(
          imageUrl: 'https://x.com/a.png',
          mediaType: CastMediaType.video,
          animationUrl: 'https://x.com/a.mp4',
        ),
        'https://x.com/a.mp4',
      );
      expect(
        ArtworkMediaResolver.bestCastUrl(
          imageUrl: 'https://x.com/a.png',
          mediaType: CastMediaType.animated,
          animationUrl: 'https://x.com/a.gif',
        ),
        'https://x.com/a.gif',
      );
    });

    test(
      'returns imageUrl for static images even when animationUrl exists',
      () {
        expect(
          ArtworkMediaResolver.bestCastUrl(
            imageUrl: 'https://x.com/a.png',
            // ignore: avoid_redundant_argument_values
            mediaType: CastMediaType.staticImage,
            animationUrl: 'https://x.com/a.mp4',
          ),
          'https://x.com/a.png',
        );
      },
    );

    test(
      'returns imageUrl for non-static when animationUrl is missing/empty',
      () {
        expect(
          ArtworkMediaResolver.bestCastUrl(
            imageUrl: 'https://x.com/a.png',
            mediaType: CastMediaType.video,
          ),
          'https://x.com/a.png',
        );
        expect(
          ArtworkMediaResolver.bestCastUrl(
            imageUrl: 'https://x.com/a.png',
            mediaType: CastMediaType.video,
            animationUrl: '',
          ),
          'https://x.com/a.png',
        );
      },
    );

    test('defaults to staticImage media type → returns imageUrl', () {
      expect(
        ArtworkMediaResolver.bestCastUrl(
          imageUrl: 'https://x.com/a.png',
          animationUrl: 'https://x.com/a.mp4',
        ),
        'https://x.com/a.png',
      );
    });
  });

  group('resolveAsync — sync fast-path (no network)', () {
    test(
      'returns the sync result without probing when extension is known',
      () async {
        expect(
          await ArtworkMediaResolver.resolveAsync(
            imageUrl: 'https://x.com/a.mp4',
          ),
          CastMediaType.video,
        );
      },
    );

    test('empty probe target defaults to staticImage', () async {
      expect(
        await ArtworkMediaResolver.resolveAsync(imageUrl: ''),
        CastMediaType.staticImage,
      );
    });
  });

  // The receivers render whatever these return, verbatim. A raw `ipfs://` URI
  // reaching an image widget / `<img src>` / video player cannot be fetched at
  // all — the receiver then sits on its loading shimmer forever, which is
  // exactly the bug the poster/original split exists to prevent. So the one
  // property that matters here is: the output is always something an HTTP
  // client can actually GET.
  group('posterUrl — the first frame every receiver paints', () {
    const ipfsSource = 'ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';

    test('resolves a raw ipfs:// source into a fetchable https URL', () {
      final poster = ArtworkMediaResolver.posterUrl(ipfsSource);
      expect(poster, startsWith('https://images.example.com/'));
      expect(
        poster,
        isNot(startsWith('ipfs://')),
        reason: 'no receiver can fetch an ipfs:// URI',
      );
    });

    test('asks the CDN for a warm bucket, not the full-size original', () {
      // Off-bucket sizes are not pre-warmed, so a miss costs a cold resize on
      // the very request whose whole job is to beat the original to screen.
      expect(
        ArtworkMediaResolver.posterUrl('https://x.test/a.png'),
        contains(
          '/${ArtworkMediaResolver.posterCdnSize}'
          'x${ArtworkMediaResolver.posterCdnSize}/',
        ),
      );
    });

    test("fits 'inside' so the receiver's own BoxFit does the cropping", () {
      // 'cover' would square-crop at the CDN, permanently discarding the edges
      // a fill-screen 16:9 TV still needs.
      expect(
        ArtworkMediaResolver.posterUrl('https://x.test/a.png'),
        contains('/inside/'),
      );
    });

    test('passes an empty source through untouched', () {
      expect(ArtworkMediaResolver.posterUrl(''), '');
    });
  });

  group('originalCastUrl — the full-resolution upgrade', () {
    test('routes a raw ipfs:// source through /original/', () {
      final url = ArtworkMediaResolver.originalCastUrl(
        imageUrl: 'ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG',
      );
      expect(url, startsWith('https://images.example.com/original/'));
    });

    test('upgrades to the animation source for animated artworks', () {
      // The poster is a still either way; the upgrade is what makes a GIF
      // actually animate on the TV.
      final url = ArtworkMediaResolver.originalCastUrl(
        imageUrl: 'https://x.test/still.png',
        mediaType: CastMediaType.animated,
        animationUrl: 'https://x.test/loop.gif',
      );
      expect(url, contains(Uri.encodeComponent('https://x.test/loop.gif')));
    });

    test('upgrades to the image source for static artworks', () {
      final url = ArtworkMediaResolver.originalCastUrl(
        imageUrl: 'https://x.test/still.png',
        animationUrl: 'https://x.test/loop.mp4',
      );
      expect(url, contains(Uri.encodeComponent('https://x.test/still.png')));
    });

    test('is distinct from the poster, so the upgrade is a real upgrade', () {
      const source = 'https://x.test/a.png';
      expect(
        ArtworkMediaResolver.originalCastUrl(imageUrl: source),
        isNot(ArtworkMediaResolver.posterUrl(source)),
      );
    });
  });
}
