import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_deposit.dart';
import 'package:mallow_wallet/features/offers/widgets/bid_refund_deposits_sheet.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';

void main() {
  const deposit = BidRefundDeposit(claim: 'CLAIM', rentPayer: 'PAYER');

  Future<void> showSheet(
    WidgetTester tester,
    Future<List<BidRefundDeposit>> Function() load,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BidRefundDepositsSheet(loadDeposits: load)),
      ),
    );
  }

  testWidgets('pending read shows loading until empty deposits are confirmed', (
    tester,
  ) async {
    final pending = Completer<List<BidRefundDeposit>>();
    await showSheet(tester, () => pending.future);
    expect(find.byType(MallowLoader), findsOneWidget);
    expect(find.text('No deposits are ready to recover.'), findsNothing);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.byType(MallowLoader), findsNothing);
    expect(find.text('No deposits are ready to recover.'), findsOneWidget);
  });

  testWidgets('read failure stays visible and retry can discover a deposit', (
    tester,
  ) async {
    var calls = 0;
    await showSheet(tester, () async {
      if (++calls == 1) throw Exception('Deposit read unavailable');
      return [deposit];
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Deposit read unavailable'), findsOneWidget);
    expect(find.text('No deposits are ready to recover.'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recover-deposit-CLAIM')), findsOneWidget);
    expect(find.textContaining('Deposit read unavailable'), findsNothing);
    expect(calls, 2);
  });

  testWidgets('completed read after dismissal is harmless', (tester) async {
    final pending = Completer<List<BidRefundDeposit>>();
    await showSheet(tester, () => pending.future);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([deposit]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'outstanding SOL shows release with bidder and fee explanation alongside recovery',
    (tester) async {
      await showSheet(
        tester,
        () async => [
          deposit,
          const BidRefundDeposit(
            claim: 'PENDING',
            rentPayer: 'PAYER',
            bidder: 'BIDDER',
            amount: '42',
            closable: false,
            releasable: true,
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recover-deposit-CLAIM')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('release-sol-refund-PENDING')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recover-deposit-PENDING')),
        findsNothing,
      );
      expect(
        find.textContaining('Refund goes to bidder BIDDER'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Availability can change before confirmation.'),
        findsOneWidget,
      );
      expect(find.textContaining('try again later'), findsNothing);
    },
  );
  testWidgets(
    'token release discloses account rent and an alternate bidder-owned destination',
    (tester) async {
      await showSheet(
        tester,
        () async => [
          const BidRefundDeposit(
            claim: 'TOKEN',
            rentPayer: 'PAYER',
            bidder: 'BIDDER',
            amount: '42',
            mint: 'TOKEN_MINT',
            closable: false,
            releasable: true,
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('release-token-refund-TOKEN')),
        findsOneWidget,
      );
      expect(find.text('Release token refund'), findsOneWidget);
      expect(
        find.textContaining('rent for any new token account'),
        findsOneWidget,
      );
      expect(
        find.textContaining('another usable token account owned by the bidder'),
        findsOneWidget,
      );
      expect(find.text('Recover deposit'), findsNothing);
      expect(
        find.byKey(const ValueKey('release-destination-TOKEN')),
        findsOneWidget,
      );
      expect(
        find.text('Leave blank to choose an account automatically.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('That rent belongs to the bidder.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'releasable token refund permits automatic or optional bidder-owned destination',
    (tester) async {
      await showSheet(
        tester,
        () async => [
          const BidRefundDeposit(
            claim: 'RELEASABLE',
            rentPayer: 'PAYER',
            bidder: 'BIDDER',
            mint: 'TOKEN_MINT',
            amount: '42',
            closable: false,
            releasable: true,
          ),
        ],
      );
      await tester.pumpAndSettle();
      final button = find.byKey(
        const ValueKey('release-token-refund-RELEASABLE'),
      );
      expect(tester.widget<MallowButton>(button).onPressed, isNotNull);
      expect(find.text('Bidder token account (optional)'), findsOneWidget);
      expect(
        find.textContaining('Their usual account is blocked.'),
        findsNothing,
      );
      final input = find.byKey(
        const ValueKey('release-destination-RELEASABLE'),
      );
      await tester.enterText(input, '   ');
      await tester.pump();
      expect(tester.widget<MallowButton>(button).onPressed, isNotNull);
      await tester.enterText(input, ' ALTERNATIVE ');
      await tester.pump();
      expect(tester.widget<MallowButton>(button).onPressed, isNotNull);
      await tester.enterText(input, '');
      await tester.pump();
      expect(tester.widget<MallowButton>(button).onPressed, isNotNull);
    },
  );
}
