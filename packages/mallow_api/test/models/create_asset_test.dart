import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('TokenStandard wire values', () {
    // Lock down the wire format. The backend routes account fetchers off
    // these strings (`core` -> safeFetchAssetV1, `core-collection` ->
    // safeFetchCollectionV1), so silently renaming a value here causes
    // UnexpectedAccountError on the server.
    const expected = {
      TokenStandard.nft: 'nft',
      TokenStandard.core: 'core',
      TokenStandard.coreCollection: 'core-collection',
      TokenStandard.pnft: 'pnft',
      TokenStandard.cnft: 'cnft',
      TokenStandard.objkt: 'objkt',
      TokenStandard.native: 'native',
      TokenStandard.erc20: 'erc20',
      TokenStandard.erc721: 'erc721',
      TokenStandard.erc1155: 'erc1155',
    };

    test('every variant has a pinned wire value', () {
      expect(
        expected.keys.toSet(),
        TokenStandard.values.toSet(),
        reason: 'Add the new TokenStandard variant to the expected map.',
      );
    });

    for (final entry in expected.entries) {
      test('${entry.key.name} serializes to "${entry.value}"', () {
        final ref = MintCollectionRef(mintAccount: 'X', tokenStandard: entry.key);
        expect(ref.toJson()['tokenStandard'], entry.value);
      });
    }
  });

  group('MintNftV2Request wire payload', () {
    // Representative payload mirroring the failing mint that motivated
    // this test: a 1/1 Core asset minted into a Core *Collection*. The
    // collection mint is a CollectionV1 account on chain, so its
    // tokenStandard MUST serialize as `core-collection`. Sending `core`
    // makes the backend call safeFetchAssetV1 on a CollectionV1 account
    // and fail with EnumDiscriminatorOutOfRangeError. The backend wire is
    // camelCase (`#[serde(rename_all = "camelCase")]` on the v2 request types).
    Map<String, dynamic> wireBytesOf(MintNftV2Request request) =>
        jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>;

    test('1/1 mint into a Core collection serializes correctly', () {
      final request = MintNftV2Request(
        authority: 'CrEaToR11111111111111111111111111111111111',
        asset: 'HTQAEC3jPVNtaPxRPbJGwdwRkpUGSGp4qaTEfg2JSyWB',
        uri: 'https://ipfs.example/QmAsset',
        nftMetadata: const EditNftV2Metadata(
          name: 'Test',
          sellerFeeBasisPoints: 500,
          creators: [
            EditNftV2Creator(address: 'GaDTz1tYDaXVQy9iA3xLKB9e9RP13UkzQXqetBxJPaos', share: 100),
          ],
        ),
        kind: MintNftV2Kind.coreAsset,
        createType: '1/1',
        collection: const EditNftV2CollectionRef(
          asset: 'UocgK2rxA2Ga3xZvphfSzc5VocT5hrbmkrSjBwUYF2D',
          tokenStandard: TokenStandard.coreCollection,
        ),
      );

      final json = wireBytesOf(request);

      // The `kind` discriminator replaces the v1 top-level tokenStandard.
      expect(json['kind'], 'core_asset');
      expect(json['createType'], '1/1');
      expect(json['paymentMethod'], 'Solana');
      // The signer is sent explicitly — the backend no longer derives it from
      // the login cookie. The contract names it `authority` (was `creator`),
      // and the new asset address `asset` (was `mintAccount`).
      expect(json['authority'], 'CrEaToR11111111111111111111111111111111111');
      expect(json['asset'], 'HTQAEC3jPVNtaPxRPbJGwdwRkpUGSGp4qaTEfg2JSyWB');
      expect(json.containsKey('creator'), isFalse);
      expect(json.containsKey('mintAccount'), isFalse);

      final collection = json['collection'] as Map<String, dynamic>;
      expect(collection['asset'], 'UocgK2rxA2Ga3xZvphfSzc5VocT5hrbmkrSjBwUYF2D');
      // Regression guard for the bug fixed in collection_picker_sheet.dart.
      expect(collection['tokenStandard'], 'core-collection');
    });

    test('omitted collection is absent from the body', () {
      final request = MintNftV2Request(
        authority: 'CrEaToR11111111111111111111111111111111111',
        asset: 'MINT',
        uri: 'https://ipfs.example/QmAsset',
        nftMetadata: const EditNftV2Metadata(name: 'Standalone'),
        kind: MintNftV2Kind.coreAsset,
        createType: '1/1',
      );

      final json = wireBytesOf(request);

      // v2 omits null optionals (`includeIfNull: false`) rather than
      // sending an explicit null.
      expect(json.containsKey('collection'), isFalse);
    });

    // `dry_run` is what stops a cost estimate from claiming the group-rent
    // subsidy slot, persisting an `NftUpload` row, and being auth-signed —
    // the mint route gates all three on it. If it stops reaching the
    // wire, every abandoned confirm sheet burns the subsidy and the real
    // mint that follows is charged user-pays.
    test('dryRun reaches the wire and defaults to false', () {
      MintNftV2Request build({required bool dryRun}) => MintNftV2Request(
        authority: 'CrEaToR11111111111111111111111111111111111',
        asset: 'MINT',
        uri: 'https://ipfs.example/QmAsset',
        nftMetadata: const EditNftV2Metadata(name: 'Standalone'),
        kind: MintNftV2Kind.coreAsset,
        createType: '1/1',
        dryRun: dryRun,
      );

      expect(wireBytesOf(build(dryRun: true))['dryRun'], isTrue);
      expect(wireBytesOf(build(dryRun: false))['dryRun'], isFalse);
      expect(
        MintNftV2Request(
          authority: 'A',
          asset: 'MINT',
          uri: 'u',
          nftMetadata: const EditNftV2Metadata(name: 'n'),
          kind: MintNftV2Kind.coreAsset,
          createType: '1/1',
        ).dryRun,
        isFalse,
        reason: 'a request built without stating intent must not be a dry run',
      );
    });
  });

  group('EditNftV2Request collection tri-state', () {
    // The backend types `collection` as `Option<Option<..>>` and reads the
    // three states differently: absent =
    // leave membership untouched, explicit null = detach a Master Edition
    // from its mpl-core group, object = assign. Collapsing detach into
    // "absent" is what made a cleared parent collection a paid no-op.
    EditNftV2Request build(EditNftV2CollectionUpdate? collection) => EditNftV2Request(
      authority: 'AuThOrItY',
      asset: 'MASTER_EDITION',
      uri: 'https://ipfs.example/QmMeta',
      nftMetadata: const EditNftV2Metadata(name: 'ME'),
      tokenStandard: TokenStandard.coreCollection,
      collection: collection,
    );

    // Retrofit hands the request object straight to Dio, which encodes it
    // with `jsonEncode` — so assert on the encoded string, not on the
    // intermediate `toJson()` map.
    Map<String, dynamic> wireBytesOf(EditNftV2Request request) =>
        jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

    test('absent collection omits the key ("leave membership untouched")', () {
      expect(wireBytesOf(build(null)).containsKey('collection'), isFalse);
    });

    test('detach sends an explicit null, not an omitted key', () {
      final json = wireBytesOf(build(const EditNftV2CollectionUpdate.detach()));
      expect(json.containsKey('collection'), isTrue);
      expect(json['collection'], isNull);
    });

    test('assign sends the collection ref', () {
      final json = wireBytesOf(
        build(
          const EditNftV2CollectionUpdate.assign(
            EditNftV2CollectionRef(asset: 'PARENT', tokenStandard: TokenStandard.coreCollection),
          ),
        ),
      );
      expect(json['collection'], {'asset': 'PARENT', 'tokenStandard': 'core-collection'});
    });

    test('re-parent fields and dryRun reach the wire', () {
      final json = wireBytesOf(
        EditNftV2Request(
          authority: 'AuThOrItY',
          asset: 'MASTER_EDITION',
          uri: 'https://ipfs.example/QmMeta',
          nftMetadata: const EditNftV2Metadata(name: 'ME'),
          tokenStandard: TokenStandard.coreCollection,
          newParentCollection: 'NEW_PARENT',
          newGroupSigner: 'NEW_GROUP_SIGNER',
          dryRun: true,
        ),
      );
      expect(json['newParentCollection'], 'NEW_PARENT');
      expect(json['newGroupSigner'], 'NEW_GROUP_SIGNER');
      expect(json['dryRun'], isTrue);
    });
  });
}
