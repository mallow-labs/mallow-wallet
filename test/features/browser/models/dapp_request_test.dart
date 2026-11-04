import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';

void main() {
  group('solanaSignsDappMessagesVerbatim', () {
    test('Keystone is offered signMessage: it signs the bytes as given', () {
      expect(solanaSignsDappMessagesVerbatim(WalletType.keystone), isTrue);
    });

    test('Ledger is not: its off-chain wrapping changes the signed bytes', () {
      expect(solanaSignsDappMessagesVerbatim(WalletType.ledger), isFalse);
    });

    test(
      'local keys and Seed Vault sign verbatim; view-only signs nothing',
      () {
        for (final type in [
          WalletType.hd,
          WalletType.importedKey,
          WalletType.social,
          WalletType.seedVault,
        ]) {
          expect(
            solanaSignsDappMessagesVerbatim(type),
            isTrue,
            reason: '$type',
          );
        }
        expect(solanaSignsDappMessagesVerbatim(WalletType.viewOnly), isFalse);
      },
    );
  });
}
