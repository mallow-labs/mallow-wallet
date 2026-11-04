import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/network/ledger_connect_controller.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart' show Transaction;

class _Database extends Mock implements MallowDatabase {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Repository extends Mock implements WalletRepository {}

class _Ledger extends Mock implements LedgerService {}

class _SeedVault extends Mock implements SeedVaultService {}

class _Keystone extends Mock implements KeystoneSignService {}

const _address = '0x1111111111111111111111111111111111111111';

void main() {
  late WalletManager manager;
  late _Ledger ledger;
  late LedgerConnectController controller;
  late Completer<void> cancelled;
  late bool active;

  final transaction = Transaction(
    to: EthereumAddress.fromHex(_address),
    value: EtherAmount.inWei(BigInt.one),
    maxGas: 21000,
    maxFeePerGas: EtherAmount.inWei(BigInt.from(30000000000)),
    maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1000000000)),
    nonce: 0,
  );

  setUpAll(() => registerFallbackValue(Uint8List(0)));

  setUp(() {
    final db = _Database();
    when(() => db.getWalletById('w')).thenAnswer(
      (_) async => const Wallet(
        id: 'w',
        address: _address,
        name: 'Ledger',
        walletType: 'ledger',
        chain: 'ethereum',
        derivationIndex: 2,
        createdAt: 0,
        sortIndex: 0,
      ),
    );
    ledger = _Ledger();
    when(() => ledger.isConnected).thenReturn(false);
    when(() => ledger.signEthereumTransaction(any(), account: 2)).thenAnswer(
      (_) async => (
        v: 0,
        r: Uint8List.fromList([...List.filled(31, 0), 1]),
        s: Uint8List.fromList([...List.filled(31, 0), 1]),
      ),
    );
    when(
      () => ledger.signEthereumPersonalMessage(any(), account: 2),
    ).thenAnswer((_) async => Uint8List(65));
    manager = WalletManager(
      _Storage(),
      db,
      _Repository(),
      ledger,
      _SeedVault(),
      _Keystone(),
    );
    controller = LedgerConnectController();
    GetIt.I.registerSingleton<LedgerConnectController>(controller);
    cancelled = Completer<void>();
    active = true;
  });

  tearDown(() async {
    manager.dispose();
    controller.dispose();
    await GetIt.I.reset();
  });

  void ensureActive() {
    if (!active) throw StateError('Request cancelled');
  }

  Future<Uint8List> sign(bool message) => message
      ? manager.signEthereumPersonalMessageForWallet(
          'w',
          Uint8List.fromList([1, 2, 3]),
          expectedAddress: _address,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        )
      : manager.signEthereumTransaction(
          'w',
          transaction,
          chainId: 1,
          ensureActive: ensureActive,
          cancelled: cancelled.future,
        );

  void verifyNoSigning() {
    verifyNever(() => ledger.signEthereumTransaction(any(), account: 2));
    verifyNever(() => ledger.signEthereumPersonalMessage(any(), account: 2));
  }

  for (final message in [false, true]) {
    group(message ? 'Ethereum personal message' : 'Ethereum transaction', () {
      test(
        'cancellation while connecting resolves without device signing',
        () async {
          final received = Completer<LedgerConnectRequest>();
          final subscription = controller.requests.listen(received.complete);
          addTearDown(subscription.cancel);
          final result = sign(message);
          final assertion = expectLater(
            result,
            throwsA(isA<LedgerNotConnectedException>()),
          );
          final request = await received.future;
          active = false;
          cancelled.complete();

          await assertion.timeout(const Duration(seconds: 2));
          expect(await request.completer.future, isFalse);
          verifyNoSigning();
        },
      );

      test('liveness is checked after the connection finishes', () async {
        final received = Completer<LedgerConnectRequest>();
        final subscription = controller.requests.listen(received.complete);
        addTearDown(subscription.cancel);
        final result = sign(message);
        final assertion = expectLater(result, throwsStateError);
        final request = await received.future;
        active = false;
        request.completer.complete(true);

        await assertion;
        verifyNoSigning();
      });

      test(
        'cancellation during stale-connection recovery prevents retry',
        () async {
          when(() => ledger.isConnected).thenReturn(true);
          if (message) {
            when(
              () => ledger.signEthereumPersonalMessage(any(), account: 2),
            ).thenThrow(const LedgerNotConnectedException());
          } else {
            when(
              () => ledger.signEthereumTransaction(any(), account: 2),
            ).thenThrow(const LedgerNotConnectedException());
          }
          final received = Completer<LedgerConnectRequest>();
          final subscription = controller.requests.listen(received.complete);
          addTearDown(subscription.cancel);
          final result = sign(message);
          final assertion = expectLater(
            result,
            throwsA(isA<LedgerNotConnectedException>()),
          );
          final request = await received.future;
          active = false;
          cancelled.complete();

          await assertion.timeout(const Duration(seconds: 2));
          expect(await request.completer.future, isFalse);
          if (message) {
            verify(
              () => ledger.signEthereumPersonalMessage(any(), account: 2),
            ).called(1);
          } else {
            verify(
              () => ledger.signEthereumTransaction(any(), account: 2),
            ).called(1);
          }
          verifyNoSigning();
        },
      );

      test(
        'existing callers can sign without cancellation arguments',
        () async {
          when(() => ledger.isConnected).thenReturn(true);
          final result = message
              ? await manager.signEthereumPersonalMessageForWallet(
                  'w',
                  Uint8List.fromList([1, 2, 3]),
                  expectedAddress: _address,
                )
              : await manager.signEthereumTransaction(
                  'w',
                  transaction,
                  chainId: 1,
                );
          expect(result, isNotEmpty);
          if (message) {
            verify(
              () => ledger.signEthereumPersonalMessage(any(), account: 2),
            ).called(1);
          } else {
            verify(
              () => ledger.signEthereumTransaction(any(), account: 2),
            ).called(1);
          }
        },
      );
    });
  }
}
