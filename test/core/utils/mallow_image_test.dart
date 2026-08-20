import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/utils/asset_url.dart';
import 'package:mallow_wallet/core/utils/mallow_image.dart';

/// [MallowImage] builds the CDN URLs that every artwork/token thumbnail
/// goes through. Wrong sizing means blurry images or bandwidth waste, and
/// the IPFS gateway fallback determines whether off-chain artwork loads at
/// all. The size-bucketing math is exercised exhaustively because the
/// boundaries are easy to get wrong on a refactor.
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

  group('MallowImage.cdnUrl — size bucketing', () {
    test('picks the smallest bucket that covers the 2× retina target', () {
      // 50px → 100 needed → fits the 100 bucket
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 50),
        contains('/100x100/'),
      );
    });

    test('rounds the 2× target up (ceil) to the next bucket', () {
      // 51px → 102 needed → exceeds 100, must pick 350
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 51),
        contains('/350x350/'),
      );
    });

    test('honours exact bucket boundaries (no off-by-one upgrades)', () {
      // 25px → exactly 50 needed → 50 bucket
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 25),
        contains('/50x50/'),
      );
      // 175px → exactly 350 needed → 350 bucket
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 175),
        contains('/350x350/'),
      );
    });

    test('clamps oversized requests to the largest bucket (800)', () {
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 10000),
        contains('/800x800/'),
      );
    });

    test('sizes the bucket from the caller-supplied pixel ratio', () {
      // A 3× screen genuinely needs 3× the pixels. Serving it the 2× bucket is
      // the upscaling bug this parameter exists to fix, so the same logicalPx
      // must land one bucket higher on a 3× device than on a 2× one.
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 140, dpr: 3),
        contains('/600x600/'),
      );
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 140),
        contains('/350x350/'),
      );
    });

    test('clamps a high-density request to the largest bucket', () {
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 400, dpr: 3),
        contains('/800x800/'),
      );
    });

    test('walks through every CDN size bucket in order', () {
      // logicalPx → expected bucket
      final cases = <double, int>{
        1: 50,
        25: 50,
        26: 100,
        50: 100,
        51: 350,
        175: 350,
        176: 600,
        256: 600,
        300: 600,
        301: 800,
        400: 800,
      };
      for (final entry in cases.entries) {
        expect(
          MallowImage.cdnUrl('https://example.com/a.png', logicalPx: entry.key),
          contains('/${entry.value}x${entry.value}/'),
          reason: 'logicalPx=${entry.key} should pick bucket ${entry.value}',
        );
      }
    });
  });

  group('MallowImage.cdnUrl — URL building', () {
    test('returns empty input unchanged (no transformation)', () {
      expect(MallowImage.cdnUrl('', logicalPx: 100), '');
    });

    test('encodes the resolved URL as a path segment', () {
      final url = MallowImage.cdnUrl(
        'https://example.com/path with spaces.png',
        logicalPx: 50,
      );
      expect(url, contains('path%20with%20spaces.png'));
    });

    test('defaults fit to "cover" and quality to 50', () {
      final url = MallowImage.cdnUrl(
        'https://example.com/a.png',
        logicalPx: 50,
      );
      expect(url, contains('/cover/'));
      expect(url, endsWith('?quality=50'));
    });

    test('overrides fit and quality when provided', () {
      final url = MallowImage.cdnUrl(
        'https://example.com/a.png',
        logicalPx: 50,
        fit: 'inside',
        quality: 80,
      );
      expect(url, contains('/inside/'));
      expect(url, endsWith('?quality=80'));
    });

    test('prefixes the canonical CDN base URL', () {
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 50),
        startsWith('https://images.example.com/'),
      );
    });
  });

  group('MallowImage.cdnUrl — IPFS resolution', () {
    test('rewrites ipfs:// to mallow\'s IPFS gateway before encoding', () {
      final url = MallowImage.cdnUrl(
        'ipfs://QmHashHashHash/file.png',
        logicalPx: 100,
      );
      // Must match what AssetUrl hands direct fetches, so the CDN and the
      // app agree on one gateway instead of splitting across two.
      expect(
        Uri.decodeComponent(url.split('/').last.split('?').first),
        '${AssetUrl.mallowIpfsBase}/ipfs/QmHashHashHash/file.png',
      );
    });

    test(
      'leaves https:// URLs untouched (only the ipfs:// scheme is rewritten)',
      () {
        final url = MallowImage.cdnUrl(
          'https://arweave.net/abc.png',
          logicalPx: 100,
        );
        expect(
          Uri.decodeComponent(url.split('/').last.split('?').first),
          'https://arweave.net/abc.png',
        );
      },
    );
  });

  group('MallowImage.cdnUrlForSize', () {
    test('passes the explicit cdnSize through verbatim (no bucketing)', () {
      expect(
        MallowImage.cdnUrlForSize('https://example.com/a.png', cdnSize: 600),
        contains('/600x600/'),
      );
    });

    test('returns empty input unchanged', () {
      expect(MallowImage.cdnUrlForSize('', cdnSize: 350), '');
    });

    test('respects fit and quality overrides', () {
      final url = MallowImage.cdnUrlForSize(
        'https://example.com/a.png',
        cdnSize: 800,
        fit: 'inside',
        quality: 90,
      );
      expect(url, contains('/inside/'));
      expect(url, endsWith('?quality=90'));
    });
  });

  /// Originals are served from R2 by images.example.com, which is dramatically
  /// faster than walking a public IPFS/Arweave gateway — so every original
  /// fetch goes through `/original/`, on both sides of the resize-path gate
  /// below. Sending one to a gateway instead trades the cache for a cold
  /// third-party fetch that also 403s/404s far more often.
  group('MallowImage.originalUrl', () {
    tearDown(() => Config.canonicalAssetUrls = false);

    test('routes ipfs:// through /original/, not the gateway', () {
      expect(
        MallowImage.originalUrl('ipfs://QmHash/file.png'),
        'https://images.example.com/original/ipfs%3A%2F%2FQmHash%2Ffile.png',
      );
    });

    test('routes arweave through /original/ in canonical ar:// form', () {
      const txid = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      expect(
        MallowImage.originalUrl('https://arweave.net/$txid'),
        'https://images.example.com/original/ar%3A%2F%2F$txid',
      );
    });

    test('is not gated on the resize-path canonical flag', () {
      const txid = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      final whileOff = MallowImage.originalUrl('https://arweave.net/$txid');
      Config.canonicalAssetUrls = true;
      expect(MallowImage.originalUrl('https://arweave.net/$txid'), whileOff);
    });

    test('returns empty input unchanged', () {
      expect(MallowImage.originalUrl(''), '');
    });
  });

  /// The canonical form is the Cloudflare/R2 cache key for every asset the app
  /// renders: emitting the gateway form instead
  /// splits one asset across an edge entry per gateway, which is precisely the
  /// fragmentation this rollout exists to remove. The gate now reads
  /// `--dart-define` then `.env`, so both sides of it have to keep working, and
  /// the default with neither set must stay off.
  group('MallowImage — canonical resize-path gate', () {
    tearDown(() => Config.canonicalAssetUrls = false);

    test('defaults to off so a build never ramps itself', () {
      expect(Config.canonicalAssetUrls, isFalse);
    });

    test('off: resize URLs keep embedding the resolved gateway URL', () {
      final url = MallowImage.cdnUrl('ipfs://QmHash/file.png', logicalPx: 100);
      expect(
        Uri.decodeComponent(url.split('/').last.split('?').first),
        '${AssetUrl.mallowIpfsBase}/ipfs/QmHash/file.png',
      );
    });

    test('on: resize URLs embed the canonical scheme-native form', () {
      Config.canonicalAssetUrls = true;
      const cid = 'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim';
      // Both arrival shapes of the same bytes must produce the same CDN URL —
      // that collapse IS the point of the change.
      final fromScheme = MallowImage.cdnUrl(
        'ipfs://$cid/0.png',
        logicalPx: 100,
      );
      final fromGateway = MallowImage.cdnUrl(
        'https://ipfs.io/ipfs/$cid/0.png?ext=png',
        logicalPx: 100,
      );
      expect(fromScheme, fromGateway);
      expect(fromScheme, contains('ipfs%3A%2F%2F$cid%2F0.png'));
    });

    test('on: an empty URL is still never turned into a request', () {
      Config.canonicalAssetUrls = true;
      expect(MallowImage.originalUrl(''), '');
      expect(MallowImage.cdnUrl('', logicalPx: 100), '');
    });
  });

  /// `CANONICAL_ASSET_URLS` and `IMAGE_CDN_BASE_URL` are configured
  /// independently and nothing cross-gates them, so "flag on, no resizer" is a
  /// build anyone can produce. It collapses the resize path onto its no-CDN
  /// early return, and what that returns goes straight to an image loader.
  /// The canonical form is a cache key, not a fetchable URL: handing one back
  /// renders the error fallback for every IPFS and Arweave asset in the app.
  group('MallowImage — canonical form with no CDN configured', () {
    const cid = 'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim';
    const txid = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

    setUp(() {
      Config.debugOverrides.addAll({
        'IMAGE_CDN_BASE_URL': '',
        'IPFS_GATEWAY_URL': 'https://ipfs.example.com',
        'ARWEAVE_GATEWAY_URL': 'https://arweave.example.com',
      });
      Config.canonicalAssetUrls = true;
    });

    tearDown(() => Config.canonicalAssetUrls = false);

    test('resolves ipfs:// back to a fetchable gateway URL', () {
      expect(
        MallowImage.cdnUrl('ipfs://$cid/0.png', logicalPx: 100),
        'https://ipfs.example.com/ipfs/$cid/0.png',
      );
    });

    test('resolves ar:// back to a fetchable gateway URL', () {
      expect(
        MallowImage.cdnUrl('ar://$txid', logicalPx: 100),
        'https://arweave.example.com/$txid',
      );
    });

    test('resolves an https gateway URL it canonicalised on the way in', () {
      // The canonicalisation runs on every arrival shape, so an https input is
      // just as capable of leaving this path as `ipfs://` as a scheme one is.
      expect(
        MallowImage.cdnUrl('https://ipfs.io/ipfs/$cid/0.png', logicalPx: 100),
        'https://ipfs.example.com/ipfs/$cid/0.png',
      );
    });

    test('leaves a URL that is not content-addressed untouched', () {
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 100),
        'https://example.com/a.png',
      );
    });

    test('cdnUrlForSize takes the same no-CDN path', () {
      expect(
        MallowImage.cdnUrlForSize('ipfs://$cid/0.png', cdnSize: 600),
        'https://ipfs.example.com/ipfs/$cid/0.png',
      );
    });
  });
}
