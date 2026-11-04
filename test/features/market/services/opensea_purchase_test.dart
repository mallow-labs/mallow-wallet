import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/market/services/opensea_purchase.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:web3dart/web3dart.dart';
import 'package:wallet/wallet.dart' show EthereumAddress;
import '../opensea_fixtures.dart';

class _Api extends Mock implements MallowApiClient {}

class _Rpc extends Mock implements EthereumRpcService {}

class _Wallet extends Mock implements WalletManager {}

class _Session extends Mock implements SessionManager {}

class _Gate extends Mock implements TransactionAuthGate {}

class _Storage extends Mock implements SecureWalletStorage {}

class _Tracker extends Mock implements PendingEvmTxTracker {}

void main() {
  final fails = throwsA(isA<AppFailure>());
  group('review assertions', () {
    test('exact ETH formatting retains all wei digits', () {
      expect(
        formatOpenSeaEth('123456789012345678901'),
        '123.456789012345678901',
      );
      expect(formatOpenSeaEth('1000000000000000000'), '1');
      expect(() => openSeaWei('-1'), fails);
    });
    test('valid ERC721 and single-copy ERC1155 quotes', () {
      for (final standard in ['erc721', 'erc1155']) {
        validateOpenSeaQuote(
          OpenSeaPurchaseQuote.fromJson(quoteJson(standard: standard)),
          mintAccount: mint,
          buyer: buyer.toUpperCase().replaceFirst('0X', '0x'),
          tokenStandard: standard,
        );
      }
    });
    for (final change in <String, Object>{
      'chainId': 5,
      'buyerAddress': contract,
      'contractAddress': buyer,
      'tokenId': '43',
      'totalWei': '999',
      'tokenStandard': 'erc1155',
      'quantity': '2',
      'listedCopies': '2',
      'protocolAddress': contract,
      'estimatedGasWei': '-1',
      'referral': {'enabled': true, 'buyerCostWei': '0'},
    }.entries) {
      test('rejects quote mismatch: ${change.key}', () {
        final q = OpenSeaPurchaseQuote.fromJson(
          quoteJson()..[change.key] = change.value,
        );
        expect(
          () => validateOpenSeaQuote(
            q,
            mintAccount: mint,
            buyer: buyer,
            tokenStandard: 'erc721',
          ),
          fails,
        );
      });
    }
    test('prepared terms pin destination, buyer, value and quote', () {
      final q = purchaseQuote();
      validateOpenSeaPrepared(q, prepared(q));
      for (final p in [
        prepared(q).copyWith(to: contract),
        prepared(q).copyWith(from: contract),
        prepared(q).copyWith(value: '1001'),
        prepared(q).copyWith(quoteId: 'other'),
        prepared(q).copyWith(orderHash: '0x${'cd' * 32}'),
        prepared(q).copyWith(chainId: 5),
        prepared(q).copyWith(data: '0x123'),
      ]) {
        expect(() => validateOpenSeaPrepared(q, p), fails);
      }
    });
    test(
      'simulation must deliver the intended copy for the exact ETH debit',
      () {
        final q = purchaseQuote();
        validateOpenSeaSimulation(q, simulation());
        final good = simulation().changes;
        for (final sim in [
          const EvmSimulationResult(changes: [], error: 'revert'),
          EvmSimulationResult(changes: [good.first]),
          EvmSimulationResult(changes: [good.last]),
          EvmSimulationResult(
            changes: [
              ...good,
              const EvmAssetChange(
                assetType: 'ERC20',
                changeType: 'TRANSFER',
                from: buyer,
                rawAmount: '1',
              ),
            ],
          ),
          EvmSimulationResult(
            changes: [
              ...good,
              const EvmAssetChange(
                assetType: 'ERC721',
                changeType: 'APPROVE',
                from: buyer,
                to: protocol,
              ),
            ],
          ),
        ]) {
          expect(() => validateOpenSeaSimulation(q, sim), fails);
        }
        validateOpenSeaSimulation(
          OpenSeaPurchaseQuote.fromJson(quoteJson(standard: 'erc1155')),
          simulation(standard: 'ERC1155'),
        );
      },
    );
  });

  group('purchase orchestration', () {
    late _Api api;
    late _Rpc rpc;
    late _Wallet wallet;
    late _Session session;
    late _Gate gate;
    late _Storage storage;
    late _Tracker tracker;
    late OpenSeaPurchaseService service;
    late OpenSeaReview review;
    late OpenSeaPurchaseQuote q;
    String? journal;
    const signer = WalletInfo(
      id: 'wallet',
      address: buyer,
      name: 'ETH',
      walletType: WalletType.importedKey,
      chain: 'ethereum',
    );
    setUpAll(() {
      registerFallbackValue(
        const FlowKey(Chain.ethereum, AppFlow.fixedPriceBuy),
      );
      registerFallbackValue(
        const OpenSeaPurchaseQuoteRequest(artworkId: mint, buyerAddress: buyer),
      );
      registerFallbackValue(
        const OpenSeaPurchasePrepareRequest(
          quoteId: 'quote',
          buyerAddress: buyer,
        ),
      );
      registerFallbackValue(
        const OpenSeaPurchaseConfirmRequest(
          artworkId: mint,
          buyerAddress: buyer,
          transactionHash: 'hash',
        ),
      );
      registerFallbackValue(Transaction());
      registerFallbackValue(Uint8List(0));
      registerFallbackValue(
        PendingEvmBroadcast(
          walletAddress: buyer,
          nonce: 3,
          chainId: 1,
          kind: PendingEvmTxKind.other,
          role: PendingTxCandidateRole.original,
          toAddress: protocol,
          valueWei: BigInt.from(1000),
          data: '0x12345678',
          gasLimit: 120,
          maxFeePerGas: BigInt.two,
          maxPriorityFeePerGas: BigInt.one,
          hash: 'hash',
        ),
      );
    });
    setUp(() {
      api = _Api();
      rpc = _Rpc();
      wallet = _Wallet();
      session = _Session();
      gate = _Gate();
      storage = _Storage();
      tracker = _Tracker();
      journal = null;
      service = OpenSeaPurchaseService(
        api,
        rpc,
        wallet,
        session,
        gate,
        storage,
        tracker,
      );
      when(() => api.confirmOpenSeaPurchase(any())).thenAnswer((_) async {});
      when(() => tracker.entries).thenReturn([]);
      when(() => tracker.register(any())).thenAnswer((_) async {});
      q = purchaseQuote();
      review = OpenSeaReview(
        q,
        mint,
        'wallet',
        BigInt.from(99999),
        BigInt.from(240),
      );
      when(
        () => session.sessionWalletForChain(Chain.ethereum),
      ).thenReturn(signer);
      when(() => rpc.chainId).thenReturn(1);
      when(
        () => storage.loadPendingOpenSeaPurchase(),
      ).thenAnswer((_) async => journal);
      when(() => storage.storePendingOpenSeaPurchase(any())).thenAnswer((
        c,
      ) async {
        journal = c.positionalArguments.first as String;
      });
      when(
        () => storage.deletePendingOpenSeaPurchase(),
      ).thenAnswer((_) async => journal = null);
      when(
        () => api.quoteOpenSeaPurchase(any()),
      ).thenAnswer((_) async => ApiResponse(result: q));
      when(() => api.prepareOpenSeaPurchase(any())).thenAnswer(
        (_) async => OpenSeaPurchasePrepareResponse(result: prepared(q)),
      );
      when(
        () => rpc.getBalance(buyer),
      ).thenAnswer((_) async => BigInt.from(99999));
      when(() => rpc.getFeeData()).thenAnswer(
        (_) async => EthFeeData(
          baseFeePerGas: BigInt.one,
          maxPriorityFeePerGas: BigInt.one,
          maxFeePerGas: BigInt.two,
        ),
      );
      when(
        () => rpc.estimateGas(
          from: buyer,
          to: protocol,
          valueWei: any(named: 'valueWei'),
          data: any(named: 'data'),
        ),
      ).thenAnswer((_) async => BigInt.from(100));
      when(
        () => rpc.simulateAssetChanges(
          from: buyer,
          to: protocol,
          value: any(named: 'value'),
          data: any(named: 'data'),
        ),
      ).thenAnswer((_) async => simulation());
      when(() => rpc.getNonce(buyer)).thenAnswer((_) async => 3);
      when(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
      when(
        () => wallet.signEthereumTransaction(
          'wallet',
          any(),
          chainId: 1,
          ensureActive: any(named: 'ensureActive'),
        ),
      ).thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));
      when(() => rpc.sendRawTransaction(any())).thenAnswer((_) async {
        expect(journal, isNotNull);
        throw const EthereumRpcException('lost response');
      });
      when(
        () => rpc.getTransactionReceipt(any()),
      ).thenAnswer((_) async => null);
    });
    test(
      'review caps network fees and binds the Ethereum session wallet',
      () async {
        final result = await service.review(artwork);
        expect(result.walletId, 'wallet');
        expect(result.networkFeeWei, BigInt.from(240));
      },
    );
    test('no signer cannot request a quote', () async {
      when(
        () => session.sessionWalletForChain(Chain.ethereum),
      ).thenReturn(null);
      await expectLater(service.review(artwork), fails);
      verifyNever(() => api.quoteOpenSeaPurchase(any()));
    });
    test('wallet changes fail before preparation', () async {
      when(
        () => session.sessionWalletForChain(Chain.ethereum),
      ).thenReturn(signer.copyWith(id: 'other'));
      await expectLater(service.buy(review), fails);
      verifyNever(() => api.prepareOpenSeaPurchase(any()));
    });
    test('expired quote fails before preparation', () async {
      final expired = OpenSeaReview(
        q.copyWith(expiresAt: DateTime(2000)),
        mint,
        'wallet',
        BigInt.from(9999),
        BigInt.from(240),
      );
      await expectLater(service.buy(expired), fails);
      verifyNever(() => api.prepareOpenSeaPurchase(any()));
    });
    test('prepared price change blocks signing', () async {
      when(() => api.prepareOpenSeaPurchase(any())).thenAnswer(
        (_) async => OpenSeaPurchasePrepareResponse(
          result: prepared(q).copyWith(value: '1001'),
        ),
      );
      await expectLater(service.buy(review), fails);
      verifyNever(
        () => wallet.signEthereumTransaction(
          any(),
          any(),
          chainId: any(named: 'chainId'),
          ensureActive: any(named: 'ensureActive'),
        ),
      );
    });
    test('insufficient ETH includes worst case network fee', () async {
      when(
        () => rpc.getBalance(buyer),
      ).thenAnswer((_) async => BigInt.from(1239));
      await expectLater(service.buy(review), fails);
      verifyNever(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      );
    });
    test('short restricted-order window blocks auth and signing', () async {
      when(() => api.prepareOpenSeaPurchase(any())).thenAnswer(
        (_) async => OpenSeaPurchasePrepareResponse(
          result: prepared(
            q,
          ).copyWith(submitBy: DateTime.now().add(const Duration(seconds: 59))),
        ),
      );
      await expectLater(service.buy(review), fails);
      verifyNever(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      );
    });
    test('auth cancellation leaves no journal and does not submit', () async {
      when(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      ).thenAnswer((_) async => TransactionAuthOutcome.cancelled);
      await expectLater(
        service.buy(review),
        throwsA(isA<TransactionAuthCancelledException>()),
      );
      expect(journal, isNull);
      verifyNever(() => rpc.sendRawTransaction(any()));
    });
    test(
      'lost send response preserves journal and blocks another purchase',
      () async {
        await expectLater(service.buy(review), fails);
        expect((await service.pending())!.nonce, 3);
        await expectLater(service.review(artwork), fails);
        await expectLater(service.buy(review), fails);
        verify(() => rpc.sendRawTransaction(any())).called(1);
        verify(
          () => gate.authorize(
            usdValue: null,
            flow: const FlowKey(Chain.ethereum, AppFlow.fixedPriceBuy),
          ),
        ).called(1);
      },
    );
    test('storage failure prevents any broadcast', () async {
      when(
        () => storage.storePendingOpenSeaPurchase(any()),
      ).thenThrow(StateError('storage'));
      await expectLater(service.buy(review), throwsStateError);
      verifyNever(() => rpc.sendRawTransaction(any()));
    });
    test(
      'tracker storage failure cannot submit and unlocks the journal',
      () async {
        when(
          () => tracker.register(any()),
        ).thenThrow(StateError('tracker storage'));
        await expectLater(service.buy(review), throwsStateError);
        expect(journal, isNull);
        verifyNever(() => rpc.sendRawTransaction(any()));
      },
    );
    test('parallel taps cannot prepare a second purchase', () async {
      final wait = Completer<OpenSeaPurchasePrepareResponse>();
      when(
        () => api.prepareOpenSeaPurchase(any()),
      ).thenAnswer((_) => wait.future);
      final first = service.buy(review);
      await Future<void>.delayed(Duration.zero);
      await expectLater(service.buy(review), fails);
      wait.complete(OpenSeaPurchasePrepareResponse(result: prepared(q)));
      await expectLater(first, fails);
      verify(() => api.prepareOpenSeaPurchase(any())).called(1);
    });
    TransactionReceipt receipt({
      required bool success,
      bool withTransfer = true,
    }) => TransactionReceipt(
      transactionHash: Uint8List(32),
      transactionIndex: 0,
      blockHash: Uint8List(32),
      cumulativeGasUsed: BigInt.from(100),
      status: success,
      from: EthereumAddress.fromHex(buyer),
      to: EthereumAddress.fromHex(protocol),
      logs: withTransfer
          ? [
              FilterEvent(
                address: EthereumAddress.fromHex(contract),
                data: '0x',
                topics: [
                  '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
                  '0x${'0' * 24}${contract.substring(2)}',
                  '0x${'0' * 24}${buyer.substring(2)}',
                  '0x${BigInt.from(42).toRadixString(16).padLeft(64, '0')}',
                ],
              ),
            ]
          : [],
    );
    test(
      'confirmed receipt must transfer the exact NFT before success',
      () async {
        when(
          () => rpc.getTransactionReceipt(any()),
        ).thenAnswer((_) async => receipt(success: true));
        final hash = await service.buy(review);
        expect(hash, startsWith('0x'));
        expect(journal, isNull);
        verify(() => api.confirmOpenSeaPurchase(any())).called(1);
      },
    );
    test(
      'mined receipt without the artwork transfer releases as unverified',
      () async {
        when(
          () => rpc.getTransactionReceipt(any()),
        ).thenAnswer((_) async => receipt(success: true, withTransfer: false));
        await expectLater(
          service.buy(review),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'message',
              openSeaUnverifiedMessage,
            ),
          ),
        );
        // The nonce is consumed, so nothing signed for it can still land.
        expect(journal, isNull);
        verifyNever(() => api.confirmOpenSeaPurchase(any()));
        await service.review(artwork);
      },
    );
    test('reverted receipt unlocks a fresh quote', () async {
      when(
        () => rpc.getTransactionReceipt(any()),
      ).thenAnswer((_) async => receipt(success: false));
      await expectLater(service.buy(review), fails);
      expect(journal, isNull);
      await service.review(artwork);
    });
    test('wallet changed during hardware approval cannot broadcast', () async {
      when(
        () => wallet.signEthereumTransaction(
          'wallet',
          any(),
          chainId: 1,
          ensureActive: any(named: 'ensureActive'),
        ),
      ).thenAnswer((_) async {
        when(
          () => session.sessionWalletForChain(Chain.ethereum),
        ).thenReturn(signer.copyWith(id: 'other'));
        return Uint8List.fromList([1, 2, 3]);
      });
      await expectLater(service.buy(review), fails);
      expect(journal, isNull);
      verifyNever(() => rpc.sendRawTransaction(any()));
    });
    test('higher gas fee must be reviewed again before auth', () async {
      final limited = OpenSeaReview(
        q,
        mint,
        'wallet',
        BigInt.from(99999),
        BigInt.from(239),
      );
      await expectLater(service.buy(limited), fails);
      verifyNever(
        () => gate.authorize(
          usdValue: any(named: 'usdValue'),
          flow: any(named: 'flow'),
        ),
      );
    });
    test('mined speed-up hash survives tracker retirement', () async {
      await expectLater(service.buy(review), fails);
      final original = (await service.pending())!;
      final observer =
          verify(
                () => tracker.addResolutionObserver(captureAny()),
              ).captured.single
              as Future<void> Function(PendingTxResolution);
      final replacementHash = '0x${'cd' * 32}';
      final tx = PendingEvmTx(
        walletAddress: buyer,
        nonce: 3,
        chainId: 1,
        kind: PendingEvmTxKind.other,
        status: PendingEvmTxStatus.pending,
        toAddress: protocol,
        valueWei: BigInt.from(1000),
        data: '0x12345678',
        gasLimit: 120,
        metadata: const PendingTxMetadata(title: 'OpenSea purchase'),
        createdAt: 0,
        candidates: [
          PendingTxCandidate(
            hash: replacementHash,
            maxFeePerGas: BigInt.two,
            maxPriorityFeePerGas: BigInt.one,
            role: 'speedup',
            broadcastAt: 1,
          ),
        ],
      );
      await observer(
        PendingTxResolution(tx: tx, kind: PendingTxResolutionKind.confirmed),
      );
      when(
        () => rpc.getTransactionReceipt(replacementHash),
      ).thenAnswer((_) async => receipt(success: true));
      expect(await service.resolve(original), OpenSeaResolution.confirmed);
      expect(service.confirmedHash, replacementHash);
      expect(journal, isNull);
    });
    group('undecodable journal entry', () {
      setUp(() {
        when(
          () => session.sessionWalletsForChain(Chain.ethereum),
        ).thenReturn([signer]);
        when(() => rpc.getLatestNonce(buyer)).thenAnswer((_) async => 3);
      });

      Future<String> corruptedEntry() async {
        await expectLater(service.buy(review), fails);
        final json = jsonDecode(journal!) as Map<String, dynamic>;
        (json['quote'] as Map<String, dynamic>)['totalWei'] = 'garbage';
        return jsonEncode(json);
      }

      test('with a readable nonce, blocks until that nonce is mined', () async {
        journal = await corruptedEntry();
        final stored = journal;
        await expectLater(service.review(artwork), fails);
        expect(journal, stored);
        verifyNever(() => api.quoteOpenSeaPurchase(any()));
        when(() => rpc.getLatestNonce(buyer)).thenAnswer((_) async => 4);
        expect(await service.pending(), isNull);
        expect(journal, isNull);
        await service.review(artwork);
      });

      test(
        'without a nonce, blocks while any session wallet has a pending transaction',
        () async {
          journal = '{}';
          when(() => rpc.getNonce(buyer)).thenAnswer((_) async => 4);
          await expectLater(service.review(artwork), fails);
          expect(journal, '{}');
          verifyNever(() => api.quoteOpenSeaPurchase(any()));
          when(() => rpc.getNonce(buyer)).thenAnswer((_) async => 3);
          expect(await service.pending(), isNull);
          expect(journal, isNull);
        },
      );

      test(
        'without a nonce, blocks while the tracker holds an OpenSea purchase',
        () async {
          journal = 'not json';
          when(() => tracker.entries).thenReturn([
            PendingEvmTx(
              walletAddress: buyer,
              nonce: 3,
              chainId: 1,
              kind: PendingEvmTxKind.other,
              status: PendingEvmTxStatus.pending,
              toAddress: protocol,
              valueWei: BigInt.from(1000),
              data: '0x12345678',
              gasLimit: 120,
              metadata: const PendingTxMetadata(title: 'OpenSea purchase'),
              createdAt: 0,
              candidates: const [],
            ),
          ]);
          await expectLater(service.pending(), fails);
          expect(journal, 'not json');
        },
      );

      test('never stops the tracker from retiring the nonce slot', () async {
        journal = '{broken';
        final observer =
            verify(
                  () => tracker.addResolutionObserver(captureAny()),
                ).captured.single
                as Future<void> Function(PendingTxResolution);
        await observer(
          PendingTxResolution(
            tx: PendingEvmTx(
              walletAddress: buyer,
              nonce: 3,
              chainId: 1,
              kind: PendingEvmTxKind.other,
              status: PendingEvmTxStatus.pending,
              toAddress: protocol,
              valueWei: BigInt.from(1000),
              data: '0x12345678',
              gasLimit: 120,
              metadata: const PendingTxMetadata(title: 'OpenSea purchase'),
              createdAt: 0,
              candidates: const [],
            ),
            kind: PendingTxResolutionKind.confirmed,
          ),
        );
        expect(journal, '{broken');
      });
    });
  });
}
