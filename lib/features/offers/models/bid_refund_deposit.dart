import '../../../core/data/mallow_tokens.dart';

/// A sponsored refund claim whose SOL deposit can return to its rent payer.
class BidRefundDeposit {
  const BidRefundDeposit({
    required this.claim,
    required this.rentPayer,
    this.bidder = '',
    this.amount = '0',
    this.mint = solMint,
    this.closable = true,
    this.releasable = false,
    this.destination,
  });

  final String claim;
  final String rentPayer;
  final String bidder;
  final String amount;
  final String mint;

  bool get isSol => mint == solMint;
  final bool closable;

  /// Whether the backend can release the recorded debt to the bidder.
  final bool releasable;
  final String? destination;

  bool get needsRelease => !closable;

  BidRefundDeposit withDestination(String? destination) => BidRefundDeposit(
    claim: claim,
    rentPayer: rentPayer,
    bidder: bidder,
    amount: amount,
    mint: mint,
    closable: closable,
    releasable: releasable,
    destination: destination == null || destination.trim().isEmpty
        ? null
        : destination.trim(),
  );
}
