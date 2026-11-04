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
      'a key imported earlier is refused, not reopened',
      // Importing the same key twice is a refusal. Only the retry of an
      // import that failed its recovery-graph write (next test) completes as
      // a duplicate.
      build: () {
        when(
          mockRepo.addImportedKeyWallet(any, any),
        ).thenThrow(DuplicateWalletException(testAddress));
        return ImportPrivateKeyBloc(mockRepo, mockManager);
      },
      seed: () => const ImportPrivateKeyState.validated(
        address: testAddress,
        rawInput: Redacted(testInput),
      ),
      act: (bloc) => bloc.add(const ImportPrivateKeyEvent.importWallet()),
      expect: () => [
        const ImportPrivateKeyState.importing(),
        const ImportPrivateKeyState.error(
          'A wallet with this address is already on this device.',
        ),
      ],
      verify: (_) {
        verifyNever(mockRepo.completeImportedKeyRetry(any));
        verifyNever(mockManager.switchWalletById(any));
      },
    );

    test('the retry after a failed recovery-graph write opens the wallet '
        'the first attempt stored', () async {
      // A well-formed key, so validation passes for real on both attempts.
      const evmKey =
          '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318';
      var attempts = 0;
      when(mockRepo.addImportedKeyWallet(any, any)).thenAnswer((_) async {
        // The first attempt stores the key and row, then its graph write
        // fails; the retry finds that row.
        if (attempts++ == 0) throw GraphSyncException(Exception('keystore'));
        throw DuplicateWalletException('held');
      });
      when(mockManager.notifyWalletDataChanged()).thenAnswer((_) async {});
      when(mockManager.switchWalletById(any)).thenAnswer((_) async {});
      var commits = 0;
      when(mockRepo.completeImportedKeyRetry(any)).thenAnswer((_) async {
        // The graph is still unwritable on the first retry: that must stay
        // an error, never a success over a graph that does not name the key.
        if (commits++ == 0) throw GraphSyncException(Exception('keystore'));
        return testWallet;
      });
      final bloc = ImportPrivateKeyBloc(mockRepo, mockManager);
      addTearDown(bloc.close);

      Future<ImportPrivateKeyState> settle(ImportPrivateKeyEvent e) {
        final next = bloc.stream.firstWhere(
          (s) =>
              s is ImportPrivateKeyValidated ||
              s.maybeWhen(
                imported: (_) => true,
                error: (_) => true,
                orElse: () => false,
              ),
        );
        bloc.add(e);
        return next;
      }

      await settle(const ImportPrivateKeyEvent.validateKey(Redacted(evmKey)));
      expect(
        await settle(const ImportPrivateKeyEvent.importWallet()),
        const ImportPrivateKeyState.error(
          'Could not update recovery data. Please try again.',
        ),
      );

      await settle(const ImportPrivateKeyEvent.validateKey(Redacted(evmKey)));
      expect(
        await settle(const ImportPrivateKeyEvent.importWallet()),
        const ImportPrivateKeyState.error(
          'Could not update recovery data. Please try again.',
        ),
      );
      verifyNever(mockManager.switchWalletById(any));

      await settle(const ImportPrivateKeyEvent.validateKey(Redacted(evmKey)));
      expect(
        await settle(const ImportPrivateKeyEvent.importWallet()),
        const ImportPrivateKeyState.imported(testWallet),
      );
      verify(mockManager.switchWalletById(testWalletId)).called(1);
    });

    blocTest<ImportPrivateKeyBloc, ImportPrivateKeyState>(
      'a failed recovery-graph write asks for a retry and refreshes the '
      'wallet set',
      // The key may already be stored (the graph write comes last), so "could
      // not import" can be false — and a retry then opens it as a duplicate.
      // The raw cause must not reach the screen.
      build: () {
        when(
          mockRepo.addImportedKeyWallet(any, any),
        ).thenThrow(GraphSyncException(Exception('keystore detail')));
        when(mockManager.notifyWalletDataChanged()).thenAnswer((_) async {});
        return ImportPrivateKeyBloc(mockRepo, mockManager);
      },
      seed: () => const ImportPrivateKeyState.validated(
        address: testAddress,
        rawInput: Redacted(testInput),
      ),
      act: (bloc) => bloc.add(const ImportPrivateKeyEvent.importWallet()),
      expect: () => [
        const ImportPrivateKeyState.importing(),
        const ImportPrivateKeyState.error(
          'Could not update recovery data. Please try again.',
        ),
      ],
      verify: (_) {
        verify(mockManager.notifyWalletDataChanged()).called(1);
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
