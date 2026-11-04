import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/tezos_forge.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/browser_transaction_tracker.dart';
import 'package:mallow_wallet/features/browser/services/tezos_dapp_adapter.dart';

class _Wallet extends Mock implements WalletManager {}

class _Rpc extends Mock implements TezosRpcService {}

const _mnemonic =
    'gym exact clown can answer hope sample mirror knife twenty powder super imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';
const _address = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
const _key = 'edpkuRXPQpuQyDemXE59dyYA1Eu5T94waiiL5PjcWDSkkw86ZvxR2j';
const _branch = 'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq';
void main() {
  late _Wallet wallet;
  late _Rpc rpc;
  late TezosDappAdapter adapter;
  late BrowserTransactionTracker tracker;
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });
  setUp(() {
    wallet = _Wallet();
    rpc = _Rpc();
    tracker = BrowserTransactionTracker();
    adapter = TezosDappAdapter(
      walletManager: wallet,
      rpc: rpc,
      tracker: tracker,
    );
    when(
      () => wallet.getTezosPublicKey(
        'w',
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => _key);
    when(() => rpc.getBranchHash()).thenAnswer((_) async => _branch);
    when(() => rpc.getChainId()).thenAnswer((_) async => 'NetXdQprcVkpaWU');
    when(() => rpc.nextCounter(_address)).thenAnswer((_) async => 1);
    when(() => rpc.getManagerKey(_address)).thenAnswer((_) async => null);
    when(
      () => rpc.runOperation(
        branch: any(named: 'branch'),
        contents: any(named: 'contents'),
        chainId: any(named: 'chainId'),
      ),
    ).thenAnswer((invocation) async {
      final contents = invocation.namedArguments[#contents] as List;
      return {
        'contents': [
          for (final op in contents)
            {
              ...op as Map,
              'metadata': {
                'operation_result': {
                  'status': 'applied',
                  'consumed_milligas': '2000000',
                  'paid_storage_size_diff': '257',
                },
              },
            },
        ],
      };
    });
    when(
      () => wallet.signTezosOperation(
        'w',
        any(),
        expectedAddress: _address,
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (invocation) => MultiChainDerivation.signTezosOperation(
        _mnemonic,
        0,
        invocation.positionalArguments[1] as String,
      ),
    );
  });
  tearDown(() => tracker.dispose());
  Future<PreparedTezosOperation> prepare([
    List<Map<String, Object?>>? operations,
  ]) => adapter.prepareOperation(
    request: TezosDappOperationRequest.parse(
      operations ??
          [
            {
              'kind': 'transaction',
              'destination': _address,
              'amount': '1000000',
            },
          ],
      account: _address,
    ),
    walletId: 'w',
    address: _address,
    origin: 'https://site.example',
    ensureActive: () {},
  );

  test(
    'Given an unrevealed account, preparation includes reveal, storage burn and local bytes',
    () async {
      final prepared = await prepare();
      expect(prepared.review.coverage, SimulationCoverage.complete);
      expect(prepared.review.networkFee, greaterThan(BigInt.from(128500)));
      expect(
        prepared.review.maxNetworkFee,
        greaterThan(prepared.review.networkFee!),
      );
      expect(prepared.details, contains('"kind": "reveal"'));
      expect(prepared.details, contains('"counter": "2"'));
      expect(prepared.review.funds.single.rawAmount, -BigInt.from(1000000));
      final signed = await adapter.signPrepared(prepared, () {});
      expect(signed, startsWith(prepared.forgedHex));
      when(
        () => rpc.injectOperation(signed),
      ).thenAnswer((_) async => tezosOperationHash(signed));
      expect(await adapter.sendSigned(signed), tezosOperationHash(signed));
      expect(tracker.records.single.status, BrowserTransactionStatus.pending);
      verify(() => rpc.injectOperation(signed)).called(1);
    },
  );
  test(
    'Given a contract call, review admits incomplete effects and preserves parameters',
    () async {
      final prepared = await prepare([
        {
          'kind': 'transaction',
          'destination': 'KT1EctCuorV2NfVb1XTQgvzJ88MQtWP8cMMv',
          'amount': '0',
          'parameters': {
            'entrypoint': 'transfer',
            'value': {
              'prim': 'Pair',
              'args': [
                {'string': _address},
                {'int': '12'},
              ],
            },
          },
        },
      ]);
      expect(prepared.review.coverage, SimulationCoverage.partial);
      expect(prepared.review.effectsUndecodable, true);
      expect(prepared.details, contains('"entrypoint": "transfer"'));
      expect(prepared.details, contains('"int": "12"'));
    },
  );
  List<Map<String, dynamic>> contentsOf(PreparedTezosOperation prepared) =>
      ((jsonDecode(prepared.details) as Map)['contents'] as List)
          .cast<Map<String, dynamic>>();
  Map<String, Object?> pricedTransfer(String fee) => {
    'kind': 'transaction',
    'destination': _address,
    'amount': '1',
    'fee': fee,
  };
  test(
    'Given an unrevealed account and a site fee that ignores the reveal, the wallet pays the shortfall on the reveal',
    () async {
      final prepared = await prepare([pricedTransfer('400')]);
      final contents = contentsOf(prepared);
      expect(contents.first['kind'], 'reveal');
      expect(
        BigInt.parse(contents.first['fee'] as String),
        greaterThan(BigInt.zero),
      );
      // The site's own fee is kept exactly as requested.
      expect(contents.last['fee'], '400');
      expect(prepared.review.warnings, contains(contains('website chose')));
    },
  );
  test(
    'Given a revealed account and a site fee below the minimum, the request is refused',
    () async {
      when(() => rpc.getManagerKey(_address)).thenAnswer((_) async => _key);
      await expectLater(
        prepare([pricedTransfer('400')]),
        throwsA(
          isA<DappException>().having(
            (e) => e.message,
            'message',
            contains('too low'),
          ),
        ),
      );
    },
  );
  test('Given a site fee far above the minimum, the review warns', () async {
    final prepared = await prepare([pricedTransfer('100000')]);
    expect(prepared.review.warnings, contains(contains('more than 5 times')));
    final modest = await prepare([pricedTransfer('1000')]);
    expect(
      modest.review.warnings,
      isNot(contains(contains('more than 5 times'))),
    );
  });
  test('Given a site fee above 1 XTZ, nothing is signed', () async {
    await expectLater(
      prepare([pricedTransfer('1000001')]),
      throwsA(
        isA<DappException>()
            .having((e) => e.code, 'code', -32602)
            .having((e) => e.message, 'message', contains('too high')),
      ),
    );
  });
  test(
    'Given default called with Unit, the operation is signed without parameters',
    () async {
      final prepared = await prepare([
        {
          'kind': 'transaction',
          'destination': 'KT1EctCuorV2NfVb1XTQgvzJ88MQtWP8cMMv',
          'amount': '1',
          'parameters': {
            'entrypoint': 'default',
            'value': {'prim': 'Unit'},
          },
        },
      ]);
      final transaction = contentsOf(prepared).last;
      expect(transaction.containsKey('parameters'), isFalse);
      // A transaction forges `parameters absent` as its final byte.
      expect(prepared.forgedHex, endsWith('00'));
      expect(prepared.forgedHex, isNot(contains('030b')));
    },
  );
  test('Given a mismatching key, nothing is simulated or signed', () async {
    when(
      () => wallet.getTezosPublicKey(
        'w',
        expectedAddress: any(named: 'expectedAddress'),
        ensureActive: any(named: 'ensureActive'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer(
      (_) => MultiChainDerivation.getTezosPublicKeyAtIndex(_mnemonic, 1),
    );
    await expectLater(prepare(), throwsA(isA<DappException>()));
    verifyNever(() => rpc.getBranchHash());
  });
  test('Given missing simulation metadata, preparation fails closed', () async {
    when(
      () => rpc.runOperation(
        branch: any(named: 'branch'),
        contents: any(named: 'contents'),
        chainId: any(named: 'chainId'),
      ),
    ).thenAnswer(
      (_) async => {
        'contents': [<String, Object>{}, <String, Object>{}],
      },
    );
    await expectLater(prepare(), throwsA(isA<DappException>()));
  });
  test('Given a node on another chain, no operation is simulated', () async {
    when(() => rpc.getChainId()).thenAnswer((_) async => 'NetWrong');
    await expectLater(
      prepare(),
      throwsA(isA<DappException>().having((e) => e.code, 'code', 4901)),
    );
    verifyNever(
      () => rpc.runOperation(
        branch: any(named: 'branch'),
        contents: any(named: 'contents'),
        chainId: any(named: 'chainId'),
      ),
    );
  });
  test(
    'Given cancellation after key loading, no chain state is fetched',
    () async {
      await expectLater(
        adapter.prepareOperation(
          request: TezosDappOperationRequest.parse([
            {'kind': 'transaction', 'destination': _address, 'amount': '1'},
          ], account: _address),
          walletId: 'w',
          address: _address,
          origin: 'https://site.example',
          ensureActive: () {
            throw const DappException(4001, 'Cancelled');
          },
        ),
        throwsA(isA<DappException>()),
      );
      verifyNever(() => rpc.getBranchHash());
    },
  );
  test(
    'Given submission timeout, hash remains visible and injection is never retried',
    () async {
      final prepared = await prepare();
      final signed = await adapter.signPrepared(prepared, () {});
      when(() => rpc.injectOperation(signed)).thenThrow(Exception('timeout'));
      await expectLater(
        adapter.sendSigned(signed),
        throwsA(isA<DappException>()),
      );
      expect(tracker.records.single.status, BrowserTransactionStatus.uncertain);
      expect(tracker.records.single.signature, tezosOperationHash(signed));
      verify(() => rpc.injectOperation(signed)).called(1);
    },
  );
  test(
    'Given packed message bytes, the signature verifies over those exact bytes',
    () async {
      when(
        () => wallet.signTezosPayloadForWallet(
          'w',
          any(),
          expectedAddress: _address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer(
        (invocation) => MultiChainDerivation.signTezosPayload(
          _mnemonic,
          0,
          invocation.positionalArguments[1] as Uint8List,
        ),
      );
      final review = TezosMessageReview(
        payload: MultiChainDerivation.packTezosMicheline('hello'),
        origin: 'https://site.example',
        address: _address,
        walletId: 'w',
        signingType: 'micheline',
      );
      expect(review.text, 'hello');
      expect(await adapter.signMessage(review, () {}), startsWith('edsig'));
    },
  );
  test(
    'Given a signature from a different wallet, the signature is refused',
    () async {
      when(
        () => wallet.signTezosPayloadForWallet(
          'w',
          any(),
          expectedAddress: _address,
          ensureActive: any(named: 'ensureActive'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer(
        (invocation) => MultiChainDerivation.signTezosPayload(
          _mnemonic,
          1,
          invocation.positionalArguments[1] as Uint8List,
        ),
      );
      final review = TezosMessageReview(
        payload: MultiChainDerivation.packTezosMicheline('hello'),
        origin: 'https://site.example',
        address: _address,
        walletId: 'w',
        signingType: 'micheline',
      );
      await expectLater(
        adapter.signMessage(review, () {}),
        throwsA(isA<DappException>()),
      );
    },
  );
  test(
    'Given complex Micheline, local forging matches Taquito 25.0.0 bytes',
    () {
      final vector =
          jsonDecode(
                File(
                  'test/features/browser/fixtures/tezos_forge.json',
                ).readAsStringSync(),
              )
              as Map;
      final group = vector['operation'] as Map;
      final op = (group['contents'] as List).single as Map;
      final parameters = op['parameters'] as Map;
      final transaction = TezosTransaction(
        source: op['source'] as String,
        destination: op['destination'] as String,
        amount: BigInt.parse(op['amount'] as String),
        fee: BigInt.parse(op['fee'] as String),
        counter: BigInt.parse(op['counter'] as String),
        gasLimit: BigInt.parse(op['gas_limit'] as String),
        storageLimit: BigInt.parse(op['storage_limit'] as String),
        parameters: TezosTransactionParameters(
          entrypoint: parameters['entrypoint'] as String,
          value: MichelineJson(parameters['value'] as Object),
        ),
      );
      expect(
        forgeOperationGroup(group['branch'] as String, [transaction]),
        vector['hex'],
      );
    },
  );

  group('Given a broadcast for a recipient wallet', () {
    late BrowserTransactionTracker fastTracker;
    late List<(String, String)> reports;
    late TezosDappAdapter reporting;
    setUp(() {
      fastTracker = BrowserTransactionTracker(
        interval: const Duration(milliseconds: 1),
      );
      reports = [];
      reporting = TezosDappAdapter(
        walletManager: wallet,
        rpc: rpc,
        tracker: fastTracker,
        onApplied: ({required opHash, required address}) =>
            reports.add((opHash, address)),
      );
    });
    tearDown(() => fastTracker.dispose());

    Future<String> broadcast({String? recipient}) async {
      final signed = await reporting.signPrepared(await prepare(), () {});
      when(
        () => rpc.injectOperation(signed),
      ).thenAnswer((_) async => tezosOperationHash(signed));
      return reporting.sendSigned(signed, recipient: recipient);
    }

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'an applied inclusion reports its hash and the recipient once',
      () async {
        when(
          () => rpc.getOperationInclusion(any()),
        ).thenAnswer((_) async => (applied: true, level: 7));

        final hash = await broadcast(recipient: _address);
        await settle();

        expect(reports, [(hash, _address)]);
        expect(
          fastTracker.records.single.status,
          BrowserTransactionStatus.confirmed,
        );
      },
    );

    test('a failed inclusion reports nothing', () async {
      when(
        () => rpc.getOperationInclusion(any()),
      ).thenAnswer((_) async => (applied: false, level: 7));

      await broadcast(recipient: _address);
      await settle();

      expect(reports, isEmpty);
      expect(
        fastTracker.records.single.status,
        BrowserTransactionStatus.failed,
      );
    });

    test('a broadcast without a recipient reports nothing', () async {
      when(
        () => rpc.getOperationInclusion(any()),
      ).thenAnswer((_) async => (applied: true, level: 7));

      await broadcast();
      await settle();

      expect(reports, isEmpty);
    });
  });
}
