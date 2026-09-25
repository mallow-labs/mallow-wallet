import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/ledger/services/ledger_auth_service.dart';
import 'package:mallow_wallet/features/ledger/widgets/hardware_verify_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockLedgerAuth extends Mock implements LedgerAuthService {}

// One sheet, two devices. The flows differ (Ledger connects over BLE and does
// the whole verification here; Seed Vault only collects consent for an approval
// that happens in the OS's own Activity), and so must the copy: a Seed Vault
// user told to switch on Bluetooth and open the Solana app has been sent
// somewhere they cannot go, with no way to tell they were misrouted.
void main() {
  const solanaAddress = '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin';

  late _MockLedgerAuth ledgerAuth;

  setUp(() {
    ledgerAuth = _MockLedgerAuth();
    when(
      () => ledgerAuth.currentState,
    ).thenReturn(const LedgerSessionState.scanning(devices: []));
    when(
      () => ledgerAuth.sessionState,
    ).thenAnswer((_) => const Stream<LedgerSessionState>.empty());
    when(() => ledgerAuth.isConnected).thenReturn(false);
    when(() => ledgerAuth.startScan()).thenAnswer((_) async {});
    when(() => ledgerAuth.clearDevices()).thenReturn(null);
    if (sl.isRegistered<LedgerAuthService>()) {
      sl.unregister<LedgerAuthService>();
    }
    sl.registerSingleton<LedgerAuthService>(ledgerAuth);
  });

  tearDown(() {
    if (sl.isRegistered<LedgerAuthService>()) {
      sl.unregister<LedgerAuthService>();
    }
  });

  Future<Completer<bool>> pump(WidgetTester tester, WalletType type) async {
    final completer = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: HardwareVerifySheet(
            address: solanaAddress,
            walletType: type,
            completer: completer,
          ),
        ),
      ),
    );
    return completer;
  }

  testWidgets('a Seed Vault wallet is asked about Seed Vault, not Ledger', (
    tester,
  ) async {
    await pump(tester, WalletType.seedVault);

    expect(find.textContaining('Seed Vault'), findsWidgets);
    expect(find.textContaining('Ledger'), findsNothing);
    expect(find.textContaining('Bluetooth'), findsNothing);
    // No transport to bring up — the approval lives in the OS Activity the
    // caller launches after this sheet returns. A scan here would ask for
    // Bluetooth the user never needs.
    verifyNever(() => ledgerAuth.startScan());
  });

  testWidgets('a Ledger wallet still gets the connect copy', (tester) async {
    await pump(tester, WalletType.ledger);

    expect(find.textContaining('Ledger'), findsWidgets);
    expect(find.textContaining('Bluetooth'), findsOneWidget);
    expect(find.textContaining('Seed Vault'), findsNothing);
    verify(() => ledgerAuth.startScan()).called(1);
  });

  testWidgets('the Seed Vault consent tap is what allows the approval', (
    tester,
  ) async {
    final completer = await pump(tester, WalletType.seedVault);

    // Nothing may resolve before the tap: the completer is the caller's
    // permission to launch the OS approval Activity, and the whole point of
    // this sheet is that a user action precedes it.
    expect(completer.isCompleted, isFalse);

    await tester.tap(find.text('Continue in Seed Vault'));
    await tester.pumpAndSettle();

    expect(await completer.future, isTrue);
  });

  testWidgets('a dismissed Seed Vault sheet declines', (tester) async {
    final completer = await pump(tester, WalletType.seedVault);

    // Disposing without a tap is a dismissal — it must read as "no", never as
    // an unanswered request the caller could take for consent.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(await completer.future, isFalse);
  });
}
