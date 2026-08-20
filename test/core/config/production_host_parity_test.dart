import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/config/system_status_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/utils/asset_url.dart';
import 'package:mallow_wallet/core/utils/canonical_asset_url.dart';
import 'package:mallow_wallet/core/utils/mallow_image.dart';
import 'package:mallow_wallet/features/mint/data/ipfs_uploader.dart';

/// The media, CDN and gateway hosts moved from `const` Dart strings into build
/// variables so the published source names no deployment's infrastructure. That
/// refactor is only safe if a configured build emits **byte-identical** URLs —
/// these are Cloudflare edge keys, R2 object keys and, for the pin gateway,
/// metadata written on-chain forever. A difference of one slash is a total
/// cache miss, and in the mint case it is permanent.
///
/// So this suite pins the migration itself: it configures every variable at
/// once and asserts each URL is joined exactly the way the constant-based code
/// joined it. It fails if a future edit changes how a host and a path are
/// combined.
///
/// Placeholder hosts, like every other suite here: the rule under test is the
/// transform, never one deployment's domain, and a hardcoded first-party host
/// is the thing this whole refactor removed. What a deployment must actually
/// put in each variable belongs in its build configuration, not in source.
///
/// The expected strings are deliberately written out in full rather than built
/// from the variables — a test that composes the URL the same way the code does
/// cannot catch the code composing it wrongly.
void main() {
  /// Every host variable set together — the migration moved them as one, and a
  /// suite that set only the one it asserts would not catch a getter reading
  /// its neighbour's variable.
  const configuredHosts = {
    'IMAGE_CDN_BASE_URL': 'https://images.example.com',
    'ASSET_CDN_BASE_URL': 'https://cdn.example.com',
    'IPFS_GATEWAY_URL': 'https://ipfs.example.com',
    'ARWEAVE_GATEWAY_URL': 'https://arweave.example.com',
    'AVATAR_SERVICE_URL': 'https://avatar.example.com',
  };

  setUp(() => Config.debugOverrides.addAll(configuredHosts));
  tearDown(Config.debugOverrides.clear);

  const cid = 'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim';
  const txid = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';

  group('image CDN', () {
    test('resize URL matches the pre-refactor shape exactly', () {
      expect(
        MallowImage.cdnUrl('https://example.com/a.png', logicalPx: 140),
        'https://images.example.com/350x350/cover/'
        'https%3A%2F%2Fexample.com%2Fa.png?quality=50',
      );
    });

    test('originals route matches', () {
      expect(
        MallowImage.originalUrl('https://example.com/a.png'),
        'https://images.example.com/original/'
        'https%3A%2F%2Fexample.com%2Fa.png',
      );
    });

    test('a trailing slash in the variable does not double the separator', () {
      Config.debugOverrides['IMAGE_CDN_BASE_URL'] =
          'https://images.example.com/';
      expect(
        MallowImage.originalUrl('https://example.com/a.png'),
        startsWith('https://images.example.com/original/'),
      );
    });
  });

  group('asset CDN', () {
    test('store base matches, production and non-production', () {
      // isProduction is compile-time, so only the arm this run is built for is
      // assertable — the other is pinned by the string it is built from.
      expect(
        Config.storeCdnBaseUrl,
        Config.isProduction
            ? 'https://cdn.example.com/store'
            : 'https://cdn.example.com/store/dev',
      );
    });

    test('status and notice feeds match', () {
      expect(kStatusFeedUrl, 'https://cdn.example.com/status.json');
      expect(kNoticeFeedUrl, 'https://cdn.example.com/notification-v2.json');
    });
  });

  group('gateways', () {
    test('ipfs:// resolves through the CONFIGURED gateway in toDirectUrl', () {
      // toDirectUrl is the no-CDN / fallback path, so it honours the variable.
      expect(toDirectUrl('ipfs://$cid'), 'https://ipfs.example.com/ipfs/$cid');
    });

    test('but the CDN source form always resolves to the public gateway', () {
      // 🛑 This is the string embedded in the resize path, so it IS the
      // resizer's cache key. The web client resolves `ipfs://` through
      // `ipfs.io` unconditionally (`getAltStorageUrl`'s first branch); sending
      // our own host here forked every ipfs:// asset across two cache entries,
      // and the backend warmer only ever warmed the web client's. Setting
      // IPFS_GATEWAY_URL must NOT be able to change this.
      expect(
        AssetUrl.primaryGatewayUrl('ipfs://$cid'),
        'https://ipfs.io/ipfs/$cid',
      );
      expect(
        MallowImage.cdnUrl('ipfs://$cid', logicalPx: 175),
        'https://images.example.com/350x350/cover/'
        '${Uri.encodeComponent('https://ipfs.io/ipfs/$cid')}?quality=50',
      );
    });

    test('ar:// resolves to the same mirror URL', () {
      expect(toDirectUrl('ar://$txid'), 'https://arweave.example.com/$txid');
    });

    test('the gateway bases AssetUrl builds on follow the variables', () {
      // Full base URLs, the same value `toDirectUrl` reads: the two files split
      // over one variable is how a configured gateway got rebuilt as
      // `https://<host>` with its port and path prefix dropped.
      expect(AssetUrl.mallowIpfsBase, 'https://ipfs.example.com');
      expect(AssetUrl.mallowArweaveBase, 'https://arweave.example.com');
    });

    test('the arweave mirror is still recognised by canonicalisation', () {
      // Host-gated, unlike IPFS. If the configured mirror is missing from the
      // recognised set, the same bytes canonicalise two ways and the R2 and
      // edge caches fork — silently, with nothing failing to show for it.
      expect(
        canonicalizeAssetUrl('https://arweave.example.com/$txid'),
        'ar://$txid',
      );
    });

    test('the 403 recovery mirror is still offered for an arweave source', () {
      expect(
        AssetUrl.assetSourceCandidates('https://arweave.net/$txid'),
        contains('https://arweave.example.com/$txid'),
      );
    });
  });

  group('mint metadata gateway — on-chain, so it is not configuration', () {
    test('is always ipfs.io, matching the web client', () {
      // The web client's `toIpfsUri` writes `https://ipfs.io/ipfs/<hash>` into
      // every minted image and metadata uri. The app wrote its own gateway
      // instead, which is baked into those tokens permanently. No variable may
      // reintroduce that — hence a constant, and hence this assertion runs
      // with IPFS_GATEWAY_URL pointing somewhere else entirely.
      expect(
        IpfsUploader().gatewayUrl('QmHash'),
        'https://ipfs.io/ipfs/QmHash',
      );
    });
  });

  group('avatar service', () {
    test('identicon URL matches the pre-refactor shape exactly', () {
      final url = AvatarService().avatarUrl('seed-1');
      expect(url.origin, 'https://avatar.example.com');
      expect(url.path, '/10.x/identicon/svg');
      expect(url.queryParameters['seed'], isNotEmpty);
    });
  });

  group('the variables that must not have a default', () {
    test('API_BASE_URL and IPFS_UPLOAD_URL are empty when unset', () {
      // Both are required in production. A compiled-in fallback is what this
      // whole change removed: for the API it would point a fork at someone
      // else's backend, and for the uploader it would write a fork's user
      // media into someone else's storage.
      Config.debugOverrides.clear();
      expect(Config.apiBaseUrl, isEmpty);
      expect(Config.apiV2BaseUrl, isEmpty);
      expect(Config.ipfsUploadUrl, isEmpty);
    });
  });
}
