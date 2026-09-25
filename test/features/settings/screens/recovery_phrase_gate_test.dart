import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/security/biometric_auth.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/recovery_phrase_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockBiometric extends Mock implements BiometricAuthService {}

/// Revealing the recovery phrase is the one action on this device that cannot
/// be taken back. The gate in front of it therefore *verifies* — it never
/// re-decides whether this device has a PIN at all. That question is settled
/// once, in `_advanceToPinGate`, which fails closed to "it has one"; a second
/// look here could only overturn it, and the way it overturns it is by
/// believing a transient keystore miss and waving the phrase through.
void main() {
  late _MockRepo repo;
  late _MockStorage storage;
  late _MockBiometric biometric;

  const wallet = WalletInfo(
    id: 'sol-1',
    address: 'So1anaAddress1111111111111111111111111111111',
    name: 'Solana',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-1',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
  );
  const account = Account(
    id: 'acct-1',
    name: 'Account 01',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
    wallets: [wallet],
  );

  setUp(() {
    repo = _MockRepo();
    storage = _MockStorage();
    biometric = _MockBiometric();

    sl.registerSingleton<WalletRepository>(repo);
    sl.registerSingleton<SecureWalletStorage>(storage);
    sl.registerSingleton<BiometricAuthService>(biometric);

    when(() => repo.getAccountViews()).thenAnswer((_) async => [account]);
    // A PIN-only device: the factor read is what decides the gate, and it is
    // the only read that may.
    when(
      () => storage.loadAuthFactors(),
    ).thenAnswer((_) async => (hasPin: true, biometricEnabled: false));
    when(
      () => storage.loadMnemonicForSeedPhrase(any()),
    ).thenAnswer((_) async => 'abandon abandon about');
    when(() => storage.loadMnemonic()).thenAnswer((_) async => null);
  });

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<SecureWalletStorage>();
    sl.unregister<BiometricAuthService>();
  });

  Future<void> pumpGate(WidgetTester tester, List<String> revealed) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const RecoveryPhraseScreen()),
        GoRoute(
          path: AppRoutes.recoveryPhraseWarning,
          builder: (_, state) {
            revealed.addAll(state.extra! as List<String>);
            return const Scaffold(body: Text('warning'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
    expect(find.text('Please enter your pin to view'), findsOneWidget);
  }

  Future<void> enterPin(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('1'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a PIN that does not verify never reveals the phrase, whatever '
      'a fresh hasPin() read says', (tester) async {
    // The transient miss the gate must not act on: the PIN is there (the
    // factor read above saw it), but this read comes back empty. Believing it
    // used to short-circuit the whole gate — `!hasPin() || verifyPin()` — and
    // hand over the phrase for six taps of any digit.
    when(() => storage.hasPin()).thenAnswer((_) async => false);
    when(() => storage.verifyPin(any())).thenAnswer((_) async => false);
    final revealed = <String>[];

    await pumpGate(tester, revealed);
    await enterPin(tester);

    expect(revealed, isEmpty);
    expect(find.text('Please enter your pin to view'), findsOneWidget);
    verifyNever(() => storage.loadMnemonicForSeedPhrase(any()));
  });

  testWidgets('a PIN read that throws is not a pass', (tester) async {
    // The stored hash lives in the vault, which reports an item it cannot read
    // as an error rather than as absent. Unknown is not verified.
    when(() => storage.hasPin()).thenAnswer((_) async => true);
    when(() => storage.verifyPin(any())).thenThrow(StateError('vault down'));
    final revealed = <String>[];

    await pumpGate(tester, revealed);
    await enterPin(tester);

    expect(revealed, isEmpty);
    verifyNever(() => storage.loadMnemonicForSeedPhrase(any()));
  });

  testWidgets('the right PIN still reveals the phrase', (tester) async {
    // The other half of the gate: closing it must not close it on the user.
    when(() => storage.hasPin()).thenAnswer((_) async => true);
    when(() => storage.verifyPin('111111')).thenAnswer((_) async => true);
    final revealed = <String>[];

    await pumpGate(tester, revealed);
    await enterPin(tester);

    expect(revealed, ['abandon', 'abandon', 'about']);
  });
}
