import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/seed_vault/screens/seed_vault_import_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockSeedVault extends Mock implements SeedVaultService {}

class _MockRepo extends Mock implements WalletRepository {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockPrefs extends Mock implements PreferencesService {}

/// `ACCESS_SEED_VAULT` can be permanently denied while the device still reports
/// Seed Vault as available. The entry row therefore still renders, the user
/// taps it, and without a way back this screen is a dead end the user cannot
/// resolve from inside the app — the switch only exists in the OS settings.
void main() {
  late _MockSeedVault seedVault;

  setUp(() {
    seedVault = _MockSeedVault();
    for (final register in <void Function()>[
      () => sl.registerSingleton<SeedVaultService>(seedVault),
      () => sl.registerSingleton<WalletRepository>(_MockRepo()),
      () => sl.registerSingleton<TokenRepository>(_MockTokens()),
      () => sl.registerSingleton<PortfolioRepository>(_MockPortfolio()),
      () => sl.registerSingleton<PreferencesService>(_MockPrefs()),
    ]) {
      register();
    }
    when(seedVault.isAvailable).thenAnswer((_) async => true);
  });

  tearDown(() {
    sl.unregister<SeedVaultService>();
    sl.unregister<WalletRepository>();
    sl.unregister<TokenRepository>();
    sl.unregister<PortfolioRepository>();
    sl.unregister<PreferencesService>();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const SeedVaultImportScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a denied permission offers the OS settings hand-off, not a dead '
      'end', (tester) async {
    when(seedVault.hasPermission).thenAnswer((_) async => false);
    when(seedVault.requestPermission).thenAnswer((_) async => false);

    await pump(tester);

    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a device without Seed Vault says so instead of showing an empty '
      'picker', (tester) async {
    when(seedVault.isAvailable).thenAnswer((_) async => false);

    await pump(tester);

    expect(find.textContaining('does not have Seed Vault'), findsOneWidget);
  });
}
