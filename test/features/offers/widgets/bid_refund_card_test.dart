import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/utils/price_formatter.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_balance.dart';
import 'package:mallow_wallet/features/offers/widgets/bid_refund_card.dart';

void main() {
  for (final input in [null, '', '   ']) {
    testWidgets(
      'Given a token refund, When destination is $input, Then uses automatic recovery and explains account rent',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final destinations = <String?>[];
        const balance = BidRefundBalance(
          bidder: 'BIDDER',
          refund: api.BidRefund(
            claim: 'CLAIM',
            mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
            amount: '2000000',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BidRefundCard(
                balance: balance,
                onWithdraw: destinations.add,
              ),
            ),
          ),
        );
        expect(
          find.text(
            'Leave blank: mallow uses your usual token account or creates a new one if it is blocked. You pay the new account’s rent.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Alternative token account (optional)'),
          findsOneWidget,
        );
        if (input != null) {
          await tester.enterText(
            find.byKey(const ValueKey('refund-destination-CLAIM')),
            input,
          );
        }
        await tester.tap(find.byKey(const ValueKey('withdraw-refund-CLAIM')));
        expect(destinations, [null]);
      },
    );
  }
  testWidgets(
    'Given a live refund, shows withdraw and preserves an alternative destination',
    (tester) async {
      String? destination;
      var tapped = false;
      const balance = BidRefundBalance(
        bidder: 'BIDDER',
        refund: api.BidRefund(
          claim: 'CLAIM',
          mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
          amount: '2000000',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidRefundCard(
              balance: balance,
              onWithdraw: (value) {
                tapped = true;
                destination = value;
              },
            ),
          ),
        ),
      );
      expect(find.text('Refund available to withdraw'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('refund-destination-CLAIM')),
        ' ALTERNATIVE ',
      );
      await tester.tap(find.byKey(const ValueKey('withdraw-refund-CLAIM')));
      expect(tapped, isTrue);
      expect(destination, 'ALTERNATIVE');
    },
  );
  testWidgets(
    'Given a SOL refund, When withdrawing, Then returns only to the bidder wallet',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final destinations = <String?>[];
      const balance = BidRefundBalance(
        bidder: 'BIDDER',
        refund: api.BidRefund(
          claim: 'SOL_CLAIM',
          mint: PriceFormatter.solMint,
          amount: '2000000000',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidRefundCard(balance: balance, onWithdraw: destinations.add),
          ),
        ),
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Alternative token account (optional)'), findsNothing);
      expect(find.text('Withdraw SOL to your wallet.'), findsOneWidget);
      final withdraw = find.byKey(const ValueKey('withdraw-refund-SOL_CLAIM'));
      await tester.tap(withdraw);
      expect(destinations, [null]);
    },
  );
  testWidgets(
    'Given an entered token destination, When the card changes to SOL, Then withdraws to the bidder wallet',
    (tester) async {
      final destinations = <String?>[];
      Future<void> showBalance(String mint) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidRefundCard(
              balance: BidRefundBalance(
                bidder: 'BIDDER',
                refund: api.BidRefund(claim: 'CLAIM', mint: mint, amount: '42'),
              ),
              onWithdraw: destinations.add,
            ),
          ),
        ),
      );
      await showBalance('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');
      await tester.enterText(
        find.byKey(const ValueKey('refund-destination-CLAIM')),
        'ALTERNATIVE',
      );
      await showBalance(PriceFormatter.solMint);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('withdraw-refund-CLAIM')));
      expect(destinations, [null]);
    },
  );
}
