import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/utils/image_fallback.dart';

/// Stub CDN: answers a HEAD probe with a fixed status, or throws to simulate
/// images.example.com being unreachable. Records the probed URL so the tests can
/// assert we probe the *failing* URL rather than the raw source.
///
/// [redirectedTo] replays what the real adapter does after following
/// `/original/`'s 307 miss-redirect: the status came from *that* host, which is
/// the difference between a mallow verdict and a broken gateway.
class _StubCdnAdapter implements HttpClientAdapter {
  _StubCdnAdapter.status(this.statusCode, {this.redirectedTo})
    : unreachable = false;
  _StubCdnAdapter.unreachable()
    : statusCode = 0,
      redirectedTo = null,
      unreachable = true;

  final int statusCode;
  final String? redirectedTo;
  final bool unreachable;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (unreachable) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'images.example.com down',
      );
    }
    final body = ResponseBody.fromString('', statusCode);
    final location = redirectedTo;
    if (location != null) {
      body.redirects = [RedirectRecord(307, 'HEAD', Uri.parse(location))];
    }
    return body;
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_StubCdnAdapter adapter) => Dio()..httpClientAdapter = adapter;

/// Once every asset in the app is fetched through one domain, that domain
/// failing would black out every image — so a failed load may retry against the
/// asset's own gateway. But the fallback target is *mallow's own* mirror
/// (`ipfs.example.com` / `arweave.example.com`), so an unchecked swap would serve
/// takedown-blacklisted bytes off mallow infrastructure the moment the CDN
/// started answering 410. These tests pin the verdict table that makes the
/// difference: only "the service is broken" earns a retry — "this asset is
/// refused" never does.
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

  const rawIpfs =
      'ipfs://bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim/0.png';
  const failedCdnUrl =
      'https://images.example.com/original/'
      'ipfs%3A%2F%2Fbafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim%2F0.png';
  const directUrl =
      'https://ipfs.example.com/ipfs/'
      'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim/0.png';
  // Where the mirror order goes next when ipfs.example.com is the host that
  // just failed (AssetUrl.assetSourceCandidates' alternate IPFS gateway).
  const altGatewayUrl =
      'https://ipfs.io/ipfs/'
      'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim/0.png';
  // Same CID on a gateway mallow does not mirror. Canonicalisation is
  // host-agnostic, so this collapses to the same `ipfs://` form as [rawIpfs] —
  // and therefore to the same /original/ URL and the same [directUrl] mirror.
  const rawThirdPartyGateway =
      'https://nftstorage.link/ipfs/'
      'bafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim/0.png';

  group('service is degraded — retry allowed', () {
    test('an unreachable CDN falls back to the asset gateway', () async {
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.unreachable()),
        ),
        directUrl,
      );
    });

    test('5xx falls back to the asset gateway', () async {
      for (final status in [500, 502, 503, 504]) {
        expect(
          await ImageFallback.directUrlFor(
            rawIpfs,
            failedUrl: failedCdnUrl,
            client: _dioWith(_StubCdnAdapter.status(status)),
          ),
          directUrl,
          reason: '$status is a service failure, not a verdict on the asset',
        );
      }
    });

    test('the probe targets the failing CDN URL, not the raw source', () async {
      final adapter = _StubCdnAdapter.unreachable();
      await ImageFallback.directUrlFor(
        rawIpfs,
        failedUrl: failedCdnUrl,
        client: _dioWith(adapter),
      );
      expect(adapter.lastRequest?.uri.toString(), failedCdnUrl);
      expect(adapter.lastRequest?.method, 'HEAD');
    });

    test('an arweave asset falls back to its own arweave gateway', () async {
      const txid = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      expect(
        await ImageFallback.directUrlFor(
          'https://arweave.net/$txid',
          failedUrl: 'https://images.example.com/800x800/inside/whatever',
          client: _dioWith(_StubCdnAdapter.status(500)),
        ),
        'https://arweave.net/$txid',
      );
    });

    test('an ar:// source falls back to the mallow arweave mirror', () async {
      // No host of its own to prefer, so the mirror leads.
      const txid = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      expect(
        await ImageFallback.directUrlFor(
          'ar://$txid',
          failedUrl: 'https://images.example.com/800x800/inside/whatever',
          client: _dioWith(_StubCdnAdapter.status(500)),
        ),
        'https://arweave.example.com/$txid',
      );
    });
  });

  group('which gateway the one retry is spent on', () {
    // Only ipfs.io and ipfs.example.com are interchangeable to us. A CID on any
    // other gateway is not guaranteed to resolve on ipfs2 — ipfs2 has to find
    // the block on the network first — while the host written into the source
    // URL is the one that demonstrably held the bytes at mint time. Since a
    // surface gets exactly one retry, spending it on the mirror can blank an
    // image the original gateway would still have served.
    test('a third-party gateway is retried on its own host', () async {
      expect(
        await ImageFallback.directUrlFor(
          rawThirdPartyGateway,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.unreachable()),
        ),
        rawThirdPartyGateway,
      );
    });

    test('ipfs.io still hands off to the mallow gateway', () async {
      // The documented swap pair — ipfs.io is not the asset's own gateway in
      // any meaningful sense, it is the one ipfs.example.com stands in for.
      expect(
        await ImageFallback.directUrlFor(
          altGatewayUrl,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.status(503)),
        ),
        directUrl,
      );
    });

    test('an ipfs:// source still goes to the mirror', () async {
      // It names no host of its own, so there is nothing to prefer over ipfs2.
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.unreachable()),
        ),
        directUrl,
      );
    });

    test(
      'the mirror takes over when the source gateway is what failed',
      () async {
        // A 403 from nftstorage.link itself (the host /original/'s miss-redirect
        // landed on) rules out its own URL, so the mirror is the next best shot.
        expect(
          await ImageFallback.directUrlFor(
            rawThirdPartyGateway,
            failedUrl: failedCdnUrl,
            client: _dioWith(
              _StubCdnAdapter.status(403, redirectedTo: rawThirdPartyGateway),
            ),
          ),
          directUrl,
        );
      },
    );
  });

  group('the redirect target answered, not mallow — retry allowed', () {
    // `/original/` 307s a miss to a third-party gateway. A 4xx from *that* host
    // is a statement about the gateway, not a mallow verdict — treating it as
    // final would let one flaky gateway blank an image the mirrors still serve.
    test('a 404 from the gateway the 307 landed on still falls back', () async {
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(
            _StubCdnAdapter.status(404, redirectedTo: altGatewayUrl),
          ),
        ),
        directUrl,
      );
    });

    test('a failed resize retries via /original/, not a gateway', () async {
      // Our CDN is up (a downstream gateway answered), so the R2-cached
      // original is the fastest thing left to try — and it can serve bytes the
      // live gateway just failed to. Only when images.example.com itself is the
      // broken party is `/original/` pointless, since it lives on that host.
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl:
              'https://images.example.com/350x350/cover/'
              'ipfs%3A%2F%2Fbafybeib7vqkbjwlsffypzczrr6t6lcjcvjyy7iuhjj4mxgz3plj7uoouim%2F0.png',
          client: _dioWith(
            _StubCdnAdapter.status(404, redirectedTo: altGatewayUrl),
          ),
        ),
        failedCdnUrl,
      );
    });

    test('a 403 skips the gateway that just refused us', () async {
      // The preferred mirror IS the host that answered, so retrying it would
      // refetch the exact 403 — the mirror order's next gateway takes over.
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(
            _StubCdnAdapter.status(403, redirectedTo: directUrl),
          ),
        ),
        altGatewayUrl,
      );
    });

    test('a 5xx from the redirect target skips that host too', () async {
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(
            _StubCdnAdapter.status(502, redirectedTo: directUrl),
          ),
        ),
        altGatewayUrl,
      );
    });

    test('a 2xx after the redirect is still a healthy fetch — no retry', () {
      expect(
        ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(
            _StubCdnAdapter.status(200, redirectedTo: altGatewayUrl),
          ),
        ),
        completion(isNull),
      );
    });
  });

  group('mallow refused the asset — retry forbidden', () {
    test('410 (takedown) renders the placeholder, never the mirror', () async {
      // The load-bearing case: the direct URL is mallow's own gateway, so
      // falling back past a takedown would keep serving blacklisted bytes from
      // mallow infrastructure.
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.status(410)),
        ),
        isNull,
      );
    });

    test('every other 4xx from the CDN itself is final too', () async {
      for (final status in [400, 401, 403, 404, 429]) {
        expect(
          await ImageFallback.directUrlFor(
            rawIpfs,
            failedUrl: failedCdnUrl,
            client: _dioWith(_StubCdnAdapter.status(status)),
          ),
          isNull,
          reason: '$status is a verdict on the asset — do not route around it',
        );
      }
    });

    test('a 410 stays final even for a relative Location header', () async {
      // An adapter can record a same-origin redirect with a host-less URI; that
      // is still our origin, so the verdict is still ours to honour.
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(
            _StubCdnAdapter.status(410, redirectedTo: '/original/blacklisted'),
          ),
        ),
        isNull,
      );
    });

    test('a healthy CDN means the failure was local (decode) — no retry', () {
      // Refetching identical bytes from another host cannot fix a decode error,
      // and would waste a full-size download on every corrupt image.
      expect(
        ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.status(200)),
        ),
        completion(isNull),
      );
    });
  });

  group('nothing to fall back to', () {
    test('a non-CDN failure is left alone (no probe at all)', () async {
      final adapter = _StubCdnAdapter.unreachable();
      expect(
        await ImageFallback.directUrlFor(
          rawIpfs,
          failedUrl: 'https://ipfs.example.com/ipfs/whatever.png',
          client: _dioWith(adapter),
        ),
        isNull,
      );
      expect(adapter.lastRequest, isNull);
    });

    test('an empty source URL is a no-op', () async {
      expect(
        await ImageFallback.directUrlFor(
          '',
          failedUrl: failedCdnUrl,
          client: _dioWith(_StubCdnAdapter.unreachable()),
        ),
        isNull,
      );
    });

    test('an https asset already fetched verbatim has nowhere to go', () async {
      // toDirectUrl returns https URLs unchanged, so if that IS the failing URL
      // the "fallback" would refetch the exact same thing forever.
      const url = 'https://images.example.com/original/x';
      expect(
        await ImageFallback.directUrlFor(
          url,
          failedUrl: url,
          client: _dioWith(_StubCdnAdapter.unreachable()),
        ),
        isNull,
      );
    });
  });
}
