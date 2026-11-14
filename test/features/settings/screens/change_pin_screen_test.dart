import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/change_pin_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

/// The current-PIN step checks the same PIN as the lock screen, so it spends
/// the same attempt budget.
void main() {
  const correctPin = '135790';
  const wrongPin = '246801';

  late _MockStorage storage;
  late int failed;
  late DateTime? until;
  late List<String> checked;

  setUpAll(() => registerFallbackValue(DateTime(2000)));

  setUp(() {
    storage = _MockStorage();
    failed = 0;
    until = null;
    checked = [];
    sl.registerSingleton<SecureWalletStorage>(storage);

    when(() => storage.hasPin()).thenAnswer((_) async => true);
    when(() => storage.verifyPin(any())).thenAnswer((inv) async {
      final pin = inv.positionalArguments.first as String;
      checked.add(pin);
      return pin == correctPin;
    });
    when(() => storage.loadFailedPinAttempts()).thenAnswer((_) async => failed);
    when(() => storage.loadPinCooldownUntil()).thenAnswer((_) async => until);
    when(() => storage.storeFailedPinAttempts(any())).thenAnswer((inv) async {
      failed = inv.positionalArguments.first as int;
    });
    when(() => storage.storePinCooldownUntil(any())).thenAnswer((inv) async {
      until = inv.positionalArguments.first as DateTime;
    });
    when(() => storage.clearPinLockout()).thenAnswer((_) async {
      failed = 0;
      until = null;
    });
  });

  tearDown(() => sl.unregister<SecureWalletStorage>());

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: MallowTheme.lightTheme, home: const ChangePinScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.text(digit), warnIfMissed: false);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  final cooldownCopy = find.textContaining('Too many failed attempts.');

  testWidgets('wrong current PINs climb the shared ladder and freeze the pad', (
    tester,
  ) async {
    failed = 4;
    await pumpScreen(tester);

    await enterPin(tester, wrongPin);

    expect(failed, 5);
    expect(until, isNotNull);
    expect(cooldownCopy, findsOneWidget);
    expect(find.text('Enter your current PIN'), findsOneWidget);

    await enterPin(tester, correctPin);
    expect(checked, [wrongPin]);
    expect(find.text('Enter a new PIN'), findsNothing);
  });

  testWidgets('a cooldown armed elsewhere is in force from the first frame', (
    tester,
  ) async {
    failed = 5;
    until = DateTime.now().add(const Duration(minutes: 5));
    await pumpScreen(tester);

    expect(cooldownCopy, findsOneWidget);
    await enterPin(tester, correctPin);

    expect(checked, isEmpty);
    expect(find.text('Enter a new PIN'), findsNothing);
  });

  testWidgets('the correct current PIN advances and clears the lockout', (
    tester,
  ) async {
    failed = 3;
    await pumpScreen(tester);

    await enterPin(tester, correctPin);

    expect(find.text('Enter a new PIN'), findsOneWidget);
    expect(failed, 0);
  });
}
