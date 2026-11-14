import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/reauth_gate.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/pin_prompt_sheet.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockBiometric extends Mock implements BiometricAuthService {}

/// The re-auth gate guards Show secrets, Reset app and key-destroying removals,
/// and its PIN sheet checks the same six-digit PIN as the lock screen. These
/// drive the real gate and sheet, with a store that remembers, because the
/// failure this guards against is a budget that resets when the sheet reopens.
void main() {
  const correctPin = '135790';
  const wrongPin = '246801';

  late _MockStorage storage;
  late _MockBiometric biometric;
  late int failed;
  late DateTime? until;
  late List<String> checked;

  setUpAll(() => registerFallbackValue(DateTime(2000)));

  setUp(() {
    storage = _MockStorage();
    biometric = _MockBiometric();
    failed = 0;
    until = null;
    checked = [];

    sl.registerSingleton<SecureWalletStorage>(storage);
    sl.registerSingleton<BiometricAuthService>(biometric);

    when(
      () => storage.loadAuthFactors(),
    ).thenAnswer((_) async => (hasPin: true, biometricEnabled: true));
    // The victim's biometric: the attacker can only ever fail it.
    when(
      () => biometric.authenticateForReauth(),
    ).thenAnswer((_) async => BiometricAuthResult.failed);
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

  tearDown(() {
    sl.unregister<SecureWalletStorage>();
    sl.unregister<BiometricAuthService>();
  });

  /// Pumps a button that opens the gate, and returns what the gate last said.
  Future<List<bool>> pumpGate(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final outcomes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async =>
                    outcomes.add(await requireReauth(context)),
                child: const Text('Open gate'),
              ),
            ),
          ),
        ),
      ),
    );
    return outcomes;
  }

  Future<void> openGate(WidgetTester tester) async {
    await tester.tap(find.text('Open gate'));
    await tester.pumpAndSettle();
    expect(find.byType(PinPromptSheet), findsOneWidget);
    // A mallow sheet ignores touches for a beat after it settles.
    await tester.pump(const Duration(milliseconds: 150));
  }

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      // A frozen pad is expected to swallow these.
      await tester.tap(find.text(digit), warnIfMissed: false);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> dismissSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byType(PinPromptSheet), findsNothing);
  }

  final cooldownCopy = find.textContaining('Too many failed attempts.');

  testWidgets('reopening the gate buys no new guesses', (tester) async {
    final outcomes = await pumpGate(tester);

    // Three wrong PINs close the first sheet, as they always have.
    await openGate(tester);
    for (var i = 0; i < 3; i++) {
      await enterPin(tester, wrongPin);
    }
    expect(find.byType(PinPromptSheet), findsNothing);
    expect(outcomes, [false]);
    expect(failed, 3);

    // The second sheet starts where the first stopped: two more, not three.
    await openGate(tester);
    await enterPin(tester, wrongPin);
    expect(failed, 4);
    expect(cooldownCopy, findsNothing);
    await enterPin(tester, wrongPin);
    expect(failed, 5);
    expect(until, isNotNull);

    // The sheet stays up and says why, with the pad frozen.
    expect(find.byType(PinPromptSheet), findsOneWidget);
    expect(cooldownCopy, findsOneWidget);

    // The correct PIN cannot be entered now, so the search stops here.
    await enterPin(tester, correctPin);
    expect(checked, isNot(contains(correctPin)));
    expect(failed, 5);

    await dismissSheet(tester);
    expect(outcomes, [false, false]);

    // Nor does a third opening reset anything.
    await openGate(tester);
    expect(cooldownCopy, findsOneWidget);
    await enterPin(tester, correctPin);
    expect(checked, hasLength(5));
    await dismissSheet(tester);
    expect(outcomes, [false, false, false]);
  });

  testWidgets('a sheet opened during a cooldown armed elsewhere shows it, and '
      'the pad takes nothing', (tester) async {
    failed = 5;
    until = DateTime.now().add(const Duration(minutes: 5));
    final outcomes = await pumpGate(tester);

    await openGate(tester);

    expect(cooldownCopy, findsOneWidget);
    await enterPin(tester, correctPin);
    expect(checked, isEmpty);
    await dismissSheet(tester);
    expect(outcomes, [false]);
  });

  testWidgets(
    'once the cooldown has passed the correct PIN clears the gate and '
    'the lockout',
    (tester) async {
      failed = 5;
      until = DateTime.now().subtract(const Duration(seconds: 1));
      final outcomes = await pumpGate(tester);

      await openGate(tester);
      expect(cooldownCopy, findsNothing);
      await enterPin(tester, correctPin);

      expect(find.byType(PinPromptSheet), findsNothing);
      expect(outcomes, [true]);
      expect(failed, 0);
      expect(until, isNull);
    },
  );

  testWidgets('a deadline left by a moved clock counts down from the top tier, '
      'and is corrected in the store', (tester) async {
    failed = 5;
    until = DateTime.utc(2040);
    await pumpGate(tester);

    await openGate(tester);

    expect(
      find.textContaining(RegExp(r'Try again in (29m \d+s|30m 0s)')),
      findsOneWidget,
    );
    expect(until!.difference(DateTime.now()).inMinutes, lessThanOrEqualTo(30));
    await dismissSheet(tester);
  });

  testWidgets('a wrong PIN past the threshold arms the next cooldown tier', (
    tester,
  ) async {
    failed = 9;
    until = DateTime.now().subtract(const Duration(seconds: 1));
    await pumpGate(tester);

    await openGate(tester);
    await enterPin(tester, wrongPin);

    expect(failed, 10);
    expect(
      until!.difference(DateTime.now()).inSeconds,
      inInclusiveRange(58, 60),
    );
    expect(cooldownCopy, findsOneWidget);
  });

  testWidgets(
    'a lockout store that cannot answer denies the gate, even for the '
    'correct PIN',
    (tester) async {
      when(() => storage.loadFailedPinAttempts()).thenThrow(StateError('down'));
      final outcomes = await pumpGate(tester);

      await openGate(tester);
      await enterPin(tester, correctPin);

      expect(find.byType(PinPromptSheet), findsNothing);
      expect(outcomes, [false]);
      expect(checked, isEmpty);
    },
  );
}
