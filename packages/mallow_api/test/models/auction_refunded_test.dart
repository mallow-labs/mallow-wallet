import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_api/src/generated/openapi.models.swagger.dart' as generated;
import 'package:test/test.dart';

void main() {
  test('generated auction schemas preserve the explicit refund field', () {
    final indexed = generated.NftPreviewAuctionMetadata.fromJson({
      'refunded': true,
      'mintAccount': 'mint',
      'reservePrice': 0,
      'bidders': <String>[],
      'bidCount': 0,
      'bidMint': 'SOL',
    });
    final live = generated.GetAuctionStateResponse.fromJson({
      'refunded': true,
      'auctionAccount': 'auction',
      'seller': 'seller',
      'bidMint': 'SOL',
      'reservePrice': 0,
      'bidCount': 0,
      'isSettled': false,
    });
    expect(indexed.toJson()['refunded'], isTrue);
    expect(live.toJson()['refunded'], isTrue);
  });
  test('generated raw auction account preserves the explicit refund field', () {
    final json = <String, dynamic>{
      'accountType': 'auctionConfig',
      'bump': 255,
      'version': 1,
      'marketplaceAuthority': 'authority',
      'seller': 'seller',
      'mint': 'mint',
      'bidMint': 'SOL',
      'startTime': 0,
      'endTime': 0,
      'highestBidAmount': '0',
      'highestBidder': '11111111111111111111111111111111',
      'reservePrice': '0',
      'duration': 0,
      'minBidIncrementBps': 0,
      'timeExtPeriod': 0,
      'timeExtDelta': 0,
      'feeAccount': 'fees',
      'feeBps': 0,
      'pausedAt': 0,
      'burnOnComplete': false,
      'buyerAck': false,
      'sellerAck': false,
      'tokenStandard': 3,
      'minBidIncrement': '0',
      'absoluteIncrement': false,
      'disablePrimarySplit': false,
      'hasFeeOverride': false,
      'overrideFeeBps': 0,
      'pubkey': 'auction',
      'program': 'mallow-auction',
    };
    for (final refunded in [false, true]) {
      final account = generated.AuctionConfigAccount.fromJson({...json, 'cnftRefunded': refunded});
      expect(account.toJson()['cnftRefunded'], refunded);
    }
  });
  test('indexed auction preserves refunded and defaults older payloads', () {
    expect(AuctionMetadata.fromJson({'refunded': true}).refunded, isTrue);
    expect(AuctionMetadata.fromJson({}).refunded, isFalse);
    expect(const AuctionMetadata(refunded: true).toJson()['refunded'], isTrue);
  });
  test('live auction preserves terminal state when backend exposes it', () {
    final json = {
      'auctionAccount': 'auction',
      'seller': 'seller',
      'bidMint': 'SOL',
      'reservePrice': 0,
    };
    expect(AuctionLiveState.fromJson({...json, 'refunded': true}).refunded, isTrue);
    expect(AuctionLiveState.fromJson(json).refunded, isFalse);
  });
}
