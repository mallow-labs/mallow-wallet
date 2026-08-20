import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/features/swap/widgets/swap_settings_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockTokenPriceService extends Mock implements TokenPriceService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferencesService prefs;
  late PriorityFeeService priorityFee;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final getIt = GetIt.I;

    prefs = await PreferencesService.create();
    if (getIt.isRegistered<PreferencesService>()) {
      await getIt.unregister<PreferencesService>();
    }
    getIt.registerSingleton<PreferencesService>(prefs);

    priorityFee = PriorityFeeService(prefs);
    if (getIt.isRegistered<PriorityFeeService>()) {
      await getIt.unregister<PriorityFeeService>();
    }
    getIt.registerSingleton<PriorityFeeService>(priorityFee);

    final priceService = _MockTokenPriceService();
    when(() => priceService.priceOf(any())).thenReturn(100);
    if (getIt.isRegistered<TokenPriceService>()) {
      await getIt.unregister<TokenPriceService>();
    }
    getIt.registerSingleton<TokenPriceService>(priceService);
  });

  tearDown(() async {
    final getIt = GetIt.I;
    if (getIt.isRegistered<PreferencesService>()) {
      await getIt.unregister<PreferencesService>();
    }
    if (getIt.isRegistered<PriorityFeeService>()) {
      await getIt.unregister<PriorityFeeService>();
    }
    if (getIt.isRegistered<TokenPriceService>()) {
      await getIt.unregister<TokenPriceService>();
    }
  });

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSwapSettingsSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // showMallowSheet swallows taps until a settle buffer elapses after the
    // entrance animation — that timer outlives pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 200));
  }

  // The caller re-quotes off the persisted values (SwapBloc.settingsChanged
  // reads them back from preferences), so anything the user commits to has to
  // be written before the sheet goes away — including on the dismissal paths
  // that never reach "Done". A value that survives only the Done path silently
  // sends the swap out at the old slippage / priority fee.
  group(
    'persists on dismissal so the caller re-quotes with the new values',
    () {
      testWidgets('custom priority fee entered on the subpage', (tester) async {
        await openSheet(tester);

        await tester.tap(find.text('Priority Fee'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Custom'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '0.001');
        await tester.pumpAndSettle();

        // Dismiss via the barrier from the subpage — no Done tap.
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // This sheet owns the swap-specific override only: the general
        // Settings → Priority Fee value must not move, or a fee raised to
        // force one swap through would silently re-price every send.
        expect(prefs.swapPriorityFeeLamports, 1000000);
        expect(prefs.priorityFeeLamports, isNull);
        expect(priorityFee.routerLamports, 1000000);
        expect(priorityFee.ceilingLamports, kAutoPriorityFeeLamports);
      });

      testWidgets('slippage preset picked on the subpage', (tester) async {
        await openSheet(tester);

        await tester.tap(find.text('Slippage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1%'));
        await tester.pumpAndSettle();

        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        expect(prefs.swapSlippageBps, 100);
      });
    },
  );

  testWidgets('an unset priority fee stays Auto', (tester) async {
    await openSheet(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(prefs.swapPriorityFeeLamports, isNull);
    expect(prefs.priorityFeeLamports, isNull);
    expect(priorityFee.routerLamports, isNull);
    expect(priorityFee.isAuto, isTrue);
    expect(prefs.swapSlippageBps, isNull);
  });
}
