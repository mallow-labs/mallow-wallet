import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/screens/add_account_screen.dart';
import 'package:mallow_wallet/features/accounts/screens/add_wallet_screen.dart';
import 'package:mallow_wallet/features/onboarding/widgets/import_wallet_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockSeedVault extends Mock implements SeedVaultService {}

class _MockRepo extends Mock implements WalletRepository {}

/// One binary ships to both stores, and Seed Vault is gated at runtime rather
/// than behind a build flavour. Every entry point therefore has to be invisible
/// on a device without a Seed Vault implementation — otherwise a normal Android
/// phone shows an import row that can only dead-end, and iOS shows an Android
/// feature.
void main() {
  late _MockSeedVault seedVault;
  late _MockRepo repo;

  setUp(() {
    seedVault = _MockSeedVault();
    repo = _MockRepo();
    for (final t in [
      () => sl.registerSingleton<SeedVaultService>(seedVault),
      () => sl.registerSingleton<WalletRepository>(repo),
    ]) {
      t();
    }
    when(repo.getAccountViews).thenAnswer((_) async => const <Account>[]);
  });

  tearDown(() {
    sl.unregister<SeedVaultService>();
    sl.unregister<WalletRepository>();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(theme: MallowTheme.lightTheme, home: child),
    );
    await tester.pumpAndSettle();
  }

  group('Add account', () {
    testWidgets('hides the Seed Vault row on a device without one', (
      tester,
    ) async {
      when(seedVault.isAvailable).thenAnswer((_) async => false);

      await pump(tester, const AddAccountScreen());

      expect(find.text('Import from Seed Vault'), findsNothing);
      // The rest of the menu is untouched.
      expect(find.text('Connect hardware wallet'), findsOneWidget);
    });

    testWidgets('shows it on a device that has one', (tester) async {
      when(seedVault.isAvailable).thenAnswer((_) async => true);

      await pump(tester, const AddAccountScreen());

      expect(find.text('Import from Seed Vault'), findsOneWidget);
    });
  });

  group('Add wallet', () {
    testWidgets('hides the Seed Vault row on a device without one', (
      tester,
    ) async {
      when(seedVault.isAvailable).thenAnswer((_) async => false);

      await pump(tester, const AddWalletScreen(accountId: 'acct-1'));

      expect(find.text('Import from Seed Vault'), findsNothing);
      expect(find.text('Connect hardware wallet'), findsOneWidget);
    });

    testWidgets('shows it on a device that has one', (tester) async {
      when(seedVault.isAvailable).thenAnswer((_) async => true);

      await pump(tester, const AddWalletScreen(accountId: 'acct-1'));

      expect(find.text('Import from Seed Vault'), findsOneWidget);
    });
  });

  group('Welcome ("I already have a wallet")', () {
    // The welcome screen owns the availability probe and hands the sheet a
    // null callback when the device has no Seed Vault; the sheet renders the
    // row only when it gets one. Exercised directly so the assertion is about
    // the gate rather than about the onboarding screen's carousel.
    Widget menu({VoidCallback? onSeedVaultTap}) => ImportWalletMenu(
      onGoogleSignIn: () async => null,
      onAppleSignIn: () async => null,
      onPrivateKeyTap: () {},
      onHardwareWalletTap: () {},
      onRecoveryPhraseTap: () {},
      onSeedVaultTap: onSeedVaultTap,
    );

    testWidgets('hides the Seed Vault row when the caller has no handler for '
        'it', (tester) async {
      await pump(tester, menu());

      expect(find.text('Use Seed Vault'), findsNothing);
      expect(find.text('Use a hardware wallet'), findsOneWidget);
    });

    testWidgets('shows it when the caller supplies one', (tester) async {
      await pump(tester, menu(onSeedVaultTap: () {}));

      expect(find.text('Use Seed Vault'), findsOneWidget);
    });
  });
}
