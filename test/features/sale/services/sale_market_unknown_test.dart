import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/auction/services/auction_bloc.dart';
import 'package:mallow_wallet/features/fixed_price/services/fixed_price_bloc.dart';

// When a Core asset's collection cannot be read, the sale is neither primary
// nor secondary as far as the app can tell. The review step then shows no
// proceeds rows and no direct-proceeds toggle: both would be for a guessed
// class, and the guess is the wrong fee half the time.

const _seller = 'seller11111111111111111111111111111111111111';
const _shares = [
  ArtworkRoyaltySplit(
    address: 'creator1111111111111111111111111111111111111',
    sharePercent: 100,
  ),
];

void main() {
  group('fixed-price review', () {
    const known = FixedPriceState(
      userPubkey: _seller,
      price: 1000000000,
      royaltyShares: _shares,
      royaltyBps: 500,
    );

    test('a classified sale shows its breakdown and the toggle', () {
      expect(known.proceedsSplits, isNotEmpty);
      expect(known.showDirectProceedsOption, isTrue);
    });

    test('an unclassified sale shows neither', () {
      final unknown = known.copyWith(saleMarketUnknown: true);
      expect(unknown.proceedsSplits, isEmpty);
      expect(unknown.showDirectProceedsOption, isFalse);
    });

    test('the next artwork picked is judged on its own read', () {
      final again = known
          .copyWith(saleMarketUnknown: true)
          .copyWith(saleMarketUnknown: false);
      expect(again.proceedsSplits, isNotEmpty);
    });
  });

  group('auction review', () {
    const known = AuctionState(
      userPubkey: _seller,
      reservePrice: 1000000000,
      royaltyShares: _shares,
      royaltyBps: 500,
    );

    test('a classified sale shows its breakdown and the toggle', () {
      expect(known.proceedsSplits, isNotEmpty);
      expect(known.showDirectProceedsOption, isTrue);
    });

    test('an unclassified sale shows neither', () {
      final unknown = known.copyWith(saleMarketUnknown: true);
      expect(unknown.proceedsSplits, isEmpty);
      expect(unknown.showDirectProceedsOption, isFalse);
    });
  });
}
