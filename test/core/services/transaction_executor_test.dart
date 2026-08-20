import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/stale_tx_tracker.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _MockLedgerService extends Mock implements LedgerService {}

class _MockMallowApi extends Mock implements MallowApiClient {}

class _FakeSignedTx extends Fake implements SignedTx {}

class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

class _DenyAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => true;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.cancelled;
}

String get _placeholderBlockhash => base58encode(Uint8List(32));

SignedTx _buildSignedTx({
  required String blockhash,
  required Ed25519HDPublicKey signer,
  required Ed25519HDPublicKey recipient,
  bool preAttachedSignature = false,
}) {
  final instr = SystemInstruction.transfer(
    fundingAccount: signer,
    recipientAccount: recipient,
    lamports: 1,
  );
  final compiled = Message.only(
    instr,
  ).compile(recentBlockhash: blockhash, feePayer: signer);
  return SignedTx(
    signatures: List<Signature>.generate(
      compiled.requiredSignatureCount,
      (_) => Signature(
        // Non-zero bytes simulate a server-co-signed tx so the executor
        // exercises its staleness-refresh branch.
        preAttachedSignature
            ? (List<int>.filled(64, 0x7f))
            : List<int>.filled(64, 0),
        publicKey: signer,
      ),
    ),
    compiledMessage: compiled,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeSignedTx());
  });

  late _MockWalletManager wallet;
  late _MockSolanaRpcService rpc;
  late _MockLedgerService ledger;
  late _MockMallowApi api;
  late Ed25519HDPublicKey signer;
  late Ed25519HDPublicKey recipient;

  setUp(() async {
    wallet = _MockWalletManager();
    rpc = _MockSolanaRpcService();
    ledger = _MockLedgerService();
    api = _MockMallowApi();
    final signerKp = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: Uint8List(32)..fillRange(0, 32, 0x11),
    );
    final recipientKp = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: Uint8List(32)..fillRange(0, 32, 0x22),
    );
    signer = signerKp.publicKey;
    recipient = recipientKp.publicKey;
    when(() => ledger.signingState).thenAnswer((_) => const Stream.empty());
  });

  TransactionExecutor buildExecutor({TransactionAuthGate? authGate}) {
    final pipeline = TransactionPipeline(
      wallet,
      rpc,
      authGate ?? _AllowAllAuthGate(),
      api,
      ledger,
    );
    return TransactionExecutor(pipeline);
  }

  void stubHappyPath({String signature = 'sigOK'}) {
    when(
      () => rpc.getLatestBlockhash(),
    ).thenAnswer((_) async => _placeholderBlockhash);
    when(
      () => wallet.signCompiledTx(
        unsignedTx: any(named: 'unsignedTx'),
        additionalSigners: any(named: 'additionalSigners'),
      ),
    ).thenAnswer((inv) async => inv.namedArguments[#unsignedTx] as SignedTx);
    when(() => rpc.sendTransaction(any())).thenAnswer((_) async => signature);
    when(
      () => rpc.awaitConfirmationOrThrow(
        any(),
        rebroadcast: any(named: 'rebroadcast'),
      ),
    ).thenAnswer((_) async {});
  }

  group('TransactionExecutor.execute', () {
    test('returns failure when txsBase64 is empty', () async {
      final executor = buildExecutor();
      final result = await executor.execute(
        txsBase64: [],
        usdValue: 0,
        flow: const FlowKey.solana(AppFlow.nftTransfer),
      );

      expect(result, isA<ResultFailure<String, AppFailure>>());
      expect(result.errorOrNull!.kind, AppFailureKind.validation);
    });

    test(
      'single-tx happy path emits awaiting → broadcasting and returns sig',
      () async {
        stubHappyPath(signature: 'sigSingle');
        final tx = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        );

        final stages = <ExecutorStage>[];
        final result = await buildExecutor().execute(
          txsBase64: [tx.encode()],
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
          onStage: (e) => stages.add(e.stage),
        );

        expect(result.valueOrNull, 'sigSingle');
        expect(stages, [
          ExecutorStage.awaitingApproval,
          ExecutorStage.broadcasting,
        ], reason: 'single-tx flows skip the ledger-device stage');
      },
    );

    test(
      'multi-tx batch signs in order and reports per-tx stage indices',
      () async {
        final txs = List.generate(
          3,
          (_) => _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
          ).encode(),
        );
        // Distinct per-call signatures so we can assert the executor
        // returned the LAST signature, not the first.
        final sigs = ['sig0', 'sig1', 'sig2'];
        var callIdx = 0;
        when(
          () => rpc.getLatestBlockhash(),
        ).thenAnswer((_) async => _placeholderBlockhash);
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer(
          (inv) async => inv.namedArguments[#unsignedTx] as SignedTx,
        );
        when(
          () => rpc.sendTransaction(any()),
        ).thenAnswer((_) async => sigs[callIdx++]);
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});

        final events = <ExecutorStageEvent>[];
        final result = await buildExecutor().execute(
          txsBase64: txs,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
          onStage: events.add,
        );

        expect(result.valueOrNull, 'sig2');
        // Two events per tx (awaitingApproval + broadcasting). Each event
        // carries its position in the batch.
        expect(events.map((e) => e.index).toList(), [0, 0, 1, 1, 2, 2]);
        expect(
          events.every((e) => e.total == 3),
          isTrue,
          reason: 'total must match the batch size on every event',
        );
      },
    );

    test(
      'cancelled by auth gate surfaces AppFailureKind.cancelled with no rpc calls',
      () async {
        final tx = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        );
        final executor = buildExecutor(authGate: _DenyAuthGate());

        final result = await executor.execute(
          txsBase64: [tx.encode()],
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(result, isA<ResultFailure<String, AppFailure>>());
        expect(result.errorOrNull!.kind, AppFailureKind.cancelled);
        verifyNever(() => rpc.sendTransaction(any()));
      },
    );

    test(
      'co-signed batch consults tracker.refreshIfStale and uses fresh batch',
      () async {
        final stale = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preAttachedSignature: true,
        ).encode();
        final fresh = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preAttachedSignature: true,
        ).encode();
        stubHappyPath(signature: 'sigFresh');

        // Tracker yields a fresh batch immediately by claiming the
        // staleness window is zero — so refreshIfStale runs the rebuild.
        final tracker = StaleTxTracker<List<String>>(staleAfter: Duration.zero);
        await tracker.buildAndTrack(() async => [fresh]);
        // Force at least 1ms past the staleness window so the tracker
        // re-runs the build closure when the executor asks.
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final result = await buildExecutor().execute(
          txsBase64: [stale],
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
          tracker: tracker,
        );

        expect(result.valueOrNull, 'sigFresh');
        // The fresh tx (not the stale one) is what gets signed.
        verify(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).called(1);
      },
    );

    test(
      'multi-tx batch stops on first failure and returns its AppFailure',
      () async {
        final txs = List.generate(
          3,
          (_) => _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
          ).encode(),
        );
        when(
          () => rpc.getLatestBlockhash(),
        ).thenAnswer((_) async => _placeholderBlockhash);
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer(
          (inv) async => inv.namedArguments[#unsignedTx] as SignedTx,
        );
        // Succeed once, then blow up on the second send.
        final sends = ['ok1'];
        when(() => rpc.sendTransaction(any())).thenAnswer((_) async {
          if (sends.isEmpty) throw Exception('boom on tx 2');
          return sends.removeAt(0);
        });
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});

        final result = await buildExecutor().execute(
          txsBase64: txs,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(result, isA<ResultFailure<String, AppFailure>>());
        expect(result.errorOrNull!.message, contains('boom on tx 2'));
        // Third tx must NOT be attempted after the second failed.
        verify(() => rpc.sendTransaction(any())).called(2);
      },
    );
  });
}
