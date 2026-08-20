import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';
import 'package:mallow_wallet/features/send/services/tezos_transfer_service.dart';
import 'package:mallow_wallet/shared/utils/tezos_address.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'tezos_transfer_service_test.mocks.dart';

// Unit coverage for the native-XTZ orchestration in
// [TezosTransferService]. The RPC client and signer are mocked, but the real
// forge + real [TezosRpcService.minimalFeeMutez] arithmetic run, so these tests
// lock down the money-movement glue: reveal branching, per-content gas/storage
// with safety margins, minimal-fee computation, and the forge→sign→inject→
// confirm ordering.
@GenerateMocks([TezosRpcService, WalletManager])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixtures shared with tezos_forge_test.dart so the real forge accepts them.
  const branch = 'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq';
  const chainId = 'NetXdQprcVkpaWU';
  const edpk = 'edpkuRXPQpuQyDemXE59dyYA1Eu5T94waiiL5PjcWDSkkw86ZvxR2j';
  const source = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
  const destination = 'tz1WCBJKr1rRivyCnN9hREpRAMqrLdmqDcym';
  const walletId = 'tez-wallet-1';
  const amountMutez = 1000000; // 1 XTZ

  late MockTezosRpcService rpc;
  late MockWalletManager wallet;
  late TezosTransferService service;

  /// One `run_operation` content result. `applied` unless [status] overrides.
  Map<String, dynamic> contentResult({
    required int consumedMilligas,
    int paidStorage = 0,
    String status = 'applied',
    List<dynamic>? errors,
  }) => {
    'metadata': {
      'operation_result': {
        'status': status,
        'consumed_milligas': '$consumedMilligas',
        'paid_storage_size_diff': '$paidStorage',
        'errors': ?errors,
      },
    },
  };

  void stubChainReads({required bool revealed, int counter = 100}) {
    when(rpc.getBranchHash()).thenAnswer((_) async => branch);
    when(rpc.getChainId()).thenAnswer((_) async => chainId);
    when(rpc.nextCounter(source)).thenAnswer((_) async => counter);
    when(rpc.isRevealed(source)).thenAnswer((_) async => revealed);
    when(wallet.getTezosPublicKey(walletId)).thenAnswer((_) async => edpk);
  }

  setUpAll(() {
    // The Max path stubs `getBalance` (a non-nullable BigInt future); recording
    // that stub needs a BigInt dummy.
    provideDummy<BigInt>(BigInt.zero);
  });

  setUp(() {
    rpc = MockTezosRpcService();
    wallet = MockWalletManager();
    service = TezosTransferService(rpc, wallet);
  });

  group('estimateNativeTransfer', () {
    test(
      'revealed account: no reveal, gas gets safety margin, fee is minimal + '
      'buffer',
      () async {
        stubChainReads(revealed: true);
        when(
          rpc.runOperation(
            branch: anyNamed('branch'),
            contents: anyNamed('contents'),
            chainId: anyNamed('chainId'),
          ),
        ).thenAnswer(
          (_) async => {
            'contents': [contentResult(consumedMilligas: 1400500)],
          },
        );

        final estimate = await service.estimateNativeTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          amountMutez: BigInt.from(amountMutez),
        );

        expect(estimate.includesReveal, isFalse);
        // 1_400_500 milligas → ceil to 1401 gas, + gasSafetyMargin (100).
        expect(estimate.gasLimit, 1401 + TezosRpcService.gasSafetyMargin);
        // Plain transfer to an existing account burns no storage.
        expect(estimate.storageLimit, 0);
        // Fee must clear the protocol minimal for the group's gas + size.
        expect(estimate.feeMutez, greaterThan(BigInt.zero));
      },
    );

    test(
      'unrevealed account: prepends a reveal, includesReveal is true, gas sums '
      'both contents',
      () async {
        stubChainReads(revealed: false);
        when(
          rpc.runOperation(
            branch: anyNamed('branch'),
            contents: anyNamed('contents'),
            chainId: anyNamed('chainId'),
          ),
        ).thenAnswer(
          (_) async => {
            'contents': [
              contentResult(consumedMilligas: 1000000), // reveal
              contentResult(consumedMilligas: 1400000), // transaction
            ],
          },
        );

        final estimate = await service.estimateNativeTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          amountMutez: BigInt.from(amountMutez),
        );

        expect(estimate.includesReveal, isTrue);
        // reveal 1000 gas + margin, tx 1400 gas + margin.
        expect(
          estimate.gasLimit,
          (1000 + TezosRpcService.gasSafetyMargin) +
              (1400 + TezosRpcService.gasSafetyMargin),
        );
        // The simulation must have carried the reveal's public key.
        verify(wallet.getTezosPublicKey(walletId)).called(1);
      },
    );

    test('folds destination-allocation storage burn into the limit', () async {
      stubChainReads(revealed: true);
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [
            {
              'metadata': {
                'operation_result': {
                  'status': 'applied',
                  'consumed_milligas': '1400000',
                  'paid_storage_size_diff': '0',
                  'allocated_destination_contract': true,
                },
              },
            },
          ],
        },
      );

      final estimate = await service.estimateNativeTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        amountMutez: BigInt.from(amountMutez),
      );

      // 257-byte allocation burn + the 10-byte storage safety margin.
      expect(estimate.storageLimit, TezosRpcService.allocationBurnBytes + 10);
      // The burn is what the user actually loses on top of the baker fee, and
      // it dwarfs it — quoting `feeMutez` alone understated a fresh-address
      // send by ~0.064 XTZ. Priced on the *simulated* bytes, so the cap-only
      // safety margin must not inflate it.
      expect(
        estimate.burnMutez,
        BigInt.from(
          TezosRpcService.allocationBurnBytes *
              TezosRpcService.costPerByteMutez,
        ),
      );
      expect(estimate.burnXtz, closeTo(0.06425, 1e-9));
      expect(estimate.totalCostMutez, estimate.feeMutez + estimate.burnMutez);
      expect(estimate.burnMutez, greaterThan(estimate.feeMutez));
    });

    test(
      'existing destination burns nothing, so total cost is the fee',
      () async {
        stubChainReads(revealed: true);
        when(
          rpc.runOperation(
            branch: anyNamed('branch'),
            contents: anyNamed('contents'),
            chainId: anyNamed('chainId'),
          ),
        ).thenAnswer(
          (_) async => {
            'contents': [contentResult(consumedMilligas: 1400000)],
          },
        );

        final estimate = await service.estimateNativeTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          amountMutez: BigInt.from(amountMutez),
        );

        expect(estimate.burnMutez, BigInt.zero);
        expect(estimate.totalCostMutez, estimate.feeMutez);
      },
    );

    test('throws TezosSimulationException when the node reports failure', () {
      stubChainReads(revealed: true);
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [
            contentResult(
              consumedMilligas: 0,
              status: 'failed',
              errors: [
                {'id': 'proto.018.contract.balance_too_low'},
              ],
            ),
          ],
        },
      );

      expect(
        () => service.estimateNativeTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          amountMutez: BigInt.from(amountMutez),
        ),
        throwsA(
          isA<TezosSimulationException>().having(
            (e) => e.toString(),
            'message',
            contains('balance too low'),
          ),
        ),
      );
    });
  });

  // Max exists so a user can empty an account. A flat headroom number cannot
  // do that: it is either too small for a fresh destination's 0.06425 XTZ
  // allocation burn, or — as the 0.1 XTZ it replaces was — so far above the
  // real cost that it strands more than half of a small wallet. So the reserve
  // is the *simulated* cost of this exact transfer.
  group('maxNativeSendable', () {
    /// Simulation of a transfer that allocates a fresh destination: the
    /// expensive case, where fee and burn differ by ~160×.
    void stubFreshDestinationSim() {
      stubChainReads(revealed: true);
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [
            {
              'metadata': {
                'operation_result': {
                  'status': 'applied',
                  'consumed_milligas': '1400000',
                  'paid_storage_size_diff': '0',
                  'allocated_destination_contract': true,
                },
              },
            },
          ],
        },
      );
    }

    test('holds back the simulated fee + burn, not a flat buffer', () async {
      stubFreshDestinationSim();
      final balance = BigInt.from(5000000); // 5 XTZ
      when(rpc.getBalance(source)).thenAnswer((_) async => balance);

      final quoted = await service.estimateNativeTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        amountMutez: BigInt.one,
      );
      final max = await service.maxNativeSendable(
        walletId: walletId,
        source: source,
        destination: destination,
      );

      final heldBack = balance - max;
      // At least the real cost — anything less and the node rejects the
      // operation the user just signed as `balance_too_low`.
      expect(heldBack, greaterThanOrEqualTo(quoted.totalCostMutez));
      // And barely more: only a few mutez of cushion for the offered amount's
      // longer zarith, versus the 0.1 XTZ the flat buffer kept.
      expect(heldBack, lessThan(quoted.totalCostMutez + BigInt.from(1000)));
      expect(heldBack, lessThan(BigInt.from(100000)));
    });

    test('falls back to flat headroom when the simulation cannot run — a '
        'conservative Max beats no Max', () async {
      stubChainReads(revealed: true);
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenThrow(Exception('node unreachable'));
      when(
        rpc.getBalance(source),
      ).thenAnswer((_) async => BigInt.from(5000000));

      final max = await service.maxNativeSendable(
        walletId: walletId,
        source: source,
        destination: destination,
      );

      expect(max, BigInt.from(5000000 - 100000));
    });

    test('offers zero when the balance cannot cover the cost', () async {
      stubFreshDestinationSim();
      // Less than the 0.06425 XTZ allocation burn alone.
      when(rpc.getBalance(source)).thenAnswer((_) async => BigInt.from(10000));

      final max = await service.maxNativeSendable(
        walletId: walletId,
        source: source,
        destination: destination,
      );

      expect(max, BigInt.zero);
    });
  });

  group('sendNativeTransfer', () {
    setUp(() {
      stubChainReads(revealed: true);
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [contentResult(consumedMilligas: 1400000)],
        },
      );
      when(
        wallet.signTezosOperation(any, any),
      ).thenAnswer((_) async => (signature: 'edsig', signedOperationHex: 'ab'));
      when(rpc.injectOperation(any)).thenAnswer((_) async => 'ooOpHash');
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async => true);
    });

    test('forges, signs, injects and confirms in order, returning the '
        'op hash', () async {
      final onBroadcasting = _CallCounter();

      final opHash = await service.sendNativeTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        amountMutez: BigInt.from(amountMutez),
        onBroadcasting: onBroadcasting.call,
      );

      expect(opHash, 'ooOpHash');
      verifyInOrder([
        wallet.signTezosOperation(walletId, any),
        rpc.injectOperation('ab'),
        rpc.waitForConfirmation('ooOpHash'),
      ]);
      // onBroadcasting fires once, after signing and before injection.
      expect(onBroadcasting.count, 1);
    });

    // Returning the hash on a timeout is what let SendBloc emit success for an
    // operation still in the mempool, which then refreshed balances against the
    // pre-send state. There is no Tezos pending-tx tracker to correct that
    // later, so inclusion has to be the thing that gates the return.
    test(
      'throws rather than returning the hash when inclusion times out',
      () async {
        when(rpc.waitForConfirmation(any)).thenAnswer((_) async => false);

        await expectLater(
          service.sendNativeTransfer(
            walletId: walletId,
            source: source,
            destination: destination,
            amountMutez: BigInt.from(amountMutez),
          ),
          throwsA(
            isA<TezosOperationUnconfirmedException>().having(
              (e) => e.opHash,
              'opHash',
              // Carried, not swallowed: the hash is the only way the user can
              // look up what actually happened to an injected operation.
              'ooOpHash',
            ),
          ),
        );

        // Injection still happened — the throw says "indeterminate", not
        // "nothing was sent", so no caller may present it as a clean failure.
        verify(rpc.injectOperation('ab')).called(1);
      },
    );

    test('re-plans against a fresh branch/counter before injecting', () async {
      await service.sendNativeTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        amountMutez: BigInt.from(amountMutez),
      );

      // A stale review estimate must never inject against an expired branch:
      // the send path fetches its own branch + counter.
      verify(rpc.getBranchHash()).called(1);
      verify(rpc.nextCounter(source)).called(1);
    });
  });

  // FA1.2 and FA2 both expose `transfer` and the balances wire carries no
  // standard field, so the contract's own entrypoint type is the only thing
  // that can tell them apart. They take *different arguments*, so guessing
  // wrong is a malformed operation, not merely a failed one.
  group('faStandardFromEntrypoints', () {
    test('a `list` transfer parameter is FA2 (a batch)', () {
      expect(
        TezosTransferService.faStandardFromEntrypoints({
          'transfer': {
            'prim': 'list',
            'args': [
              {'prim': 'pair'},
            ],
          },
        }),
        TezosFaStandard.fa2,
      );
    });

    test('a `pair` transfer parameter is FA1.2 (one amount)', () {
      expect(
        TezosTransferService.faStandardFromEntrypoints({
          'transfer': {
            'prim': 'pair',
            'args': [
              {'prim': 'address'},
              {'prim': 'pair'},
            ],
          },
        }),
        TezosFaStandard.fa12,
      );
    });

    test('null for a contract with no recognisable transfer', () {
      expect(TezosTransferService.faStandardFromEntrypoints(const {}), isNull);
      expect(
        TezosTransferService.faStandardFromEntrypoints({
          'mint': {'prim': 'list'},
        }),
        isNull,
      );
      // A `transfer` of some third shape is not an FA transfer.
      expect(
        TezosTransferService.faStandardFromEntrypoints({
          'transfer': {'prim': 'unit'},
        }),
        isNull,
      );
    });
  });

  group('FA token transfers', () {
    // A real KT1 (the shadownet FA2 fixture) — the forge Base58Check-decodes
    // the destination, so a synthetic string would not survive it.
    const contract = 'KT1SjXiUX63QvdNMcM2m492f7kuf8JxXRLp4';
    final fa2Token = TezosTokenRef(contract: contract, tokenId: BigInt.from(3));

    void stubFa2Entrypoints() {
      when(rpc.getContractEntrypoints(contract)).thenAnswer(
        (_) async => {
          'transfer': {'prim': 'list'},
        },
      );
    }

    setUp(() {
      stubChainReads(revealed: true);
      stubFa2Entrypoints();
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [
            contentResult(consumedMilligas: 5200000, paidStorage: 67),
          ],
        },
      );
      when(
        wallet.signTezosOperation(any, any),
      ).thenAnswer((_) async => (signature: 'edsig', signedOperationHex: 'ab'));
      when(rpc.injectOperation(any)).thenAnswer((_) async => 'ooFa2Hash');
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async => true);
    });

    /// The single `transaction` content the service simulated.
    Map<String, dynamic> simulatedTransaction() {
      final captured =
          verify(
                rpc.runOperation(
                  branch: anyNamed('branch'),
                  contents: captureAnyNamed('contents'),
                  chainId: anyNamed('chainId'),
                ),
              ).captured.last
              as List<Map<String, dynamic>>;
      return captured.last;
    }

    test('simulates a `transfer` call to the KT1, moving zero XTZ', () async {
      await service.estimateTokenTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        token: fa2Token,
        amountRaw: BigInt.from(2500),
      );

      final tx = simulatedTransaction();
      // The destination is the token contract, not the recipient, and the XTZ
      // amount is zero — the recipient only appears inside the parameters. A
      // send that got this wrong would move XTZ to the recipient instead.
      expect(tx['destination'], contract);
      expect(tx['amount'], '0');
      final params = tx['parameters'] as Map<String, dynamic>;
      expect(params['entrypoint'], 'transfer');
      // FA2 `transfer`: [ Pair from_ [ Pair to_ (Pair token_id amount) ] ].
      final batch = params['value'] as List<dynamic>;
      final outer = batch.single as Map<String, dynamic>;
      final txs = (outer['args'] as List<dynamic>)[1] as List<dynamic>;
      final leg = txs.single as Map<String, dynamic>;
      final idAndAmount =
          (leg['args'] as List<dynamic>)[1] as Map<String, dynamic>;
      expect((idAndAmount['args'] as List<dynamic>)[0], {'int': '3'});
      expect((idAndAmount['args'] as List<dynamic>)[1], {'int': '2500'});
    });

    test('quotes the XTZ fee and the storage the contract writes', () async {
      final estimate = await service.estimateTokenTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        token: fa2Token,
        amountRaw: BigInt.one,
      );

      expect(estimate.includesReveal, isFalse);
      expect(estimate.gasLimit, 5200 + TezosRpcService.gasSafetyMargin);
      // Writing the recipient's ledger entry burns storage, which the fee alone
      // never covers — it is charged on the *simulated* bytes, not the padded
      // limit, so the cap-only margin must stay out of the quote.
      expect(estimate.storageLimit, 67 + 10);
      expect(
        estimate.burnMutez,
        BigInt.from(67 * TezosRpcService.costPerByteMutez),
      );
      expect(estimate.totalCostMutez, estimate.feeMutez + estimate.burnMutez);
    });

    test(
      'forges, signs, injects and confirms, returning the op hash',
      () async {
        final onBroadcasting = _CallCounter();

        final opHash = await service.sendTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.from(2500),
          onBroadcasting: onBroadcasting.call,
        );

        expect(opHash, 'ooFa2Hash');
        verifyInOrder([
          wallet.signTezosOperation(walletId, any),
          rpc.injectOperation('ab'),
          rpc.waitForConfirmation('ooFa2Hash'),
        ]);
        expect(onBroadcasting.count, 1);
      },
    );

    test('an inclusion timeout throws rather than reporting success', () async {
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async => false);

      await expectLater(
        service.sendTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.one,
        ),
        throwsA(isA<TezosOperationUnconfirmedException>()),
      );
      verify(rpc.injectOperation('ab')).called(1);
    });

    test('reads the standard once per contract, then memoises it', () async {
      for (var i = 0; i < 3; i++) {
        await service.estimateTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.one,
        );
      }
      // Contract code is immutable once originated, so re-reading it on every
      // keystroke-driven review would be a round-trip for a constant.
      verify(rpc.getContractEntrypoints(contract)).called(1);
    });

    test('an FA1.2 contract gets the FA1.2 argument shape', () async {
      when(rpc.getContractEntrypoints(contract)).thenAnswer(
        (_) async => {
          'transfer': {'prim': 'pair'},
        },
      );

      await service.estimateTokenTransfer(
        walletId: walletId,
        source: source,
        destination: destination,
        token: TezosTokenRef(contract: contract, tokenId: BigInt.zero),
        amountRaw: BigInt.from(2500),
      );

      final params =
          simulatedTransaction()['parameters'] as Map<String, dynamic>;
      // FA1.2: Pair from (Pair to value) — a bare Pair, never a batch list.
      expect(params['value'], isA<Map<String, dynamic>>());
      expect((params['value'] as Map<String, dynamic>)['prim'], 'Pair');
    });

    test('refuses an FA1.2 contract carrying a non-zero token id', () async {
      when(rpc.getContractEntrypoints(contract)).thenAnswer(
        (_) async => {
          'transfer': {'prim': 'pair'},
        },
      );

      // Dropping the id and sending anyway would move the contract's only
      // token while the confirm screen named a different one.
      await expectLater(
        service.estimateTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.one,
        ),
        throwsA(isA<TezosUnsupportedTokenException>()),
      );
      verifyNever(rpc.injectOperation(any));
    });

    test('refuses a contract with no FA transfer entrypoint', () async {
      when(
        rpc.getContractEntrypoints(contract),
      ).thenAnswer((_) async => const {});

      await expectLater(
        service.sendTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.one,
        ),
        throwsA(
          isA<TezosUnsupportedTokenException>().having(
            (e) => e.toString(),
            'message',
            contains(contract),
          ),
        ),
      );
      verifyNever(wallet.signTezosOperation(any, any));
    });

    test('surfaces a failed simulation before anything is signed', () async {
      when(
        rpc.runOperation(
          branch: anyNamed('branch'),
          contents: anyNamed('contents'),
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer(
        (_) async => {
          'contents': [
            contentResult(
              consumedMilligas: 0,
              status: 'failed',
              errors: [
                {'id': 'proto.023.michelson_v1.script_rejected'},
              ],
            ),
          ],
        },
      );

      await expectLater(
        service.sendTokenTransfer(
          walletId: walletId,
          source: source,
          destination: destination,
          token: fa2Token,
          amountRaw: BigInt.from(999999999),
        ),
        throwsA(isA<TezosSimulationException>()),
      );
      verifyNever(wallet.signTezosOperation(any, any));
    });
  });
}

/// Counts invocations of a zero-arg callback (Tezos onBroadcasting hook).
class _CallCounter {
  int count = 0;
  void call() => count++;
}
