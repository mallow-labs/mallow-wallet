import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/data/auction_live_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_account_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_action_state.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements MallowApiClient {}

class _MockApiV2 extends Mock implements MallowApiV2Client {}

void main() {
  const mint = 'So11111111111111111111111111111111111111112';
  const defaultBidder = '11111111111111111111111111111111';

  for (final hasBids in [false, true]) {
    test(
      'indexed unlisted refund reaches the action resolver with bids=$hasBids',
      () async {
        final api = _MockApi();
        when(() => api.getArtworkByMint(mint)).thenAnswer(
          (_) async => ApiResponse(
            result: ArtworkResult.fromJson({
              'item': {
                'mintAccount': mint,
                'name': 'Artwork',
                'listingType': 'unlisted',
                'auctionMetadata': {
                  'refunded': true,
                  'auctionAccount': 'auction',
                  'currentBidAmount': hasBids ? 1000000000 : null,
                  'currentBidder': hasBids ? 'bidder' : null,
                  'bidCount': hasBids ? 1 : 0,
                },
              },
            }),
          ),
        );
        final details = await ArtworkRepository(api).getArtworkDetail(mint);
        expect(details.auctionMetadata!.refunded, isTrue);
        expect(
          resolveArtworkActionState(
            artwork: details,
            currentAddress: null,
            creatorLinkedAddresses: const {},
            permissions: null,
          ),
          isA<ArtworkAuctionRefundedAction>(),
        );
        verify(() => api.getArtworkByMint(mint)).called(1);
      },
    );
  }

  for (final envelope in [false, true]) {
    for (final refunded in [null, false, true]) {
      test(
        'live refund=$refunded survives decode, envelope=$envelope',
        () async {
          final api = _MockApiV2();
          final auction = <String, dynamic>{
            'auctionAccount': 'auction',
            'seller': 'seller',
            'bidMint': mint,
            'reservePrice': 0,
            'currentBidAmount': 0,
            'currentBidder': defaultBidder,
            'refunded': ?refunded,
          };
          when(() => api.getAuctionState(mint)).thenAnswer(
            (_) async => ApiResponse(
              result: RawAccountRecord(
                envelope ? {'viewSlot': 500, 'auction': auction} : auction,
              ),
            ),
          );
          final state = await AuctionLiveRepository(api).getState(mint);
          expect(state, isNotNull);
          expect(state!.refunded, refunded ?? false);
          verify(() => api.getAuctionState(mint)).called(1);
        },
      );

      test(
        'raw no-bid refund=$refunded survives decode, envelope=$envelope',
        () async {
          final api = _MockApiV2();
          final account = <String, dynamic>{
            'accountType': 'auctionConfig',
            'pubkey': 'auction',
            'highestBidAmount': '0',
            'highestBidder': defaultBidder,
            'cnftRefunded': ?refunded,
          };
          when(
            () => api.getProgramAccount('auction', 'auction-config', any()),
          ).thenAnswer(
            (_) async => ApiResponse(
              result: RawAccountRecord(
                envelope ? {'viewSlot': 500, 'account': account} : account,
              ),
            ),
          );
          final read = await MarketAccountRepository(
            api,
          ).readAuctionConfig(mint);
          expect(read.status, OnChainReadStatus.present);
          expect(read.account!.cnftRefunded, refunded ?? false);
          expect(read.account!.highestBidder, isNull);
          expect(read.viewSlot, envelope ? 500 : null);
          verify(
            () => api.getProgramAccount('auction', 'auction-config', read.pda),
          ).called(1);
        },
      );
    }
  }
}
