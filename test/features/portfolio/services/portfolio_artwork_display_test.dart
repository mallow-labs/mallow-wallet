import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/utils/price_formatter.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';

/// `PortfolioArtwork.displayPrice` / `.soldCountLabel` are what every browse
/// card renders. They are the display half of the SYOP defect: a "set your own
/// price" listing has an on-chain price of 0, so a card that prints the number
/// tells the buyer the piece is worth nothing — the same misreading that let a
/// SYOP purchase settle at 0. The webapp swaps in a word instead
/// (`PriceDisplay`, rendered with `fullSYOP` from
/// `ArtworkCardMetadata`).
PortfolioArtwork _artwork({
  api.ListingType? listingType,
  api.BuyNowMetadata? buyNow,
  int? supply,
  int? maxSupply,
  String? chain,
}) => PortfolioArtwork(
  mintAccount: 'mint',
  title: 'Piece',
  imageUrl: '',
  artistName: 'artist',
  listingType: listingType,
  buyNowMetadata: buyNow,
  supply: supply,
  maxSupply: maxSupply,
  chain: chain,
);

void main() {
  group('displayPrice', () {
    test('a SYOP listing names the mechanic instead of its zero price', () {
      final artwork = _artwork(
        listingType: api.ListingType.buyNow,
        buyNow: const api.BuyNowMetadata(
          amount: 0,
          currencyMint: PriceFormatter.solMint,
          buyerSetsPrice: true,
        ),
      );
      expect(artwork.displayPrice, 'Set your own price');
    });

    test('a genuinely free mint reads "Free", not "0 SOL"', () {
      final artwork = _artwork(
        listingType: api.ListingType.buyNow,
        buyNow: const api.BuyNowMetadata(
          amount: 0,
          currencyMint: PriceFormatter.solMint,
        ),
      );
      expect(artwork.displayPrice, 'Free');
    });

    test('a priced listing is unaffected', () {
      final artwork = _artwork(
        listingType: api.ListingType.buyNow,
        buyNow: const api.BuyNowMetadata(
          amount: 1500000000,
          currencyMint: PriceFormatter.solMint,
        ),
      );
      expect(artwork.displayPrice, '1.5 SOL');
    });

    test('an unlisted artwork still renders no price row at all', () {
      // The webapp omits `PriceDisplay` entirely rather than printing
      // "Not listed" on a card, and the card hides the row on an empty string.
      expect(_artwork().displayPrice, '');
      expect(_artwork(listingType: api.ListingType.unlisted).displayPrice, '');
    });
  });

  group('soldCountLabel', () {
    test('four-digit counts are thousands-grouped like the webapp', () {
      final open = _artwork(listingType: api.ListingType.buyNow, supply: 1234);
      expect(open.soldCountLabel, '1,234 sold');

      final limited = _artwork(
        listingType: api.ListingType.buyNow,
        supply: 1234,
        maxSupply: 10000,
      );
      expect(limited.soldCountLabel, '1,234 / 10,000 sold');
    });

    test('small counts are untouched', () {
      final open = _artwork(listingType: api.ListingType.buyNow, supply: 7);
      expect(open.soldCountLabel, '7 sold');
    });

    // Why this matters: "Sold out" is a buying decision. `maxSupply - supply`
    // reads the Metaplex master-edition counter, which only exists on Solana —
    // off-Solana the two fields describe the contract, not this listing, so
    // trusting them either hides a buyable edition behind "Sold out" or
    // advertises prints that are already gone. The webapp draws the same line
    // and reads `quantityLeft` instead.
    group('off-Solana editions use quantityLeft, not maxSupply - supply', () {
      test('an ETH edition with prints left is not "Sold out"', () {
        final eth = _artwork(
          listingType: api.ListingType.buyNow,
          chain: 'ethereum',
          supply: 10,
          maxSupply: 10,
          buyNow: const api.BuyNowMetadata(quantity: 10, quantityLeft: 4),
        );
        expect(eth.soldCountLabel, '10 / 10 sold');
      });

      test('an ETH edition with none left reads "Sold out"', () {
        final eth = _artwork(
          listingType: api.ListingType.buyNow,
          chain: 'ethereum',
          supply: 2,
          maxSupply: 10,
          buyNow: const api.BuyNowMetadata(quantity: 10, quantityLeft: 0),
        );
        expect(eth.soldCountLabel, 'Sold out');
      });

      test('Solana keeps the master-edition derivation', () {
        // quantityLeft is deliberately 0 here: if the Solana arm ever started
        // reading it, this would flip to "Sold out".
        final sol = _artwork(
          listingType: api.ListingType.buyNow,
          chain: 'solana',
          supply: 2,
          maxSupply: 10,
          buyNow: const api.BuyNowMetadata(quantity: 10, quantityLeft: 0),
        );
        expect(sol.soldCountLabel, '2 / 10 sold');
      });

      test('an absent chain is treated as Solana', () {
        // Several endpoints omit `chain`; defaulting the other way would flip
        // every Solana edition on those surfaces onto the wrong derivation.
        final unknown = _artwork(
          listingType: api.ListingType.buyNow,
          supply: 2,
          maxSupply: 10,
          buyNow: const api.BuyNowMetadata(quantity: 10, quantityLeft: 0),
        );
        expect(unknown.soldCountLabel, '2 / 10 sold');
      });
    });
  });
}
