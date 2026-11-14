import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/sale/services/direct_proceeds.dart';

// The single source of truth for the "Direct all proceeds to creators" gate.
// It mirrors webapp `isSecondaryMarket` (on its asset model),
// `showDirectProceedsOption` (ProceedsInfo), and `getRoyalties`
// (umi). A regression here silently mispays a listing: a resold NFT
// wrongly gets primary-branch fees + the toggle, or a genuine primary hides
// the option and routes the whole remainder to the seller.

const _owner = 'owner11111111111111111111111111111111111111';
const _updateAuth = 'ua1111111111111111111111111111111111111111';
const _seller = 'seller11111111111111111111111111111111111111';

DigitalAsset _asset({
  required TokenStandard standard,
  bool primarySaleHappened = false,
  String? owner,
  String? updateAuthority,
  String? collectionKey,
  int? royaltiesPluginBasisPoints,
  List<OnChainCreator> royaltiesPluginCreators = const [],
  int? sellerFeeBasisPoints,
  List<OnChainCreator> tokenMetadataCreators = const [],
  List<String> verifiedCreators = const [],
}) => DigitalAsset(
  id: 'mint',
  tokenStandard: standard,
  isMutable: true,
  frozen: false,
  supply: 0,
  freezeDelegateFrozen: false,
  permanentFreezeDelegateFrozen: false,
  hasMasterEditionPlugin: false,
  owner: owner,
  updateAuthority: updateAuthority,
  collectionKey: collectionKey,
  primarySaleHappened: primarySaleHappened,
  royaltiesPluginBasisPoints: royaltiesPluginBasisPoints,
  royaltiesPluginCreators: royaltiesPluginCreators,
  sellerFeeBasisPoints: sellerFeeBasisPoints,
  tokenMetadataCreators: tokenMetadataCreators,
  verifiedCreators: verifiedCreators,
);

void main() {
  test(
    'v2 trades are secondary even before the leaf primary-sale flag is set',
    () {
      expect(
        isSecondaryMarketOf(_asset(standard: TokenStandard.cnftV2)),
        isTrue,
      );
    },
  );
  group('Bubblegum v2 royalty inheritance', () {
    const leafCreator = OnChainCreator(
      address: 'leafCreator',
      share: 100,
      verified: true,
    );
    const collectionCreator = OnChainCreator(
      address: 'collectionCreator',
      share: 100,
      verified: true,
    );
    final collection = _asset(
      standard: TokenStandard.coreCollection,
      royaltiesPluginBasisPoints: 750,
      royaltiesPluginCreators: [collectionCreator],
    );
    for (final bps in [500, 65535]) {
      for (final creators in [
        <OnChainCreator>[],
        [leafCreator],
      ]) {
        test(
          'bps $bps and ${creators.length} leaf creators choose the authenticated source',
          () {
            final asset = _asset(
              standard: TokenStandard.cnftV2,
              collectionKey: 'mint',
              sellerFeeBasisPoints: bps,
              tokenMetadataCreators: creators,
            );
            final royalties = resolveOnChainRoyalties(
              asset,
              collection: collection,
            );
            final useLeaf = bps != 65535 && creators.isNotEmpty;
            expect(royalties.royaltyBps, useLeaf ? 500 : 750);
            expect(
              royalties.shares.single.address,
              useLeaf ? 'leafCreator' : 'collectionCreator',
            );
          },
        );
      }
    }
    for (final standard in [TokenStandard.coreCollection, TokenStandard.nft]) {
      test(
        'mismatched collection or non-Core parent $standard resolves to zero',
        () {
          final result = resolveOnChainRoyalties(
            _asset(
              standard: TokenStandard.cnftV2,
              collectionKey: standard == TokenStandard.coreCollection
                  ? 'different'
                  : 'mint',
              sellerFeeBasisPoints: 65535,
              tokenMetadataCreators: [leafCreator],
            ),
            collection: _asset(
              standard: standard,
              royaltiesPluginBasisPoints: 750,
              royaltiesPluginCreators: [collectionCreator],
            ),
          );
          expect(result.royaltyBps, 0);
          expect(result.shares, isEmpty);
        },
      );
    }
    test('sentinel with no collection resolves to zero', () {
      final royalties = resolveOnChainRoyalties(
        _asset(
          standard: TokenStandard.cnftV2,
          sellerFeeBasisPoints: 65535,
          tokenMetadataCreators: [leafCreator],
        ),
      );
      expect(royalties.royaltyBps, 0);
      expect(royalties.shares, isEmpty);
    });
  });

  group('isSecondaryMarketOf - token-metadata Nft', () {
    test('nft keys off primarySaleHappened', () {
      expect(
        isSecondaryMarketOf(_asset(standard: TokenStandard.nft)),
        isFalse,
        reason: 'no primary sale yet (default false) → primary market',
      );
      expect(
        isSecondaryMarketOf(
          _asset(standard: TokenStandard.nft, primarySaleHappened: true),
        ),
        isTrue,
        reason: 'primary sale happened → secondary market',
      );
    });
  });

  // Token Metadata cannot flip primarySaleHappened on a pNFT, so the programs
  // settle every pNFT sale as secondary whatever the flag says.
  test('isSecondaryMarketOf - pNFT is always secondary', () {
    expect(isSecondaryMarketOf(_asset(standard: TokenStandard.pnft)), isTrue);
    expect(
      isSecondaryMarketOf(
        _asset(standard: TokenStandard.pnft, primarySaleHappened: true),
      ),
      isTrue,
    );
  });

  // The marketplace program charges every compressed sale the secondary fee,
  // and DAS reports `primarySaleHappened: false` for every leaf.
  group('isSecondaryMarketOf - cNFT', () {
    for (final standard in [TokenStandard.cnft, TokenStandard.cnftV2]) {
      test('$standard is always secondary', () {
        expect(isSecondaryMarketOf(_asset(standard: standard)), isTrue);
        expect(
          isSecondaryMarketOf(
            _asset(standard: standard, primarySaleHappened: true),
          ),
          isTrue,
        );
      });
    }
  });

  group('isSecondaryMarketOf - Core', () {
    test('no collection: signed owner == updateAuthority → primary', () {
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _updateAuth,
            updateAuthority: _updateAuth,
            verifiedCreators: const [_updateAuth],
          ),
        ),
        isFalse,
      );
    });

    // The program charges this the secondary fee.
    test('an authority that owns it but never signed → secondary', () {
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _updateAuth,
            updateAuthority: _updateAuth,
          ),
        ),
        isTrue,
      );
    });

    test('reads the signature from the DAS plugin, verified only', () {
      DigitalAsset parsed(bool verified) => DigitalAsset.fromJson({
        'id': 'mint',
        'interface': 'MplCoreAsset',
        'mutable': true,
        'ownership': {'owner': _updateAuth, 'frozen': false},
        'authorities': [
          {
            'address': _updateAuth,
            'scopes': ['full'],
          },
        ],
        'plugins': {
          'verified_creators': {
            'data': {
              'signatures': [
                {'address': _updateAuth, 'verified': verified},
              ],
            },
          },
        },
      });

      expect(parsed(true).verifiedCreators, [_updateAuth]);
      expect(parsed(false).verifiedCreators, isEmpty);
      expect(isSecondaryMarketOf(parsed(true)), isFalse);
      expect(isSecondaryMarketOf(parsed(false)), isTrue);
    });

    test('no collection: owner != updateAuthority → secondary', () {
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _owner,
            updateAuthority: _updateAuth,
          ),
        ),
        isTrue,
      );
    });

    test('with collection: classifies off collection update authority', () {
      final collection = _asset(
        standard: TokenStandard.coreCollection,
        updateAuthority: _updateAuth,
      );
      // Owner is the collection UA → still the creator's hands → primary.
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _updateAuth,
            verifiedCreators: const [_updateAuth],
          ),
          collection: collection,
        ),
        isFalse,
      );
      // The signature can sit on the collection instead.
      expect(
        isSecondaryMarketOf(
          _asset(standard: TokenStandard.core, owner: _updateAuth),
          collection: _asset(
            standard: TokenStandard.coreCollection,
            updateAuthority: _updateAuth,
            verifiedCreators: const [_updateAuth],
          ),
        ),
        isFalse,
      );
      // A collector owns it → secondary, even though the asset's own
      // updateAuthority field is unset.
      expect(
        isSecondaryMarketOf(
          _asset(standard: TokenStandard.core, owner: _owner),
          collection: collection,
        ),
        isTrue,
      );
    });
  });

  // The program reads a grouped asset's update authority from its collection
  // and counts a creator signature on the collection too. Without the
  // collection the asset alone cannot answer, and a guess shows the wrong fee.
  group('isSecondaryMarketOf - Core asset in a collection', () {
    const collectionKey = 'collection1111111111111111111111111111111';

    DigitalAsset collection({List<String> verifiedCreators = const []}) =>
        DigitalAsset(
          id: collectionKey,
          tokenStandard: TokenStandard.coreCollection,
          isMutable: true,
          frozen: false,
          supply: 0,
          freezeDelegateFrozen: false,
          permanentFreezeDelegateFrozen: false,
          hasMasterEditionPlugin: false,
          updateAuthority: _updateAuth,
          verifiedCreators: verifiedCreators,
        );

    // Held by its creator, whose only signature is on the collection.
    final asset = _asset(
      standard: TokenStandard.core,
      owner: _updateAuth,
      updateAuthority: _updateAuth,
      collectionKey: collectionKey,
    );

    test('collection read, its authority signed and owns it → primary', () {
      expect(
        isSecondaryMarketOf(
          asset,
          collection: collection(verifiedCreators: const [_updateAuth]),
        ),
        isFalse,
      );
    });

    test('collection read, a collector owns it → secondary', () {
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _owner,
            collectionKey: collectionKey,
          ),
          collection: collection(verifiedCreators: const [_updateAuth]),
        ),
        isTrue,
      );
    });

    test('collection read, nobody signed → secondary', () {
      expect(isSecondaryMarketOf(asset, collection: collection()), isTrue);
    });

    test('collection not read → unknown, whatever the asset says', () {
      expect(isSecondaryMarketOf(asset), isNull);
      // Even an asset that carries its own signature: the authority that has
      // to match it is the collection's, which was not read.
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _updateAuth,
            updateAuthority: _updateAuth,
            collectionKey: collectionKey,
            verifiedCreators: const [_updateAuth],
          ),
        ),
        isNull,
      );
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _owner,
            updateAuthority: _updateAuth,
            collectionKey: collectionKey,
          ),
        ),
        isNull,
      );
    });
  });

  test('isSecondaryMarketOf - CoreCollection is always primary', () {
    expect(
      isSecondaryMarketOf(
        _asset(standard: TokenStandard.coreCollection, owner: _owner),
      ),
      isFalse,
    );
  });

  group('showDirectProceedsOptionOf', () {
    const shares = [
      ArtworkRoyaltySplit(address: _updateAuth, sharePercent: 100),
    ];

    test('shown on a primary sale with a non-seller first creator', () {
      expect(
        showDirectProceedsOptionOf(
          isSecondary: false,
          seller: _seller,
          shares: shares,
        ),
        isTrue,
      );
    });

    test('hidden on a secondary sale', () {
      expect(
        showDirectProceedsOptionOf(
          isSecondary: true,
          seller: _seller,
          shares: shares,
        ),
        isFalse,
      );
    });

    test('hidden when the seller is the first creator', () {
      expect(
        showDirectProceedsOptionOf(
          isSecondary: false,
          seller: _seller,
          shares: const [
            ArtworkRoyaltySplit(address: _seller, sharePercent: 100),
          ],
        ),
        isFalse,
      );
    });

    test('hidden with no shares', () {
      expect(
        showDirectProceedsOptionOf(
          isSecondary: false,
          seller: _seller,
          shares: const [],
        ),
        isFalse,
      );
    });
  });

  group('resolveOnChainRoyalties', () {
    test('Core reads its own royalties plugin when present', () {
      final r = resolveOnChainRoyalties(
        _asset(
          standard: TokenStandard.core,
          royaltiesPluginBasisPoints: 500,
          royaltiesPluginCreators: const [
            OnChainCreator(address: 'c1', share: 60, verified: true),
            OnChainCreator(address: 'c2', share: 40, verified: false),
          ],
        ),
      );
      expect(r.royaltyBps, 500);
      expect(r.shares.map((s) => s.address), ['c1', 'c2']);
      expect(r.shares.map((s) => s.sharePercent), [60, 40]);
    });

    test('Core with no own plugin falls back to collection royalties', () {
      final collection = _asset(
        standard: TokenStandard.coreCollection,
        royaltiesPluginBasisPoints: 750,
        royaltiesPluginCreators: const [
          OnChainCreator(address: 'cc1', share: 100, verified: true),
        ],
      );
      final r = resolveOnChainRoyalties(
        _asset(standard: TokenStandard.core),
        collection: collection,
      );
      expect(r.royaltyBps, 750);
      expect(r.shares.single.address, 'cc1');
      expect(r.shares.single.sharePercent, 100);
    });

    test('Core with its own plugin ignores the collection fallback', () {
      final collection = _asset(
        standard: TokenStandard.coreCollection,
        royaltiesPluginBasisPoints: 750,
        royaltiesPluginCreators: const [
          OnChainCreator(address: 'cc1', share: 100, verified: true),
        ],
      );
      final r = resolveOnChainRoyalties(
        _asset(
          standard: TokenStandard.core,
          royaltiesPluginBasisPoints: 250,
          royaltiesPluginCreators: const [
            OnChainCreator(address: 'own', share: 100, verified: true),
          ],
        ),
        collection: collection,
      );
      expect(r.royaltyBps, 250);
      expect(r.shares.single.address, 'own');
    });

    test('token-metadata reads sellerFeeBasisPoints + creators', () {
      final r = resolveOnChainRoyalties(
        _asset(
          standard: TokenStandard.nft,
          sellerFeeBasisPoints: 1000,
          tokenMetadataCreators: const [
            OnChainCreator(address: 'a', share: 100, verified: true),
          ],
        ),
      );
      expect(r.royaltyBps, 1000);
      expect(r.shares.single.address, 'a');
    });

    test('CoreCollection reads its own plugin', () {
      final r = resolveOnChainRoyalties(
        _asset(
          standard: TokenStandard.coreCollection,
          royaltiesPluginBasisPoints: 300,
          royaltiesPluginCreators: const [
            OnChainCreator(address: 'x', share: 100, verified: true),
          ],
        ),
      );
      expect(r.royaltyBps, 300);
      expect(r.shares.single.address, 'x');
    });
  });
}
