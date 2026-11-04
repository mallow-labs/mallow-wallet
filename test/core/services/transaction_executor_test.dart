import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/stale_tx_tracker.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/core/services/transaction_signing.dart';
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

/// Exercise the real signing primitive without waiting ten seconds per prompt.
/// Only the duration threshold changes; signing, validity checks and broadcast
/// still run against the same dependencies as the production pipeline.
class _CheckEverySignaturePipeline extends TransactionPipeline {
  _CheckEverySignaturePipeline(
    this.wallet,
    this.rpc,
    MallowApiClient api,
    LedgerService ledger,
  ) : super(wallet, rpc, _AllowAllAuthGate(), api, ledger);

  final WalletManager wallet;
  final SolanaRpcService rpc;

  @override
  Future<Result<String, AppFailure>> signAndBroadcast({
    required String unsignedTxBase64,
    required double? usdValue,
    required FlowKey flow,
    List<Ed25519HDKeyPair> additionalSigners = const [],
    void Function()? onSigned,
    void Function(LedgerSigningState)? onLedgerSigning,
    bool useLedger = true,
    SolanaRpcService? rpcOverride,
    bool Function()? discardSignatureIf,
  }) => Result.guard(
    () => signSendConfirm(
      unsignedTxBase64,
      walletManager: wallet,
      rpcService: rpcOverride ?? rpc,
      authGate: _AllowAllAuthGate(),
      usdValue: usdValue,
      flow: flow,
      additionalSigners: additionalSigners,
      onSigned: onSigned,
      discardSignatureIf: discardSignatureIf,
      slowSigningThreshold: Duration.zero,
    ),
  );
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

/// A base64 tx carrying the ALT program's `CreateLookupTable` instruction —
/// the shape the backend's `alt::create_and_extend_ixs` emits for a cNFT
/// `setupTx`. Deliberately NOT pre-signed: trade routes are never co-signed,
/// which is exactly why a blockhash refresh hides the dying `recent_slot`.
String _lutSetupTxBase64({
  required Ed25519HDPublicKey payer,
  required Ed25519HDPublicKey table,
  int recentSlot = 400000000,
}) {
  final ix = Instruction(
    programId: Ed25519HDPublicKey.fromBase58(addressLookupTableProgramId),
    accounts: [
      AccountMeta.writeable(pubKey: table, isSigner: false),
      AccountMeta.writeable(pubKey: payer, isSigner: true),
    ],
    // bincode: u32 LE variant 0 (CreateLookupTable), u64 LE recent_slot, bump.
    data: ByteArray.merge([
      ByteArray.u32(0),
      ByteArray.u64(recentSlot),
      ByteArray.u8(255),
    ]),
  );
  final compiled = Message.only(
    ix,
  ).compile(recentBlockhash: _placeholderBlockhash, feePayer: payer);
  return SignedTx(
    signatures: List<Signature>.generate(
      compiled.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: payer),
    ),
    compiledMessage: compiled,
  ).encode();
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
    // Non-Keystone by default: only its QR round trip uses the post-sign
    // staleness discard, and only the tests about it turn that on.
    when(() => wallet.activeSignerIsKeystone()).thenAnswer((_) async => false);
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
    group('client-refreshed Keystone expiry', () {
      late KeystoneSignController controller;
      late List<KeystoneSignPrompt> prompts;
      late List<String> signedBlockhashes;
      late List<String> sentBlockhashes;
      late String txBase64;

      setUp(() {
        controller = KeystoneSignController();
        GetIt.instance.registerSingleton<KeystoneSignController>(controller);
        addTearDown(() async {
          await GetIt.instance.unregister<KeystoneSignController>();
          controller.dispose();
        });
        prompts = [];
        final sub = controller.requests.listen((prompt) {
          prompts.add(prompt);
          prompt.completer.complete(prompt.request);
        });
        addTearDown(sub.cancel);
        signedBlockhashes = [];
        sentBlockhashes = [];
        txBase64 = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        ).encode();
        var refreshes = 0;
        when(() => rpc.getLatestBlockhash()).thenAnswer(
          (_) async =>
              base58encode(Uint8List(32)..fillRange(0, 32, ++refreshes)),
        );
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => true);
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((inv) async {
          final tx = inv.namedArguments[#unsignedTx] as SignedTx;
          signedBlockhashes.add(tx.compiledMessage.recentBlockhash);
          await controller.present(
            KeystoneSignPrompt(
              request: SolSignRequest(
                requestId: SolSignRequest.newRequestId(),
                signData: Uint8List.fromList(
                  tx.compiledMessage.toByteArray().toList(),
                ),
                path: KeystoneKeypath.parse(
                  "m/44'/501'/0'/0'",
                  sourceFingerprint: 0x12121212,
                ),
              ).toUr(),
              purpose: KeystoneSignPurpose.transaction,
              address: signer.toBase58(),
              validate: (_) async => null,
            ),
          );
          return SignedTx(
            signatures: [Signature(List<int>.filled(64, 7), publicKey: signer)],
            compiledMessage: tx.compiledMessage,
          );
        });
        when(() => rpc.sendTransaction(any())).thenAnswer((inv) async {
          final tx = inv.positionalArguments.first as SignedTx;
          sentBlockhashes.add(tx.compiledMessage.recentBlockhash);
          return 'sig';
        });
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});
      });

      TransactionExecutor executor() => TransactionExecutor(
        _CheckEverySignaturePipeline(wallet, rpc, api, ledger),
      );

      test(
        'expired co-signed mint stops without retrying the same bytes',
        () async {
          final coSigned = _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
            preAttachedSignature: true,
          ).encode();
          when(
            () => rpc.isBlockhashStillValid(_placeholderBlockhash),
          ).thenAnswer((_) async => false);

          final result = await executor().execute(
            txsBase64: [coSigned],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.nftMint),
            useLedger: false,
          );

          expect(result.errorOrNull?.cause, isA<SignedTooLateException>());
          expect(
            result.errorOrNull?.message,
            'That took too long, so the transaction expired. Try again.',
          );
          expect(signedBlockhashes, [_placeholderBlockhash]);
          expect(prompts, hasLength(1));
          expect(sentBlockhashes, isEmpty);
          verifyNever(() => rpc.getLatestBlockhash());
        },
      );

      test(
        'co-signed edit expires after LUT setup without repeating either tx',
        () async {
          final setup = _lutSetupTxBase64(payer: signer, table: recipient);
          final edit = _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
            preAttachedSignature: true,
          ).encode();
          when(() => rpc.isBlockhashStillValid(any())).thenAnswer(
            (inv) async =>
                inv.positionalArguments.single != _placeholderBlockhash,
          );

          final result = await executor().execute(
            txsBase64: [setup, edit],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.nftEdit),
            useLedger: false,
          );

          expect(result.errorOrNull?.cause, isA<SignedTooLateException>());
          expect(signedBlockhashes, hasLength(2));
          expect(sentBlockhashes, [signedBlockhashes.first]);
          expect(prompts.map((p) => p.index), [0, 1]);
          expect(prompts.map((p) => p.total), [2, 2]);
          verify(() => rpc.getLatestBlockhash()).called(1);
          verify(
            () => rpc.isBlockhashStillValid(_placeholderBlockhash),
          ).called(1);
          verify(
            () => rpc.awaitConfirmationOrThrow(
              'sig',
              rebroadcast: any(named: 'rebroadcast'),
            ),
          ).called(1);
        },
      );

      test(
        'refreshes again after expiry and shows a scoped retry notice',
        () async {
          var validityChecks = 0;
          when(
            () => rpc.isBlockhashStillValid(any()),
          ).thenAnswer((_) async => ++validityChecks > 1);

          final result = await executor().execute(
            txsBase64: [txBase64, txBase64],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.nftTransfer),
            useLedger: false,
          );

          expect(result.valueOrNull, 'sig');
          expect(signedBlockhashes, hasLength(3));
          expect(signedBlockhashes.toSet(), hasLength(3));
          expect(sentBlockhashes, signedBlockhashes.sublist(1));
          expect(prompts.map((p) => p.index), [0, 0, 1]);
          expect(prompts.map((p) => p.total), [2, 2, 2]);
          expect(prompts.map((p) => p.notice), [
            null,
            'That took too long, so the transaction expired before it was sent. '
                'Approve it again on your Keystone.',
            null,
          ]);
          verify(() => rpc.getLatestBlockhash()).called(3);
          verify(() => rpc.isBlockhashStillValid(any())).called(3);
        },
      );

      test(
        'stops after two retries without sending an expired signature',
        () async {
          when(
            () => rpc.isBlockhashStillValid(any()),
          ).thenAnswer((_) async => false);

          final result = await executor().execute(
            txsBase64: [txBase64],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.nftTransfer),
            useLedger: false,
          );

          expect(result.errorOrNull?.cause, isA<SignedTooLateException>());
          expect(
            result.errorOrNull?.message,
            'That took too long, so the transaction expired. Try again.',
          );
          expect(signedBlockhashes, hasLength(3));
          expect(prompts, hasLength(3));
          expect(prompts.first.notice, isNull);
          expect(prompts.skip(1).every((p) => p.notice != null), isTrue);
          expect(
            prompts.every((p) => p.index == null && p.total == null),
            isTrue,
          );
          expect(sentBlockhashes, isEmpty);
          verify(() => rpc.getLatestBlockhash()).called(3);
          verifyNever(
            () => rpc.awaitConfirmationOrThrow(
              any(),
              rebroadcast: any(named: 'rebroadcast'),
            ),
          );
        },
      );
    });

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
      'waits for setup confirmation before signing or submitting the main tx',
      () async {
        final txs = List.generate(
          2,
          (_) => _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
          ).encode(),
        );
        final setupConfirmationStarted = Completer<void>();
        final setupConfirmation = Completer<void>();
        var sendCount = 0;
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
        ).thenAnswer((_) async => sendCount++ == 0 ? 'sigSetup' : 'sigMain');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.positionalArguments.single == 'sigSetup') {
            setupConfirmationStarted.complete();
            await setupConfirmation.future;
          }
        });

        final execution = buildExecutor().execute(
          txsBase64: txs,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );
        await setupConfirmationStarted.future;
        await pumpEventQueue();

        verify(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);

        setupConfirmation.complete();
        final result = await execution;

        expect(result.valueOrNull, 'sigMain');
        verify(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
      },
    );

    test('setup on-chain failure prevents the main transaction', () async {
      final txs = List.generate(
        2,
        (_) => _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        ).encode(),
      );
      stubHappyPath(signature: 'sigSetup');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenThrow(
        const SolanaTransactionFailedException('sigSetup', 'setup failed'),
      );

      final result = await buildExecutor().execute(
        txsBase64: txs,
        usdValue: 0,
        flow: const FlowKey.solana(AppFlow.nftTransfer),
      );

      expect(result, isA<ResultFailure<String, AppFailure>>());
      expect(result.errorOrNull!.message, contains('setup failed'));
      verify(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).called(1);
      verify(() => rpc.sendTransaction(any())).called(1);
    });

    test(
      'unconfirmed setup transaction prevents the main transaction',
      () async {
        final txs = List.generate(
          2,
          (_) => _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
          ).encode(),
        );
        stubHappyPath(signature: 'sigSetup');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenThrow(const SolanaTransactionUnconfirmedException('sigSetup'));

        final result = await buildExecutor().execute(
          txsBase64: txs,
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(result, isA<ResultFailure<String, AppFailure>>());
        expect(result.errorOrNull!.message, contains('may still land'));
        verify(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).called(1);
        verify(() => rpc.sendTransaction(any())).called(1);
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

    // ── Bug A: mid-batch blockhash expiry on a co-signed chunk batch ──────
    //
    // `/v2/tx/nft/edit-collection-artworks` compiles every chunk of one edit
    // against ONE blockhash and, when the edit is subsidized, co-signs each
    // chunk with the subsidy keypair. The executor signs, broadcasts and
    // **confirms** one chunk at a time and each chunk is its own approval
    // prompt, so chunk k > 0 routinely arrives past the ~60s blockhash
    // lifetime. Its signature is the backend's, so nothing client-side may
    // rewrite the blockhash: without a rebuild inside the loop chunk k dies
    // with "Blockhash not found" and the collection edit is left HALF
    // APPLIED, with nothing on screen saying which artworks moved.
    // A Keystone signature is a QR round trip that can outlast the tracker's
    // window. The pre-sign refresh only sees the age when signing starts, so
    // a co-signed tx would otherwise be broadcast after it had expired.
    group('a signature that arrives too late', () {
      late String stale;
      late String fresh;
      late DateTime now;

      setUp(() {
        now = DateTime.utc(2026, 1, 1);
        stale = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
          preAttachedSignature: true,
        ).encode();
        fresh = _buildSignedTx(
          blockhash: base58encode(Uint8List(32)..fillRange(0, 32, 9)),
          signer: signer,
          recipient: recipient,
          preAttachedSignature: true,
        ).encode();
      });

      /// Advances time by [delays] (one per call, the last repeating) and records
      /// what was signed and what was broadcast.
      ({List<String> signed, List<String> sent}) stubSlowSigner(
        List<Duration> delays, {
        KeystoneSignController? controller,
      }) {
        // Only Keystone discards a signature after crossing this window.
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => true);
        final signed = <String>[];
        final sent = <String>[];
        var call = 0;
        when(
          () => rpc.getLatestBlockhash(),
        ).thenAnswer((_) async => _placeholderBlockhash);
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((inv) async {
          final delay = delays[call < delays.length ? call : delays.length - 1];
          call++;
          final tx = inv.namedArguments[#unsignedTx] as SignedTx;
          if (controller != null) {
            await controller.present(
              KeystoneSignPrompt(
                request: SolSignRequest(
                  requestId: SolSignRequest.newRequestId(),
                  signData: Uint8List.fromList(
                    tx.compiledMessage.toByteArray().toList(),
                  ),
                  path: KeystoneKeypath.parse(
                    "m/44'/501'/0'/0'",
                    sourceFingerprint: 0x12121212,
                  ),
                ).toUr(),
                purpose: KeystoneSignPurpose.transaction,
                address: signer.toBase58(),
                validate: (_) async => null,
              ),
            );
          }
          now = now.add(delay);
          signed.add(tx.encode());
          return tx;
        });
        when(() => rpc.sendTransaction(any())).thenAnswer((inv) async {
          sent.add((inv.positionalArguments.first as SignedTx).encode());
          return 'sig';
        });
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});
        return (signed: signed, sent: sent);
      }

      test('discards it unsent, rebuilds, and signs the fresh tx', () async {
        final calls = stubSlowSigner([
          const Duration(milliseconds: 80),
          Duration.zero,
        ]);
        var builds = 0;
        final tracker = StaleTxTracker<List<String>>(
          now: () => now,
          staleAfter: const Duration(milliseconds: 40),
        );
        await tracker.buildAndTrack(
          () async => builds++ == 0 ? [stale] : [fresh],
        );

        final result = await buildExecutor().execute(
          txsBase64: [stale],
          usdValue: null,
          flow: const FlowKey.solana(AppFlow.editionBuy),
          tracker: tracker,
        );

        expect(result.valueOrNull, 'sig');
        expect(calls.signed, [stale, fresh]);
        expect(calls.sent, [
          fresh,
        ], reason: 'the late signature must never reach the network');
      });

      test(
        'rebuilt Keystone prompts explain expiry and retain batch position',
        () async {
          final controller = KeystoneSignController();
          GetIt.instance.registerSingleton<KeystoneSignController>(controller);
          addTearDown(() async {
            await GetIt.instance.unregister<KeystoneSignController>();
            controller.dispose();
          });
          final prompts = <KeystoneSignPrompt>[];
          final sub = controller.requests.listen((prompt) {
            prompts.add(prompt);
            prompt.completer.complete(prompt.request);
          });
          addTearDown(sub.cancel);
          final calls = stubSlowSigner([
            const Duration(milliseconds: 80),
            Duration.zero,
          ], controller: controller);
          var builds = 0;
          final tracker = StaleTxTracker<List<String>>(
            now: () => now,
            staleAfter: const Duration(milliseconds: 40),
          );
          await tracker.buildAndTrack(
            () async => builds++ == 0 ? [stale, stale] : [fresh, fresh],
          );

          final executor = buildExecutor();
          final result = await executor.execute(
            txsBase64: [stale, stale],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.editionBuy),
            tracker: tracker,
          );

          expect(result.valueOrNull, 'sig');
          expect(calls.signed, [stale, fresh, fresh]);
          expect(calls.sent, [fresh, fresh]);
          expect(prompts.map((p) => p.index), [0, 0, 1]);
          expect(prompts.map((p) => p.total), [2, 2, 2]);
          expect(prompts.map((p) => p.notice), [
            null,
            'That took too long, so the transaction expired before it was sent. '
                'Approve it again on your Keystone.',
            null,
          ]);

          final later = await executor.execute(
            txsBase64: [fresh],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.editionBuy),
          );
          expect(later.valueOrNull, 'sig');
          expect(prompts.last.notice, isNull);
          expect(prompts.last.index, isNull);
          expect(prompts.last.total, isNull);
        },
      );

      test('gives up after two rebuilds with a readable error', () async {
        final calls = stubSlowSigner([const Duration(milliseconds: 60)]);
        final tracker = StaleTxTracker<List<String>>(
          now: () => now,
          staleAfter: const Duration(milliseconds: 20),
        );
        await tracker.buildAndTrack(() async => [stale]);

        final result = await buildExecutor().execute(
          txsBase64: [stale],
          usdValue: null,
          flow: const FlowKey.solana(AppFlow.editionBuy),
          tracker: tracker,
        );

        expect(result.errorOrNull?.cause, isA<SignedTooLateException>());
        expect(calls.signed, hasLength(3));
        expect(calls.sent, isEmpty);
      });

      test(
        'a Ledger signature that crosses the stale window is broadcast',
        () async {
          final calls = stubSlowSigner([const Duration(seconds: 40)]);
          when(
            () => wallet.activeSignerIsKeystone(),
          ).thenAnswer((_) async => false);
          when(() => wallet.isLocalSigner()).thenAnswer((_) async => false);
          final tracker = StaleTxTracker<List<String>>(now: () => now);
          await tracker.buildAndTrack(() async => [stale]);

          final result = await buildExecutor().execute(
            txsBase64: [stale],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.editionBuy),
            tracker: tracker,
          );

          expect(result.valueOrNull, 'sig');
          expect(calls.signed, [stale]);
          expect(calls.sent, [stale]);
        },
      );

      test('a local signer is not second-guessed', () async {
        // Even if signing crosses the window, local signing must not loop.
        final calls = stubSlowSigner([const Duration(milliseconds: 1)]);
        when(
          () => wallet.activeSignerIsKeystone(),
        ).thenAnswer((_) async => false);
        final tracker = StaleTxTracker<List<String>>(
          now: () => now,
          staleAfter: Duration.zero,
        );
        await tracker.buildAndTrack(() async => [stale]);

        final result = await buildExecutor().execute(
          txsBase64: [stale],
          usdValue: null,
          flow: const FlowKey.solana(AppFlow.editionBuy),
          tracker: tracker,
        );

        expect(result.valueOrNull, 'sig');
        expect(calls.sent, hasLength(1));
      });

      test(
        'a tx the client can freshen itself is not second-guessed',
        () async {
          final unsigned = _buildSignedTx(
            blockhash: _placeholderBlockhash,
            signer: signer,
            recipient: recipient,
          ).encode();
          final calls = stubSlowSigner([const Duration(milliseconds: 60)]);
          final tracker = StaleTxTracker<List<String>>(
            now: () => now,
            staleAfter: const Duration(milliseconds: 20),
          );
          await tracker.buildAndTrack(() async => [unsigned]);

          final result = await buildExecutor().execute(
            txsBase64: [unsigned],
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.tokenSend),
            tracker: tracker,
          );

          // Its blockhash was refreshed just before signing, so the age the
          // tracker reports says nothing about it.
          expect(result.valueOrNull, 'sig');
          expect(calls.sent, hasLength(1));
        },
      );
    });

    group('mid-batch staleness (rebuildsRemainingWork)', () {
      late List<String> chunks;
      late String freshRemainder;

      setUp(() async {
        final other = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: Uint8List(32)..fillRange(0, 32, 0x33),
        );
        chunks = [
          for (var i = 0; i < 3; i++)
            _buildSignedTx(
              blockhash: _placeholderBlockhash,
              signer: signer,
              recipient: i.isEven ? recipient : other.publicKey,
              preAttachedSignature: true,
            ).encode(),
        ];
        // The rebuilt remainder: distinct bytes so we can tell it from the
        // chunk compiled against the dead blockhash.
        freshRemainder = _buildSignedTx(
          blockhash: base58encode(Uint8List(32)..fillRange(0, 32, 5)),
          signer: signer,
          recipient: recipient,
          preAttachedSignature: true,
        ).encode();
      });

      /// Captures the base64 of every tx handed to the wallet.
      List<String> stubCapturingSigner() {
        final signed = <String>[];
        when(
          () => rpc.getLatestBlockhash(),
        ).thenAnswer((_) async => _placeholderBlockhash);
        when(
          () => wallet.signCompiledTx(
            unsignedTx: any(named: 'unsignedTx'),
            additionalSigners: any(named: 'additionalSigners'),
          ),
        ).thenAnswer((inv) async {
          final tx = inv.namedArguments[#unsignedTx] as SignedTx;
          signed.add(tx.encode());
          return tx;
        });
        when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig');
        when(
          () => rpc.awaitConfirmationOrThrow(
            any(),
            rebroadcast: any(named: 'rebroadcast'),
          ),
        ).thenAnswer((_) async {});
        return signed;
      }

      test(
        'opted in: re-asks the builder between chunks and signs the fresh '
        'remainder, so a subsidized edit cannot be left half applied',
        () async {
          final signed = stubCapturingSigner();
          // Builder answers, in order: the initial batch, then "nothing has
          // landed yet", then — after chunk 0 confirmed — the single chunk
          // that is still outstanding, recompiled against a live blockhash.
          final answers = <List<String>>[
            chunks,
            chunks,
            [freshRemainder],
          ];
          var call = 0;
          final tracker = StaleTxTracker<List<String>>(
            staleAfter: Duration.zero,
          );
          await tracker.buildAndTrack(() async => answers[call++]);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final events = <ExecutorStageEvent>[];
          final result = await buildExecutor().execute(
            txsBase64: chunks,
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.collectionArtworksEdit),
            tracker: tracker,
            rebuildsRemainingWork: true,
            onStage: events.add,
          );

          expect(result.valueOrNull, 'sig');
          expect(
            signed,
            [chunks[0], freshRemainder],
            reason:
                'chunk 1 was compiled against the blockhash chunk 0 already '
                'outlived; the executor must send the rebuilt remainder '
                'instead of the stale chunk',
          );
          // Index never runs backwards and total follows the builder down
          // from 3 to "one already done + one left".
          expect(events.map((e) => e.index).toList(), [0, 0, 1, 1]);
          expect(events.map((e) => e.total).toList(), [3, 3, 2, 2]);
        },
      );

      test('not opted in: the builder is asked only before the first tx — a '
          'closure keyed on user intent (an edition buy of quantity N) would '
          'otherwise re-issue the whole quantity mid-batch', () async {
        final signed = stubCapturingSigner();
        final answers = <List<String>>[
          chunks,
          chunks,
          [freshRemainder],
        ];
        var call = 0;
        final tracker = StaleTxTracker<List<String>>(staleAfter: Duration.zero);
        await tracker.buildAndTrack(() async => answers[call++]);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final result = await buildExecutor().execute(
          txsBase64: chunks,
          usdValue: null,
          flow: const FlowKey.solana(AppFlow.editionBuy),
          tracker: tracker,
          onStage: (_) {},
        );

        expect(result.valueOrNull, 'sig');
        expect(
          call,
          2,
          reason: 'one build to track it, one pre-loop refresh — and no more',
        );
        expect(
          signed,
          chunks,
          reason: 'every tx the user authorised is submitted exactly once',
        );
      });

      test(
        'a rebuild that returns nothing left ends the batch on the last '
        'landed signature rather than replaying work already applied',
        () async {
          stubCapturingSigner();
          when(
            () => rpc.sendTransaction(any()),
          ).thenAnswer((_) async => 'sigLast');
          final answers = <List<String>>[chunks, chunks, <String>[]];
          var call = 0;
          final tracker = StaleTxTracker<List<String>>(
            staleAfter: Duration.zero,
          );
          await tracker.buildAndTrack(() async => answers[call++]);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final result = await buildExecutor().execute(
            txsBase64: chunks,
            usdValue: null,
            flow: const FlowKey.solana(AppFlow.collectionArtworksEdit),
            tracker: tracker,
            rebuildsRemainingWork: true,
          );

          expect(result.valueOrNull, 'sigLast');
          verify(() => rpc.sendTransaction(any())).called(1);
        },
      );
    });

    // ── Bug B: a LUT setupTx whose staleness a blockhash refresh hides ────
    //
    // cNFT trade routes are never co-signed, so `_refreshBlockhashIfSafe`
    // rewrites the setup tx's blockhash and it never expires. The
    // `recent_slot` baked into `create_lookup_table` does, after ~512 slots
    // (~3.4 min), and no refresh touches it. A confirmation sheet left open
    // that long then sends a transaction that looks perfectly fresh and fails
    // on-chain — on the FIRST transaction of the buy/list/cancel/settle, for
    // a reason nothing on screen explains.
    group('lookup-table setup staleness', () {
      late String setupTx;
      late String tradeTx;

      setUp(() async {
        final table = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: Uint8List(32)..fillRange(0, 32, 0x44),
        );
        setupTx = _lutSetupTxBase64(payer: signer, table: table.publicKey);
        tradeTx = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        ).encode();
      });

      test(
        'a non-co-signed batch led by a LUT-creating setupTx is sent back to '
        'the builder, not merely refreshed',
        () async {
          final signed = <String>[];
          when(
            () => rpc.getLatestBlockhash(),
          ).thenAnswer((_) async => _placeholderBlockhash);
          when(
            () => wallet.signCompiledTx(
              unsignedTx: any(named: 'unsignedTx'),
              additionalSigners: any(named: 'additionalSigners'),
            ),
          ).thenAnswer((inv) async {
            final tx = inv.namedArguments[#unsignedTx] as SignedTx;
            signed.add(tx.encode());
            return tx;
          });
          when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sig');
          when(
            () => rpc.awaitConfirmationOrThrow(
              any(),
              rebroadcast: any(named: 'rebroadcast'),
            ),
          ).thenAnswer((_) async {});

          // The rebuild carries a live `recent_slot`; only the bytes differ.
          final freshTable = await Ed25519HDKeyPair.fromPrivateKeyBytes(
            privateKey: Uint8List(32)..fillRange(0, 32, 0x45),
          );
          final freshSetup = _lutSetupTxBase64(
            payer: signer,
            table: freshTable.publicKey,
            recentSlot: 400000512,
          );
          final tracker = StaleTxTracker<List<String>>(
            staleAfter: Duration.zero,
          );
          await tracker.buildAndTrack(() async => [freshSetup, tradeTx]);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final result = await buildExecutor().execute(
            txsBase64: [setupTx, tradeTx],
            usdValue: 0,
            flow: const FlowKey.solana(AppFlow.fixedPriceBuy),
            tracker: tracker,
          );

          expect(result.valueOrNull, 'sig');
          expect(
            signed.first,
            freshSetup,
            reason:
                'the stale setup tx would broadcast a dead recent_slot; a '
                'refreshed blockhash does not make it valid',
          );
        },
      );

      test(
        'a plain non-co-signed batch is NOT rebuilt — the blockhash refresh '
        'is the whole fix there, and a needless round-trip is a regression',
        () async {
          stubHappyPath(signature: 'sigPlain');
          var rebuilds = 0;
          final tracker = StaleTxTracker<List<String>>(
            staleAfter: Duration.zero,
          );
          await tracker.buildAndTrack(() async {
            rebuilds++;
            return [tradeTx];
          });
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final result = await buildExecutor().execute(
            txsBase64: [tradeTx],
            usdValue: 0,
            flow: const FlowKey.solana(AppFlow.fixedPriceBuy),
            tracker: tracker,
          );

          expect(result.valueOrNull, 'sigPlain');
          expect(rebuilds, 1, reason: 'only the initial buildAndTrack ran');
        },
      );
    });
  });
}
