import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/features/send/widgets/edit_gas_fee_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Replacement mode is what the "Speed up" action opens: the same Edit Gas Fee
/// sheet, re-pointed at an already-broadcast transaction.
///
/// Two invariants make it safe. Every fee the sheet offers must clear the
/// node's 10% bump — a tier quoted below the floor would produce a replacement
/// the network silently refuses, leaving the user convinced they sped a
/// transaction up when nothing changed. And the gas limit must stay the
/// original's: a replacement replays the original payload, which was estimated
/// (and gated) at that exact limit.
void main() {
  final gwei = BigInt.from(1000000000);
  BigInt g(int n) => BigInt.from(n) * gwei;

  // Base fee 10 gwei; Low 10/1, Market 20/2 (maxFee / tip).
  final market = EthGasMarket(
    baseFeeWei: g(10),
    priorityLowWei: g(1),
    priorityHighWei: g(2),
    congestion: 0.2,
    historicalBaseFeeMinWei: g(8),
    historicalBaseFeeMaxWei: g(30),
    historicalPriorityMinWei: g(1),
    historicalPriorityMaxWei: g(3),
    low: EthGasTier(
      mode: EthGasMode.low,
      maxFeePerGas: g(10),
      maxPriorityFeePerGas: g(1),
      minWaitMs: 30000,
      maxWaitMs: 60000,
    ),
    market: EthGasTier(
      mode: EthGasMode.market,
      maxFeePerGas: g(20),
      maxPriorityFeePerGas: g(2),
      minWaitMs: 15000,
      maxWaitMs: 30000,
    ),
  );

  /// Floor from a stuck transaction that already bid far above both tiers.
  late final EvmFeeCaps floor = (
    maxFeePerGas: g(100),
    maxPriorityFeePerGas: g(5),
  );

  const gasLimit = 21000;
  final selection = EthGasSelection.fromTier(market.market, gasLimit: gasLimit);

  setUpAll(() async {
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
  });

  /// Opens the sheet and returns a getter for the selection it pops with.
  Future<EthGasSelection? Function()> openSheet(
    WidgetTester tester, {
    String title = 'Edit Gas Fee',
    EvmFeeCaps? replacementFloor,
  }) async {
    // Phone-sized: the Advanced page's three fields don't fit the default
    // 800×600 test surface.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    EthGasSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showEditGasFeeSheet(
                  context,
                  market: market,
                  selection: selection,
                  estimatedGasUsed: BigInt.from(gasLimit),
                  defaultGasLimit: gasLimit,
                  ethPriceUsd: 2000,
                  title: title,
                  replacementFloor: replacementFloor,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The sheet swallows taps until its entrance animation plus a short settle
    // buffer (a Timer, which pumpAndSettle alone does not advance) has run.
    await tester.pump(const Duration(milliseconds: 200));
    return () => result;
  }

  testWidgets('prices every tier off the floored caps', (tester) async {
    await openSheet(tester, replacementFloor: floor);

    // Both tiers are floored to a 5 gwei tip, so both are expected to pay
    // base (10) + tip (5) = 15 gwei → 21 000 × 15 gwei = 0.000315 ETH.
    expect(find.text('0.000315 ETH'), findsNWidgets(2));
    // The un-floored quotes: Low is capped at its own 10 gwei max fee, Market
    // pays base (10) + tip (2).
    expect(find.text('0.00021 ETH'), findsNothing);
    expect(find.text('0.000252 ETH'), findsNothing);
  });

  testWidgets('applies the floor to the fee it returns', (tester) async {
    final result = await openSheet(tester, replacementFloor: floor);

    await tester.tap(find.text('Market'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final applied = result();
    expect(applied, isNotNull);
    expect(applied!.maxFeePerGas, g(100));
    expect(applied.maxPriorityFeePerGas, g(5));
    expect(applied.gasLimit, gasLimit);
  });

  testWidgets('leaves the tiers alone without a floor', (tester) async {
    await openSheet(tester);

    expect(find.text('0.00021 ETH'), findsOneWidget);
    expect(find.text('0.000252 ETH'), findsOneWidget);
  });

  testWidgets('takes the caller\'s title', (tester) async {
    await openSheet(
      tester,
      title: 'Speed Up Transaction',
      replacementFloor: floor,
    );

    expect(find.text('Speed Up Transaction'), findsOneWidget);
    expect(find.text('Edit Gas Fee'), findsNothing);
  });

  testWidgets('shows a loading state before the fee market is ready', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final preparation = Completer<EditGasFeeSheetData>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                unawaited(
                  showEditGasFeeSheetLoading(
                    context,
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
    expect(find.text('Market'), findsNothing);

    preparation.complete(
      EditGasFeeSheetData(
        market: market,
        selection: selection,
        estimatedGasUsed: BigInt.from(gasLimit),
        defaultGasLimit: gasLimit,
        ethPriceUsd: 2000,
        title: 'Speed Up Transaction',
        replacementFloor: floor,
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Market'), findsOneWidget);
  });

  testWidgets('hides the gas-limit control in replacement mode', (
    tester,
  ) async {
    await openSheet(tester, replacementFloor: floor);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Advanced Gas Fee'), findsOneWidget);
    expect(find.text('Max base fee'), findsOneWidget);
    expect(find.text('Gas limit'), findsNothing);
  });

  testWidgets('still offers the gas-limit control for an unsent transaction', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(find.text('Gas limit'), findsOneWidget);
  });

  // WHY (funds/UX loss): the Advanced page keeps its text controllers alive when
  // the user backs out with the arrow instead of applying. If a preset tier read
  // the gas limit from that controller, an abandoned "5000000" would ride along
  // with Low/Market — and downstream only limits that are too *low* get floored,
  // so the inflated one is signed verbatim: a previously-fine native send fails
  // the `value + gasLimit × maxFeePerGas` budget check, and an ERC-20 / NFT
  // transfer is signed against a nonsense limit. Only an applied Advanced edit
  // may change the limit.
  testWidgets('preset tiers ignore an abandoned Advanced gas limit', (
    tester,
  ) async {
    final result = await openSheet(tester);

    // Enter Advanced, type an inflated gas limit, then leave via the back arrow
    // — no Done, so nothing was applied.
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, gasLimit.toString()),
      '5000000',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is MallowSvgIcon && w.assetPath == 'assets/icons/arrow_left.svg',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit Gas Fee'), findsOneWidget);

    // Pick a preset and apply it.
    await tester.tap(find.text('Market'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final applied = result();
    expect(applied, isNotNull);
    expect(applied!.mode, EthGasMode.market);
    expect(applied.gasLimit, gasLimit);
  });

  testWidgets('an applied Advanced edit still carries its gas limit', (
    tester,
  ) async {
    final result = await openSheet(tester);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, gasLimit.toString()),
      '90000',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final applied = result();
    expect(applied, isNotNull);
    expect(applied!.mode, EthGasMode.custom);
    expect(applied.gasLimit, 90000);
  });

  testWidgets('seeds the Advanced fields with floored values', (tester) async {
    await openSheet(tester, replacementFloor: floor);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    // maxFee 100 gwei − 5 gwei tip = 95 gwei of max base fee.
    expect(find.widgetWithText(TextField, '95'), findsOneWidget);
    expect(find.widgetWithText(TextField, '5'), findsOneWidget);
  });
}
