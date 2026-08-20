import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';

ArtworkDetails _auctionArtwork({String? currentBidder, String? seller}) {
  return ArtworkDetails(
    mintAccount: 'mint-1',
    title: 'Test',
    imageUrl: 'https://x/i.png',
    description: null,
    artistName: 'A',
    artistAddress: 'ART',
    listingType: ListingType.auction,
    auctionMetadata: AuctionMetadata(
      auctionAccount: 'AUC',
      currentBidder: currentBidder,
      seller: seller,
      bidCount: currentBidder == null ? 0 : 1,
    ),
  );
}

MarketPrepData _prep({
  bool isSimulating = false,
  int estimatedFeeLamports = 5000,
}) {
  return MarketPrepData(
    transactionsBase64: const ['tx'],
    mintAccount: 'mint-1',
    actionType: 'buy',
    flow: AppFlow.fixedPriceBuy,
    totalCost: const MarketPrice(rawAmount: 1.0),
    estimatedFeeLamports: estimatedFeeLamports,
    isSimulating: isSimulating,
  );
}

void main() {
  group('marketArtworkListenWhen', () {
    test('fires on the transition into TxFlowReady', () {
      const previous = TxFlowIdle<MarketPrepData, MarketSuccessData>();
      final current = TxFlowReady<MarketPrepData, MarketSuccessData>(_prep());

      expect(marketArtworkListenWhen(previous, current), isTrue);
    });

    test('fires again on a within-TxFlowReady re-emit when the prep payload '
        'changes (simulation result arriving)', () {
      // The bug being guarded against: a `previous is! TxFlowReady` guard
      // skips this transition, so simulation refreshes never reach the
      // screen-level listener and the open confirmation sheet's
      // simulation banner stops updating.
      final previous = TxFlowReady<MarketPrepData, MarketSuccessData>(
        _prep(isSimulating: true),
      );
      final current = TxFlowReady<MarketPrepData, MarketSuccessData>(
        _prep(estimatedFeeLamports: 7500),
      );

      expect(marketArtworkListenWhen(previous, current), isTrue);
    });

    test(
      'fires twice across TxFlowReady(initial) → TxFlowReady(withSimulation)',
      () {
        // Reproduces the reviewer-supplied scenario: the screen listener
        // must fire once on the initial enter and once again when the
        // simulation result lands on the same TxFlowReady type.
        const idle = TxFlowIdle<MarketPrepData, MarketSuccessData>();
        final initial = TxFlowReady<MarketPrepData, MarketSuccessData>(
          _prep(isSimulating: true),
        );
        final withSimulation = TxFlowReady<MarketPrepData, MarketSuccessData>(
          _prep(estimatedFeeLamports: 7500),
        );

        expect(marketArtworkListenWhen(idle, initial), isTrue);
        expect(marketArtworkListenWhen(initial, withSimulation), isTrue);
      },
    );

    test('does NOT fire when prep payload is unchanged', () {
      final prep = _prep();
      final previous = TxFlowReady<MarketPrepData, MarketSuccessData>(prep);
      final current = TxFlowReady<MarketPrepData, MarketSuccessData>(prep);

      expect(marketArtworkListenWhen(previous, current), isFalse);
    });

    test('fires on transition into TxFlowSuccess', () {
      const previous = TxFlowIdle<MarketPrepData, MarketSuccessData>();
      const current = TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'sig',
        result: MarketSuccessData(
          explorerUrl: 'https://example/sig',
          actionType: 'buy',
          mintAccount: 'mint-1',
        ),
      );

      expect(marketArtworkListenWhen(previous, current), isTrue);
    });

    test('fires when TxFlowSuccess.indexed flips from null to true', () {
      const previous = TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'sig',
        result: MarketSuccessData(
          explorerUrl: 'https://example/sig',
          actionType: 'buy',
          mintAccount: 'mint-1',
        ),
      );
      const current = TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'sig',
        result: MarketSuccessData(
          explorerUrl: 'https://example/sig',
          actionType: 'buy',
          mintAccount: 'mint-1',
          indexed: true,
        ),
      );

      expect(marketArtworkListenWhen(previous, current), isTrue);
    });

    test(
      'does NOT fire on a TxFlowSuccess re-emit with the same indexed value',
      () {
        const success = TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: 'sig',
          result: MarketSuccessData(
            explorerUrl: 'https://example/sig',
            actionType: 'buy',
            mintAccount: 'mint-1',
            indexed: true,
          ),
        );

        expect(marketArtworkListenWhen(success, success), isFalse);
      },
    );

    test('fires on TxFlowFailure', () {
      const previous = TxFlowIdle<MarketPrepData, MarketSuccessData>();
      const current = TxFlowFailure<MarketPrepData, MarketSuccessData>(
        AppFailure.unknown('boom'),
      );

      expect(marketArtworkListenWhen(previous, current), isTrue);
    });

    test(
      'does not fire on intermediate states (preparing/signing/broadcasting)',
      () {
        const idle = TxFlowIdle<MarketPrepData, MarketSuccessData>();
        const preparing = TxFlowPreparing<MarketPrepData, MarketSuccessData>();
        const signing = TxFlowSigning<MarketPrepData, MarketSuccessData>();
        const broadcasting =
            TxFlowBroadcasting<MarketPrepData, MarketSuccessData>();

        expect(marketArtworkListenWhen(idle, preparing), isFalse);
        expect(marketArtworkListenWhen(preparing, signing), isFalse);
        expect(marketArtworkListenWhen(signing, broadcasting), isFalse);
      },
    );
  });

  group('claimsOwnershipAfter', () {
    test('cancel-auction: the seller always reclaims the NFT', () {
      // No bidder needed — reclaim returns the NFT to the seller (caller).
      expect(
        claimsOwnershipAfter(
          actionType: 'cancel-auction',
          currentAddress: 'ME',
          artwork: _auctionArtwork(),
        ),
        isTrue,
      );
    });

    test('settle-auction: the high bidder (winner) takes ownership', () {
      expect(
        claimsOwnershipAfter(
          actionType: 'settle-auction',
          currentAddress: 'ME',
          artwork: _auctionArtwork(currentBidder: 'ME'),
        ),
        isTrue,
      );
    });

    test('settle-auction: a seller settling someone else\'s win does not '
        'take ownership (NFT goes to the winner)', () {
      expect(
        claimsOwnershipAfter(
          actionType: 'settle-auction',
          currentAddress: 'SELLER',
          artwork: _auctionArtwork(currentBidder: 'WINNER'),
        ),
        isFalse,
      );
    });

    test('no connected wallet never claims ownership', () {
      expect(
        claimsOwnershipAfter(
          actionType: 'cancel-auction',
          currentAddress: null,
          artwork: _auctionArtwork(),
        ),
        isFalse,
      );
    });

    test('unrelated actions (bid, buy) never claim ownership', () {
      expect(
        claimsOwnershipAfter(
          actionType: 'bid',
          currentAddress: 'ME',
          artwork: _auctionArtwork(currentBidder: 'ME'),
        ),
        isFalse,
      );
      expect(
        claimsOwnershipAfter(
          actionType: 'buy',
          currentAddress: 'ME',
          artwork: _auctionArtwork(currentBidder: 'ME'),
        ),
        isFalse,
      );
    });
  });

  group('settledWonAuctionWinner', () {
    test('seller settling a won auction yields the winning bidder', () {
      // The seller relinquishes the NFT to the winner, so the screen flips
      // the seller's sheet to the unlisted "Make offer" viewer state.
      expect(
        settledWonAuctionWinner(
          actionType: 'settle-auction',
          currentAddress: 'SELLER',
          artwork: _auctionArtwork(currentBidder: 'WINNER', seller: 'SELLER'),
        ),
        'WINNER',
      );
    });

    test('winner claiming their own win is not a relinquish (null)', () {
      // The winner takes ownership — that path is claimsOwnershipAfter's job.
      expect(
        settledWonAuctionWinner(
          actionType: 'settle-auction',
          currentAddress: 'WINNER',
          artwork: _auctionArtwork(currentBidder: 'WINNER', seller: 'SELLER'),
        ),
        isNull,
      );
    });

    test('a non-seller, non-winner observer never relinquishes (null)', () {
      expect(
        settledWonAuctionWinner(
          actionType: 'settle-auction',
          currentAddress: 'OBSERVER',
          artwork: _auctionArtwork(currentBidder: 'WINNER', seller: 'SELLER'),
        ),
        isNull,
      );
    });

    test('no-bid auction (no winner) does not relinquish (null)', () {
      // bidCount == 0 / currentBidder == null — the seller reclaims via
      // cancel-auction instead, not a relinquish.
      expect(
        settledWonAuctionWinner(
          actionType: 'settle-auction',
          currentAddress: 'SELLER',
          artwork: _auctionArtwork(seller: 'SELLER'),
        ),
        isNull,
      );
    });

    test('unrelated actions never relinquish (null)', () {
      expect(
        settledWonAuctionWinner(
          actionType: 'cancel-auction',
          currentAddress: 'SELLER',
          artwork: _auctionArtwork(currentBidder: 'WINNER', seller: 'SELLER'),
        ),
        isNull,
      );
    });
  });
}
