import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';

// DAS `getAsset` results drive permission gating (burn/transfer/edit/list)
// and live edition state. A misparse here either silently strips a delegate
// authority — letting the menu offer a destructive action that fails
// on-chain — or hides legitimate actions from owners. Both are user-visible
// regressions, so the parser is worth its own coverage.

void main() {
  group('DigitalAsset.fromJson - interface mapping', () {
    test('MplCoreAsset → TokenStandard.core', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreAsset',
      });
      expect(a.tokenStandard, TokenStandard.core);
    });

    test('MplCoreCollection → TokenStandard.coreCollection', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreCollection',
      });
      expect(a.tokenStandard, TokenStandard.coreCollection);
    });

    test('ProgrammableNFT → TokenStandard.pnft', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'ProgrammableNFT',
      });
      expect(a.tokenStandard, TokenStandard.pnft);
    });

    test('unknown interface defaults to TokenStandard.nft', () {
      final a = DigitalAsset.fromJson({'id': 'mint1', 'interface': 'V1_NFT'});
      expect(a.tokenStandard, TokenStandard.nft);
    });

    test('compressed asset overrides interface and becomes cnft', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'ProgrammableNFT',
        'compression': {'compressed': true},
      });
      expect(a.tokenStandard, TokenStandard.cnft);
    });

    test('compression.compressed=false keeps interface mapping', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreAsset',
        'compression': {'compressed': false},
      });
      expect(a.tokenStandard, TokenStandard.core);
    });
  });

  group('DigitalAsset.fromJson - authorities & ownership', () {
    test('picks the authority whose scopes contain "full"', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'authorities': [
          {
            'address': 'partial-1',
            'scopes': ['data'],
          },
          {
            'address': 'full-1',
            'scopes': ['data', 'full'],
          },
          {
            'address': 'full-2',
            'scopes': ['full'],
          },
        ],
      });
      // First "full"-scoped authority wins.
      expect(a.updateAuthority, 'full-1');
    });

    test('no full-scope authority leaves updateAuthority null', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'authorities': [
          {
            'address': 'partial-1',
            'scopes': ['data'],
          },
        ],
      });
      expect(a.updateAuthority, isNull);
    });

    test('authority with missing scopes array is skipped', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'authorities': [
          {'address': 'no-scopes'},
          {
            'address': 'full',
            'scopes': ['full'],
          },
        ],
      });
      expect(a.updateAuthority, 'full');
    });

    test('owner pulled from ownership.owner', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'ownership': {'owner': 'OwnerAddr'},
      });
      expect(a.owner, 'OwnerAddr');
    });

    test('frozen is OR of ownership.frozen + delegate frozens', () {
      final ownerFrozen = DigitalAsset.fromJson({
        'id': 'mint1',
        'ownership': {'frozen': true},
      });
      expect(ownerFrozen.frozen, isTrue);
      expect(ownerFrozen.freezeDelegateFrozen, isFalse);

      // Plugin shape captured from a live proxy getAsset response (listed
      // Core asset): snake_case keys, fields nested under `data`.
      final delegateFrozen = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'freeze_delegate': {
            'data': {'frozen': true},
            'authority': {'type': 'Address', 'address': 'fz'},
          },
        },
      });
      expect(delegateFrozen.frozen, isTrue);
      expect(delegateFrozen.freezeDelegateFrozen, isTrue);

      final permFrozen = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'permanent_freeze_delegate': {
            'data': {'frozen': true},
            'authority': {'type': 'UpdateAuthority', 'address': null},
          },
        },
      });
      expect(permFrozen.frozen, isTrue);
      expect(permFrozen.permanentFreezeDelegateFrozen, isTrue);

      final notFrozen = DigitalAsset.fromJson({'id': 'mint1'});
      expect(notFrozen.frozen, isFalse);
    });
  });

  group('DigitalAsset.fromJson - grouping & supply', () {
    test('collectionKey picked from group_key=="collection" entry', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'grouping': [
          {'group_key': 'authority', 'group_value': 'auth-skip'},
          {'group_key': 'collection', 'group_value': 'coll-1'},
          {'group_key': 'collection', 'group_value': 'coll-2'},
        ],
      });
      expect(a.collectionKey, 'coll-1');
    });

    test('missing collection grouping leaves collectionKey null', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'grouping': [
          {'group_key': 'authority', 'group_value': 'auth-only'},
        ],
      });
      expect(a.collectionKey, isNull);
    });

    test('supply.print_current_supply maps to supply, defaults to 0', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'supply': {'print_current_supply': 7},
      });
      expect(a.supply, 7);

      final b = DigitalAsset.fromJson({'id': 'mint1'});
      expect(b.supply, 0);
    });

    test('currentSize read from mpl_core_info for Core collections', () {
      // DAS nests the collection count under `mpl_core_info`, NOT at the
      // top level. Reading it top-level made every collection parse as
      // empty (null → 0), so the burn gate offered burns of non-empty
      // collections that mpl-core rejects with CollectionMustBeEmpty.
      // Shape from a live proxy getAsset of a devnet Core collection.
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreCollection',
        'mpl_core_info': {
          'num_minted': 4,
          'current_size': 3,
          'plugins_json_version': 1,
        },
      });
      expect(a.currentSize, 3);

      final b = DigitalAsset.fromJson({'id': 'mint1'});
      expect(b.currentSize, isNull);
    });
  });

  group('DigitalAsset.fromJson - plugin delegates', () {
    test('extracts freeze / transfer / burn / update delegate addresses', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'freeze_delegate': {
            'data': {'frozen': false},
            'authority': {'type': 'Address', 'address': 'fz-addr'},
          },
          'transfer_delegate': {
            'data': <String, dynamic>{},
            'authority': {'type': 'Address', 'address': 'tx-addr'},
          },
          'burn_delegate': {
            'data': <String, dynamic>{},
            'authority': {'type': 'Address', 'address': 'bn-addr'},
          },
          'permanent_burn_delegate': {
            'data': <String, dynamic>{},
            'authority': {'type': 'Address', 'address': 'pbn-addr'},
          },
          'update_delegate': {
            'data': {'additional_delegates': <dynamic>[]},
            'authority': {'type': 'Address', 'address': 'up-addr'},
          },
        },
      });
      expect(a.freezeDelegateAuthority, 'fz-addr');
      expect(a.transferDelegateAuthority, 'tx-addr');
      expect(a.burnDelegateAuthority, 'bn-addr');
      expect(a.permanentBurnDelegateAuthority, 'pbn-addr');
      expect(a.updateDelegateAuthority, 'up-addr');
    });

    test('non-Address authority types leave the delegate address null', () {
      // Owner/UpdateAuthority-typed plugin authorities carry no address —
      // the gate must not resolve them to anyone.
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'burn_delegate': {
            'data': <String, dynamic>{},
            'authority': {'type': 'UpdateAuthority', 'address': null},
          },
        },
      });
      expect(a.burnDelegateAuthority, isNull);
    });

    test('master_edition plugin presence sets hasMasterEditionPlugin', () {
      final closed = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'master_edition': {
            'data': {'max_supply': 100},
            'authority': {'type': 'UpdateAuthority', 'address': null},
          },
        },
      });
      expect(closed.hasMasterEditionPlugin, isTrue);
      expect(closed.masterEditionMaxSupply, 100);

      final open = DigitalAsset.fromJson({
        'id': 'mint1',
        'plugins': {
          'master_edition': {
            'data': {'max_supply': null},
            'authority': {'type': 'UpdateAuthority', 'address': null},
          },
        },
      });
      expect(open.hasMasterEditionPlugin, isTrue);
      expect(
        open.masterEditionMaxSupply,
        isNull,
        reason: 'null max_supply marks an open edition',
      );

      final none = DigitalAsset.fromJson({'id': 'mint1'});
      expect(none.hasMasterEditionPlugin, isFalse);
      expect(none.masterEditionMaxSupply, isNull);
    });
  });

  group('DigitalAsset.fromJson - metadata & royalties', () {
    test('name + uri pulled from content', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'content': {
          'metadata': {'name': 'Hello'},
          'json_uri': 'https://example.com/m.json',
        },
      });
      expect(a.name, 'Hello');
      expect(a.uri, 'https://example.com/m.json');
    });

    test('missing content keeps name/uri null', () {
      final a = DigitalAsset.fromJson({'id': 'mint1'});
      expect(a.name, isNull);
      expect(a.uri, isNull);
    });

    test('royalty.basis_points coerced to int', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'royalty': {'basis_points': 750},
      });
      expect(a.sellerFeeBasisPoints, 750);

      final b = DigitalAsset.fromJson({
        'id': 'mint1',
        'royalty': {'basis_points': 7.5},
      });
      expect(
        b.sellerFeeBasisPoints,
        7,
        reason: 'num → int via toInt() truncates',
      );
    });

    test('creators with empty / missing address are dropped', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'creators': [
          {'address': 'c1', 'share': 50, 'verified': true},
          {'address': '', 'share': 50, 'verified': false},
          {'share': 100},
          {'address': 'c2', 'share': 50, 'verified': false},
        ],
      });
      expect(a.tokenMetadataCreators.map((c) => c.address), ['c1', 'c2']);
      expect(a.tokenMetadataCreators.first.verified, isTrue);
      expect(a.tokenMetadataCreators.last.verified, isFalse);
    });

    test('verified flag normalizes to bool (only literal true counts)', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'creators': [
          {'address': 'c1', 'share': 1, 'verified': 'true'},
        ],
      });
      expect(
        a.tokenMetadataCreators.single.verified,
        isFalse,
        reason: 'string "true" must not parse as verified',
      );
    });

    // `royalty.primary_sale_happened` drives the secondary-market gate for
    // token-metadata assets (webapp assets). A misparse either offers
    // the primary-only "direct proceeds" toggle on a resold NFT or hides it
    // on a genuine primary — both change who gets paid.
    test(
      'royalty.primary_sale_happened parses to bool (literal true only)',
      () {
        expect(
          DigitalAsset.fromJson({
            'id': 'mint1',
            'royalty': {'primary_sale_happened': true},
          }).primarySaleHappened,
          isTrue,
        );
        expect(
          DigitalAsset.fromJson({
            'id': 'mint1',
            'royalty': {'primary_sale_happened': false},
          }).primarySaleHappened,
          isFalse,
        );
        // Absent → false (matches Core, which never sets it).
        expect(
          DigitalAsset.fromJson({'id': 'mint1'}).primarySaleHappened,
          isFalse,
        );
        // Truthy non-bool must not count.
        expect(
          DigitalAsset.fromJson({
            'id': 'mint1',
            'royalty': {'primary_sale_happened': 'true'},
          }).primarySaleHappened,
          isFalse,
        );
      },
    );
  });

  group('DigitalAsset.fromJson - mpl-core royalties plugin', () {
    // The edit-collection prefill seeds royalty splits from this plugin;
    // a misparse falls back to the artwork-render lookup, which 404s
    // for collection mints and seeds empty creators — the chain then
    // rejects the edit with mpl-core 0x1C "Invalid setting for plugin"
    // (shares must sum to 100). Shape captured from a live Helius
    // devnet getAsset response.
    test('parses basis_points + percentage creators from plugins.royalties '
        'and derives verified from the update authority', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreCollection',
        'authorities': [
          {
            'address': 'authority1',
            'scopes': ['full'],
          },
        ],
        'plugins': {
          'royalties': {
            'data': {
              'basis_points': 500,
              'rule_set': 'None',
              'creators': [
                {'address': 'authority1', 'percentage': 60},
                {'address': 'other1', 'percentage': 40},
              ],
            },
            'index': 0,
            'authority': {'type': 'UpdateAuthority', 'address': null},
          },
        },
      });
      expect(a.royaltiesPluginBasisPoints, 500);
      expect(a.royaltiesPluginCreators, hasLength(2));
      expect(a.royaltiesPluginCreators.first.address, 'authority1');
      expect(a.royaltiesPluginCreators.first.share, 60);
      expect(a.royaltiesPluginCreators.first.verified, isTrue);
      expect(a.royaltiesPluginCreators.last.share, 40);
      expect(a.royaltiesPluginCreators.last.verified, isFalse);
    });

    test('no royalties plugin → null basis points + empty creators', () {
      final a = DigitalAsset.fromJson({
        'id': 'mint1',
        'interface': 'MplCoreCollection',
      });
      expect(a.royaltiesPluginBasisPoints, isNull);
      expect(a.royaltiesPluginCreators, isEmpty);
    });
  });

  test('isMutable is true only when mutable==true', () {
    expect(
      DigitalAsset.fromJson({'id': 'mint1', 'mutable': true}).isMutable,
      isTrue,
    );
    expect(
      DigitalAsset.fromJson({'id': 'mint1', 'mutable': false}).isMutable,
      isFalse,
    );
    expect(DigitalAsset.fromJson({'id': 'mint1'}).isMutable, isFalse);
  });
}
