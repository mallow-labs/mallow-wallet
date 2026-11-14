import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';

class _Database extends Mock implements MallowDatabase {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Repository extends Mock implements WalletRepository {}

class _Ledger extends Mock implements LedgerService {}

class _Vault extends Mock implements SeedVaultService {}

class _Keystone extends Mock implements KeystoneSignService {}

const _address = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
const _mnemonic =
    'gym exact clown can answer hope sample mirror knife twenty powder super imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';
void main() {
  late _Database db;
  late _Storage storage;
  late WalletManager manager;
  var active = true;
  final payload = MultiChainDerivation.packTezosMicheline('hello');
  void ensureActive() {
    if (!active) throw StateError('Cancelled');
  }

  setUp(() {
    active = true;
    db = _Database();
    storage = _Storage();
    when(() => db.getWalletById('w')).thenAnswer(
      (_) async => const Wallet(
        id: 'w',
        address: _address,
        name: 'Test',
        walletType: 'hd',
        chain: 'tezos',
        seedPhraseId: 'seed',
        derivationIndex: 0,
        legacySocial: false,
        createdAt: 0,
        sortIndex: 0,
      ),
    );
    when(
      () => storage.loadMnemonicForSeedPhrase('seed'),
    ).thenAnswer((_) async => _mnemonic);
    manager = WalletManager(
      storage,
      db,
      _Repository(),
      _Ledger(),
      _Vault(),
      _Keystone(),
    );
  });
  tearDown(() => manager.dispose());
  test(
    'Given an HD wallet, the reviewed packed payload uses its stored account index',
    () async {
      final signature = await manager.signTezosPayloadForWallet(
        'w',
        payload,
        expectedAddress: _address,
        ensureActive: ensureActive,
      );
      expect(
        signature,
        await MultiChainDerivation.signTezosPayload(_mnemonic, 0, payload),
      );
    },
  );
  test('Given a changed wallet row, its key is never loaded', () async {
    await expectLater(
      manager.signTezosPayloadForWallet(
        'w',
        payload,
        expectedAddress: 'other',
        ensureActive: ensureActive,
      ),
      throwsStateError,
    );
    await expectLater(
      manager.signTezosOperation(
        'w',
        '00',
        expectedAddress: 'other',
        ensureActive: ensureActive,
      ),
      throwsStateError,
    );
    verifyNever(() => storage.loadMnemonicForSeedPhrase(any()));
  });
  test(
    'Given cancellation while the vault loads, neither message nor operation signs',
    () async {
      final key = Completer<String?>();
      when(
        () => storage.loadMnemonicForSeedPhrase('seed'),
      ).thenAnswer((_) => key.future);
      final message = manager.signTezosPayloadForWallet(
        'w',
        payload,
        expectedAddress: _address,
        ensureActive: ensureActive,
      );
      final operation = manager.signTezosOperation(
        'w',
        '00',
        expectedAddress: _address,
        ensureActive: ensureActive,
      );
      final first = expectLater(message, throwsStateError);
      final second = expectLater(operation, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      active = false;
      key.complete(_mnemonic);
      await Future.wait([first, second]);
    },
  );
  test(
    'Given operation bytes disguised as a message, no wallet key is read',
    () async {
      final bytes = MultiChainDerivation.packTezosMicheline('hello')..[0] = 3;
      await expectLater(
        manager.signTezosPayloadForWallet(
          'w',
          bytes,
          expectedAddress: _address,
          ensureActive: ensureActive,
        ),
        throwsFormatException,
      );
      verifyNever(() => db.getWalletById(any()));
    },
  );
}
