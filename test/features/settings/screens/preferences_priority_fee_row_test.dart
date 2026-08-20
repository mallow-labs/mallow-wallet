import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/preferences_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockPrefs extends Mock implements PreferencesService {}

void main() {
  late _MockPrefs prefs;
  late PriorityFeeService service;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  void pumpWith(int? lamports) {
    when(() => prefs.priorityFeeLamports).thenReturn(lamports);
    service = PriorityFeeService(prefs);
    register<PriorityFeeService>(service);
  }

  setUp(() {
    prefs = _MockPrefs();
    when(() => prefs.priorityFeeLamports).thenReturn(null);
    when(() => prefs.swapPriorityFeeLamports).thenReturn(null);
    when(() => prefs.clearGeneration).thenReturn(ValueNotifier<int>(0));
    when(() => prefs.showNsfwNotifier).thenReturn(ValueNotifier<bool>(true));
    when(() => prefs.setPriorityFeeLamports(any())).thenAnswer((_) async {});

    register<PreferencesService>(prefs);
    pumpWith(null);
  });

  tearDown(() {
    sl.unregister<PreferencesService>();
    sl.unregister<PriorityFeeService>();
  });

  // The row is the only place the selection is visible without opening the
  // sub-screen, so "Auto" has to be a shown state, not an empty one.
  testWidgets('Auto renders as a value, not a blank row', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PreferencesScreen()));

    expect(find.text('Auto'), findsOneWidget);
  });

  testWidgets('a persisted ceiling renders in SOL', (tester) async {
    pumpWith(PriorityFeeTier.high.lamports);
    await tester.pumpWidget(const MaterialApp(home: PreferencesScreen()));

    expect(find.text('0.001 SOL'), findsOneWidget);
  });

  // The value is edited on a pushed sub-screen: reading it once at build time
  // would leave this row showing the pre-edit selection after the pop.
  testWidgets('the row follows a change made while it is mounted', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PreferencesScreen()));
    expect(find.text('Auto'), findsOneWidget);

    await service.set(PriorityFeeTier.turbo.lamports);
    await tester.pump();

    expect(find.text('0.01 SOL'), findsOneWidget);
    expect(find.text('Auto'), findsNothing);
  });
}
