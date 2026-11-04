import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/services/dapp_request_coordinator.dart';

void main() {
  const solanaAddress = '11111111111111111111111111111111';
  const ethAddress = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
  final origin = Uri.parse('https://example.org');
  late String? stored;
  late DappPermissionService permissions;
  late DappRequestCoordinator coordinator;
  late DappWallet? ethereum;
  late int approvals;
  late List<DappSigningRequest> executed;
  late Completer<Map<String, Object?>>? hold;
  late List<(String, List<Object?>)> reads;
  var sequence = 0;

  final frame = DappFrameContext(
    tabId: 'tab',
    generation: 1,
    origin: origin,
    isMainFrame: true,
    isActive: true,
  );
  Map<String, dynamic> eth(String method, [Map<String, dynamic>? params]) => {
    'id': '${sequence++}',
    'method': method,
    'namespace': 'eip155',
    'params': params ?? {},
  };
  int? errorCode(Map<String, Object?> result) =>
      (result['error'] as Map?)?['code'] as int?;

  setUp(() {
    stored = null;
    approvals = 0;
    executed = [];
    hold = null;
    reads = [];
    ethereum = const DappWallet(
      id: 'eth-wallet',
      address: ethAddress,
      canSign: true,
      chains: ['eip155:1'],
    );
    permissions = DappPermissionService(
      read: () async => stored,
      write: (value) async {
        stored = value;
      },
    );
    coordinator = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => const DappWallet(
        id: 'sol-wallet',
        address: solanaAddress,
        canSign: true,
      ),
      currentEthereumWallet: () => ethereum,
      ethereumRead: (method, params) async {
        reads.add((method, params));
        return '0x10';
      },
      approveConnection: (_) async {
        approvals++;
        return true;
      },
      execute: (request) {
        executed.add(request);
        return hold?.future ?? Future.value({'signature': '0x00'});
      },
      isContextCurrent: (_) => true,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    await permissions.dispose();
  });

  Future<void> connect() async {
    final result = await coordinator.handle(eth('connect'), frame);
    expect(result['error'], isNull);
  }

  test('without an Ethereum wallet the namespace is unsupported', () async {
    ethereum = null;
    expect(errorCode(await coordinator.handle(eth('connect'), frame)), 4100);
    final unsupported = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => null,
      approveConnection: (_) async => true,
      execute: (_) async => {},
      isContextCurrent: (_) => true,
    );
    expect(errorCode(await unsupported.handle(eth('connect'), frame)), -32601);
    unsupported.dispose();
  });

  test('an unknown namespace is an invalid request', () async {
    final message = eth('connect')..['namespace'] = 'cosmos';
    expect(errorCode(await coordinator.handle(message, frame)), -32600);
  });

  test(
    'silent connect returns no accounts without an Ethereum wallet',
    () async {
      ethereum = null;

      final result = await coordinator.handle(
        eth('connect', {'silent': true}),
        frame,
      );

      expect(result, {
        'result': {'accounts': <Object?>[]},
      });
      expect(approvals, 0);
      expect(executed, isEmpty);
      expect(stored, isNull);
    },
  );

  test('silent connect stays silent and empty until approved', () async {
    final silent = await coordinator.handle(
      eth('connect', {'silent': true}),
      frame,
    );
    expect(silent['result'], {'accounts': <Object?>[]});
    expect(approvals, 0);
    await connect();
    expect(approvals, 1);
    final again = await coordinator.handle(
      eth('connect', {'silent': true}),
      frame,
    );
    expect((again['result']! as Map)['accounts'], [ethAddress]);
    expect((again['result']! as Map)['chainId'], '0x1');
    expect(approvals, 1);
  });

  test('an Ethereum grant does not connect the Solana provider', () async {
    await connect();
    final solana = await coordinator.handle({
      'id': 'sol',
      'method': 'connect',
      'params': {'onlyIfTrusted': true},
    }, frame);
    expect(errorCode(solana), 4100);
  });

  test('signing requires the grant and the connected account', () async {
    expect(
      errorCode(
        await coordinator.handle(
          eth('personal_sign', {'message': '0x68', 'address': ethAddress}),
          frame,
        ),
      ),
      4100,
    );
    await connect();
    expect(
      errorCode(
        await coordinator.handle(
          eth('personal_sign', {
            'message': '0x68',
            'address': '0x${'00' * 20}',
          }),
          frame,
        ),
      ),
      4100,
    );
    expect(executed, isEmpty);
  });

  test('personal_sign decodes hex and keeps other text as UTF-8', () async {
    await connect();
    await coordinator.handle(
      eth('personal_sign', {
        'message': '0x68656c6c6f',
        'address': ethAddress.toLowerCase(),
      }),
      frame,
    );
    await coordinator.handle(
      eth('personal_sign', {'message': 'hello', 'address': ethAddress}),
      frame,
    );
    expect(executed.map((r) => utf8.decode(r.payloads.single)), [
      'hello',
      'hello',
    ]);
    expect(executed.first.chain, 'eip155:1');
    expect(executed.first.wallet.address, ethAddress);
  });

  test(
    'typed data is refused for a wallet without a typed-data path',
    () async {
      ethereum = const DappWallet(
        id: 'eth-wallet',
        address: ethAddress,
        canSign: true,
        canSignTypedData: false,
        chains: ['eip155:1'],
      );
      await connect();
      final result = await coordinator.handle(
        eth('eth_signTypedData_v4', {'address': ethAddress, 'typedData': '{}'}),
        frame,
      );
      expect(errorCode(result), 4200);
      expect(executed, isEmpty);
    },
  );

  test('view-only wallets connect but cannot sign', () async {
    ethereum = const DappWallet(
      id: 'eth-wallet',
      address: ethAddress,
      canSign: false,
      chains: ['eip155:1'],
    );
    await connect();
    final result = await coordinator.handle(
      eth('eth_sendTransaction', {
        'transaction': {'from': ethAddress, 'to': ethAddress},
      }),
      frame,
    );
    expect(errorCode(result), 4200);
  });

  group('eth_sendTransaction refuses before review', () {
    Future<int?> send(Map<String, Object?> transaction) async => errorCode(
      await coordinator.handle(
        eth('eth_sendTransaction', {'transaction': transaction}),
        frame,
      ),
    );

    setUp(connect);

    test('another sender', () async {
      expect(await send({'from': '0x${'00' * 20}', 'to': ethAddress}), 4100);
    });

    test('a contract deployment', () async {
      expect(await send({'from': ethAddress, 'data': '0x60'}), 4200);
    });

    test('an EIP-7702 delegation', () async {
      expect(
        await send({
          'from': ethAddress,
          'to': ethAddress,
          'authorizationList': <Object?>[],
        }),
        4200,
      );
    });

    test('another network', () async {
      expect(
        await send({'from': ethAddress, 'to': ethAddress, 'chainId': '0x89'}),
        4901,
      );
    });

    test('a non-hex value', () async {
      expect(
        await send({'from': ethAddress, 'to': ethAddress, 'value': '100'}),
        -32602,
      );
    });

    tearDown(() => expect(executed, isEmpty));
  });

  test('a valid transaction reaches review in canonical form', () async {
    await connect();
    await coordinator.handle(
      eth('eth_sendTransaction', {
        'transaction': {
          'to': ethAddress,
          'value': '0x0de0b6b3a7640000',
          'input': '0xABCD',
          'nonce': '0x99',
        },
      }),
      frame,
    );
    expect(jsonDecode(utf8.decode(executed.single.payloads.single)), {
      'from': ethAddress.toLowerCase(),
      'to': ethAddress.toLowerCase(),
      'value': '0xde0b6b3a7640000',
      'data': '0xabcd',
    });
  });

  test('reads skip the approval lane but not the allowlist', () async {
    await connect();
    hold = Completer();
    final pending = coordinator.handle(
      eth('personal_sign', {'message': '0x68', 'address': ethAddress}),
      frame,
    );
    await Future<void>.delayed(Duration.zero);
    final read = await coordinator.handle(
      eth('read', {'method': 'eth_blockNumber', 'params': <Object?>[]}),
      frame,
    );
    expect(read['result'], '0x10');
    expect(reads.single.$1, 'eth_blockNumber');
    final refused = await coordinator.handle(
      eth('read', {
        'method': 'eth_sendRawTransaction',
        'params': ['0x00'],
      }),
      frame,
    );
    expect(errorCode(refused), 4200);
    expect(reads, hasLength(1));
    hold!.complete({'signature': '0x00'});
    expect((await pending)['result'], {'signature': '0x00'});
  });

  test('a silent account check does not wait behind an open review', () async {
    await connect();
    hold = Completer();
    final pending = coordinator.handle(
      eth('personal_sign', {'message': '0x68', 'address': ethAddress}),
      frame,
    );
    await Future<void>.delayed(Duration.zero);
    final silent = await coordinator.handle(
      eth('connect', {'silent': true}),
      frame,
    );
    expect((silent['result']! as Map)['accounts'], [ethAddress]);
    hold!.complete({'signature': '0x00'});
    await pending;
  });

  test('past a certificate exception a saved grant is never silent', () async {
    await connect();
    final untrusted = DappFrameContext(
      tabId: 'tab',
      generation: 1,
      origin: origin,
      isMainFrame: true,
      isActive: true,
      certificateException: true,
    );
    final silent = await coordinator.handle(
      eth('connect', {'silent': true}),
      untrusted,
    );
    expect(silent['result'], {'accounts': <Object?>[]});
    await coordinator.handle(eth('connect'), untrusted);
    expect(approvals, 2);
  });

  test('disconnect revokes only the Ethereum grant', () async {
    await connect();
    await coordinator.handle({
      'id': 'sol',
      'method': 'connect',
      'params': <String, Object?>{},
    }, frame);
    await coordinator.handle(eth('disconnect'), frame);
    expect(await permissions.isGranted(origin.origin, ethAddress), isFalse);
    expect(await permissions.isGranted(origin.origin, solanaAddress), isTrue);
  });
}
