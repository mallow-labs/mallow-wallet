import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/seed_vault/widgets/seed_vault_entry.dart';
import 'package:mocktail/mocktail.dart';

class _MockSeedVault extends Mock implements SeedVaultService {}

/// Seed Vault code ships in every Android build and is gated at runtime, so the
/// Play artifact and the dApp Store artifact differ only in identity and
/// signing. That only works if the gate actually hides the feature: on a phone
/// with no Seed Vault implementation — every iPhone, and every Android device
/// that is not a Solana Mobile one — no Seed Vault surface may render at all.
void main() {
  late _MockSeedVault seedVault;

  setUp(() {
    seedVault = _MockSeedVault();
    if (sl.isRegistered<SeedVaultService>()) {
      sl.unregister<SeedVaultService>();
    }
    sl.registerSingleton<SeedVaultService>(seedVault);
  });

  tearDown(() {
    if (sl.isRegistered<SeedVaultService>()) {
      sl.unregister<SeedVaultService>();
    }
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SeedVaultEntry(builder: (_) => const Text('Seed Vault row')),
      ),
    ),
  );

  testWidgets('renders nothing on a device without Seed Vault', (tester) async {
    when(seedVault.isAvailable).thenAnswer((_) async => false);

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Seed Vault row'), findsNothing);
  });

  testWidgets('renders nothing while the probe is still in flight, so the row '
      'never appears and then disappears', (tester) async {
    final probe = Completer<bool>();
    when(seedVault.isAvailable).thenAnswer((_) => probe.future);

    await pump(tester);
    await tester.pump();
    expect(find.text('Seed Vault row'), findsNothing);

    probe.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Seed Vault row'), findsOneWidget);
  });

  testWidgets('renders the row on a device that has Seed Vault', (
    tester,
  ) async {
    when(seedVault.isAvailable).thenAnswer((_) async => true);

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Seed Vault row'), findsOneWidget);
  });
}
