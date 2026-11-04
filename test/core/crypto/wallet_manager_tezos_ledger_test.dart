import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/network/ledger_connect_controller.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/crypto/tezos_forge.dart' show bytesToHex;

class _Database extends Mock implements MallowDatabase {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Repository extends Mock implements WalletRepository {}

class _Ledger extends Mock implements LedgerService {}

class _Vault extends Mock implements SeedVaultService {}

class _Keystone extends Mock implements KeystoneSignService {}

const _mnemonic =
    'gym exact clown can answer hope sample mirror knife twenty powder super imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';
void main() {
  late WalletManager manager;
  late _Ledger ledger;
  late _Storage storage;
  late String address;
  late Uint8List publicKey;
  late LedgerConnectController controller;
  late Completer<void> cancelled;
  var active = true;
  final message = MultiChainDerivation.packTezosMicheline('hello');
  final forged = '00' * 33;
  Uint8List raw(String encoded, int prefix) => Uint8List.fromList(
    base58decode(encoded).sublist(prefix, base58decode(encoded).length - 4),
  );
  void ensureActive() {
    if (!active) throw StateError('Cancelled');
  }

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });
  setUp(() async {
    address = await MultiChainDerivation.getTezosAddressAtIndex(_mnemonic, 2);
    publicKey = raw(
      await MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 2),
      4,
    );
    final db = _Database();
    storage = _Storage();
    ledger = _Ledger();
    when(() => db.getWalletById('w')).thenAnswer(
      (_) async => Wallet(
        id: 'w',
        address: address,
        name: 'Ledger',
        walletType: 'ledger',
        chain: 'tezos',
        derivationIndex: 2,
        createdAt: 0,
        sortIndex: 0,
      ),
    );
    when(() => ledger.isConnected).thenReturn(true);
    when(
      () => ledger.getTezosPublicKey(
        account: 2,
        cancelled: any(named: 'cancelled'),
        ensureActive: any(named: 'ensureActive'),
      ),
    ).thenAnswer((_) async => publicKey);
    when(
      () => ledger.signTezosMessage(
        any(),
        account: 2,
        cancelled: any(named: 'cancelled'),
        ensureActive: any(named: 'ensureActive'),
      ),
    ).thenAnswer(
      (invocation) async => raw(
        await MultiChainDerivation.signTezosPayload(
          _mnemonic,
          2,
          invocation.positionalArguments[0] as Uint8List,
        ),
        5,
      ),
    );
    when(
      () => ledger.signTezosOperation(
        any(),
        account: 2,
        cancelled: any(named: 'cancelled'),
        ensureActive: any(named: 'ensureActive'),
      ),
    ).thenAnswer(
      (invocation) async => raw(
        (await MultiChainDerivation.signTezosOperation(
          _mnemonic,
          2,
          bytesToHex(invocation.positionalArguments[0] as Uint8List),
        )).signature,
        5,
      ),
    );
    manager = WalletManager(
      storage,
      db,
      _Repository(),
      ledger,
      _Vault(),
      _Keystone(),
    );
    controller = LedgerConnectController();
    GetIt.I.registerSingleton<LedgerConnectController>(controller);
    cancelled = Completer();
    active = true;
  });
  tearDown(() async {
    manager.dispose();
    controller.dispose();
    await GetIt.I.reset();
  });
  Future<Object> sign(bool operation) => operation
      ? manager.signTezosOperation(
          'w',
          forged,
          expectedAddress: address,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        )
      : manager.signTezosPayloadForWallet(
          'w',
          message,
          expectedAddress: address,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        );
  void noSigning() {
    verifyNever(
      () => ledger.signTezosMessage(
        any(),
        account: 2,
        cancelled: any(named: 'cancelled'),
        ensureActive: any(named: 'ensureActive'),
      ),
    );
    verifyNever(
      () => ledger.signTezosOperation(
        any(),
        account: 2,
        cancelled: any(named: 'cancelled'),
        ensureActive: any(named: 'ensureActive'),
      ),
    );
  }

  test(
    'Given a Ledger wallet, public-key lookup uses the stored index and matches the row',
    () async {
      expect(
        await manager.getTezosPublicKey(
          'w',
          expectedAddress: address,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        ),
        await MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 2),
      );
      verifyNever(() => storage.loadPrivateKey(any()));
      verifyNever(() => storage.loadMnemonicForSeedPhrase(any()));
    },
  );
  for (final operation in [false, true]) {
    test(
      'Given a reviewed ${operation ? 'operation' : 'message'}, device signatures match the local vector at index 2',
      () async {
        final result = await sign(operation);
        if (operation) {
          expect(
            result,
            await MultiChainDerivation.signTezosOperation(_mnemonic, 2, forged),
          );
          final invocation = verify(
            () => ledger.signTezosOperation(
              any(),
              account: 2,
              cancelled: captureAny(named: 'cancelled'),
              ensureActive: captureAny(named: 'ensureActive'),
            ),
          ).captured;
          expect(invocation, [cancelled.future, ensureActive]);
        } else {
          expect(
            result,
            await MultiChainDerivation.signTezosPayload(_mnemonic, 2, message),
          );
        }
        verifyNever(() => storage.loadPrivateKey(any()));
      },
    );
    test(
      'Given a wrong Ledger key for ${operation ? 'operation' : 'message'}, the device is never asked to sign',
      () async {
        final wrong = raw(
          await MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 3),
          4,
        );
        when(
          () => ledger.getTezosPublicKey(
            account: 2,
            cancelled: any(named: 'cancelled'),
            ensureActive: any(named: 'ensureActive'),
          ),
        ).thenAnswer((_) async => wrong);
        await expectLater(sign(operation), throwsStateError);
        noSigning();
      },
    );
    test(
      'Given cancellation during ${operation ? 'operation' : 'message'} connection, the prompt is released without signing',
      () async {
        when(() => ledger.isConnected).thenReturn(false);
        final received = Completer<LedgerConnectRequest>();
        final subscription = controller.requests.listen(received.complete);
        addTearDown(subscription.cancel);
        final future = sign(operation);
        final assertion = expectLater(
          future,
          throwsA(isA<LedgerNotConnectedException>()),
        );
        final request = await received.future;
        active = false;
        cancelled.complete();
        await assertion;
        expect(await request.completer.future, false);
        noSigning();
      },
    );
    test(
      'Given cancellation while the device key loads for ${operation ? 'operation' : 'message'}, signing stops at the key boundary',
      () async {
        final key = Completer<Uint8List>();
        when(
          () => ledger.getTezosPublicKey(
            account: 2,
            cancelled: any(named: 'cancelled'),
            ensureActive: any(named: 'ensureActive'),
          ),
        ).thenAnswer((_) => key.future);
        final future = sign(operation);
        final assertion = expectLater(future, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        active = false;
        key.complete(publicKey);
        await assertion;
        noSigning();
      },
    );
  }
  test(
    'Given an invalid device signature, no message signature is returned',
    () async {
      when(
        () => ledger.signTezosMessage(
          any(),
          account: 2,
          cancelled: any(named: 'cancelled'),
          ensureActive: any(named: 'ensureActive'),
        ),
      ).thenAnswer((_) async => Uint8List(64));
      await expectLater(sign(false), throwsStateError);
    },
  );
}
