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
);

void main() {
  group('isSecondaryMarketOf - token-metadata (Nft/pNFT/cNFT)', () {
    for (final standard in [
      TokenStandard.nft,
      TokenStandard.pnft,
      TokenStandard.cnft,
    ]) {
      test('$standard keys off primarySaleHappened', () {
        expect(
          isSecondaryMarketOf(_asset(standard: standard)),
          isFalse,
          reason: 'no primary sale yet (default false) → primary market',
        );
        expect(
          isSecondaryMarketOf(
            _asset(standard: standard, primarySaleHappened: true),
          ),
          isTrue,
          reason: 'primary sale happened → secondary market',
        );
      });
    }
  });

  group('isSecondaryMarketOf - Core', () {
    test('no collection: owner == updateAuthority → primary', () {
      expect(
        isSecondaryMarketOf(
          _asset(
            standard: TokenStandard.core,
            owner: _updateAuth,
            updateAuthority: _updateAuth,
          ),
        ),
        isFalse,
      );
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
          _asset(standard: TokenStandard.core, owner: _updateAuth),
          collection: collection,
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
