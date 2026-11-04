import 'package:mallow_api/mallow_api.dart' as api;

/// A live currency refund scoped to one session bidder, independent of artwork.
class BidRefundBalance {
  const BidRefundBalance({required this.bidder, required this.refund});
  final String bidder;
  final api.BidRefund refund;
}
