import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/shared/utils/artwork_mappers.dart';

// SupplyType is re-exported through artwork_bloc.dart's mallow_api import.

ArtworkDetails _details({
  String mintAccount = 'MINT1111111111111111111111111111111111111111',
  String title = 'Untitled',
  String imageUrl = 'https://cdn.example.com/img.png',
  String artistName = 'Artist',
  String artistAddress = 'ARTIST11111111111111111111111111111111111111',
  String? artistUsername,
  String? collectionName,
  int? supply,
  int? maxSupply,
  int? editionNumber,
  SupplyType supplyType = SupplyType.oneOfOne,
  String? animationUrl,
  String? updateAuthority,
}) {
  return ArtworkDetails(
    mintAccount: mintAccount,
    title: title,
    imageUrl: imageUrl,
    description: null,
    artistName: artistName,
    artistAddress: artistAddress,
    artistUsername: artistUsername,
    collectionName: collectionName,
    supply: supply,
    maxSupply: maxSupply,
    editionNumber: editionNumber,
    supplyType: supplyType,
    animationUrl: animationUrl,
    updateAuthority: updateAuthority,
  );
}

void main() {
  group('ArtworkDetailsToPortfolio.toPortfolioArtwork', () {
    test('copies scalar fields verbatim', () {
      final d = _details(
        mintAccount: 'MINT2',
        title: 'A piece',
        imageUrl: 'https://cdn.example.com/a.png',
        artistName: 'Jane',
        artistUsername: 'jane',
        collectionName: 'Genesis',
        supply: 3,
        maxSupply: 10,
        editionNumber: 2,
        animationUrl: 'https://cdn.example.com/a.mp4',
        updateAuthority: 'UPDATEAUTH',
      );

      final p = d.toPortfolioArtwork();

      expect(p.mintAccount, 'MINT2');
      expect(p.title, 'A piece');
      expect(p.imageUrl, 'https://cdn.example.com/a.png');
      expect(p.artistName, 'Jane');
      expect(p.artistUsername, 'jane');
      expect(p.collectionName, 'Genesis');
      expect(p.supply, 3);
      expect(p.maxSupply, 10);
      expect(p.editionNumber, 2);
      expect(p.animationUrl, 'https://cdn.example.com/a.mp4');
      expect(p.updateAuth, 'UPDATEAUTH');
    });

    test('non-print supply types → parentEdition is null', () {
      for (final type in [
        SupplyType.oneOfOne,
        SupplyType.limitedEdition,
        SupplyType.openEdition,
        SupplyType.collection,
      ]) {
        final p = _details(supplyType: type).toPortfolioArtwork();
        expect(
          p.parentEdition,
          isNull,
          reason: '$type should not produce a parentEdition marker',
        );
        // Sanity: derived `isMasterEdition` honors parentEdition being null
        // (the supplyLabel branch checks parentEdition).
      }
    });

    test('editionPrint → parentEdition seeded with this artwork\'s mint', () {
      final p = _details(
        mintAccount: 'EDITIONMINT',
        supplyType: SupplyType.editionPrint,
        editionNumber: 5,
      ).toPortfolioArtwork();

      // ArtworkDetails doesn't expose the master mint, so the mapper uses
      // the artwork's own mint purely as a non-null marker.
      expect(p.parentEdition, 'EDITIONMINT');
      // PortfolioArtwork.supplyLabel checks parentEdition first.
      expect(p.supplyLabel, 'Edition print #5');
    });

    test('editionPrint without editionNumber → "Edition print" label', () {
      final p = _details(
        mintAccount: 'EDITIONMINT',
        supplyType: SupplyType.editionPrint,
      ).toPortfolioArtwork();
      expect(p.parentEdition, 'EDITIONMINT');
      expect(p.supplyLabel, 'Edition print');
    });
  });
}
