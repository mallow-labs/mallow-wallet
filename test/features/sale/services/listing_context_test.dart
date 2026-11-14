import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/sale/services/direct_proceeds.dart';
import 'package:mallow_wallet/features/sale/services/marketplace_config_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/features/sell/services/trade_eligibility.dart';

class _Das extends Mock implements DasApiService {}

class _Artworks extends Mock implements ArtworkRepository {}

class _Config extends Mock implements MarketplaceConfigService {}

void main() {
  const fees = (primaryBps: 500, secondaryBps: 250, printFeeLamports: 0);
  ArtworkDetails detail({String? standard, String? royaltyPercent}) =>
      ArtworkDetails(
        mintAccount: 'leaf',
        title: '',
        imageUrl: '',
        description: '',
        artistName: '',
        artistAddress: '',
        tokenStandard: standard,
        royaltyPercent: royaltyPercent,
      );
  test('indexed royalty sentinel cannot become listing economics', () {
    final result = resolveListingEconomics(
      detail: detail(royaltyPercent: '655.35'),
      fees: fees,
    );
    expect(result.royaltyBps, 0);
  });
  test('ordinary indexed percentage still resolves', () {
    expect(
      resolveListingEconomics(
        detail: detail(royaltyPercent: '7.5'),
        fees: fees,
      ).royaltyBps,
      750,
    );
  });

  test('parent verification overlaps the slower artwork detail read', () async {
    final das = _Das();
    final artworks = _Artworks();
    final config = _Config();
    final pendingDetail = Completer<ArtworkDetails>();
    final parentRequested = Completer<void>();
    when(() => config.get()).thenAnswer((_) async => fees);
    when(
      () => artworks.getArtworkDetail('leaf'),
    ).thenAnswer((_) => pendingDetail.future);
    when(() => das.getAsset('leaf')).thenAnswer(
      (_) async => DigitalAsset.fromJson({
        'id': 'leaf',
        'interface': 'MplBubblegumV2',
        'compression': {'flags': 0},
        'grouping': [
          {'group_key': 'collection', 'group_value': 'parent'},
        ],
      }),
    );
    when(() => das.getAsset('parent')).thenAnswer((_) async {
      parentRequested.complete();
      return DigitalAsset.fromJson({
        'id': 'parent',
        'interface': 'MplCoreCollection',
      });
    });
    final pendingContext = resolveListingContext(
      mint: 'leaf',
      sellerPubkey: 'seller',
      dasApi: das,
      artworkRepo: artworks,
      marketplaceConfig: config,
    );
    await parentRequested.future;
    expect(pendingDetail.isCompleted, isFalse);
    pendingDetail.complete(detail());
    expect((await pendingContext).tradeEligibility, TradeEligibility.eligible);
    verify(() => das.getAsset('parent')).called(1);
  });

  for (final flags in [0, 1, 4]) {
    test(
      'v2 listing reuses one parent read for eligibility and inherited royalties, flags $flags',
      () async {
        final das = _Das();
        final artworks = _Artworks();
        final config = _Config();
        when(() => config.get()).thenAnswer((_) async => fees);
        when(() => artworks.getArtworkDetail('leaf')).thenAnswer(
          (_) async => detail(standard: 'cnft', royaltyPercent: '655.35'),
        );
        when(() => das.getAsset('leaf')).thenAnswer(
          (_) async => DigitalAsset.fromJson({
            'id': 'leaf',
            'interface': 'MplBubblegumV2',
            'compression': {'flags': flags, 'compressed': true},
            'royalty': {'basis_points': 65535},
            'creators': [
              {'address': 'proofCreator', 'share': 100},
            ],
            'grouping': [
              {'group_key': 'collection', 'group_value': 'parent'},
            ],
          }),
        );
        when(() => das.getAsset('parent')).thenAnswer(
          (_) async => DigitalAsset.fromJson({
            'id': 'parent',
            'interface': 'MplCoreCollection',
            'plugins': {
              'royalties': {
                'data': {
                  'basis_points': 750,
                  'creators': [
                    {'address': 'payoutCreator', 'percentage': 100},
                  ],
                },
              },
            },
          }),
        );
        final result = await resolveListingContext(
          mint: 'leaf',
          sellerPubkey: 'seller',
          dasApi: das,
          artworkRepo: artworks,
          marketplaceConfig: config,
        );
        expect(
          result.tradeEligibility,
          flags == 0 ? TradeEligibility.eligible : TradeEligibility.restricted,
        );
        expect(result.royaltyBps, 750);
        expect(result.royaltyShares.single.address, 'payoutCreator');
        expect(result.isSecondaryMarket, isTrue);
        verify(() => das.getAsset('leaf')).called(1);
        verify(() => das.getAsset('parent')).called(1);
      },
    );
  }
  for (final standard in ['cnft', 'cnft-v2']) {
    test(
      'failed DAS read blocks only suspected v2 listing context $standard',
      () async {
        final das = _Das();
        final artworks = _Artworks();
        final config = _Config();
        when(() => config.get()).thenAnswer((_) async => fees);
        when(
          () => artworks.getArtworkDetail('leaf'),
        ).thenAnswer((_) async => detail(standard: standard));
        when(() => das.getAsset('leaf')).thenThrow(StateError('unavailable'));
        final result = await resolveListingContext(
          mint: 'leaf',
          sellerPubkey: 'seller',
          dasApi: das,
          artworkRepo: artworks,
          marketplaceConfig: config,
        );
        expect(
          result.tradeEligibility,
          standard == 'cnft-v2'
              ? TradeEligibility.unverified
              : TradeEligibility.eligible,
        );
      },
    );
  }
  for (final failure in ['collection', 'unknown_leaf', 'known_v2_leaf']) {
    test(
      'failed $failure lookup reports unverified with retry wording',
      () async {
        final das = _Das();
        final artworks = _Artworks();
        final config = _Config();
        when(() => config.get()).thenAnswer((_) async => fees);
        when(
          () => artworks.getArtworkDetail('leaf'),
        ).thenThrow(StateError('offline'));
        if (failure == 'collection') {
          when(() => das.getAsset('leaf')).thenAnswer(
            (_) async => DigitalAsset.fromJson({
              'id': 'leaf',
              'interface': 'MplBubblegumV2',
              'compression': {'compressed': true, 'flags': 0},
              'grouping': [
                {'group_key': 'collection', 'group_value': 'parent'},
              ],
            }),
          );
          when(() => das.getAsset('parent')).thenThrow(StateError('offline'));
        } else {
          when(() => das.getAsset('leaf')).thenThrow(StateError('offline'));
        }
        final result = await resolveListingContext(
          mint: 'leaf',
          sellerPubkey: 'seller',
          dasApi: das,
          artworkRepo: artworks,
          marketplaceConfig: config,
          expectedTokenStandard: failure == 'known_v2_leaf' ? 'cnft-v2' : null,
        );
        expect(result.tradeEligibility, TradeEligibility.unverified);
        expect(result.tradeEligibility.message, contains('try again'));
        expect(
          result.tradeEligibility.message,
          isNot(contains('restrictions')),
        );
        if (failure == 'collection')
          verify(() => das.getAsset('parent')).called(1);
      },
    );
  }

  group('a Core asset in a collection', () {
    const creator = 'creator';

    Map<String, dynamic> coreAsset() => {
      'id': 'leaf',
      'interface': 'MplCoreAsset',
      'ownership': {'owner': creator, 'frozen': false},
      'authorities': [
        {
          'address': creator,
          'scopes': ['full'],
        },
      ],
      'grouping': [
        {'group_key': 'collection', 'group_value': 'parent'},
      ],
    };

    // The only creator signature sits on the collection, as it does for a
    // piece minted into a signed collection.
    DigitalAsset signedCollection() => DigitalAsset.fromJson({
      'id': 'parent',
      'interface': 'MplCoreCollection',
      'authorities': [
        {
          'address': creator,
          'scopes': ['full'],
        },
      ],
      'plugins': {
        'verified_creators': {
          'data': {
            'signatures': [
              {'address': creator, 'verified': true},
            ],
          },
        },
      },
    });

    ({_Das das, _Artworks artworks, _Config config}) mocks() {
      final das = _Das();
      final artworks = _Artworks();
      final config = _Config();
      when(() => config.get()).thenAnswer((_) async => fees);
      when(
        () => artworks.getArtworkDetail('leaf'),
      ).thenAnswer((_) async => detail(standard: 'core'));
      when(
        () => das.getAsset('leaf'),
      ).thenAnswer((_) async => DigitalAsset.fromJson(coreAsset()));
      return (das: das, artworks: artworks, config: config);
    }

    test('is primary when the collection read answers', () async {
      final m = mocks();
      when(
        () => m.das.getAsset('parent'),
      ).thenAnswer((_) async => signedCollection());

      final result = await resolveListingContext(
        mint: 'leaf',
        sellerPubkey: creator,
        dasApi: m.das,
        artworkRepo: m.artworks,
        marketplaceConfig: m.config,
      );

      expect(result.isSecondaryMarket, isFalse);
      verify(() => m.das.getAsset('parent')).called(1);
    });

    test('one failed collection read is tried again', () async {
      final m = mocks();
      var reads = 0;
      when(() => m.das.getAsset('parent')).thenAnswer((_) async {
        if (reads++ == 0) throw StateError('offline');
        return signedCollection();
      });

      final result = await resolveListingContext(
        mint: 'leaf',
        sellerPubkey: creator,
        dasApi: m.das,
        artworkRepo: m.artworks,
        marketplaceConfig: m.config,
      );

      expect(result.isSecondaryMarket, isFalse);
      expect(reads, 2);
    });

    // Judged from the asset alone this piece reads as secondary, while the
    // program settles it as primary. Neither answer may be shown.
    test('is unclassified, not secondary, when the collection cannot be '
        'read', () async {
      final m = mocks();
      when(() => m.das.getAsset('parent')).thenThrow(StateError('offline'));

      final result = await resolveListingContext(
        mint: 'leaf',
        sellerPubkey: creator,
        dasApi: m.das,
        artworkRepo: m.artworks,
        marketplaceConfig: m.config,
      );

      expect(result.isSecondaryMarket, isNull);
      verify(() => m.das.getAsset('parent')).called(2);
    });
  });
}
