import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/metadata_host.dart';

/// Covers the [classifyMetadataHost] branches that drive the artwork /
/// collection "metadata host" detail row. Edge cases here matter because
/// the URL space is wide (custom protocols, gateway domains, signed S3
/// URLs) and a misclassification surfaces visibly to the user.
void main() {
  group('classifyMetadataHost — null/empty inputs', () {
    test('null URL returns null', () {
      expect(classifyMetadataHost(null), isNull);
    });

    test('empty string returns null', () {
      expect(classifyMetadataHost(''), isNull);
    });

    test('whitespace-only string returns null', () {
      expect(classifyMetadataHost('   '), isNull);
    });
  });

  group('classifyMetadataHost — custom protocols', () {
    test('ipfs:// scheme classifies as IPFS', () {
      expect(classifyMetadataHost('ipfs://QmHashHashHash'), metadataHostIpfs);
    });

    test('ipns:// scheme classifies as IPFS', () {
      expect(classifyMetadataHost('ipns://example.eth'), metadataHostIpfs);
    });

    test('ar:// scheme classifies as Arweave', () {
      expect(classifyMetadataHost('ar://abc123'), metadataHostArweave);
    });

    test('protocol matching is case-insensitive', () {
      expect(classifyMetadataHost('IPFS://abc'), metadataHostIpfs);
      expect(classifyMetadataHost('Ar://abc'), metadataHostArweave);
    });

    test('leading/trailing whitespace is stripped before classification', () {
      expect(classifyMetadataHost('  ipfs://abc  '), metadataHostIpfs);
    });
  });

  group('classifyMetadataHost — Arweave hosts', () {
    test('arweave.net host classifies as Arweave', () {
      expect(
        classifyMetadataHost('https://arweave.net/abc'),
        metadataHostArweave,
      );
    });

    test('subdomain of arweave.net classifies as Arweave', () {
      expect(
        classifyMetadataHost('https://abc.arweave.net/'),
        metadataHostArweave,
      );
    });
  });

  group('classifyMetadataHost — Irys hosts', () {
    test('gateway.irys.xyz classifies as Irys', () {
      expect(
        classifyMetadataHost('https://gateway.irys.xyz/abc123'),
        metadataHostIrys,
      );
    });

    test('bare irys.xyz classifies as Irys', () {
      expect(classifyMetadataHost('https://irys.xyz/abc123'), metadataHostIrys);
    });

    test('devnet.irys.xyz classifies as Irys', () {
      expect(
        classifyMetadataHost('https://devnet.irys.xyz/abc123'),
        metadataHostIrys,
      );
    });

    // Irys settles on Arweave, but the row should name Irys — not collapse
    // into the Arweave bucket and not fall through to the bare domain.
    test('Irys is not reported as Arweave or a bare domain', () {
      final label = classifyMetadataHost('https://uploader.irys.xyz/tx/abc');
      expect(label, isNot(metadataHostArweave));
      expect(label, isNot('irys.xyz'));
      expect(label, metadataHostIrys);
    });

    test(
      'a lookalike host that merely ends in irys.xyz-like text is not Irys',
      () {
        expect(classifyMetadataHost('https://notirys.xyz/abc'), 'notirys.xyz');
      },
    );
  });

  group('classifyMetadataHost — Shdw-drive hosts', () {
    test('shdw-drive.genesysgo.net classifies as Shdw-drive', () {
      expect(
        classifyMetadataHost(
          'https://shdw-drive.genesysgo.net/something/meta.json',
        ),
        metadataHostShdwDrive,
      );
    });

    test('any host containing shdw-drive classifies as Shdw-drive', () {
      expect(
        classifyMetadataHost('https://my.shdw-drive.example/x'),
        metadataHostShdwDrive,
      );
    });
  });

  group('classifyMetadataHost — IPFS gateways', () {
    test('canonical ipfs.io classifies as IPFS', () {
      expect(
        classifyMetadataHost('https://ipfs.io/ipfs/Qm123/meta.json'),
        metadataHostIpfs,
      );
    });

    test('Pinata public gateway classifies as IPFS', () {
      expect(
        classifyMetadataHost('https://gateway.pinata.cloud/ipfs/Qm123'),
        metadataHostIpfs,
      );
    });

    test('dedicated *.mypinata.cloud subdomain classifies as IPFS', () {
      expect(
        classifyMetadataHost('https://my-app.mypinata.cloud/ipfs/Qm123'),
        metadataHostIpfs,
      );
    });

    test('NFT.Storage and web3.storage gateways classify as IPFS', () {
      expect(
        classifyMetadataHost('https://nftstorage.link/ipfs/Qm123'),
        metadataHostIpfs,
      );
      expect(
        classifyMetadataHost('https://Qm123.ipfs.nftstorage.link/'),
        metadataHostIpfs,
      );
      expect(
        classifyMetadataHost('https://Qm123.ipfs.w3s.link/'),
        metadataHostIpfs,
      );
    });

    test('dweb.link path-based and subdomain forms both classify as IPFS', () {
      expect(
        classifyMetadataHost('https://dweb.link/ipfs/Qm123'),
        metadataHostIpfs,
      );
      expect(
        classifyMetadataHost('https://Qm123.ipfs.dweb.link/'),
        metadataHostIpfs,
      );
    });

    test('Cloudflare and 4everland and Fleek gateways classify as IPFS', () {
      expect(
        classifyMetadataHost('https://cloudflare-ipfs.com/ipfs/Qm123'),
        metadataHostIpfs,
      );
      expect(
        classifyMetadataHost('https://4everland.io/ipfs/Qm123'),
        metadataHostIpfs,
      );
      expect(
        classifyMetadataHost('https://ipfs.fleek.co/ipfs/Qm123'),
        metadataHostIpfs,
      );
    });

    test('unknown host with /ipfs/ path segment still classifies as IPFS', () {
      expect(
        classifyMetadataHost('https://some-random-gateway.example/ipfs/Qm123'),
        metadataHostIpfs,
      );
    });
  });

  group('classifyMetadataHost — S3 hosts', () {
    test('virtual-hosted bucket on amazonaws.com classifies as S3', () {
      expect(
        classifyMetadataHost(
          'https://my-bucket.s3.us-east-1.amazonaws.com/meta.json',
        ),
        metadataHostS3,
      );
    });

    test('dualstack S3 endpoint classifies as S3', () {
      expect(
        classifyMetadataHost('https://bucket.s3.dualstack/us-east-1/meta.json'),
        metadataHostS3,
      );
    });
  });

  group('classifyMetadataHost — fallback to bare domain', () {
    test('unrecognised host returns the bare domain', () {
      expect(
        classifyMetadataHost('https://example.com/meta.json'),
        'example.com',
      );
    });

    test('strips a leading www. from the domain', () {
      expect(
        classifyMetadataHost('https://www.example.com/meta.json'),
        'example.com',
      );
    });

    test('keeps subdomains other than www', () {
      expect(
        classifyMetadataHost('https://api.example.com/meta.json'),
        'api.example.com',
      );
    });

    test('host is lowercased', () {
      expect(
        classifyMetadataHost('https://EXAMPLE.com/meta.json'),
        'example.com',
      );
    });
  });

  group('classifyMetadataHost — malformed inputs', () {
    test(
      'string without a parseable URL still returns null when host empty',
      () {
        // `Uri.parse` accepts almost anything; a bare token with no scheme has
        // an empty host, which the classifier treats as null.
        expect(classifyMetadataHost('not a url'), isNull);
        expect(classifyMetadataHost('justtext'), isNull);
      },
    );
  });
}
