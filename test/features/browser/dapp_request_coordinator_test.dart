import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart' show WalletType;
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/models/solana_offchain_message.dart';
import 'package:mallow_wallet/features/browser/services/dapp_permission_service.dart';
import 'package:mallow_wallet/features/browser/services/dapp_request_coordinator.dart';
import 'package:solana/base58.dart';

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

  test('a served request reports its namespace as activity', () async {
    final activity = <String>[];
    final watched = DappRequestCoordinator(
      permissions: permissions,
      currentWallet: () => wallet,
      approveConnection: (request) => approve(request),
      execute: (request) => execute(request),
      isContextCurrent: (_) => current,
      onActivity: activity.add,
    );
    addTearDown(watched.dispose);
    await watched.handle(message('connect', {'onlyIfTrusted': true}), frame());
    expect(activity, ['solana']);
    // A method the wallet does not serve is not a sign of use.
    await watched.handle(message('mine'), frame());
    await watched.handle({
      ...message('connect', {'silent': true}),
      'namespace': 'eip155',
    }, frame());
    expect(activity, ['solana'], reason: 'no Ethereum wallet is offered');
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
    'Given a Ledger, off-chain messages are built natively and reach the review while raw messages stay refused',
    () async {
      const other = 'So11111111111111111111111111111111111111112';
      wallet = const DappWallet(
        id: 'ledger',
        address: address,
        canSign: true,
        canSignMessages: false,
        type: WalletType.ledger,
      );
      await permissions.grant(origin.origin, address);
      DappSigningRequest? received;
      execute = (request) async {
        received = request;
        return {'signature': 'sig'};
      };
      Map<String, dynamic> offchain(List<String> signers, [String? text]) => {
        'message': text ?? 'Approve order 42',
        'requiredSigners': [
          for (final signer in signers) base64Encode(base58decode(signer)),
        ],
        'account': address,
      };

      final connect = await coordinator.handle(message('connect'), frame());
      expect(connect['result'], containsPair('canSignOffchainMessages', true));
      expect(connect['result'], containsPair('canSignMessages', false));

      final signed = await coordinator.handle(
        message('signOffchainMessage', offchain([other, address])),
        frame(),
      );
      expect(signed['result'], {'signature': 'sig'});
      expect(received!.method, 'signOffchainMessage');
      final built = SolanaOffchainMessage.parse(received!.payloads.single);
      expect(built.content, 'Approve order 42');
      expect(built.signers, [address, other]);

      // The connected account must be one of the signers.
      final notSigner = await coordinator.handle(
        message('signOffchainMessage', offchain([other])),
        frame(),
      );
      expect(errorCode(notSigner), -32602);
      final duplicate = await coordinator.handle(
        message('signOffchainMessage', offchain([address, address])),
        frame(),
      );
      expect(errorCode(duplicate), -32602);
      final empty = await coordinator.handle(
        message('signOffchainMessage', offchain([address], '')),
        frame(),
      );
      expect(errorCode(empty), -32602);
      expect(executions, 0, reason: 'only the valid request executed');
    },
  );

  test(
    'Connecting never asks for a signature, for any wallet; only an explicit sign-in does',
    () async {
      for (final type in WalletType.values) {
        wallet = DappWallet(
          id: type.name,
          address: address,
          canSign: type != WalletType.viewOnly,
          type: type,
        );
        final connect = await coordinator.handle(message('connect'), frame());
        expect(connect['result'], containsPair('publicKey', address));
        await coordinator.handle(
          message('connect', {'onlyIfTrusted': true}),
          frame(),
        );
        await coordinator.handle(message('connect', {'silent': true}), frame());
      }
      expect(approvals, 1, reason: 'one grant per origin and address');
      expect(executions, 0);
    },
  );

  test(
    'Given no connection, sign-in asks to connect, then signs the message it wrote and returns the account',
    () async {
      DappSigningRequest? received;
      execute = (request) async {
        received = request;
        return {'signature': 'sig', 'signedMessage': 'msg'};
      };
      final result = await coordinator.handle(
        message('signIn', {'nonce': 'abc12345', 'statement': 'Hello'}),
        frame(),
      );
      expect(approvals, 1);
      expect(await permissions.isGranted(origin.origin, address), isTrue);
      expect(result['result'], containsPair('publicKey', address));
      expect(result['result'], containsPair('signedMessage', 'msg'));
      expect(received!.method, 'signIn');
      expect(received!.options['offchainMessage'], isFalse);
      expect(
        utf8.decode(received!.payloads.single),
        'example.org wants you to sign in with your Solana account:\n'
        '$address\n\nHello\n\nNonce: abc12345',
      );

      // Connected now: a second sign-in signs without asking again.
      await coordinator.handle(message('signIn'), frame());
      expect(approvals, 1);
    },
  );

  group('sign-in from a site that is not connected', () {
    const other = 'So11111111111111111111111111111111111111112';
    const ledger = DappWallet(
      id: 'ledger',
      address: address,
      canSign: true,
      canSignMessages: false,
      type: WalletType.ledger,
    );
    const viewOnly = DappWallet(
      id: 'view',
      address: address,
      canSign: false,
      type: WalletType.viewOnly,
    );
    String? errorMessage(Map<String, Object?> result) =>
        (result['error'] as Map?)?['message'] as String?;

    test('naming another account asks to connect first, and reports the '
        'mismatch only once the connection is approved', () async {
      final result = await coordinator.handle(
        message('signIn', {'address': other}),
        frame(),
      );
      expect(approvals, 1, reason: 'the connect sheet came first');
      expect(errorCode(result), 4100);
      expect(errorMessage(result), contains('does not match'));
      expect(executions, 0);
      expect(await permissions.isGranted(origin.origin, address), isTrue);
    });

    test('a view-only wallet asks to connect first, and says it cannot sign '
        'only once the connection is approved', () async {
      wallet = viewOnly;
      final result = await coordinator.handle(message('signIn'), frame());
      expect(approvals, 1, reason: 'the connect sheet came first');
      expect(errorCode(result), 4200);
      expect(errorMessage(result), contains('view-only'));
      expect(executions, 0);
    });

    test('a wallet that signs in only off-chain asks to connect first, then '
        'says so, and signs the off-chain form', () async {
      wallet = ledger;
      final plain = await coordinator.handle(message('signIn'), frame());
      expect(approvals, 1, reason: 'the connect sheet came first');
      expect(errorCode(plain), 4200);
      expect(errorMessage(plain), contains('off-chain'));
      expect(executions, 0);

      // The off-chain form is one a Ledger can sign.
      DappSigningRequest? received;
      execute = (request) async {
        received = request;
        return {'signature': 'sig'};
      };
      final offchain = await coordinator.handle(
        message('signIn', {
          'useOffchainMessage': {'messageVersion': 1},
        }),
        frame(),
      );
      expect(offchain['result'], containsPair('canSignOffchainMessages', true));
      expect(received!.options['offchainMessage'], isTrue);
      final built = SolanaOffchainMessage.parse(received!.payloads.single);
      expect(built.signers, [address]);
      expect(built.content, startsWith('example.org wants you to sign in'));
    });

    test(
      'a rejected connection reads the same whichever wallet is active',
      () async {
        approve = (_) async {
          approvals++;
          return false;
        };
        final outcomes = <String>[];
        for (final (active, params) in <(DappWallet, Map<String, dynamic>)>[
          (wallet, {}),
          (wallet, {'address': other}),
          (wallet, {'address': address}),
          (ledger, {}),
          (viewOnly, {}),
          (viewOnly, {'address': other}),
        ]) {
          wallet = active;
          final result = await coordinator.handle(
            message('signIn', params),
            frame(),
          );
          outcomes.add(jsonEncode(result['error']));
        }
        expect(approvals, outcomes.length, reason: 'every request prompted');
        expect(outcomes.toSet(), hasLength(1));
        expect(outcomes.first, contains('4001'));
        expect(executions, 0);
        expect(await permissions.isGranted(origin.origin, address), isFalse);
      },
    );

    test('a malformed request fails without a prompt, and the same way '
        'whichever wallet is active', () async {
      for (final params in <Map<String, dynamic>>[
        {'statement': 'a\nb'},
        {'address': 42},
        {'version': '2'},
        {'expirationTime': '2020-01-01T00:00:00Z'},
        // Malformed and naming another account: still only malformed.
        {'statement': 'a\nb', 'address': other},
      ]) {
        final outcomes = <String>[];
        for (final active in [wallet, ledger, viewOnly]) {
          wallet = active;
          final result = await coordinator.handle(
            message('signIn', params),
            frame(),
          );
          expect(errorCode(result), -32602, reason: '$params');
          outcomes.add(jsonEncode(result['error']));
        }
        expect(outcomes.toSet(), hasLength(1), reason: '$params');
      }
      expect(approvals, 0);
      expect(executions, 0);
    });
  });

  test(
    'Given a connected site, a sign-in the wallet cannot answer fails at once',
    () async {
      await permissions.grant(origin.origin, address);
      final otherAccount = await coordinator.handle(
        message('signIn', {
          'address': 'So11111111111111111111111111111111111111112',
        }),
        frame(),
      );
      expect(errorCode(otherAccount), 4100);
      final malformed = await coordinator.handle(
        message('signIn', {'statement': 'a\nb'}),
        frame(),
      );
      expect(errorCode(malformed), -32602);

      wallet = const DappWallet(
        id: 'ledger',
        address: address,
        canSign: true,
        canSignMessages: false,
        type: WalletType.ledger,
      );
      final plain = await coordinator.handle(message('signIn'), frame());
      expect(errorCode(plain), 4200);
      expect((plain['error'] as Map)['message'], contains('off-chain'));

      wallet = const DappWallet(
        id: 'view',
        address: address,
        canSign: false,
        type: WalletType.viewOnly,
      );
      final viewOnly = await coordinator.handle(message('signIn'), frame());
      expect(errorCode(viewOnly), 4200);
      expect((viewOnly['error'] as Map)['message'], contains('view-only'));

      expect(approvals, 0);
      expect(executions, 0);
    },
  );

  group('sign-in validity', () {
    late DateTime clock;
    setUp(() {
      clock = DateTime.utc(2026, 10, 28, 10);
      coordinator.dispose();
      coordinator = DappRequestCoordinator(
        permissions: permissions,
        currentWallet: () => wallet,
        approveConnection: (request) => approve(request),
        execute: (request) => execute(request),
        isContextCurrent: (_) => current,
        now: () => clock,
      );
    });

    test('a request inside its window is signed', () async {
      final result = await coordinator.handle(
        message('signIn', {
          'version': '1',
          'issuedAt': '2026-10-28T10:02:00Z',
          'notBefore': '2026-10-28T10:04:00Z',
          'expirationTime': '2026-10-28T10:10:00Z',
        }),
        frame(),
      );
      expect(result['error'], isNull);
      expect(executions, 1);
    });

    test('an expired, not yet valid, future-dated or unreadable request is '
        'refused without any sheet', () async {
      for (final (params, reason) in <(Map<String, dynamic>, String)>[
        ({'expirationTime': '2026-10-28T10:00:00Z'}, 'expired'),
        ({'expirationTime': '2026-10-28T09:00:00.000Z'}, 'expired'),
        ({'notBefore': '2026-10-28T10:06:00Z'}, 'not valid yet'),
        ({'issuedAt': '2026-10-28T10:06:00Z'}, 'dated in the future'),
        ({'expirationTime': 'tomorrow'}, 'cannot read'),
        ({'issuedAt': '2026-10-28 10:00:00'}, 'cannot read'),
        ({'version': '2'}, 'version'),
      ]) {
        final result = await coordinator.handle(
          message('signIn', params),
          frame(),
        );
        expect(errorCode(result), -32602, reason: '$params');
        expect(
          (result['error'] as Map)['message'],
          contains(reason),
          reason: '$params',
        );
      }
      expect(approvals, 0);
      expect(executions, 0);
    });

    test(
      'a request that expires while the connect sheet is open is not signed',
      () async {
        approve = (_) async {
          approvals++;
          clock = clock.add(const Duration(minutes: 11));
          return true;
        };
        final result = await coordinator.handle(
          message('signIn', {'expirationTime': '2026-10-28T10:10:00Z'}),
          frame(),
        );
        expect(approvals, 1);
        expect(errorCode(result), -32602);
        expect((result['error'] as Map)['message'], contains('expired'));
        expect(executions, 0);
      },
    );
  });

  test('Given a rejected connection, sign-in signs nothing', () async {
    approve = (_) async => false;
    final result = await coordinator.handle(message('signIn'), frame());
    expect(errorCode(result), 4001);
    expect(executions, 0);
    expect(await permissions.isGranted(origin.origin, address), isFalse);
  });

  test(
    'Given a view-only wallet, off-chain message signing is refused',
    () async {
      wallet = const DappWallet(
        id: 'view',
        address: address,
        canSign: false,
        type: WalletType.viewOnly,
      );
      await permissions.grant(origin.origin, address);
      final connect = await coordinator.handle(message('connect'), frame());
      expect(connect['result'], containsPair('canSignOffchainMessages', false));
      final result = await coordinator.handle(
        message('signOffchainMessage', {
          'message': 'hi',
          'requiredSigners': [base64Encode(base58decode(address))],
        }),
        frame(),
      );
      expect(errorCode(result), 4200);
      expect(executions, 0);
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
