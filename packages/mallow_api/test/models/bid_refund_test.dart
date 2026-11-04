import 'dart:convert';
import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  test('Given an older claim, release defaults off; current claims preserve releasability', () {
    final json = {
      'claim': 'CLAIM',
      'bidder': 'BIDDER',
      'mint': 'SOL',
      'rentPayer': 'PAYER',
      'amount': '42',
      'closable': false,
    };
    expect(BidRefundClaim.fromJson(json).releasable, isFalse);
    expect(BidRefundClaim.fromJson({...json, 'releasable': true}).releasable, isTrue);
  });

  test('withdraw binds bidder/currency/destination with camelCase priority fees', () {
    final wire =
        jsonDecode(
              jsonEncode(
                const WithdrawBidRefundTxRequest(
                  bidder: 'BIDDER',
                  mint: 'CURRENCY',
                  destination: 'ALTERNATIVE',
                  targetPriorityFeeLamports: 5000,
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(wire['bidder'], 'BIDDER');
    expect(wire['mint'], 'CURRENCY');
    expect(wire['destination'], 'ALTERNATIVE');
    expect(wire['targetPriorityFeeLamports'], 5000);
    expect(wire.containsKey('target_priority_fee_lamports'), isFalse);
  });
  test('refund balance stays an exact decimal string including full u64 values', () {
    final response = BidRefundsResponse.fromJson({
      'refunds': [
        {'claim': 'CLAIM', 'mint': 'CURRENCY', 'amount': '18446744073709551615'},
      ],
    });
    expect(response.refunds.single.amount, '18446744073709551615');
  });
  test('deposit recovery serializes the recorded rent payer and claim in camelCase', () {
    final wire =
        jsonDecode(
              jsonEncode(
                const CloseBidRefundClaimTxRequest(
                  rentPayer: 'PAYER',
                  claim: 'CLAIM',
                  targetPriorityFeeLamports: 5000,
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(wire['rentPayer'], 'PAYER');
    expect(wire['claim'], 'CLAIM');
    expect(wire['targetPriorityFeeLamports'], 5000);
    expect(wire.containsKey('rent_payer'), isFalse);
    expect(wire.containsKey('target_priority_fee_lamports'), isFalse);
    expect(wire.containsKey('bidder'), isFalse);
  });

  test('rent-payer discovery preserves closability and exact refund amounts', () {
    final claims = BidRefundClaimsResponse.fromJson({
      'claims': [
        {
          'claim': 'CLAIM',
          'bidder': 'BIDDER',
          'mint': 'MINT',
          'rentPayer': 'PAYER',
          'amount': '18446744073709551615',
          'closable': false,
        },
      ],
    }).claims;
    expect(claims.single.rentPayer, 'PAYER');
    expect(claims.single.bidder, 'BIDDER');
    expect(claims.single.closable, isFalse);
    expect(claims.single.amount, '18446744073709551615');
  });
}
