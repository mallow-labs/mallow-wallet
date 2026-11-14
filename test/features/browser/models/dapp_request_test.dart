import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';

void main() {
  group('solanaSignsDappMessagesVerbatim', () {
    test('Keystone is offered signMessage: it signs the bytes as given', () {
      expect(solanaSignsDappMessagesVerbatim(WalletType.keystone), isTrue);
    });

    test('Ledger is not: it signs only the off-chain format', () {
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

  group('solanaSignsOffchainMessages', () {
    test('every signer, Ledger included, signs the bytes the wallet built', () {
      for (final type in WalletType.values) {
        expect(
          solanaSignsOffchainMessages(type),
          type != WalletType.viewOnly,
          reason: '$type',
        );
      }
    });

    test('a wallet offers it only when it can sign at all', () {
      const ledger = DappWallet(
        id: 'ledger',
        address: 'address',
        canSign: true,
        canSignMessages: false,
        type: WalletType.ledger,
      );
      expect(ledger.canSignOffchainMessages, isTrue);
      expect(
        const DappWallet(
          id: 'view',
          address: 'address',
          canSign: false,
          type: WalletType.hd,
        ).canSignOffchainMessages,
        isFalse,
      );
    });
  });
}
