import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/services/collection_download_service.dart';

/// A download fetches the artwork's *stored* image URL, which is not
/// necessarily fetchable: the API hands back whatever was minted, routinely an
/// `ipfs://` URI or an `arweave.net` link. Handing that straight to Dio is why
/// a one-artwork download reported "0/1 — 1 failed" instantly — an `ipfs://`
/// URI has no HTTP scheme, so the request never left the device, and the
/// failure was swallowed by a bare `catch`.
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

  PortfolioArtwork artwork(String imageUrl, {String? chain}) =>
      PortfolioArtwork(
        mintAccount: 'mint',
        title: 'Art',
        imageUrl: imageUrl,
        artistName: 'Artist',
        chain: chain,
      );

  group('CollectionDownloadService.sourceCandidates', () {
    test('never offers a raw ipfs:// URI — Dio cannot fetch one', () {
      const raw = 'ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';
      final candidates = CollectionDownloadService.sourceCandidates(
        artwork(raw),
      );

      expect(candidates, isNot(contains(raw)));
      expect(
        candidates.every((c) => c.startsWith('https://')),
        isTrue,
        reason: 'every candidate must be fetchable over HTTP',
      );
    });

    test('leads with the images service /original/ route', () {
      final candidates = CollectionDownloadService.sourceCandidates(
        artwork('ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG'),
      );

      expect(
        candidates.first,
        startsWith('https://images.example.com/original/'),
      );
    });

    test('falls back to the asset gateway ladder after /original/', () {
      final candidates = CollectionDownloadService.sourceCandidates(
        artwork('ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG'),
      );

      expect(candidates.length, greaterThan(1));
      expect(
        candidates.skip(1),
        contains(startsWith('https://ipfs.example.com/ipfs/')),
      );
    });

    test(
      'offers the mallow arweave mirror — arweave.net 403s some clients',
      () {
        const raw =
            'https://arweave.net/PVMFmz4XQCwvjabQZFHYnGeBQnGmruo2Kn1F6X7Fn3M';
        final candidates = CollectionDownloadService.sourceCandidates(
          artwork(raw),
        );

        expect(
          candidates,
          contains(startsWith('https://arweave.example.com/')),
        );
      },
    );

    test('does not repeat the /original/ URL in the ladder', () {
      final candidates = CollectionDownloadService.sourceCandidates(
        artwork('https://example.com/art.png'),
      );

      expect(candidates.toSet().length, candidates.length);
    });

    test('still offers /original/ for a source with no gateway ladder', () {
      // `shdw-drive` is a dead host, so the ladder is empty — R2 may still hold
      // the mint-time bytes, so the batch must not give up before trying.
      final candidates = CollectionDownloadService.sourceCandidates(
        artwork('https://shdw-drive.genesysgo.net/abc/art.png'),
      );

      expect(candidates, hasLength(1));
      expect(
        candidates.first,
        startsWith('https://images.example.com/original/'),
      );
    });
  });
}
