import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/features/send/services/ethereum_transfer_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
// web3dart 3.x re-homed EthereumAddress in package:wallet.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';

import 'ethereum_transfer_service_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

const _owner = '0x2222222222222222222222222222222222222222';
const _recipient = '0x3333333333333333333333333333333333333333';
const _token = '0x1111111111111111111111111111111111111111';
const _other = '0x9999999999999999999999999999999999999999';

/// Canonical ERC-20 `transfer(to,amount)` calldata the backend is expected to
/// return — the same ABI [EthereumTransferService] re-encodes to assert against.
Uint8List _erc20Calldata(String to, BigInt amount) {
  const abi =
      '[{"constant":false,"inputs":[{"name":"_to","type":"address"},'
      '{"name":"_value","type":"uint256"}],"name":"transfer",'
      '"outputs":[{"name":"","type":"bool"}],"type":"function"}]';
  final c = DeployedContract(
    ContractAbi.fromJson(abi, 'ERC20'),
    EthereumAddress.fromHex(_token),
  );
  return c.function('transfer').encodeCall([
    EthereumAddress.fromHex(to),
    amount,
  ]);
}

String _hex(Uint8List bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

@GenerateMocks([
  MallowApiV2Client,
  EthereumRpcService,
  WalletManager,
  PendingEvmTxTracker,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    provideDummy<BigInt>(BigInt.zero);
    provideDummy<ApiResponse<TransferTxResponse>>(
      const ApiResponse<TransferTxResponse>(result: TransferTxResponse()),
    );
  });

  late MockMallowApiV2Client apiV2;
  late MockEthereumRpcService rpc;
  late MockWalletManager walletManager;
  late EthereumTransferService service;

  // 1 USDC at 6 decimals — base units, exactly what the caller passes through.
  final amount = BigInt.from(1000000);
  const erc20Token = TokenBalance(
    mint: _token,
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 0,
    uiBalance: 0,
    chain: Chain.ethereum,
  );

  setUp(() {
    apiV2 = MockMallowApiV2Client();
    rpc = MockEthereumRpcService();
    walletManager = MockWalletManager();
    service = EthereumTransferService(apiV2, rpc, walletManager);

    when(rpc.chainId).thenReturn(1);
    when(
      rpc.estimateGas(
        from: anyNamed('from'),
        to: anyNamed('to'),
        valueWei: anyNamed('valueWei'),
        data: anyNamed('data'),
      ),
    ).thenAnswer((_) async => BigInt.from(50000));
    when(rpc.getFeeData()).thenAnswer(
      (_) async => EthFeeData(
        baseFeePerGas: BigInt.from(10),
        maxPriorityFeePerGas: BigInt.from(1),
        maxFeePerGas: BigInt.from(21),
      ),
    );
  });

  void stubBackend(String data, {required String value, required String to}) {
    when(apiV2.getTransferTx(any)).thenAnswer(
      (_) async => ApiResponse<TransferTxResponse>(
        result: TransferTxResponse(
          evm: EvmUnsignedTx(to: to, data: data, value: value),
        ),
      ),
    );
  }

  void stubSimulation(List<EvmAssetChange> changes) {
    when(
      rpc.simulateAssetChanges(
        from: anyNamed('from'),
        to: anyNamed('to'),
        data: anyNamed('data'),
        value: anyNamed('value'),
      ),
    ).thenAnswer((_) async => EvmSimulationResult(changes: changes));
  }

  EvmAssetChange erc20Out({String contract = _token, String? raw}) =>
      EvmAssetChange(
        assetType: 'ERC20',
        changeType: 'TRANSFER',
        from: _owner.toLowerCase(),
        to: _recipient.toLowerCase(),
        contractAddress: contract.toLowerCase(),
        rawAmount: raw ?? amount.toString(),
      );

  /// How `decodeSimulateV1` reads a *legacy* ERC-20 whose `Transfer` declares
  /// `uint256 indexed value`: four topics, identical to an ERC-721's, so the
  /// amount lands in `tokenId` under an `ERC721` label with no `rawAmount`.
  /// Nothing in the log distinguishes the two — only the contract does.
  EvmAssetChange legacyErc20Out({String contract = _token, String? raw}) =>
      EvmAssetChange(
        assetType: 'ERC721',
        changeType: 'TRANSFER',
        from: _owner.toLowerCase(),
        to: _recipient.toLowerCase(),
        contractAddress: contract.toLowerCase(),
        tokenId: raw ?? amount.toString(),
      );

  EvmAssetChange nativeOut({String? raw}) => EvmAssetChange(
    assetType: 'NATIVE',
    changeType: 'TRANSFER',
    from: _owner.toLowerCase(),
    to: _recipient.toLowerCase(),
    rawAmount: raw ?? amount.toString(),
  );

  Future<PreparedEthTransfer> prepareErc20() => service.prepare(
    walletId: 'w1',
    source: _owner,
    destination: _recipient,
    amountRaw: amount,
    token: erc20Token,
  );

  Future<PreparedEthTransfer> prepareNative() => service.prepare(
    walletId: 'w1',
    source: _owner,
    destination: _recipient,
    amountRaw: amount,
  );

  group('ERC-20 calldata assertion', () {
    test('accepts calldata that matches the intended transfer', () async {
      stubBackend(
        _hex(_erc20Calldata(_recipient, amount)),
        value: '0x0',
        to: _token,
      );
      stubSimulation([erc20Out()]);

      final prepared = await prepareErc20();
      expect(prepared.to.with0x.toLowerCase(), _token);
      expect(prepared.value, BigInt.zero);
      expect(prepared.data, isNotNull);
    });

    test('rejects calldata for a different recipient', () async {
      // Backend encodes a transfer to a DIFFERENT address than intended.
      stubBackend(
        _hex(_erc20Calldata(_owner, amount)),
        value: '0x0',
        to: _token,
      );
      stubSimulation([erc20Out()]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects calldata for a different amount', () async {
      stubBackend(
        _hex(_erc20Calldata(_recipient, BigInt.from(999))),
        value: '0x0',
        to: _token,
      );
      stubSimulation([erc20Out()]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects a non-zero value on an ERC-20 transfer', () async {
      stubBackend(
        _hex(_erc20Calldata(_recipient, amount)),
        value: '0x1',
        to: _token,
      );
      stubSimulation([erc20Out()]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects when `to` is not the token contract', () async {
      stubBackend(
        _hex(_erc20Calldata(_recipient, amount)),
        value: '0x0',
        to: _recipient,
      );
      stubSimulation([erc20Out()]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });
  });

  group('ERC-20 simulation gate', () {
    setUp(() {
      stubBackend(
        _hex(_erc20Calldata(_recipient, amount)),
        value: '0x0',
        to: _token,
      );
    });

    // An approval the wallet itself grants (from == owner) is the real threat —
    // it hands a spender standing rights over the owner's assets — so it must
    // fail closed even alongside an otherwise-clean outflow.
    test('rejects an approval the wallet grants (from == owner)', () async {
      stubSimulation([
        erc20Out(),
        const EvmAssetChange(
          assetType: 'ERC20',
          changeType: 'APPROVE',
          from: _owner,
          to: _recipient,
          contractAddress: _token,
        ),
      ]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    // WHY: the approve gate keys on `from`, not merely on changeType. Alchemy's
    // asset changes include approvals surfaced from nested contract calls, whose
    // `from` is that contract, not the wallet — e.g. a recipient contract's
    // receive() hook doing its own approve. Such an approval cannot touch the
    // owner's assets, so blocking it would fail-closed a clean send with a
    // misleading "grant an approval over your assets" message.
    test(
      'ignores an approval that does not originate from the wallet',
      () async {
        stubSimulation([
          erc20Out(),
          const EvmAssetChange(
            assetType: 'ERC20',
            changeType: 'APPROVE',
            from: _other,
            to: _recipient,
            contractAddress: _token,
          ),
        ]);

        final prepared = await prepareErc20();
        expect(prepared.to.with0x.toLowerCase(), _token);
      },
    );

    test('rejects an unexpected asset leaving the wallet', () async {
      stubSimulation([erc20Out(), erc20Out(contract: _other)]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    // WHY: the asset label is not knowable for a four-topic Transfer — a legacy
    // ERC-20 that indexes `value` emits the same log an ERC-721 does, and the
    // decoder has no token metadata to break the tie. Keying the match on the
    // `ERC20` label would block every send of such a token as "an unexpected
    // asset": a fail-closed denial of service for that whole token class.
    test('accepts a legacy ERC-20 that indexes its transfer value', () async {
      stubSimulation([legacyErc20Out()]);

      final prepared = await prepareErc20();
      expect(prepared.to.with0x.toLowerCase(), _token);
    });

    // Accepting that shape must not cost the exact-amount check. The indexed
    // operand is the amount, so it is held to the requested amount too.
    test('rejects a legacy indexed-value transfer of a wrong amount', () async {
      stubSimulation([legacyErc20Out(raw: '999')]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    // The widened label match is scoped to the chosen contract. A four-topic
    // outflow from anywhere else is still an asset the user did not choose.
    test('rejects a four-topic outflow from another contract', () async {
      stubSimulation([erc20Out(), legacyErc20Out(contract: _other)]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects a mismatched simulated amount', () async {
      stubSimulation([erc20Out(raw: '999')]);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    // A fee-on-transfer / rebasing token moves a different amount than sent, so
    // it deterministically trips the exact-amount gate. That block is
    // intentional (an off-by-fee move is indistinguishable from a tampered
    // amount), but the message must tell the user *why* — that such tokens
    // aren't supported — rather than reading as a generic "amount mismatch".
    test('mismatch block message explains fee-on-transfer tokens', () async {
      stubSimulation([erc20Out(raw: '990000')]); // 1% transfer fee withheld
      expect(
        prepareErc20,
        throwsA(
          isA<EthTransferBlockedException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('different amount'),
              contains('fee-on-transfer'),
              contains('not supported'),
            ),
          ),
        ),
      );
    });

    test('rejects when the sim shows nothing leaving the wallet', () async {
      stubSimulation(const []);
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects when the sim reports a revert', () async {
      when(
        rpc.simulateAssetChanges(
          from: anyNamed('from'),
          to: anyNamed('to'),
          data: anyNamed('data'),
          value: anyNamed('value'),
        ),
      ).thenAnswer(
        (_) async =>
            const EvmSimulationResult(changes: [], error: 'execution reverted'),
      );
      expect(prepareErc20, throwsA(isA<EthTransferBlockedException>()));
    });
  });

  group('native ETH', () {
    String valueHex(BigInt v) => '0x${v.toRadixString(16)}';

    test('accepts a matching native transfer (no calldata)', () async {
      stubBackend('0x', value: valueHex(amount), to: _recipient);
      stubSimulation([nativeOut()]);

      final prepared = await prepareNative();
      expect(prepared.to.with0x.toLowerCase(), _recipient);
      expect(prepared.value, amount);
      expect(
        prepared.data,
        isNull,
        reason: 'native transfer carries no calldata',
      );
    });

    test('rejects a value that differs from the amount', () async {
      stubBackend('0x', value: '0x1', to: _recipient);
      stubSimulation([nativeOut()]);
      expect(prepareNative, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects a target that is not the recipient', () async {
      stubBackend('0x', value: valueHex(amount), to: _token);
      stubSimulation([nativeOut()]);
      expect(prepareNative, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects a mismatched simulated native amount', () async {
      stubBackend('0x', value: valueHex(amount), to: _recipient);
      stubSimulation([nativeOut(raw: '1')]);
      expect(prepareNative, throwsA(isA<EthTransferBlockedException>()));
    });

    test('rejects an unexpected ERC-20 outflow on a native send', () async {
      stubBackend('0x', value: valueHex(amount), to: _recipient);
      stubSimulation([nativeOut(), erc20Out()]);
      expect(prepareNative, throwsA(isA<EthTransferBlockedException>()));
    });

    // The token gate accepts either asset label on the chosen contract; a native
    // send has no chosen contract, so that widening must not reach it — any
    // token outflow riding along with an ETH send is still unexpected.
    test('rejects a four-topic token outflow on a native send', () async {
      stubBackend('0x', value: valueHex(amount), to: _recipient);
      stubSimulation([nativeOut(), legacyErc20Out()]);
      expect(prepareNative, throwsA(isA<EthTransferBlockedException>()));
    });
  });

  group('execute — broadcast-time fee freshness', () {
    // The review estimate baked into the prepared transfer. Its fee caps are
    // deliberately *stale* (low) so the test can prove execute does not sign
    // them when the user hasn't overridden the fee.
    final staleEstimate = EthereumSendEstimate(
      gasLimit: 60000,
      estimatedGasUsed: BigInt.from(50000),
      maxFeePerGas: BigInt.from(21), // stale review-time cap
      maxPriorityFeePerGas: BigInt.from(1),
      effectiveGasPrice: BigInt.from(11),
    );

    PreparedEthTransfer prepared() => PreparedEthTransfer(
      walletId: 'w1',
      source: _owner,
      to: EthereumAddress.fromHex(_recipient),
      value: amount,
      data: null,
      estimate: staleEstimate,
    );

    late Transaction signed;

    setUp(() {
      // Fresh fee market at broadcast — a base-fee spike since review.
      when(rpc.getFeeData()).thenAnswer(
        (_) async => EthFeeData(
          baseFeePerGas: BigInt.from(100),
          maxPriorityFeePerGas: BigInt.from(7), // fresh tip
          maxFeePerGas: BigInt.from(207), // fresh cap
        ),
      );
      when(rpc.getNonce(any)).thenAnswer((_) async => 5);
      // Native sends re-read the balance for the pre-sign budget guard; a large
      // balance keeps it a no-op for the fee-freshness tests.
      when(
        rpc.getBalance(any),
      ).thenAnswer((_) async => BigInt.from(10).pow(18));
      when(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer((invocation) async {
        signed = invocation.positionalArguments[1] as Transaction;
        return Uint8List(0);
      });
      when(rpc.sendRawTransaction(any)).thenAnswer((_) async => '0xhash');
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async {});
    });

    // WHY: a stale review estimate must never broadcast an under-priced fee. If
    // execute signed the prepared caps verbatim, a base-fee spike between review
    // and broadcast would leave the tx stuck. With no user override, execute must
    // re-fetch the live fee market and sign the *fresh* caps.
    test('re-fetches fresh fee caps when no fee override is given', () async {
      final hash = await service.execute(prepared());

      expect(hash, '0xhash');
      // Signed the FRESH caps, not the stale review-time ones.
      expect(signed.maxFeePerGas!.getInWei, BigInt.from(207));
      expect(signed.maxPriorityFeePerGas!.getInWei, BigInt.from(7));
      verify(rpc.getFeeData()).called(1);
      // estimateGas is re-run as the pre-sign revert check.
      verify(
        rpc.estimateGas(
          from: anyNamed('from'),
          to: anyNamed('to'),
          valueWei: anyNamed('valueWei'),
          data: anyNamed('data'),
        ),
      ).called(1);
    });

    // WHY: a user-chosen fee is authoritative — re-fetching would override the
    // exact caps they picked on the Edit Gas Fee sheet, so the override path must
    // sign them verbatim and skip the refresh entirely.
    test('signs the override fee verbatim without re-fetching', () async {
      final override = EthGasSelection(
        mode: EthGasMode.custom,
        maxFeePerGas: BigInt.from(500),
        maxPriorityFeePerGas: BigInt.from(9),
        gasLimit: 80000,
      );

      await service.execute(prepared(), feeOverride: override);

      expect(signed.maxFeePerGas!.getInWei, BigInt.from(500));
      expect(signed.maxPriorityFeePerGas!.getInWei, BigInt.from(9));
      expect(signed.maxGas, 80000);
      verifyNever(rpc.getFeeData());
      verifyNever(
        rpc.estimateGas(
          from: anyNamed('from'),
          to: anyNamed('to'),
          valueWei: anyNamed('valueWei'),
          data: anyNamed('data'),
        ),
      );
    });

    // WHY (FINDING 1, defense-in-depth): a fee override whose gas limit is below
    // the prepared estimate — e.g. a stale ~25 200-gas limit resolved onto a
    // heavier transfer — must be floored at the estimate before signing, or the
    // tx mines an out-of-gas revert with the fee still charged. The estimate's
    // headroom is refunded when unused, so flooring never costs the user.
    test('floors an override gas limit below the prepared estimate', () async {
      final override = EthGasSelection(
        mode: EthGasMode.custom,
        maxFeePerGas: BigInt.from(500),
        maxPriorityFeePerGas: BigInt.from(9),
        gasLimit: 21000, // below the prepared estimate (60000)
      );

      await service.execute(prepared(), feeOverride: override);

      // Floored at prepared.estimate.gasLimit, not signed at the low override.
      expect(signed.maxGas, 60000);
      // The override caps are still authoritative (verbatim, no refresh).
      expect(signed.maxFeePerGas!.getInWei, BigInt.from(500));
      verifyNever(rpc.getFeeData());
    });

    // WHY (FINDING 1, funds loss): when fees are refreshed the pre-sign
    // estimateGas is not merely a revert check — its result reconciles the gas
    // limit. If the recipient's storage state changed since review (a token slot
    // went zero→nonzero, ~34k→~49k gas), the prepared pad (~41k) is now too low;
    // signing it would mine an out-of-gas revert with the fee still charged and
    // the tokens unmoved. The signed limit must rise to the freshly padded
    // estimate — unused gas is refunded, so the higher cap never overcharges.
    test('raises the signed gas limit to the fresh padded estimate', () async {
      when(
        rpc.estimateGas(
          from: anyNamed('from'),
          to: anyNamed('to'),
          valueWei: anyNamed('valueWei'),
          data: anyNamed('data'),
        ),
      ).thenAnswer((_) async => BigInt.from(49000)); // heavier than at review

      final stalePrepared = PreparedEthTransfer(
        walletId: 'w1',
        source: _owner,
        to: EthereumAddress.fromHex(_recipient),
        value: amount,
        data: null,
        estimate: EthereumSendEstimate(
          gasLimit: 41000, // ~34k review estimate padded — now insufficient
          estimatedGasUsed: BigInt.from(34000),
          maxFeePerGas: BigInt.from(21),
          maxPriorityFeePerGas: BigInt.from(1),
          effectiveGasPrice: BigInt.from(11),
        ),
      );

      await service.execute(stalePrepared);

      // 49 000 × 12 / 10 = 58 800 — the fresh padded estimate wins over 41 000.
      expect(signed.maxGas, 58800);
    });

    // WHY (FINDING 2, funds loss): the node reserves value + gasLimit×maxFeePerGas
    // at inclusion, so a Max native send whose gas limit or fee cap rose since it
    // was computed exceeds the balance and is rejected "insufficient funds for
    // gas * price + value" — but only AFTER biometric auth. execute must re-read
    // the balance and fail closed BEFORE signing, surfacing a re-quote message.
    test(
      'fails closed without signing when value + gas×cap exceeds balance',
      () async {
        // Fresh cap 207 × 60 000 gas = 12 420 000; value = 1 000 000 → budget
        // 13 420 000. Balance one wei under → the send must not be signed.
        when(
          rpc.getBalance(any),
        ).thenAnswer((_) async => BigInt.from(13420000 - 1));

        await expectLater(
          service.execute(prepared()),
          throwsA(isA<EthTransferBlockedException>()),
        );
        verifyNever(
          walletManager.signEthereumTransaction(
            any,
            any,
            chainId: anyNamed('chainId'),
          ),
        );
        verifyNever(rpc.sendRawTransaction(any));
      },
    );

    // WHY: the pre-sign estimateGas is the fail-closed revert check. If the
    // transfer would now revert (e.g. balance moved since review), execute must
    // throw before signing — never broadcast a tx that would fail on-chain.
    test(
      'fails closed without signing when the revert check reverts',
      () async {
        when(
          rpc.estimateGas(
            from: anyNamed('from'),
            to: anyNamed('to'),
            valueWei: anyNamed('valueWei'),
            data: anyNamed('data'),
          ),
        ).thenThrow(const EthereumRpcException('execution reverted'));

        await expectLater(
          service.execute(prepared()),
          throwsA(isA<EthereumRpcException>()),
        );
        verifyNever(
          walletManager.signEthereumTransaction(
            any,
            any,
            chainId: anyNamed('chainId'),
          ),
        );
        verifyNever(rpc.sendRawTransaction(any));
      },
    );
  });

  // WHY (FINDING 1, silent tx loss): the send pipeline's "Done" early exit pops
  // the send sheet, disposing the bloc that is the *only* surface a broadcast
  // failure can reach. It is therefore gated on [onBroadcastRegistered], and the
  // ordering below is that gate's contract: the signal may not fire until the
  // node has accepted the raw transaction and the pending-tx tracker owns its
  // nonce. Fire it any earlier and a throwing `sendRawTransaction` leaves the
  // user with no error, no Pending entry, and a transaction they believe is in
  // flight.
  group('execute — early-exit signal', () {
    late List<String> events;
    late MockPendingEvmTxTracker tracker;

    PreparedEthTransfer prepared() => PreparedEthTransfer(
      walletId: 'w1',
      source: _owner,
      to: EthereumAddress.fromHex(_recipient),
      value: amount,
      data: null,
      estimate: EthereumSendEstimate(
        gasLimit: 60000,
        estimatedGasUsed: BigInt.from(50000),
        maxFeePerGas: BigInt.from(21),
        maxPriorityFeePerGas: BigInt.from(1),
        effectiveGasPrice: BigInt.from(11),
      ),
    );

    PendingTxResolutionClaim? handedClaim;

    Future<String> run() => service.execute(
      prepared(),
      onBroadcasting: () => events.add('broadcasting'),
      onBroadcastRegistered: (claim) {
        handedClaim = claim;
        events.add('registered');
      },
    );

    setUp(() {
      events = <String>[];
      handedClaim = null;
      tracker = MockPendingEvmTxTracker();
      when(tracker.register(any)).thenAnswer((_) async {
        events.add('register');
      });
      sl.registerSingleton<PendingEvmTxTracker>(tracker);

      when(rpc.getFeeData()).thenAnswer(
        (_) async => EthFeeData(
          baseFeePerGas: BigInt.from(10),
          maxPriorityFeePerGas: BigInt.from(1),
          maxFeePerGas: BigInt.from(21),
        ),
      );
      when(rpc.getNonce(any)).thenAnswer((_) async => 5);
      when(
        rpc.getBalance(any),
      ).thenAnswer((_) async => BigInt.from(10).pow(18));
      when(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer((_) async => Uint8List(0));
      when(rpc.sendRawTransaction(any)).thenAnswer((_) async {
        events.add('send');
        return '0xhash';
      });
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async {
        events.add('wait');
      });
    });

    tearDown(() => sl.unregister<PendingEvmTxTracker>());

    test('stays silent when the broadcast fails', () async {
      when(
        rpc.sendRawTransaction(any),
      ).thenThrow(const EthereumRpcException('insufficient funds'));

      await expectLater(run(), throwsA(isA<EthereumRpcException>()));

      // The signing → broadcasting transition happened (the tx was signed), but
      // nothing was registered and no early exit was ever offered — the error
      // reaches the pipeline the user is still looking at.
      expect(events, ['broadcasting']);
      verifyNever(tracker.register(any));
      verifyNever(tracker.claimResolution(any, any));
    });

    test(
      'fires only after the tracker has been handed the broadcast',
      () async {
        final hash = await run();

        expect(hash, '0xhash');
        expect(events, [
          'broadcasting',
          'send',
          'register',
          'registered',
          'wait',
        ]);
      },
    );

    // WHY (duplicate toast): this call waits out inclusion itself and the caller
    // shows its own success step, so the tracker must not also announce the
    // resolution. The claim is taken in the same turn as the registration (before
    // any pass can see the row) and reported once the wait returns; the caller is
    // handed it so an early exit can give the announcement back.
    test('claims the resolution notice and reports it after the wait', () async {
      when(tracker.claimResolution(any, any)).thenAnswer((_) {
        events.add('claim');
      });
      when(tracker.resolutionReported(any, any)).thenAnswer((_) async {
        events.add('reported');
      });

      await run();

      expect(events, [
        'broadcasting',
        'send',
        'register',
        'claim',
        'registered',
        'wait',
        'reported',
      ]);
      verify(tracker.claimResolution(_owner, 5)).called(1);
      verify(tracker.resolutionReported(_owner, 5)).called(1);
      // The pipeline can only hand the claim back if it knows which slot it is.
      expect(handedClaim?.walletAddress, _owner);
      expect(handedClaim?.nonce, 5);
    });

    test('hands the notice back when the inclusion wait fails', () async {
      // Nothing was learned about the outcome, so silencing the toast would
      // leave the transaction reported nowhere.
      when(
        rpc.waitForConfirmation(any),
      ).thenThrow(const EthereumRpcException('connection reset'));

      await expectLater(run(), throwsA(isA<EthereumRpcException>()));

      verify(tracker.releaseResolutionClaim(_owner, 5)).called(1);
      verifyNever(tracker.resolutionReported(any, any));
    });
  });

  group('maxNativeSendable (fallback reserve)', () {
    // WHY (FINDING 2): the fallback reserve (used when the Edit-Gas fee market is
    // unavailable, the same case where execute() refreshes getFeeData and signs
    // no override) reserves the padded native gas limit at the node fee cap — so
    // the Max amount plus what execute() signs never exceeds the balance, and the
    // send is never rejected for "insufficient funds for gas * price + value".
    test('reserves nativeSendGasLimit × getFeeData maxFeePerGas', () async {
      final balance = BigInt.from(10).pow(18); // 1 ETH
      when(rpc.getBalance(_owner)).thenAnswer((_) async => balance);

      final spendable = await service.maxNativeSendable(_owner);

      // getFeeData default (setUp): maxFeePerGas = 21.
      final reserve =
          BigInt.from(EthereumTransferService.nativeSendGasLimit) *
          BigInt.from(21);
      expect(spendable, balance - reserve);
      // Broadcastable invariant: value(=spendable) + reserve == balance exactly.
      expect(spendable + reserve, balance);
    });

    test('returns zero when the reserve exceeds the balance', () async {
      when(rpc.getBalance(_owner)).thenAnswer((_) async => BigInt.from(1));
      expect(await service.maxNativeSendable(_owner), BigInt.zero);
    });
  });
}
