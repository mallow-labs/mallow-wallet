import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/features/send/widgets/edit_gas_fee_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final market = EthGasMarket.fromSuggestedGasFees(const {
    'estimatedBaseFee': '10',
    'low': {
      'suggestedMaxFeePerGas': '12',
      'suggestedMaxPriorityFeePerGas': '1',
    },
    'medium': {
      'suggestedMaxFeePerGas': '20',
      'suggestedMaxPriorityFeePerGas': '2',
    },
  });
  final seed = EthGasSelection(
    mode: EthGasMode.custom,
    maxFeePerGas: BigInt.parse('9000000000001'),
    maxPriorityFeePerGas: BigInt.parse('2000000003'),
    gasLimit: 500000,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sl.registerSingleton<PreferencesService>(await PreferencesService.create());
  });
  tearDown(() => sl.unregister<PreferencesService>());

  Future<EthGasSelection? Function()> openAdvanced(
    WidgetTester tester, {
    bool persist = true,
    EvmFeeCaps? replacementFloor,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
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
                  selection: seed,
                  estimatedGasUsed: BigInt.from(21000),
                  defaultGasLimit: 25200,
                  persist: persist,
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
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    return () => result;
  }

  for (final persist in [false, true]) {
    testWidgets('a gas-limit-only edit preserves exact fee caps '
        'with persist=$persist', (tester) async {
      final result = await openAdvanced(tester, persist: persist);
      expect(find.widgetWithText(TextField, '8998'), findsOneWidget);
      expect(find.widgetWithText(TextField, '2'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '500000'), '30000');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result()!.maxFeePerGas, seed.maxFeePerGas);
      expect(result()!.maxPriorityFeePerGas, seed.maxPriorityFeePerGas);
      expect(result()!.gasLimit, 30000);
      expect(result()!.mode, EthGasMode.custom);
      expect(sl<PreferencesService>().ethGasMode, persist ? 'custom' : isNull);
    });
  }

  for (final editBase in [false, true]) {
    testWidgets('editing ${editBase ? 'base' : 'priority'} fee preserves '
        'the untouched fee field exactly', (tester) async {
      final result = await openAdvanced(tester, persist: false);
      await tester.enterText(
        find.widgetWithText(TextField, editBase ? '8998' : '2'),
        editBase ? '8000' : '3',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final priority = editBase
          ? seed.maxPriorityFeePerGas
          : EthGasMarket.gweiToWei(3);
      final base = editBase
          ? EthGasMarket.gweiToWei(8000)
          : seed.maxFeePerGas - seed.maxPriorityFeePerGas;
      expect(result()!.maxFeePerGas, base + priority);
      expect(result()!.maxPriorityFeePerGas, priority);
      expect(result()!.gasLimit, seed.gasLimit);
    });
  }

  testWidgets('an untouched replacement preserves exact floored caps', (
    tester,
  ) async {
    final floor = (
      maxFeePerGas: seed.maxFeePerGas + BigInt.one,
      maxPriorityFeePerGas: seed.maxPriorityFeePerGas + BigInt.one,
    );
    final result = await openAdvanced(tester, replacementFloor: floor);
    expect(find.text('Gas limit'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(result()!.maxFeePerGas, floor.maxFeePerGas);
    expect(result()!.maxPriorityFeePerGas, floor.maxPriorityFeePerGas);
    expect(result()!.gasLimit, 25200);
    expect(sl<PreferencesService>().ethGasMode, isNull);
  });
}
