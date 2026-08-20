import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/mint/data/ipfs_uploader.dart';
import 'package:mallow_wallet/features/mint/data/mint_repository.dart';
import 'package:mallow_wallet/features/mint/models/picked_mint_asset.dart';
import 'package:mockito/annotations.dart';

import 'mint_metadata_uri_test.mocks.dart';

/// Every URL this app writes into an NFT — the `image`, the `animation_url`,
/// the entries in `files[]`, and the metadata `uri` itself — is produced by
/// `IpfsUploader.gatewayUrl`, and lands somewhere immutable: inside the
/// metadata JSON pinned to IPFS, and on-chain as the token's `uri`. Every
/// marketplace and wallet that ever reads the token resolves those strings, so
/// a wrong host is not a bug that can be fixed by the next deploy — it is
/// wrong for the life of the token.
///
/// The app used to write its deployment's own gateway there, which the web
/// client never did (`toIpfsUri` → `https://ipfs.io/ipfs/<hash>`). Same
/// artwork, two URLs, depending on which client minted it.
///
/// Mint, edit-NFT, mint-collection and edit-collection are one bloc and one
/// repository, so all four reach the chain through the two methods below.
/// These tests pin both, with a first-party host configured, so no future
/// variable or default can reintroduce a deployment-specific gateway.
@GenerateMocks([MallowApiClient, MallowApiV2Client])
void main() {
  const cid = 'QmSimulatedMetadataPlaceholder0000000000000000';

  late _StubAdapter adapter;
  late MintRepository repository;

  setUp(() {
    // A first-party pinner IS configured. The uploaded bytes go there; only
    // the URL written into the token must not name it.
    Config.debugOverrides['IPFS_UPLOAD_URL'] = 'https://pin.example.com';
    adapter = _StubAdapter(cid);
    repository = MintRepository(
      MockMallowApiClient(),
      MockMallowApiV2Client(),
      IpfsUploader.forTest(Dio()..httpClientAdapter = adapter),
    );
  });

  tearDown(Config.debugOverrides.clear);

  test('an uploaded asset is tagged with an ipfs.io URL', () async {
    // Covers the main image, thumbnail, process video and banner slots — the
    // bloc calls this once per picked file, for NFTs and collections alike.
    final result = await repository.uploadAsset(
      PickedMintAsset(
        fileName: 'a.png',
        mimeType: 'image/png',
        sizeBytes: 3,
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
    );

    expect(result.ipfsHash, cid);
    expect(result.ipfsUrl, 'https://ipfs.io/ipfs/$cid');
  });

  test('the metadata uri is an ipfs.io URL', () async {
    // This is the string that goes on-chain as the token's `uri`.
    expect(
      await repository.uploadMetadata({'name': 'x'}),
      'https://ipfs.io/ipfs/$cid',
    );
  });

  test('the pinner host never leaks into the written URL', () async {
    final uri = await repository.uploadMetadata({'name': 'x'});

    // The bytes really did go to the configured first-party pinner — without
    // this the test would also pass against an uploader that posts nowhere.
    expect(adapter.lastUrl, startsWith('https://pin.example.com'));
    // ...and the URL handed to the chain still does not name it.
    expect(uri, isNot(contains('pin.example.com')));
  });

  test('no build variable can redirect the written URL', () async {
    // The nearest-miss regression: reintroducing a gateway variable and
    // letting it feed this path. Setting every host the app knows about must
    // leave the minted URL untouched.
    Config.debugOverrides.addAll({
      'IPFS_GATEWAY_URL': 'https://ipfs.example.com',
      'IMAGE_CDN_BASE_URL': 'https://images.example.com',
      'IPFS_PIN_GATEWAY_URL': 'https://pin-gw.example.com',
    });

    expect(
      await repository.uploadMetadata({'name': 'x'}),
      'https://ipfs.io/ipfs/$cid',
    );
  });
}

/// Answers every upload with the same CID, and records where it was sent.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.cid);

  final String cid;
  String? lastUrl;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastUrl = options.uri.toString();
    return ResponseBody.fromString(
      jsonEncode({'hash': cid}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
