import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/security/redacted.dart';
import 'package:mallow_wallet/features/accounts/services/import_private_key_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'import_private_key_bloc_test.mocks.dart';

@GenerateMocks([WalletRepository, WalletManager])
void main() {
  late MockWalletRepository mockRepo;
  late MockWalletManager mockManager;

  const testAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testInput = 'fake-private-key-input';
  const testWalletId = 'wallet-id-123';
  const testWalletName = 'Imported wallet';

  const testWallet = WalletInfo(
    id: testWalletId,
    address: testAddress,
    name: testWalletName,
    walletType: WalletType.importedKey,
    chain: 'solana',
  );

  setUp(() {
    mockRepo = MockWalletRepository();
    mockManager = MockWalletManager();
  });

  group('ImportPrivateKeyBloc', () {
    blocTest<ImportPrivateKeyBloc, ImportPrivateKeyState>(
      'activates the new wallet via WalletManager so onWalletChanged fires',
      build: () {
        when(
          mockRepo.addImportedKeyWallet(any, any),
        ).thenAnswer((_) async => testWallet);
        when(mockManager.switchWalletById(any)).thenAnswer((_) async {});
        return ImportPrivateKeyBloc(mockRepo, mockManager);
      },
      seed: () => const ImportPrivateKeyState.validated(
        address: testAddress,
        rawInput: Redacted(testInput),
      ),
      act: (bloc) => bloc.add(const ImportPrivateKeyEvent.importWallet()),
      expect: () => [
        const ImportPrivateKeyState.importing(),
        const ImportPrivateKeyState.imported(testWallet),
      ],
      verify: (_) {
        verify(
          mockRepo.addImportedKeyWallet(testInput, testWalletName),
        ).called(1);
        // The critical assertion: without this call, AuthService keeps the
        // old wallet's session and the next signing attempt fails with
        // "Signer ... is not in the tx signer slots".
        verify(mockManager.switchWalletById(testWalletId)).called(1);
      },
    );

    blocTest<ImportPrivateKeyBloc, ImportPrivateKeyState>(
      'does not activate when add fails',
      build: () {
        when(
          mockRepo.addImportedKeyWallet(any, any),
        ).thenThrow(Exception('boom'));
        return ImportPrivateKeyBloc(mockRepo, mockManager);
      },
      seed: () => const ImportPrivateKeyState.validated(
        address: testAddress,
        rawInput: Redacted(testInput),
      ),
      act: (bloc) => bloc.add(const ImportPrivateKeyEvent.importWallet()),
      // A non-validation failure on this key-handling path must surface fixed
      // copy — never the raw exception text ('boom'), which is
      // error.toString() for `unknown` and can carry keystore/crypto detail.
      expect: () => [
        const ImportPrivateKeyState.importing(),
        predicate<ImportPrivateKeyState>(
          (s) => s.maybeWhen(
            error: (message) =>
                message == 'Could not import this key.' &&
                !message.contains('boom'),
            orElse: () => false,
          ),
          'error state carrying fixed copy with no raw detail',
        ),
      ],
      verify: (_) {
        verifyNever(mockManager.switchWalletById(any));
      },
    );

    blocTest<ImportPrivateKeyBloc, ImportPrivateKeyState>(
      'surfaces the validation message when the key cannot be parsed',
      // InvalidPrivateKeyException now classifies as AppFailureKind.validation,
      // so its message flows through Result.guard → AppFailure.message into the
      // error state instead of a raw `toString()`. A user typing garbage should
      // see the parser's "Unrecognized private key…" copy, not "Exception: …".
      build: () => ImportPrivateKeyBloc(mockRepo, mockManager),
      act: (bloc) => bloc.add(
        const ImportPrivateKeyEvent.validateKey(Redacted('not-a-valid-key')),
      ),
      expect: () => [
        const ImportPrivateKeyState.validating(),
        predicate<ImportPrivateKeyState>(
          (s) => s.maybeWhen(
            error: (message) => message.contains('Unrecognized private key'),
            orElse: () => false,
          ),
          'error state carrying the parser validation message',
        ),
      ],
      verify: (_) {
        verifyNever(mockRepo.addImportedKeyWallet(any, any));
      },
    );

    blocTest<ImportPrivateKeyBloc, ImportPrivateKeyState>(
      'ignores import event when not in validated state',
      build: () => ImportPrivateKeyBloc(mockRepo, mockManager),
      act: (bloc) => bloc.add(const ImportPrivateKeyEvent.importWallet()),
      expect: () => <ImportPrivateKeyState>[],
      verify: (_) {
        verifyNever(mockRepo.addImportedKeyWallet(any, any));
        verifyNever(mockManager.switchWalletById(any));
      },
    );
  });
}
