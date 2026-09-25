import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/router/app_router.dart';

/// The no-wallet redirect sends anything that is neither an onboarding route
/// nor a wallet-import route to `/welcome`. During onboarding the device holds
/// no wallet yet, so an import route missing from that allowlist does not fail
/// loudly — "I already have a wallet -> Seed Vault" simply bounces back to the
/// welcome screen and the entry point looks broken for no visible reason.
void main() {
  test('the Seed Vault import route survives the no-wallet guard', () {
    expect(isWalletImportLocation(AppRoutes.seedVaultImport), isTrue);
  });

  test('the routes that were already allowed still are', () {
    expect(isWalletImportLocation(AppRoutes.ledgerScan), isTrue);
    expect(isWalletImportLocation(AppRoutes.importPrivateKeyGlobal), isTrue);
  });

  test('an ordinary route is still guarded', () {
    expect(isWalletImportLocation(AppRoutes.home), isFalse);
    expect(isWalletImportLocation(AppRoutes.settings), isFalse);
  });
}
