import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/utils/asset_url.dart';

/// [AssetUrl] decides which gateways an *original* artwork asset (video source,
/// full-res image) is fetched from, and in what order. It exists because those
/// origins 403 unpredictably — most notably `arweave.net`, whose CDN blocks
/// specific clients even for data it serves fine elsewhere. These tests pin the
/// two behaviours the player depends on: the public gateway must come FIRST
/// (matching the webapp, which only mirrors on a real load failure), and a
/// working mirror/alternate must ALWAYS follow so a 403 is recoverable rather
/// than fatal. If the mirror stopped following the primary, video playback
/// would silently regress to the still poster for every arweave asset.
void main() {
  // These suites assert URL *shapes*, which only exist once the build declares
  // the hosts that produce them. Placeholder hosts on purpose: the rule under
  // test is the transform, never one deployment's domain.
  setUp(() {
    Config.debugOverrides.addAll({
      'IMAGE_CDN_BASE_URL': 'https://images.example.com',
      'IPFS_GATEWAY_URL': 'https://ipfs.example.com',
      'ARWEAVE_GATEWAY_URL': 'https://arweave.example.com',
    });
  });

  tearDown(Config.debugOverrides.clear);

  const cid = 'QmAbc123';

  group('AssetUrl.mallowArweaveUrl', () {
    test(
      'mirrors arweave.net onto arweave.example.com, preserving the path',
      () {
        expect(
          AssetUrl.mallowArweaveUrl('https://arweave.net/abc123'),
          'https://arweave.example.com/abc123',
        );
      },
    );

    test('preserves the query string on the mirror', () {
      expect(
        AssetUrl.mallowArweaveUrl('https://arweave.net/abc123?ext=mp4'),
        'https://arweave.example.com/abc123?ext=mp4',
      );
    });

    test('mirrors per-tx arweave.net sandbox subdomains', () {
      expect(
        AssetUrl.mallowArweaveUrl('https://base32hash.arweave.net/abc'),
        'https://arweave.example.com/abc',
      );
    });

    test('mirrors the permagate.io gateway', () {
      expect(
        AssetUrl.mallowArweaveUrl('https://permagate.io/abc123'),
        'https://arweave.example.com/abc123',
      );
    });

    test('returns null for a non-arweave URL', () {
      expect(AssetUrl.mallowArweaveUrl('https://ipfs.io/ipfs/$cid'), isNull);
    });
  });

  group('AssetUrl.assetSourceCandidates — arweave (the 403 case)', () {
    test('serves the public gateway first, then the mallow mirror', () {
      // Order matters: the webapp shows the public gateway and only swaps to the
      // mirror when it actually fails, so the mirror must come SECOND, not first.
      expect(AssetUrl.assetSourceCandidates('https://arweave.net/abc123'), [
        'https://arweave.net/abc123',
        'https://arweave.example.com/abc123',
      ]);
    });

    test('does not append a duplicate when already on the mallow mirror', () {
      // A URL that's already the mirror has nothing left to fall back to, so the
      // list is a single entry — otherwise the player would "retry" the same URL.
      expect(
        AssetUrl.assetSourceCandidates('https://arweave.example.com/abc123'),
        ['https://arweave.example.com/abc123'],
      );
    });
  });

  group('AssetUrl.assetSourceCandidates — ipfs', () {
    test(
      'resolves ipfs:// through the PUBLIC gateway first, then the mirror',
      () {
        // 🛑 ipfs.io leads on every chain, and the configured mirror is only a
        // retry behind it. The first candidate is also the string embedded in
        // the image CDN's resize path, so it is the resizer cache key: the web
        // client resolves `ipfs://` through ipfs.io unconditionally, and a
        // different host here forks every ipfs:// asset across two cache
        // entries with nothing failing to show for it.
        expect(AssetUrl.assetSourceCandidates('ipfs://$cid', chain: 'solana'), [
          'https://ipfs.io/ipfs/$cid',
          'https://ipfs.example.com/ipfs/$cid',
          'https://dweb.link/ipfs/$cid',
        ]);
      },
    );

    test('is chain-independent for the ipfs:// scheme', () {
      expect(AssetUrl.assetSourceCandidates('ipfs://$cid', chain: 'ethereum'), [
        'https://ipfs.io/ipfs/$cid',
        'https://ipfs.example.com/ipfs/$cid',
        'https://dweb.link/ipfs/$cid',
      ]);
    });

    test('offers dweb.link last — neither of our hosts is a complete index', () {
      // Both of ours failing together is a real, observed state, not a freak
      // outage: a CID that was never pinned on ipfs.example.com 404s there
      // forever, and ipfs.io 504s cold-fetching a large object. With only those
      // two the ladder ended there, which is what made a download of a live
      // artwork report "1 failed" while its thumbnail rendered fine from the
      // CDN's cached resize variant.
      final candidates = AssetUrl.assetSourceCandidates(
        'ipfs://$cid',
        chain: 'solana',
      );
      expect(candidates.last, 'https://dweb.link/ipfs/$cid');
    });

    test('does not offer dweb.link for a non-IPFS source', () {
      expect(
        AssetUrl.assetSourceCandidates('https://arweave.net/abc123'),
        isNot(contains(startsWith('https://dweb.link/'))),
      );
    });

    test('treats an unspecified chain as Solana for the http rewrite', () {
      // The chain still selects the mirror for an already-http ipfs.io URL —
      // only the ipfs:// scheme branch is unconditional.
      expect(
        AssetUrl.assetSourceCandidates('https://ipfs.io/ipfs/$cid').first,
        'https://ipfs.example.com/ipfs/$cid',
      );
    });

    test('absorbs the redundant ipfs://ipfs/<cid> form', () {
      expect(
        AssetUrl.assetSourceCandidates(
          'ipfs://ipfs/$cid',
          chain: 'solana',
        ).first,
        'https://ipfs.io/ipfs/$cid',
      );
    });

    test('rewrites an ipfs.io http URL to the mallow gateway for Solana', () {
      expect(AssetUrl.assetSourceCandidates('https://ipfs.io/ipfs/$cid'), [
        'https://ipfs.example.com/ipfs/$cid',
        'https://ipfs.io/ipfs/$cid',
        'https://dweb.link/ipfs/$cid',
      ]);
    });
  });

  group('AssetUrl.assetSourceCandidates — skipped sources', () {
    test('returns empty for a blacklisted shdw-drive URL', () {
      // shdw-drive assets are known-unplayable; an empty list tells the caller to
      // keep the poster instead of spinning on a source that will never load.
      expect(
        AssetUrl.assetSourceCandidates(
          'https://shdw-drive.genesysgo.net/xyz/video.mp4',
        ),
        isEmpty,
      );
    });

    test('returns empty for an empty URL', () {
      expect(AssetUrl.assetSourceCandidates(''), isEmpty);
    });

    test('leaves a plain https source untouched with no phantom fallbacks', () {
      expect(AssetUrl.assetSourceCandidates('https://cdn.example.com/v.mp4'), [
        'https://cdn.example.com/v.mp4',
      ]);
    });
  });

  /// A gateway variable holds a whole base URL, not a host: the e2e harness
  /// points both at one local mock, `http://<host>:<port>/<gateway-prefix>`, and
  /// a deployment can proxy a gateway under a path. Reducing the variable to its
  /// host and rebuilding on `https://<host>/` dropped the scheme, the port and
  /// the prefix, so every rung of the ladder dialled an origin nothing was
  /// serving while the configured gateway went untouched — and
  /// `canonical_asset_url.dart` read the same two variables as full base URLs
  /// all along, so the two files disagreed about identical configuration.
  group('AssetUrl — gateway bases with a scheme, port and path prefix', () {
    const ipfsBase = 'http://127.0.0.1:8099/ipfs-gateway';
    const arweaveBase = 'http://127.0.0.1:8099/arweave-gateway';

    setUp(() {
      Config.debugOverrides.addAll({
        'IPFS_GATEWAY_URL': ipfsBase,
        'ARWEAVE_GATEWAY_URL': arweaveBase,
      });
    });

    test('the arweave mirror keeps all three parts', () {
      expect(
        AssetUrl.mallowArweaveUrl('https://arweave.net/abc123?ext=mp4'),
        '$arweaveBase/abc123?ext=mp4',
      );
    });

    test('a trailing slash in the variable does not double the separator', () {
      Config.debugOverrides['ARWEAVE_GATEWAY_URL'] = '$arweaveBase/';
      expect(
        AssetUrl.mallowArweaveUrl('https://arweave.net/abc123'),
        '$arweaveBase/abc123',
      );
    });

    test('every ipfs rung keeps all three parts', () {
      // dweb.link stays a plain https host — it is a third party, not something
      // the local prefix may leak into.
      expect(AssetUrl.assetSourceCandidates('ipfs://$cid', chain: 'solana'), [
        'https://ipfs.io/ipfs/$cid',
        '$ipfsBase/ipfs/$cid',
        'https://dweb.link/ipfs/$cid',
      ]);
    });

    test('an ipfs.io source rewrites onto the configured base', () {
      expect(AssetUrl.assetSourceCandidates('https://ipfs.io/ipfs/$cid'), [
        '$ipfsBase/ipfs/$cid',
        'https://ipfs.io/ipfs/$cid',
        'https://dweb.link/ipfs/$cid',
      ]);
    });

    test('a source already on a configured base gets no second rung', () {
      // Both bases share a host here, so a host-equality test would call the
      // IPFS URL an arweave source and offer a mirror under the wrong prefix.
      expect(AssetUrl.assetSourceCandidates('$arweaveBase/abc123'), [
        '$arweaveBase/abc123',
      ]);
      expect(
        AssetUrl.assetSourceCandidates('$ipfsBase/ipfs/$cid'),
        isNot(contains(startsWith(arweaveBase))),
      );
    });

    test('the video ladder carries the same bases behind /original/', () async {
      final result = await AssetUrl.videoSourceCandidates(
        'https://arweave.net/abc123',
        chain: 'solana',
      );
      expect(result, [
        'https://images.example.com/original/https%3A%2F%2Farweave.net%2Fabc123',
        'https://arweave.net/abc123',
        '$arweaveBase/abc123',
      ]);
    });
  });

  /// The images service gets first refusal via `/original/` before the
  /// on-device gateway walk: it serves the R2-cached original when it has one,
  /// which is far faster than any public gateway. The retired resolver never
  /// leads the list.
  group('AssetUrl.videoSourceCandidates', () {
    const cid = 'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim';

    test('/original/ leads even with the resize-path gate off', () async {
      final result = await AssetUrl.videoSourceCandidates(
        'https://arweave.net/abc123',
        chain: 'solana',
      );
      expect(result, [
        'https://images.example.com/original/https%3A%2F%2Farweave.net%2Fabc123',
        'https://arweave.net/abc123',
        'https://arweave.example.com/abc123',
      ]);
    });

    test('/original/ leads, the gateway ladder still follows', () async {
      final result = await AssetUrl.videoSourceCandidates(
        'ipfs://$cid/v.mp4',
        chain: 'solana',
      );
      // The service picks the gateway behind a 307 — but the host it lands on
      // can 404/403 the player, and without the direct candidates behind it
      // that ends playback with nothing left to try (decision 24).
      expect(result, [
        'https://images.example.com/original/ipfs%3A%2F%2F$cid%2Fv.mp4',
        'https://ipfs.io/ipfs/$cid/v.mp4',
        'https://ipfs.example.com/ipfs/$cid/v.mp4',
        'https://dweb.link/ipfs/$cid/v.mp4',
      ]);
    });

    test(
      'every arrival shape of one asset yields one CDN source URL',
      () async {
        // Same bytes reached three ways must produce one CDN key, or the video
        // fragments across edge entries exactly like the images did. Only the
        // leading `/original/` URL is that key; the gateway candidates behind
        // it are per-arrival-shape by construction and never reach the edge.
        final fromScheme = await AssetUrl.videoSourceCandidates(
          'ipfs://$cid/v.mp4',
        );
        final fromGateway = await AssetUrl.videoSourceCandidates(
          'https://ipfs.io/ipfs/$cid/v.mp4',
        );
        final fromQuery = await AssetUrl.videoSourceCandidates(
          'https://ipfs.example.com/ipfs/$cid/v.mp4?ext=mp4',
        );
        expect(fromScheme.first, fromGateway.first);
        expect(fromScheme.first, fromQuery.first);
      },
    );

    test('unplayable sources are still skipped entirely', () async {
      // The blacklist is a playback decision, not a gateway one — routing a
      // known-dead shdw-drive asset through /original/ would spin the player on
      // a source that can never load.
      expect(
        await AssetUrl.videoSourceCandidates(
          'https://shdw-drive.genesysgo.net/xyz/video.mp4',
        ),
        isEmpty,
      );
      expect(await AssetUrl.videoSourceCandidates(''), isEmpty);
    });

    test('a playback id leads, the originals stay behind it', () async {
      // Inline playback asks for the transcode: an adaptive HLS stream starts
      // in a fraction of the time and none of the bytes of a multi-megabyte
      // gateway original, which is what every detail-screen open used to cost.
      // The originals must survive behind it, or a Mux outage takes playback
      // down with it.
      final result = await AssetUrl.videoSourceCandidates(
        'https://arweave.net/abc123',
        chain: 'solana',
        playbackId: 'pb123',
      );
      expect(result, [
        'https://stream.mux.com/pb123.m3u8',
        'https://images.example.com/original/https%3A%2F%2Farweave.net%2Fabc123',
        'https://arweave.net/abc123',
        'https://arweave.example.com/abc123',
      ]);
    });

    test('a transcode plays even when the original never can', () async {
      // The shdw-drive blacklist is a verdict on that host, not on the bytes.
      // Mux holds its own copy, so refusing to play here would blank an artwork
      // that the cards happily animate.
      expect(
        await AssetUrl.videoSourceCandidates(
          'https://shdw-drive.genesysgo.net/xyz/video.mp4',
          playbackId: 'pb123',
        ),
        ['https://stream.mux.com/pb123.m3u8'],
      );
    });

    test('a blank playback id is not a transcode', () async {
      // The wire field is absent until Mux reports `ready`, but an empty or
      // whitespace string must not become `stream.mux.com/.m3u8` at the head of
      // the ladder — that 404s, and every real source waits behind it.
      final blank = await AssetUrl.videoSourceCandidates(
        'https://arweave.net/abc123',
        playbackId: '   ',
      );
      final none = await AssetUrl.videoSourceCandidates(
        'https://arweave.net/abc123',
      );
      expect(blank, none);
    });
  });
}
