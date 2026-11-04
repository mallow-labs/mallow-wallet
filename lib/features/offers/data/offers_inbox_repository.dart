import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../models/bid_refund_balance.dart';
import '../models/bid_refund_deposit.dart';

/// Reads the aggregated active offers + auction bids the session is involved
/// in via `POST /v2/offers/inbox` — both received (on the viewer's art) and
/// placed (by the viewer), across every wallet in [owners]. Backs the Offers
/// screen.
@lazySingleton
class OffersInboxRepository {
  OffersInboxRepository(this._apiV2);

  final api.MallowApiV2Client _apiV2;

  /// Runs only when the user opens deposit recovery, independently of the inbox.
  Future<List<BidRefundDeposit>> getBidRefundDeposits(
    Iterable<String> solanaOwners,
  ) async {
    final results = await Future.wait(
      solanaOwners.where((owner) => owner.isNotEmpty).toSet().map((
        payer,
      ) async {
        final response = await _apiV2.getBidRefundClaims(payer);
        return response.result.claims
            .where(
              (claim) =>
                  claim.rentPayer == payer &&
                  (claim.closable || claim.releasable == true),
            )
            .map(
              (claim) => BidRefundDeposit(
                claim: claim.claim,
                rentPayer: payer,
                bidder: claim.bidder,
                amount: claim.amount,
                mint: claim.mint,
                closable: claim.closable,
                releasable: claim.releasable == true,
              ),
            );
      }),
    );
    return {
      for (final deposit in results.expand((items) => items))
        deposit.claim: deposit,
    }.values.toList();
  }

  /// One page of the merged, recency-sorted feed. [owners] is every session
  /// wallet address. [sort] defaults to latest-first.
  Future<api.OffersInboxPage> getInbox({
    required Iterable<String> owners,
    api.OffersInboxSort sort = api.OffersInboxSort.latest,
    int page = 0,
    int pageSize = 30,
  }) async {
    final response = await _apiV2.getOffersInbox(
      api.GetOffersInboxRequest(
        owners: owners.where((a) => a.isNotEmpty).toSet().toList(),
        sort: sort,
        page: page,
        pageSize: pageSize,
      ),
    );
    return response.result;
  }

  /// Queries every Solana wallet once, including bidders whose auctions closed.
  Future<List<BidRefundBalance>> getBidRefunds(
    Iterable<String> solanaOwners,
  ) async {
    final results = await Future.wait(
      solanaOwners.where((owner) => owner.isNotEmpty).toSet().map((
        bidder,
      ) async {
        final response = await _apiV2.getBidRefunds(bidder);
        return response.result.refunds.map(
          (refund) => BidRefundBalance(bidder: bidder, refund: refund),
        );
      }),
    );
    return results.expand((balances) => balances).toList();
  }
}
