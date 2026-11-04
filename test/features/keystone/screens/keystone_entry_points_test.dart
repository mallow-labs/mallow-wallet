import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/screens/add_account_screen.dart';
import 'package:mallow_wallet/features/accounts/screens/add_wallet_screen.dart';
import 'package:mallow_wallet/features/accounts/screens/hardware_wallet_chooser_screen.dart';
import 'package:mallow_wallet/features/onboarding/widgets/import_wallet_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockSeedVault extends Mock implements SeedVaultService {}

class _MockRepo extends Mock implements WalletRepository {}

/// Every entry point offers one hardware-wallet row, which opens the Ledger /
/// Keystone chooser.
void main() {
  late _MockSeedVault seedVault;
  late _MockRepo repo;

  setUp(() {
    seedVault = _MockSeedVault();
    repo = _MockRepo();
    sl.registerSingleton<SeedVaultService>(seedVault);
    sl.registerSingleton<WalletRepository>(repo);
    when(seedVault.isAvailable).thenAnswer((_) async => false);
    when(repo.getAccountViews).thenAnswer((_) async => const <Account>[]);
  });

  tearDown(() {
    sl.unregister<SeedVaultService>();
    sl.unregister<WalletRepository>();
  });

  /// Pumps [home] under a router whose import destinations are stubs, so a tap
  /// can be asserted by the route it lands on.
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: AppRoutes.hardwareWalletImport,
          builder: (_, _) => const HardwareWalletChooserScreen(),
        ),
        for (final route in [AppRoutes.ledgerScan, AppRoutes.keystoneImport])
          GoRoute(path: route, builder: (_, _) => Text('route:$route')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
  }

  for (final (name, screen) in [
    ('Add account', const AddAccountScreen()),
    ('Add wallet', const AddWalletScreen(accountId: 'acct-1')),
  ]) {
    group(name, () {
      testWidgets('one hardware row', (tester) async {
        await pump(tester, screen);

        expect(find.text('Connect hardware wallet'), findsOneWidget);
        expect(find.text('Connect Ledger'), findsNothing);
        expect(find.text('Connect Keystone'), findsNothing);
      });

      testWidgets('the row opens the chooser', (tester) async {
        await pump(tester, screen);

        await tester.tap(find.text('Connect hardware wallet'));
        await tester.pumpAndSettle();

        expect(find.byType(HardwareWalletChooserScreen), findsOneWidget);
      });
    });
  }

  group('Welcome ("I already have a wallet")', () {
    testWidgets('one hardware button, wired to its callback', (tester) async {
      var tapped = false;
      await pump(
        tester,
        ImportWalletMenu(
          onGoogleSignIn: () async => null,
          onAppleSignIn: () async => null,
          onPrivateKeyTap: () {},
          onHardwareWalletTap: () => tapped = true,
          onRecoveryPhraseTap: () {},
        ),
      );

      expect(find.text('Use Ledger'), findsNothing);
      expect(find.text('Use Keystone'), findsNothing);
      await tester.tap(find.text('Use a hardware wallet'));
      expect(tapped, isTrue);
    });
  });

  group('Hardware wallet chooser', () {
    for (final (device, route) in [
      ('Ledger', AppRoutes.ledgerScan),
      ('Keystone', AppRoutes.keystoneImport),
    ]) {
      testWidgets('$device opens its import', (tester) async {
        await pump(tester, const HardwareWalletChooserScreen());

        expect(find.text('Choose your device'), findsOneWidget);
        await tester.tap(find.text(device));
        await tester.pumpAndSettle();

        expect(find.text('route:$route'), findsOneWidget);
      });
    }

    test('survives the no-wallet guard during onboarding', () {
      expect(isWalletImportLocation(AppRoutes.hardwareWalletImport), isTrue);
    });
  });
}
