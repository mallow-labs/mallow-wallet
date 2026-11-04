import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/network/ledger_connect_controller.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';

class _Database extends Mock implements MallowDatabase {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Repository extends Mock implements WalletRepository {}

class _Ledger extends Mock implements LedgerService {}

class _SeedVault extends Mock implements SeedVaultService {}

class _Keystone extends Mock implements KeystoneSignService {}

const _address = '0x1111111111111111111111111111111111111111';

final _permit = Eip712TypedData.parse({
  'types': {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
      {'name': 'verifyingContract', 'type': 'address'},
    ],
    'Permit': [
      {'name': 'owner', 'type': 'address'},
      {'name': 'value', 'type': 'uint256'},
      {'name': 'tags', 'type': 'bytes4[]'},
    ],
  },
  'primaryType': 'Permit',
  'domain': {
    'name': 'Token',
    'chainId': '0x1',
    'verifyingContract': '0x2222222222222222222222222222222222222222',
  },
  'message': {
    'owner': _address,
    'value': '1000',
    'tags': ['0x01020304'],
  },
});

void main() {
  late WalletManager manager;
  late _Ledger ledger;
  late LedgerConnectController controller;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      const Eip712LedgerMessage(
        types: {},
        primaryType: '',
        domain: {},
        message: {},
      ),
    );
  });

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
    when(() => ledger.isConnected).thenReturn(true);
    when(
      () => ledger.signEthereumTypedData(
        message: any(named: 'message'),
        domainSeparator: any(named: 'domainSeparator'),
        messageHash: any(named: 'messageHash'),
        account: any(named: 'account'),
        cancelled: any(named: 'cancelled'),
      ),
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
  });

  tearDown(() async {
    manager.dispose();
    controller.dispose();
    await GetIt.I.reset();
  });

  test('a Ledger wallet streams the reviewed message and its hashes at its '
      'account index', () async {
    final cancelled = Completer<void>();
    await manager.signEthereumTypedDataForWallet(
      'w',
      _permit,
      expectedAddress: _address,
      cancelled: cancelled.future,
    );
    final call = verify(
      () => ledger.signEthereumTypedData(
        message: captureAny(named: 'message'),
        domainSeparator: captureAny(named: 'domainSeparator'),
        messageHash: captureAny(named: 'messageHash'),
        account: 2,
        cancelled: cancelled.future,
      ),
    )..called(1);
    final [
      message as Eip712LedgerMessage,
      domainSeparator as Uint8List,
      messageHash as Uint8List,
    ] = call.captured;
    expect(domainSeparator, _permit.domainSeparator);
    expect(messageHash, _permit.structHash);
    expect(message.primaryType, 'Permit');
    expect(message.types['Permit']!.map((f) => '${f.type} ${f.name}'), [
      'address owner',
      'uint256 value',
      'bytes4[] tags',
    ]);
    // Canonical leaves, not the JSON the website sent.
    expect(message.domain['chainId'], BigInt.one);
    expect(message.domain['verifyingContract'], hasLength(20));
    expect(message.message['value'], BigInt.from(1000));
    expect(message.message['tags'], [
      [1, 2, 3, 4],
    ]);
  });

  test(
    'a request cancelled before the device is reached does not sign',
    () async {
      await expectLater(
        manager.signEthereumTypedDataForWallet(
          'w',
          _permit,
          expectedAddress: _address,
          ensureActive: () => throw StateError('Request cancelled'),
        ),
        throwsStateError,
      );
      verifyNever(
        () => ledger.signEthereumTypedData(
          message: any(named: 'message'),
          domainSeparator: any(named: 'domainSeparator'),
          messageHash: any(named: 'messageHash'),
          account: any(named: 'account'),
          cancelled: any(named: 'cancelled'),
        ),
      );
    },
  );
}
