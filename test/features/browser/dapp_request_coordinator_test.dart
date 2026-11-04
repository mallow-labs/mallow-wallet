import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/services/dapp_request_coordinator.dart';

void main() {
  const address = '11111111111111111111111111111111';
  final origin = Uri.parse('https://example.org');
  late String? stored;
  late DappPermissionService permissions;
  late DappRequestCoordinator coordinator;
  late DappWallet wallet;
  late bool current;
  late int approvals;
  late int executions;
  late Future<bool> Function(DappConnectionRequest) approve;
  late Future<Map<String, Object?>> Function(DappSigningRequest) execute;
  int sequence = 0;

  DappFrameContext frame({
    Uri? url,
    bool mainFrame = true,
    bool active = true,
  }) => DappFrameContext(
    tabId: 'tab',
    generation: 1,
    origin: url ?? origin,
    isMainFrame: mainFrame,
    isActive: active,
  );
  Map<String, dynamic> message(String method, [Map<String, dynamic>? params]) =>
      {'id': '${sequence++}', 'method': method, 'params': params ?? {}};
  Map<String, dynamic> transaction({String? chain}) => {
    'transaction': base64Encode([1, 2, 3]),
    'chain': ?chain,
  };
  int? errorCode(Map<String, Object?> result) =>
      (result['error'] as Map?)?['code'] as int?;

  setUp(() {
    stored = null;
    current = true;
    approvals = executions = 0;
    wallet = const DappWallet(
      id: 'wallet',
      address: address,
      canSign: true,
      chains: ['solana:mainnet', 'solana:devnet'],
    );
    permissions = DappPermissionService(
      read: () async => stored,
      write: (value) async {
        stored = value;
      },
    );
    approve = (_) async {
      approvals++;
      return true;
    };
    execute = (_) async {
      executions++;
      return {'transaction': 'AQID'};
    };
    coordinator = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => wallet,
      approveConnection: (request) => approve(request),
      execute: (request) => execute(request),
      isContextCurrent: (_) => current,
    );
  });
  tearDown(() async {
    coordinator.dispose();
    await permissions.dispose();
  });

  test(
    'Given no consent, silent connect exposes no address and signing fails',
    () async {
      final connect = await coordinator.handle(
        message('connect', {'onlyIfTrusted': true}),
        frame(),
      );
      final sign = await coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      expect(errorCode(connect), 4100);
      expect(errorCode(sign), 4100);
      expect(jsonEncode(connect), isNot(contains(address)));
      expect(approvals, 0);
      expect(executions, 0);
    },
  );

  test(
    'Given no consent, Wallet Standard silent connect returns empty accounts while legacy trusted connect rejects',
    () async {
      final standard = await coordinator.handle(
        message('connect', {'silent': true}),
        frame(),
      );
      final legacy = await coordinator.handle(
        message('connect', {'onlyIfTrusted': true}),
        frame(),
      );

      expect(standard['result'], {'accounts': <Object?>[]});
      expect(errorCode(legacy), 4100);
      expect(jsonEncode(standard), isNot(contains(address)));
      expect(approvals, 0);
    },
  );

  test(
    'Given approved origin and wallet, later connection uses remembered grant',
    () async {
      expect(
        (await coordinator.handle(message('connect'), frame()))['result'],
        containsPair('publicKey', address),
      );
      await coordinator.handle(message('connect'), frame());
      expect(approvals, 1);
      expect(await permissions.isGranted(origin.origin, address), isTrue);
      final reloaded = DappPermissionService(
        read: () async => stored,
        write: (value) async {
          stored = value;
        },
      );
      expect(await reloaded.isGranted(origin.origin, address), isTrue);
      await reloaded.dispose();
    },
  );

  test(
    'Given a different host, port or wallet, the existing grant does not apply',
    () async {
      await permissions.grant(origin.origin, address);
      for (final uri in ['https://other.org', 'https://example.org:444']) {
        final response = await coordinator.handle(
          message('connect', {'silent': true}),
          frame(url: Uri.parse(uri)),
        );
        expect(response['result'], {'accounts': <Object?>[]});
        expect(jsonEncode(response), isNot(contains(address)));
      }
      wallet = const DappWallet(
        id: 'other',
        address: 'other-address',
        canSign: true,
      );
      final response = await coordinator.handle(
        message('connect', {'silent': true}),
        frame(),
      );
      expect(response['result'], {'accounts': <Object?>[]});
      expect(jsonEncode(response), isNot(contains('other-address')));
    },
  );

  test(
    'Given a subframe, HTTP page, background tab or stale document, bridge rejects before consent',
    () async {
      for (final context in [
        frame(mainFrame: false),
        frame(active: false),
        frame(url: Uri.parse('http://example.org')),
      ]) {
        expect(
          errorCode(await coordinator.handle(message('connect'), context)),
          4100,
        );
      }
      current = false;
      expect(
        errorCode(await coordinator.handle(message('connect'), frame())),
        4100,
      );
      expect(approvals, 0);
    },
  );

  test(
    'Given a view-only wallet, a transaction reaches the native review but a message does not',
    () async {
      wallet = const DappWallet(id: 'view', address: address, canSign: false);
      expect(
        (await coordinator.handle(message('connect'), frame()))['result'],
        containsPair('canSign', false),
      );
      final messageResult = await coordinator.handle(
        message('signMessage', {
          'message': base64Encode([1, 2, 3]),
        }),
        frame(),
      );
      expect(errorCode(messageResult), 4200);
      expect((messageResult['error'] as Map)['message'], contains('view-only'));
      expect(executions, 0);

      // The review shows what the transaction would do; the signing service,
      // not the coordinator, refuses to sign for a view-only wallet.
      await coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      expect(executions, 1);
    },
  );

  test(
    'Given a transaction-only wallet, message signing rejects before native approval while transactions remain available',
    () async {
      wallet = const DappWallet(
        id: 'ledger',
        address: address,
        canSign: true,
        canSignMessages: false,
      );
      await permissions.grant(origin.origin, address);

      final connect = await coordinator.handle(message('connect'), frame());
      final messageResult = await coordinator.handle(
        message('signMessage', {
          'message': base64Encode([1, 2, 3]),
        }),
        frame(),
      );
      final transactionResult = await coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );

      expect(connect['result'], containsPair('canSignMessages', false));
      expect(errorCode(messageResult), 4200);
      expect(
        (messageResult['error'] as Map)['message'],
        contains('not message signing'),
      );
      expect(transactionResult['result'], isNotNull);
      expect(executions, 1);
    },
  );

  test(
    'Given unsupported chain or wrong account, request fails before execution',
    () async {
      await permissions.grant(origin.origin, address);
      expect(
        errorCode(
          await coordinator.handle(
            message('signTransaction', transaction(chain: 'solana:testnet')),
            frame(),
          ),
        ),
        4901,
      );
      expect(
        errorCode(
          await coordinator.handle(
            message('signTransaction', {...transaction(), 'account': 'other'}),
            frame(),
          ),
        ),
        4100,
      );
      expect(executions, 0);
    },
  );

  test(
    'Given navigation during connection, pending sheet receives cancellation and no grant survives',
    () async {
      final entered = Completer<DappConnectionRequest>();
      final decision = Completer<bool>();
      approve = (request) {
        entered.complete(request);
        return decision.future;
      };
      final response = coordinator.handle(message('connect'), frame());
      final request = await entered.future;
      coordinator.invalidate();
      await request.cancelled;
      expect(errorCode(await response), 4001);
      decision.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(await permissions.list(), isEmpty);
      expect(request.ensureActive, throwsA(isA<DappException>()));
    },
  );

  test(
    'Given wallet switch during approval, reviewed signer cannot be replaced',
    () async {
      await permissions.grant(origin.origin, address);
      final entered = Completer<DappSigningRequest>();
      final finish = Completer<void>();
      execute = (request) async {
        entered.complete(request);
        await finish.future;
        request.ensureActive();
        executions++;
        return {};
      };
      final response = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await entered.future;
      wallet = const DappWallet(
        id: 'different-wallet',
        address: address,
        canSign: true,
      );
      finish.complete();
      expect(errorCode(await response), 4001);
      expect(executions, 0);
    },
  );

  test(
    'Given an external signer returning before resume, the approved signature is delivered',
    () async {
      coordinator.dispose();
      var continuing = true;
      coordinator = DappRequestCoordinator(
        permissions: permissions,
        currentWallet: () => wallet,
        approveConnection: (request) => approve(request),
        execute: (request) => execute(request),
        isContextCurrent: (_) => current,
        isRequestCurrent: (_) => continuing,
      );
      await permissions.grant(origin.origin, address);
      final entered = Completer<DappSigningRequest>();
      final finish = Completer<void>();
      execute = (request) async {
        entered.complete(request);
        await finish.future;
        request.ensureActive();
        return {'signature': 'AQID'};
      };
      final response = coordinator.handle(
        message('signMessage', {'message': base64Encode(utf8.encode('hi'))}),
        frame(),
      );
      await entered.future;
      // The signer's activity leaves the app inactive: no new admissions.
      current = false;
      expect(
        errorCode(await coordinator.handle(message('connect'), frame())),
        4100,
      );
      finish.complete();
      expect((await response)['result'], {'signature': 'AQID'});

      // Backgrounding ends the in-flight request as well.
      current = true;
      final second = Completer<void>();
      execute = (request) async {
        await second.future;
        request.ensureActive();
        return {'signature': 'AQID'};
      };
      final cancelled = coordinator.handle(
        message('signMessage', {'message': base64Encode(utf8.encode('hi'))}),
        frame(),
      );
      await Future<void>.delayed(Duration.zero);
      continuing = false;
      second.complete();
      expect(errorCode(await cancelled), 4100);
    },
  );

  test(
    'Given revoked consent during approval, signing freshness fails',
    () async {
      await permissions.grant(origin.origin, address);
      final entered = Completer<DappSigningRequest>();
      final finish = Completer<void>();
      execute = (request) async {
        entered.complete(request);
        await finish.future;
        request.ensureActive();
        return {};
      };
      final response = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await entered.future;
      await permissions.revoke(origin.origin, address);
      finish.complete();
      expect(errorCode(await response), 4001);
    },
  );

  test(
    'Given duplicate ID during approval, duplicate cannot remove original cancellation',
    () async {
      final entered = Completer<DappConnectionRequest>();
      final finish = Completer<bool>();
      approve = (request) {
        entered.complete(request);
        return finish.future;
      };
      final original = message('connect');
      final response = coordinator.handle(original, frame());
      await entered.future;
      expect(errorCode(await coordinator.handle(original, frame())), -32600);
      coordinator.invalidate();
      expect(errorCode(await response), 4001);
      finish.complete(false);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'Given queued requests, only one approval executes and payload is immutable',
    () async {
      await permissions.grant(origin.origin, address);
      final entered = Completer<DappSigningRequest>();
      final finish = Completer<void>();
      final captured = <DappSigningRequest>[];
      execute = (request) async {
        captured.add(request);
        if (captured.length == 1) {
          entered.complete(request);
          await finish.future;
        }
        request.ensureActive();
        return {};
      };
      final first = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await entered.future;
      final secondMessage = message(
        'signTransaction',
        transaction(chain: 'solana:devnet'),
      );
      final second = coordinator.handle(secondMessage, frame());
      (secondMessage['params'] as Map)['transaction'] = base64Encode([9]);
      expect(captured, hasLength(1));
      finish.complete();
      await first;
      await second;
      expect(captured, hasLength(2));
      expect(captured[1].chain, 'solana:devnet');
      expect(captured[1].payloads.single, [1, 2, 3]);
      expect(() => captured[1].payloads.single[0] = 9, throwsUnsupportedError);
    },
  );

  test(
    'Given oversized batch, message or transaction, no execution occurs',
    () async {
      await permissions.grant(origin.origin, address);
      for (final request in [
        message('signAllTransactions', {
          'transactions': List.filled(101, 'AQ=='),
        }),
        message('signTransaction', {
          'transaction': base64Encode(Uint8List(1233)),
        }),
        message('signMessage', {'message': base64Encode(Uint8List(65537))}),
      ]) {
        expect(errorCode(await coordinator.handle(request, frame())), -32602);
      }
      expect(executions, 0);
    },
  );

  test(
    'Given cancellation during secure grant write, stored grant rolls back',
    () async {
      await permissions.dispose();
      final writing = Completer<void>();
      final finishWrite = Completer<void>();
      var writes = 0;
      permissions = DappPermissionService(
        read: () async => stored,
        write: (value) async {
          if (writes++ == 0) {
            writing.complete();
            await finishWrite.future;
          }
          stored = value;
        },
      );
      coordinator.dispose();
      coordinator = DappRequestCoordinator(
        permissions: permissions,
        currentWallet: () => wallet,
        approveConnection: (request) => approve(request),
        execute: (request) => execute(request),
        isContextCurrent: (_) => current,
      );
      final response = coordinator.handle(message('connect'), frame());
      await writing.future;
      coordinator.invalidate();
      expect(errorCode(await response), 4001);
      finishWrite.complete();
      expect(await permissions.list(), isEmpty);
    },
  );

  test(
    'Given an empty off-chain message, native review receives the exact bytes',
    () async {
      await permissions.grant(origin.origin, address);
      execute = (request) async {
        expect(request.payloads.single, isEmpty);
        return {'signature': 'approved'};
      };
      expect(
        (await coordinator.handle(
          message('signMessage', {'message': ''}),
          frame(),
        ))['result'],
        containsPair('signature', 'approved'),
      );
    },
  );

  test(
    'Given disconnect during signing, approval cancels immediately and disconnect succeeds despite grant listeners',
    () async {
      await permissions.grant(origin.origin, address);
      final entered = Completer<void>();
      execute = (request) async {
        entered.complete();
        await request.cancelled;
        request.ensureActive();
        executions++;
        return {};
      };
      final listener = permissions.changes.listen(
        (_) => coordinator.invalidate(),
      );
      final signing = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await entered.future;
      final disconnect = await coordinator.handle(
        message('disconnect'),
        frame(),
      );
      expect(errorCode(await signing), 4001);
      expect(disconnect['result'], isEmpty);
      expect(executions, 0);
      expect(await permissions.list(), isEmpty);
      await listener.cancel();
    },
  );

  test(
    'Given cancelled signing cleanup is still running, the next request stays serialized',
    () async {
      await permissions.grant(origin.origin, address);
      final firstStarted = Completer<void>();
      final cleanup = Completer<void>();
      final secondStarted = Completer<void>();
      var call = 0;
      execute = (request) async {
        call++;
        if (call == 1) {
          firstStarted.complete();
          await request.cancelled;
          await cleanup.future;
          request.ensureActive();
        }
        secondStarted.complete();
        return {'transaction': 'AQID'};
      };

      final first = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await firstStarted.future;
      coordinator.invalidate();
      expect(errorCode(await first), 4001);

      final second = coordinator.handle(
        message('signTransaction', transaction()),
        frame(),
      );
      await Future<void>.value();
      expect(secondStarted.isCompleted, isFalse);

      cleanup.complete();
      await secondStarted.future;
      expect((await second)['result'], containsPair('transaction', 'AQID'));
      expect(call, 2);
    },
  );

  test('Given malformed send options, no native execution occurs', () async {
    await permissions.grant(origin.origin, address);
    for (final options in <Map<String, Object?>>[
      {'commitment': 'root'},
      {'commitment': true},
      {'preflightCommitment': 1},
      {'skipPreflight': 'true'},
      {'minContextSlot': -1},
      {'minContextSlot': 1.5},
      {'maxRetries': 1},
      {'maxRetries': -1},
    ]) {
      expect(
        errorCode(
          await coordinator.handle(
            message('signAndSendTransaction', {
              ...transaction(),
              'options': options,
            }),
            frame(),
          ),
        ),
        -32602,
      );
    }
    expect(executions, 0);
  });

  test(
    'Given valid send options, exact immutable options reach native execution',
    () async {
      await permissions.grant(origin.origin, address);
      final options = <String, Object?>{
        'commitment': 'finalized',
        'preflightCommitment': 'processed',
        'skipPreflight': true,
        'minContextSlot': 123,
        'maxRetries': 0,
      };
      execute = (request) async {
        expect(request.options, options);
        expect(
          () => request.options['skipPreflight'] = false,
          throwsUnsupportedError,
        );
        return {'signature': 'submitted'};
      };
      expect(
        (await coordinator.handle(
          message('signAndSendTransaction', {
            ...transaction(),
            'options': options,
          }),
          frame(),
        ))['result'],
        containsPair('signature', 'submitted'),
      );
    },
  );

  test('Given disconnect, remembered permission is revoked', () async {
    await permissions.grant(origin.origin, address);
    expect(
      (await coordinator.handle(message('disconnect'), frame()))['result'],
      isEmpty,
    );
    expect(await permissions.list(), isEmpty);
  });
}
