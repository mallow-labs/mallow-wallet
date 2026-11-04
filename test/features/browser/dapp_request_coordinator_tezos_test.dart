import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/models/account.dart' show WalletType;
import 'package:mallow_wallet/core/crypto/tezos_forge.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/services/dapp_request_coordinator.dart';
import 'package:mallow_wallet/features/browser/services/tezos_dapp_adapter.dart';

void main() {
  const address = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
  const key = 'edpkuRXPQpuQyDemXE59dyYA1Eu5T94waiiL5PjcWDSkkw86ZvxR2j';
  final frame = DappFrameContext(
    tabId: 'tab',
    generation: 1,
    origin: Uri.parse('https://site.example'),
    isMainFrame: true,
    isActive: true,
  );
  late DappPermissionService permissions;
  late DappRequestCoordinator coordinator;
  late DappWallet? wallet;
  late List<DappSigningRequest> executed;
  late Completer<Map<String, Object?>>? hold;
  String? cachedKey;
  Future<void>? keyCancellation;
  var sequence = 0;
  var approvals = 0;

  Map<String, dynamic> message(
    String method, [
    Map<String, Object?> params = const {},
  ]) => {
    'id': '${sequence++}',
    'namespace': 'tezos',
    'method': method,
    'params': params,
  };
  int? code(Map<String, Object?> response) =>
      (response['error'] as Map?)?['code'] as int?;

  setUp(() {
    String? stored;
    approvals = 0;
    cachedKey = null;
    keyCancellation = null;
    executed = [];
    hold = null;
    wallet = const DappWallet(
      id: 'tez',
      address: address,
      canSign: true,
      chains: [tezosMainnet],
    );
    permissions = DappPermissionService(
      read: () async => stored,
      write: (s) async {
        stored = s;
      },
    );
    coordinator = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => null,
      currentTezosWallet: () => wallet,
      tezosPublicKey: (_, active) async {
        active();
        return key;
      },
      cachedTezosPublicKey: (_) => cachedKey,
      connectTezosPublicKey: (_, active, cancelled) async {
        active();
        cachedKey = key;
        keyCancellation = cancelled;
        return key;
      },
      approveConnection: (_) async {
        approvals++;
        return true;
      },
      execute: (request) {
        executed.add(request);
        return hold?.future ?? Future.value({'signature': 'edsig'});
      },
      isContextCurrent: (_) => true,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    await permissions.dispose();
  });

  test(
    'Given no grant, silent connection reveals no account and never prompts',
    () async {
      expect(
        (await coordinator.handle(
          message('connect', {'silent': true}),
          frame,
        ))['result'],
        {'accounts': <Object>[]},
      );
      expect(approvals, 0);
      final result =
          (await coordinator.handle(message('connect'), frame))['result']
              as Map;
      expect(result['publicKey'], key);
      expect(result['address'], address);
      expect(approvals, 1);
    },
  );
  test(
    'Given a mainnet request naming the site\'s own node, it connects and signs',
    () async {
      const network = {'type': 'mainnet', 'rpcUrl': 'https://rpc.site.example'};
      final result =
          (await coordinator.handle(
                message('connect', {
                  'network': network,
                  'scopes': ['operation_request', 'sign'],
                }),
                frame,
              ))['result']
              as Map;
      expect(result['address'], address);
      expect(result['network'], {'type': 'mainnet'});
      final packed = MultiChainDerivation.packTezosMicheline(
        'Tezos Signed Message: hello',
      );
      await coordinator.handle(
        message('signPayload', {
          'network': network,
          'payload': bytesToHex(packed),
          'signingType': 'micheline',
          'sourceAddress': address,
        }),
        frame,
      );
      expect(executed.single.payloads.single, packed);
    },
  );
  test(
    'Given a connected wallet, packed messages reach review without repacking',
    () async {
      await coordinator.handle(message('connect'), frame);
      final packed = MultiChainDerivation.packTezosMicheline(
        'Tezos Signed Message: hello',
      );
      await coordinator.handle(
        message('signPayload', {
          'payload': bytesToHex(packed),
          'signingType': 'micheline',
          'sourceAddress': address,
        }),
        frame,
      );
      expect(executed.single.payloads.single, packed);
      expect(executed.single.chain, tezosMainnet);
      expect(executed.single.options, {'signingType': 'micheline'});
    },
  );
  test(
    'Given raw operation bytes, signing is refused before execute',
    () async {
      await coordinator.handle(message('connect'), frame);
      expect(
        code(
          await coordinator.handle(
            message('signPayload', {
              'payload': '03${'00' * 32}',
              'signingType': 'raw',
            }),
            frame,
          ),
        ),
        4200,
      );
      expect(executed, isEmpty);
    },
  );
  test(
    'Given wrong source or network, operations never reach review',
    () async {
      await coordinator.handle(message('connect'), frame);
      final operation = {
        'kind': 'transaction',
        'destination': address,
        'amount': '1',
      };
      expect(
        code(
          await coordinator.handle(
            message('sendOperations', {
              'sourceAddress': 'another',
              'operationDetails': [operation],
            }),
            frame,
          ),
        ),
        4100,
      );
      expect(
        code(
          await coordinator.handle(
            message('sendOperations', {
              'network': {'type': 'ghostnet'},
              'operationDetails': [operation],
            }),
            frame,
          ),
        ),
        4901,
      );
      expect(executed, isEmpty);
    },
  );
  test(
    'Given site counters, the wallet owns source and counter in canonical review',
    () async {
      await coordinator.handle(message('connect'), frame);
      await coordinator.handle(
        message('sendOperations', {
          'operationDetails': [
            {
              'kind': 'transaction',
              'destination': address,
              'amount': '0001',
              'source': address,
              'counter': '999',
            },
          ],
        }),
        frame,
      );
      expect(jsonDecode(utf8.decode(executed.single.payloads.single)), [
        {'kind': 'transaction', 'destination': address, 'amount': '1'},
      ]);
    },
  );
  test(
    'Given a pending review, disconnect cancels and revokes only Tezos',
    () async {
      await coordinator.handle(message('connect'), frame);
      await permissions.grant(frame.canonicalOrigin, '0xother');
      hold = Completer();
      final pending = coordinator.handle(
        message('signPayload', {
          'payload': bytesToHex(
            MultiChainDerivation.packTezosMicheline('hello'),
          ),
        }),
        frame,
      );
      await Future<void>.delayed(Duration.zero);
      await coordinator.handle(message('disconnect'), frame);
      expect(code(await pending), 4001);
      expect(
        await permissions.isGranted(frame.canonicalOrigin, address),
        false,
      );
      expect(
        await permissions.isGranted(frame.canonicalOrigin, '0xother'),
        true,
      );
      hold!.complete({});
    },
  );
  test(
    'Given a wallet switch while queued, the pinned request is cancelled',
    () async {
      await coordinator.handle(message('connect'), frame);
      hold = Completer();
      final pending = coordinator.handle(
        message('signPayload', {
          'payload': bytesToHex(
            MultiChainDerivation.packTezosMicheline('hello'),
          ),
        }),
        frame,
      );
      await Future<void>.delayed(Duration.zero);
      wallet = null;
      hold!.complete({'signature': 'stale'});
      expect(code(await pending), 4001);
    },
  );
  test(
    'Given a frame without native main-frame provenance, no connection prompts',
    () async {
      final subframe = DappFrameContext(
        tabId: 'tab',
        generation: 1,
        origin: frame.origin,
        isMainFrame: false,
        isActive: true,
      );
      expect(
        code(await coordinator.handle(message('connect'), subframe)),
        4100,
      );
      expect(approvals, 0);
    },
  );
  test(
    'Given message-only permission, operations require a new approval',
    () async {
      await coordinator.handle(
        message('connect', {
          'scopes': ['sign'],
        }),
        frame,
      );
      final refused = await coordinator.handle(
        message('sendOperations', {
          'operationDetails': [
            {'kind': 'transaction', 'destination': address, 'amount': '1'},
          ],
        }),
        frame,
      );
      expect(code(refused), 4100);
      expect(executed, isEmpty);
      await coordinator.handle(
        message('connect', {
          'scopes': ['sign', 'operation_request'],
        }),
        frame,
      );
      expect(approvals, 2);
      expect(
        await permissions.hasScope(
          frame.canonicalOrigin,
          address,
          'operation_request',
        ),
        true,
      );
    },
  );
  test(
    'Given an uncached Ledger grant, silent restoration cannot prompt for a connection',
    () async {
      wallet = const DappWallet(
        id: 'tez',
        address: address,
        canSign: true,
        chains: [tezosMainnet],
        type: WalletType.ledger,
      );
      await permissions.grant(
        frame.canonicalOrigin,
        address,
        scopes: ['sign', 'operation_request'],
      );
      expect(
        (await coordinator.handle(
          message('connect', {'silent': true}),
          frame,
        ))['result'],
        {'accounts': <Object>[]},
      );
      expect(keyCancellation, isNull);
      expect(approvals, 0);
      await coordinator.handle(message('connect'), frame);
      expect(keyCancellation, isNotNull);
      final restored =
          (await coordinator.handle(
                message('connect', {'silent': true}),
                frame,
              ))['result']
              as Map;
      expect(restored['publicKey'], key);
      expect(approvals, 0);
    },
  );
}
