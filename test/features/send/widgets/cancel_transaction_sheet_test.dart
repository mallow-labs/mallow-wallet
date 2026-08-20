import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/widgets/cancel_transaction_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';

/// The Cancel Transaction sheet is the last stop before the user pays a second
/// fee on a transaction they already paid for, so three things are contractual
/// rather than cosmetic:
///
///  * the fee it quotes is the real worst case (21 000 gas × the cap the cancel
///    will be signed with) — quote it low and the user consents to a cost they
///    didn't see;
///  * there is no wallet switcher — only the wallet holding the stuck nonce can
///    replace it, so offering another wallet offers something that cannot work;
///  * Confirm is unavailable when the balance can't cover that fee — starting a
///    cancel that the node will reject leaves the user stuck *and* confused.
void main() {
  final gwei = BigInt.from(1000000000);

  // 21 000 × 2 gwei = 0.000042 ETH; at $2 000/ETH that is $0.08.
  final maxFeePerGas = BigInt.two * gwei;
  final feeWei = BigInt.from(21000) * maxFeePerGas;

  Future<void> pump(
    WidgetTester tester, {
    required BigInt balanceWei,
    double? ethPriceUsd = 2000,
    bool feeMayIncrease = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: CancelTransactionSheet(
            walletAddress: '0x3ka1F2eb0d8fD6cB2Ff1a7bF83b1c7B0912em4K',
            maxFeePerGas: maxFeePerGas,
            balanceWei: balanceWei,
            ethPriceUsd: ethPriceUsd,
            feeMayIncrease: feeMayIncrease,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  MallowButton confirmButton(WidgetTester tester) =>
      tester.widget<MallowButton>(
        find.byWidgetPredicate(
          (w) => w is MallowButton && w.label == 'Confirm',
        ),
      );

  testWidgets('quotes 21000 × the cancel fee cap in ETH and USD', (
    tester,
  ) async {
    await pump(tester, balanceWei: feeWei * BigInt.two);

    expect(find.text('Fee'), findsOneWidget);
    expect(find.text('0.000042 ETH'), findsOneWidget);
    expect(find.text(r'~$0.08'), findsOneWidget);
  });

  testWidgets(
    'offers no wallet switch — only the stuck nonce owner can replace it',
    (tester) async {
      await pump(tester, balanceWei: feeWei * BigInt.two);

      expect(find.textContaining('Your wallet'), findsOneWidget);
      expect(find.text('0x3ka…2em4K'), findsOneWidget);
      expect(find.text('Switch'), findsNothing);
    },
  );

  testWidgets('disables Confirm when the balance cannot cover the fee', (
    tester,
  ) async {
    await pump(tester, balanceWei: feeWei - BigInt.one);

    expect(
      find.text('Not enough ETH to pay the cancellation fee.'),
      findsOneWidget,
    );
    expect(confirmButton(tester).enabled, isFalse);
  });

  testWidgets('enables Confirm once the balance exactly covers the fee', (
    tester,
  ) async {
    await pump(tester, balanceWei: feeWei);

    expect(
      find.text('Not enough ETH to pay the cancellation fee.'),
      findsNothing,
    );
    expect(confirmButton(tester).enabled, isTrue);
  });

  testWidgets('warns that a blind cancel may cost more than quoted', (
    tester,
  ) async {
    await pump(tester, balanceWei: feeWei * BigInt.two, feeMayIncrease: true);

    expect(find.textContaining('may adjust upward'), findsOneWidget);
  });

  testWidgets('drops the USD line when no ETH price is available', (
    tester,
  ) async {
    await pump(tester, balanceWei: feeWei * BigInt.two, ethPriceUsd: null);

    expect(find.text('0.000042 ETH'), findsOneWidget);
    expect(find.textContaining(r'~$'), findsNothing);
  });

  testWidgets('shows a loading state before the fee quote is ready', (
    tester,
  ) async {
    final preparation = Completer<CancelTransactionSheetData>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                unawaited(
                  showCancelTransactionSheetLoading(
                    context,
                    walletAddress: '0x3ka1F2eb0d8fD6cB2Ff1a7bF83b1c7B0912em4K',
                    preparation: preparation.future,
                    onPreparationError: (_) {},
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Fee'), findsNothing);

    preparation.complete(
      CancelTransactionSheetData(
        maxFeePerGas: maxFeePerGas,
        balanceWei: feeWei,
        ethPriceUsd: 2000,
        caps: (maxFeePerGas: maxFeePerGas, maxPriorityFeePerGas: maxFeePerGas),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Fee'), findsOneWidget);
  });
}
