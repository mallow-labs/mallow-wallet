import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/mint/data/edit_prefill.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'edit_prefill_test.mocks.dart';

// The royalties source selection is the load-bearing part of the edit
// prefill: the backend rebuilds the on-chain royalties plugin from
// whatever creators/bps the form submits, and mpl-core rejects shares
// that don't sum to 100 (0x1C "Invalid setting for plugin"). Seeding the
// wrong source therefore turns a metadata-only edit into an opaque
// on-chain failure at confirm time.

@GenerateMocks([DasApiService, ArtworkRepository])
void main() {
  late MockDasApiService mockDas;
  late MockArtworkRepository mockArtworkRepo;
  late EditNftPrefillService service;

  const collectionMint = 'CollectionMint11111111111111111111111111111';
  const creatorAddress = 'CreatorWallet1111111111111111111111111111111';

  setUp(() {
    mockDas = MockDasApiService();
    mockArtworkRepo = MockArtworkRepository();
    service = EditNftPrefillService(mockDas, mockArtworkRepo);
  });

  test(
    'core collection royalties come from the mpl-core royalties plugin — '
    'collections are not in the artwork index, so the render fallback '
    '404s and would otherwise seed empty creators that the chain rejects',
    () async {
      when(mockDas.getAsset(collectionMint)).thenAnswer(
        (_) async => const DigitalAsset(
          id: collectionMint,
          tokenStandard: TokenStandard.coreCollection,
          isMutable: true,
          frozen: false,
          supply: 0,
          freezeDelegateFrozen: false,
          permanentFreezeDelegateFrozen: false,
          hasMasterEditionPlugin: false,
          updateAuthority: creatorAddress,
          name: 'My Collection',
          royaltiesPluginBasisPoints: 500,
          royaltiesPluginCreators: [
            OnChainCreator(address: creatorAddress, share: 100, verified: true),
          ],
        ),
      );
      // The artwork-render lookup 404s for a collection mint.
      when(
        mockArtworkRepo.getArtworkDetail(collectionMint),
      ).thenThrow(Exception('404'));

      final prefill = await service.load(collectionMint);

      expect(prefill.isCollection, isTrue);
      expect(prefill.sellerFeeBasisPoints, 500);
      expect(prefill.creators, hasLength(1));
      expect(prefill.creators.single.address, creatorAddress);
      expect(prefill.creators.single.share, 100);
    },
  );

  // A Master Edition links to its parent via an mpl-core Group, which DAS does
  // not surface as a `grouping` entry — so the usual `collectionKey` read comes
  // back empty for one. If the prefill accepted that as "no parent", an edit
  // where the user changed nothing but the title would show an empty picker,
  // and re-picking the same parent would bill them for a group migration that
  // moves the asset nowhere. Webapp parity: `useCreateMetadata`
  // falls back to the indexer's group-resolved key for exactly this case.
  group('master-edition parent collection', () {
    const masterEditionMint = 'MasterEd1t10n1111111111111111111111111111111';
    const parentMint = 'PaReNt1111111111111111111111111111111111111';

    DigitalAsset masterEdition() => const DigitalAsset(
      id: masterEditionMint,
      tokenStandard: TokenStandard.coreCollection,
      isMutable: true,
      frozen: false,
      supply: 0,
      freezeDelegateFrozen: false,
      permanentFreezeDelegateFrozen: false,
      hasMasterEditionPlugin: true,
      updateAuthority: creatorAddress,
      name: 'My edition',
      royaltiesPluginBasisPoints: 500,
      royaltiesPluginCreators: [
        OnChainCreator(address: creatorAddress, share: 100, verified: true),
      ],
    );

    test('falls back to the artwork render when DAS grouping is empty, so an '
        'untouched edit does not read as a cleared parent', () async {
      when(
        mockDas.getAsset(masterEditionMint),
      ).thenAnswer((_) async => masterEdition());
      when(mockArtworkRepo.getArtworkDetail(masterEditionMint)).thenAnswer(
        (_) async => _artworkDetails(
          mintAccount: masterEditionMint,
          collectionMint: parentMint,
          collectionName: 'Parent Collection',
        ),
      );

      final prefill = await service.load(masterEditionMint);

      expect(prefill.isMasterEdition, isTrue);
      expect(prefill.collection?.mintAccount, parentMint);
      expect(prefill.collectionName, 'Parent Collection');
    });

    test('stays null for a master edition that genuinely has no parent — the '
        'indexer resolves the key from the group, so an absent one means '
        'ungrouped, not unknown', () async {
      when(
        mockDas.getAsset(masterEditionMint),
      ).thenAnswer((_) async => masterEdition());
      when(mockArtworkRepo.getArtworkDetail(masterEditionMint)).thenAnswer(
        (_) async => _artworkDetails(mintAccount: masterEditionMint),
      );

      final prefill = await service.load(masterEditionMint);

      expect(prefill.collection, isNull);
      expect(prefill.collectionName, isNull);
    });
  });
}

ArtworkDetails _artworkDetails({
  required String mintAccount,
  String? collectionMint,
  String? collectionName,
}) => ArtworkDetails(
  mintAccount: mintAccount,
  title: 'My edition',
  imageUrl: '',
  description: 'desc',
  artistName: 'Artist',
  artistAddress: 'CreatorWallet1111111111111111111111111111111',
  collectionMint: collectionMint,
  collectionName: collectionName,
);
