import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/priority_fee_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockPrefs extends Mock implements PreferencesService {}

class _MockPrices extends Mock implements TokenPriceService {}

void main() {
  late _MockPrefs prefs;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  setUp(() {
    prefs = _MockPrefs();
    when(() => prefs.priorityFeeLamports).thenReturn(null);
    when(() => prefs.swapPriorityFeeLamports).thenReturn(null);
    when(() => prefs.clearGeneration).thenReturn(ValueNotifier<int>(0));
    when(() => prefs.setPriorityFeeLamports(any())).thenAnswer((_) async {});

    final prices = _MockPrices();
    when(() => prices.priceOf(any())).thenReturn(null);

    register<PreferencesService>(prefs);
    register<PriorityFeeService>(PriorityFeeService(prefs));
    register<TokenPriceService>(prices);
  });

  tearDown(() {
    sl.unregister<PreferencesService>();
    sl.unregister<PriorityFeeService>();
    sl.unregister<TokenPriceService>();
  });

  // The custom field is the only text input on a screen that commits as you
  // type: with no Done button, the keyboard's own action key is the only way
  // out of it, so it has to both persist the value and dismiss the keyboard.
  testWidgets('the number pad action key commits and dismisses the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PriorityFeeScreen()));

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '0.002');
    await tester.pump();
    expect(
      tester.testTextInput.isVisible,
      isTrue,
      reason: 'sanity: the keyboard is up while typing',
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: 'the action key must close the keyboard, not just commit',
    );
    verify(() => prefs.setPriorityFeeLamports(2000000)).called(1);
  });
}
