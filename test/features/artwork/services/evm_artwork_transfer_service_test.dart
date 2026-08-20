import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/features/artwork/services/evm_artwork_transfer_service.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
// web3dart 3.x re-homed EthereumAddress in package:wallet.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart';

import 'evm_artwork_transfer_service_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

// A 20-byte contract + owner + recipient, and a token id, shared across tests.
const _contract = '0x1111111111111111111111111111111111111111';
const _owner = '0x2222222222222222222222222222222222222222';
const _recipient = '0x3333333333333333333333333333333333333333';
const _zeroAddress = '0x0000000000000000000000000000000000000000';
// A second, non-active session ETH wallet — the explicit transfer holder.
const _holder = '0x4444444444444444444444444444444444444444';
const _tokenId = '7';

/// Encode the canonical ERC-721 `safeTransferFrom(from,to,tokenId)` calldata the
/// backend is expected to return — same ABI the service re-encodes to assert.
Uint8List _erc721Calldata(String from, String to, BigInt tokenId) {
  const abi =
      '[{"inputs":[{"name":"from","type":"address"},'
      '{"name":"to","type":"address"},{"name":"tokenId","type":"uint256"}],'
      '"name":"safeTransferFrom","outputs":[],"type":"function"}]';
  final c = DeployedContract(
    ContractAbi.fromJson(abi, 'ERC721'),
    EthereumAddress.fromHex(_contract),
  );
  return c.function('safeTransferFrom').encodeCall([
    EthereumAddress.fromHex(from),
    EthereumAddress.fromHex(to),
    tokenId,
  ]);
}

String _hex(Uint8List bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

@GenerateMocks([
  MallowApiV2Client,
  EthereumRpcService,
  WalletManager,
  TransactionAuthGate,
  SessionManager,
  PendingEvmTxTracker,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Mockito needs dummies for the non-nullable return types touched during
    // stub setup (BigInt from estimateGas/balanceOf; the tx response envelope).
    provideDummy<BigInt>(BigInt.zero);
    provideDummy<ApiResponse<TransferTxResponse>>(
      const ApiResponse<TransferTxResponse>(result: TransferTxResponse()),
    );
    provideDummy<PendingEvmBroadcast>(
      PendingEvmBroadcast(
        walletAddress: _owner,
        nonce: 0,
        chainId: 1,
        kind: PendingEvmTxKind.nftTransfer,
        role: PendingTxCandidateRole.original,
        toAddress: _contract,
        valueWei: BigInt.zero,
        data: '',
        gasLimit: 72000,
        maxFeePerGas: BigInt.from(21),
        maxPriorityFeePerGas: BigInt.one,
        hash: '0xhash',
      ),
    );
  });

  late MockMallowApiV2Client apiV2;
  late MockEthereumRpcService rpc;
  late MockWalletManager walletManager;
  late MockTransactionAuthGate authGate;
  late MockSessionManager session;
  late EvmArtworkTransferService service;

  setUp(() {
    apiV2 = MockMallowApiV2Client();
    rpc = MockEthereumRpcService();
    walletManager = MockWalletManager();
    authGate = MockTransactionAuthGate();
    session = MockSessionManager();
    service = EvmArtworkTransferService(apiV2, rpc, walletManager, authGate);

    // The service resolves an explicit holder against the session wallets via
    // the global service locator. Register a mock so holder-threading tests can
    // supply the (non-active) holder wallet; non-holder tests never read it.
    if (GetIt.instance.isRegistered<SessionManager>()) {
      GetIt.instance.unregister<SessionManager>();
    }
    GetIt.instance.registerSingleton<SessionManager>(session);

    // The fallback signer comes from the session (never the active account),
    // so a Profile only ever signs with a wallet it links.
    when(session.sessionWalletForChain(Chain.ethereum)).thenReturn(
      const WalletInfo(
        id: 'w1',
        address: _owner,
        name: 'EVM',
        walletType: WalletType.hd,
        chain: 'ethereum',
      ),
    );
    when(rpc.chainId).thenReturn(1);
    when(
      rpc.estimateGas(
        from: anyNamed('from'),
        to: anyNamed('to'),
        valueWei: anyNamed('valueWei'),
        data: anyNamed('data'),
      ),
    ).thenAnswer((_) async => BigInt.from(60000));
    when(rpc.getFeeData()).thenAnswer(
      (_) async => EthFeeData(
        baseFeePerGas: BigInt.from(10),
        maxPriorityFeePerGas: BigInt.from(1),
        maxFeePerGas: BigInt.from(21),
      ),
    );
    when(rpc.hasContractCode(any)).thenAnswer((_) async => false);
  });

  tearDown(() {
    if (GetIt.instance.isRegistered<SessionManager>()) {
      GetIt.instance.unregister<SessionManager>();
    }
  });

  void stubBackend(String data, {String value = '0x0', String to = _contract}) {
    when(apiV2.getTransferTx(any)).thenAnswer(
      (_) async => ApiResponse<TransferTxResponse>(
        result: TransferTxResponse(
          evm: EvmUnsignedTx(to: to, data: data, value: value),
        ),
      ),
    );
  }

  EvmAssetChange transferOut({
    String contract = _contract,
    String tokenId = _tokenId,
  }) => EvmAssetChange(
    assetType: 'ERC721',
    changeType: 'TRANSFER',
    from: _owner.toLowerCase(),
    to: _recipient.toLowerCase(),
    contractAddress: contract.toLowerCase(),
    tokenId: tokenId,
  );

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

  Future<PreparedEvmTransfer> prepare721() => service.prepare(
    contract: _contract,
    tokenId: _tokenId,
    standard: TokenStandard.erc721,
    recipient: _recipient,
  );

  group('calldata assertion', () {
    test('accepts calldata that matches the intended transfer', () async {
      final data = _hex(
        _erc721Calldata(_owner, _recipient, BigInt.parse(_tokenId)),
      );
      stubBackend(data);
      stubSimulation([transferOut()]);

      final prepared = await prepare721();
      expect(prepared.to, _contract);
      expect(prepared.valueWei, BigInt.zero);
      // effectiveGasPrice (11) × gasLimit (60000 × 1.2 = 72000).
      expect(prepared.feeWei, BigInt.from(11) * BigInt.from(72000));
    });

    test('rejects a non-zero value (would send ETH)', () async {
      final data = _hex(
        _erc721Calldata(_owner, _recipient, BigInt.parse(_tokenId)),
      );
      stubBackend(data, value: '0x1');
      stubSimulation([transferOut()]);

      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });

    test('rejects calldata for a different recipient', () async {
      // Backend calldata sends to a DIFFERENT address than the user intended.
      final tampered = _hex(
        _erc721Calldata(_owner, _contract, BigInt.parse(_tokenId)),
      );
      stubBackend(tampered);
      stubSimulation([transferOut()]);

      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });

    test('rejects when `to` is not the NFT contract', () async {
      final data = _hex(
        _erc721Calldata(_owner, _recipient, BigInt.parse(_tokenId)),
      );
      stubBackend(data, to: _recipient);
      stubSimulation([transferOut()]);

      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });
  });

  group('simulation gate', () {
    setUp(() {
      final data = _hex(
        _erc721Calldata(_owner, _recipient, BigInt.parse(_tokenId)),
      );
      stubBackend(data);
    });

    test('rejects an approval in the simulated changes', () async {
      stubSimulation([
        transferOut(),
        const EvmAssetChange(
          assetType: 'ERC721',
          changeType: 'APPROVE',
          from: _owner,
          to: _recipient,
          contractAddress: _contract,
        ),
      ]);
      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });

    test(
      'allows an approval revocation during the simulated transfer',
      () async {
        stubSimulation([
          const EvmAssetChange(
            assetType: 'ERC721',
            changeType: 'APPROVE',
            from: _owner,
            to: _zeroAddress,
            contractAddress: _contract,
            tokenId: _tokenId,
          ),
          transferOut(),
        ]);

        final prepared = await prepare721();
        expect(prepared.to.toLowerCase(), _contract);
      },
    );

    test('rejects an unexpected asset leaving the wallet', () async {
      stubSimulation([
        transferOut(),
        transferOut(contract: '0x9999999999999999999999999999999999999999'),
      ]);
      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });

    test('rejects when the sim shows the asset never leaves', () async {
      stubSimulation(const []);
      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
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
      expect(prepare721, throwsA(isA<EvmTransferBlockedException>()));
    });
  });

  group('execute', () {
    test('aborts without signing when auth is declined', () async {
      when(
        authGate.authorize(
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.cancelled);

      final prepared = PreparedEvmTransfer(
        walletId: 'w1',
        source: _owner,
        to: _contract,
        data: Uint8List(0),
        valueWei: BigInt.zero,
        estimatedGasUsed: BigInt.from(60000),
        gasLimit: 72000,
        maxFeePerGas: BigInt.from(21),
        maxPriorityFeePerGas: BigInt.from(1),
        feeWei: BigInt.from(100),
        recipientIsContract: false,
      );

      await expectLater(
        service.execute(prepared),
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      verifyNever(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      );
      verifyNever(rpc.sendRawTransaction(any));
    });

    test('a killed cell throws the kill type, not the cancel type', () async {
      // Throwing
      // TransactionAuthCancelledException for a kill made every silent-cancel
      // branch downstream swallow the operator's copy — which is the only thing
      // that can tell a user whether their NFT is safe. The distinct type is
      // what routes it to AppFailureKind.flowDisabled and the explanation sheet.
      const message = 'ETH transfers are paused. Your NFT has not moved.';
      when(
        authGate.authorize(
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
        ),
      ).thenAnswer(
        (_) async => const TransactionAuthOutcome.flowDisabled(message),
      );

      final prepared = PreparedEvmTransfer(
        walletId: 'w1',
        source: _owner,
        to: _contract,
        data: Uint8List(0),
        valueWei: BigInt.zero,
        estimatedGasUsed: BigInt.from(60000),
        gasLimit: 72000,
        maxFeePerGas: BigInt.from(21),
        maxPriorityFeePerGas: BigInt.from(1),
        feeWei: BigInt.from(100),
        recipientIsContract: false,
      );

      await expectLater(
        service.execute(prepared),
        throwsA(
          isA<TransactionFlowDisabledException>().having(
            // Rendered verbatim by FlowUnavailableSheet — no client wrapper copy.
            (e) => e.operatorMessage,
            'operatorMessage',
            message,
          ),
        ),
      );
      verifyNever(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      );
      verifyNever(rpc.sendRawTransaction(any));
    });

    // The prepared transfer carries stale review-time fee caps (maxFeePerGas
    // 21); a fresh market at broadcast has spiked (maxFeePerGas 207).
    PreparedEvmTransfer stalePrepared() => PreparedEvmTransfer(
      walletId: 'w1',
      source: _owner,
      to: _contract,
      data: Uint8List(0),
      valueWei: BigInt.zero,
      estimatedGasUsed: BigInt.from(60000),
      gasLimit: 72000,
      maxFeePerGas: BigInt.from(21),
      maxPriorityFeePerGas: BigInt.from(1),
      feeWei: BigInt.from(100),
      recipientIsContract: false,
    );

    // WHY: the artwork bloc passes a null feeOverride whenever its gasMarket
    // fetch failed, so this flow can reach broadcast on a stale review estimate
    // just like the send flow. Signing the prepared caps verbatim would risk an
    // under-priced, stuck tx after a base-fee spike — execute must re-fetch the
    // live caps and sign the fresh ones, with a pre-sign estimateGas revert
    // check, when no override is given.
    test('re-fetches fresh fee caps when no fee override is given', () async {
      when(
        authGate.authorize(
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
      when(rpc.getFeeData()).thenAnswer(
        (_) async => EthFeeData(
          baseFeePerGas: BigInt.from(100),
          maxPriorityFeePerGas: BigInt.from(7),
          maxFeePerGas: BigInt.from(207),
        ),
      );
      when(rpc.getNonce(any)).thenAnswer((_) async => 3);
      late Transaction signed;
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

      final hash = await service.execute(stalePrepared());

      expect(hash, '0xhash');
      expect(signed.maxFeePerGas!.getInWei, BigInt.from(207));
      expect(signed.maxPriorityFeePerGas!.getInWei, BigInt.from(7));
      verify(rpc.getFeeData()).called(1);
      verify(
        rpc.estimateGas(
          from: anyNamed('from'),
          to: anyNamed('to'),
          valueWei: anyNamed('valueWei'),
          data: anyNamed('data'),
        ),
      ).called(1);
    });

    test('registers the NFT transfer with pending activity metadata', () async {
      final tracker = MockPendingEvmTxTracker();
      when(tracker.register(any)).thenAnswer((_) async {});
      GetIt.instance.registerSingleton<PendingEvmTxTracker>(tracker);
      addTearDown(() => GetIt.instance.unregister<PendingEvmTxTracker>());

      when(
        authGate.authorize(
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
      when(rpc.getNonce(any)).thenAnswer((_) async => 3);
      when(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer((_) async => Uint8List(0));
      when(rpc.sendRawTransaction(any)).thenAnswer((_) async => '0xhash');
      when(rpc.waitForConfirmation(any)).thenAnswer((_) async {});

      await service.execute(
        PreparedEvmTransfer(
          walletId: 'w1',
          source: _owner,
          to: _contract,
          data: Uint8List(0),
          valueWei: BigInt.zero,
          estimatedGasUsed: BigInt.from(60000),
          gasLimit: 72000,
          maxFeePerGas: BigInt.from(21),
          maxPriorityFeePerGas: BigInt.from(1),
          feeWei: BigInt.from(100),
          recipientIsContract: false,
          trackAs: const PendingTxMetadata(
            title: 'Transfer',
            artworkMint: '0x1111111111111111111111111111111111111111-7',
            imageUrl: 'https://example.com/nft.png',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final broadcast =
          verify(tracker.register(captureAny)).captured.single
              as PendingEvmBroadcast;
      expect(broadcast.kind, PendingEvmTxKind.nftTransfer);
      expect(broadcast.metadata?.artworkMint, contains('-7'));
      expect(broadcast.metadata?.imageUrl, 'https://example.com/nft.png');
    });

    // WHY (FINDING 1, funds loss): a stale low gas limit from another flow's
    // persisted custom fee (e.g. a 25 200-gas native send) must never sign a
    // ~72 000-gas safeTransferFrom — it would mine an out-of-gas revert, burning
    // the fee and leaving the NFT unmoved. execute floors the override at the
    // prepared estimate (refunded if unused), so the artwork always ships.
    test('floors an override gas limit below the prepared estimate', () async {
      when(
        authGate.authorize(
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
      when(rpc.getNonce(any)).thenAnswer((_) async => 3);
      late Transaction signed;
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

      final override = EthGasSelection(
        mode: EthGasMode.custom,
        maxFeePerGas: BigInt.from(500),
        maxPriorityFeePerGas: BigInt.from(9),
        gasLimit: 21000, // below the prepared safeTransferFrom estimate (72000)
      );

      await service.execute(stalePrepared(), feeOverride: override);

      // Floored at prepared.gasLimit, not signed at the low override.
      expect(signed.maxGas, 72000);
      // The override caps are still authoritative (verbatim, no refresh).
      expect(signed.maxFeePerGas!.getInWei, BigInt.from(500));
      verifyNever(rpc.getFeeData());
    });
  });

  group('holder threading', () {
    // A second, non-active session ETH wallet (distinct id from the active w1).
    const holderWallet = WalletInfo(
      id: 'w2',
      address: _holder,
      name: 'Holder ETH',
      walletType: WalletType.hd,
      chain: 'ethereum',
    );

    EvmAssetChange holderTransferOut() => EvmAssetChange(
      assetType: 'ERC721',
      changeType: 'TRANSFER',
      from: _holder.toLowerCase(),
      to: _recipient.toLowerCase(),
      contractAddress: _contract.toLowerCase(),
      tokenId: _tokenId,
    );

    test(
      'prepare signs as the passed holder, not the active ETH wallet',
      () async {
        when(
          session.sessionWalletForAddressCaseInsensitive(_holder),
        ).thenReturn(holderWallet);
        // Backend calldata + simulation are keyed off the HOLDER as `from`.
        final data = _hex(
          _erc721Calldata(_holder, _recipient, BigInt.parse(_tokenId)),
        );
        stubBackend(data);
        stubSimulation([holderTransferOut()]);

        final prepared = await service.prepare(
          contract: _contract,
          tokenId: _tokenId,
          standard: TokenStandard.erc721,
          recipient: _recipient,
          holder: _holder,
        );

        // execute() signs keyed by walletId, so this is the load-bearing
        // assertion: the tx is bound to the holder's wallet, not the active one.
        expect(prepared.walletId, 'w2');
        expect(prepared.source, _holder);
        verifyNever(session.sessionWalletForChain(any));
      },
    );

    test('queries the balance against the resolved holder wallet', () async {
      // The service delegates the (case-insensitive, EIP-55) holder→wallet
      // resolution to SessionManager — unit-tested there. Here the resolved
      // wallet stores the lowercase address; the service must query the balance
      // against THAT stored address, not the active w1.
      const lower = '0xabcdef0000000000000000000000000000000abc';
      const checksummed = '0xABCdef0000000000000000000000000000000ABC';
      when(
        session.sessionWalletForAddressCaseInsensitive(checksummed),
      ).thenReturn(
        const WalletInfo(
          id: 'w2',
          address: lower,
          name: 'Holder ETH',
          walletType: WalletType.hd,
          chain: 'ethereum',
        ),
      );
      when(
        rpc.erc1155BalanceOf(
          owner: anyNamed('owner'),
          contract: anyNamed('contract'),
          tokenId: anyNamed('tokenId'),
        ),
      ).thenAnswer((_) async => BigInt.from(4));

      final owned = await service.ownedErc1155Amount(
        contract: _contract,
        tokenId: BigInt.parse(_tokenId),
        holder: checksummed,
      );

      expect(owned, BigInt.from(4));
      // The balance is queried against the session wallet's stored address, not
      // the active w1 — proving the checksummed holder matched.
      verify(
        rpc.erc1155BalanceOf(
          owner: lower,
          contract: _contract,
          tokenId: BigInt.parse(_tokenId),
        ),
      ).called(1);
      verifyNever(session.sessionWalletForChain(any));
    });

    test(
      'falls back to the session ETH wallet when no holder is passed',
      () async {
        final data = _hex(
          _erc721Calldata(_owner, _recipient, BigInt.parse(_tokenId)),
        );
        stubBackend(data);
        stubSimulation([transferOut()]);

        final prepared = await prepare721();

        expect(prepared.walletId, 'w1');
        expect(prepared.source, _owner);
        verify(session.sessionWalletForChain(Chain.ethereum)).called(1);
        verifyNever(session.sessionWalletForAddressCaseInsensitive(any));
      },
    );
  });
}
