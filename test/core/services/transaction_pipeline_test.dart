import 'dart:async';
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
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/services/activity_refresh_signal.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _MockLedgerService extends Mock implements LedgerService {}

class _MockMallowApi extends Mock implements MallowApiClient {}

class _FakeSignedTx extends Fake implements SignedTx {}

/// Always-allows auth gate. The transaction-auth gate itself is exercised
/// in transaction_auth_gate_test.dart; we only need to confirm that a
/// cancel from the gate propagates as [AppFailureKind.cancelled].
class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

/// Always-denies auth gate — simulates a user-cancelled biometric prompt
/// so [signSendConfirm] throws [TransactionAuthCancelledException].
class _DenyAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => true;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.cancelled;
}

SignedTx _buildSignedTx({
  required String blockhash,
  required Ed25519HDPublicKey signer,
  required Ed25519HDPublicKey recipient,
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
      (_) => Signature(List<int>.filled(64, 0), publicKey: signer),
    ),
    compiledMessage: compiled,
  );
}

String get _placeholderBlockhash => base58encode(Uint8List(32));

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
    // Ledger signing-state stream is subscribed when useLedger=true; give
    // it an empty stream so the subscription cancels cleanly.
    when(() => ledger.signingState).thenAnswer((_) => const Stream.empty());
  });

  group('TransactionPipeline.signAndBroadcast', () {
    test('returns ResultSuccess with signature on happy path', () async {
      final unsigned = _buildSignedTx(
        blockhash: _placeholderBlockhash,
        signer: signer,
        recipient: recipient,
      );
      when(
        () => rpc.getLatestBlockhash(),
      ).thenAnswer((_) async => _placeholderBlockhash);
      when(
        () => wallet.signCompiledTx(
          unsignedTx: any(named: 'unsignedTx'),
          additionalSigners: any(named: 'additionalSigners'),
        ),
      ).thenAnswer((inv) async => inv.namedArguments[#unsignedTx] as SignedTx);
      when(() => rpc.sendTransaction(any())).thenAnswer((_) async => 'sigOK');
      when(
        () => rpc.awaitConfirmationOrThrow(
          any(),
          rebroadcast: any(named: 'rebroadcast'),
        ),
      ).thenAnswer((_) async {});

      final pipeline = TransactionPipeline(
        wallet,
        rpc,
        _AllowAllAuthGate(),
        api,
        ledger,
      );

      var onSignedFired = false;
      final result = await pipeline.signAndBroadcast(
        unsignedTxBase64: unsigned.encode(),
        usdValue: 0,
        flow: const FlowKey.solana(AppFlow.nftTransfer),
        onSigned: () => onSignedFired = true,
      );

      expect(result, isA<ResultSuccess<String, AppFailure>>());
      expect(result.valueOrNull, 'sigOK');
      expect(
        onSignedFired,
        isTrue,
        reason: 'onSigned must fire between sign and broadcast',
      );
    });

    test(
      'classifies user-cancel from auth gate as AppFailureKind.cancelled',
      () async {
        final unsigned = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
        );
        // Deny gate throws TransactionAuthCancelledException before any
        // wallet/RPC call happens — those mocks should never be hit.
        final pipeline = TransactionPipeline(
          wallet,
          rpc,
          _DenyAuthGate(),
          api,
          ledger,
        );

        final result = await pipeline.signAndBroadcast(
          unsignedTxBase64: unsigned.encode(),
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(result, isA<ResultFailure<String, AppFailure>>());
        final failure = result.errorOrNull!;
        expect(failure.kind, AppFailureKind.cancelled);
        expect(
          failure.isCancelled,
          isTrue,
          reason: 'isCancelled is what BLoCs branch on for un-prefixed copy',
        );
        verifyNever(() => rpc.sendTransaction(any()));
      },
    );

    test(
      'classifies generic broadcast failure as AppFailureKind.unknown',
      () async {
        final unsigned = _buildSignedTx(
          blockhash: _placeholderBlockhash,
          signer: signer,
          recipient: recipient,
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
        when(
          () => rpc.sendTransaction(any()),
        ).thenThrow(Exception('network exploded'));

        final pipeline = TransactionPipeline(
          wallet,
          rpc,
          _AllowAllAuthGate(),
          api,
          ledger,
        );

        final result = await pipeline.signAndBroadcast(
          unsignedTxBase64: unsigned.encode(),
          usdValue: 0,
          flow: const FlowKey.solana(AppFlow.nftTransfer),
        );

        expect(result, isA<ResultFailure<String, AppFailure>>());
        expect(result.errorOrNull!.kind, AppFailureKind.unknown);
        expect(result.errorOrNull!.isCancelled, isFalse);
      },
    );
  });

  group('TransactionPipeline.runIndexerCheck', () {
    test('invokes onAck with the poll result once', () async {
      when(
        () => api.checkTx(any()),
      ).thenAnswer((_) async => <String, dynamic>{});

      final pipeline = TransactionPipeline(
        wallet,
        rpc,
        _AllowAllAuthGate(),
        api,
        ledger,
      );

      final calls = <(String, bool)>[];
      pipeline.runIndexerCheck(
        signature: 'sig123',
        onAck: (sig, ok) => calls.add((sig, ok)),
        isClosed: () => false,
        delay: Duration.zero,
      );

      // Yield until the background poll's onAck runs. With delay=0 the
      // poll completes after a couple microtask pumps.
      for (var i = 0; i < 50 && calls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(calls, [('sig123', true)]);
    });

    // Before this, `notifyActivityRefresh()` had exactly one producer — the
    // EVM pending-tx tracker — so the "Recent activity" sheet was stale after
    // every Solana action (buy, list, offer, stake, swap, mint). Every one of
    // those flows funnels through `runIndexerCheck`, which is the one place
    // that knows the server has actually ingested the tx.
    test('prods the activity feed once the indexer acks the tx', () async {
      when(
        () => api.checkTx(any()),
      ).thenAnswer((_) async => <String, dynamic>{});

      final signal = ActivityRefreshSignal();
      if (sl.isRegistered<ActivityRefreshSignal>()) {
        sl.unregister<ActivityRefreshSignal>();
      }
      sl.registerSingleton<ActivityRefreshSignal>(signal);
      addTearDown(() => sl.unregister<ActivityRefreshSignal>());
      var refreshes = 0;
      final sub = signal.stream.listen((_) => refreshes++);
      addTearDown(sub.cancel);

      final pipeline = TransactionPipeline(
        wallet,
        rpc,
        _AllowAllAuthGate(),
        api,
        ledger,
      );

      var acked = false;
      pipeline.runIndexerCheck(
        signature: 'sig123',
        onAck: (_, _) => acked = true,
        isClosed: () => false,
        delay: Duration.zero,
      );

      for (var i = 0; i < 50 && !acked; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // The stream is async, so give the listener a turn.
      await Future<void>.delayed(Duration.zero);

      expect(refreshes, 1);
    });

    test('short-circuits before polling when isClosed is true', () async {
      final pipeline = TransactionPipeline(
        wallet,
        rpc,
        _AllowAllAuthGate(),
        api,
        ledger,
      );

      var ackCount = 0;
      pipeline.runIndexerCheck(
        signature: 'sig123',
        onAck: (_, _) => ackCount++,
        isClosed: () => true,
      );

      await Future<void>.delayed(Duration.zero);
      expect(ackCount, 0);
      verifyNever(() => api.checkTx(any()));
    });

    test('short-circuits ack when bloc closes mid-poll', () async {
      final completer = Completer<Map<String, dynamic>>();
      when(() => api.checkTx(any())).thenAnswer((_) => completer.future);

      final pipeline = TransactionPipeline(
        wallet,
        rpc,
        _AllowAllAuthGate(),
        api,
        ledger,
      );

      var ackCount = 0;
      var closed = false;
      pipeline.runIndexerCheck(
        signature: 'sig123',
        onAck: (_, _) => ackCount++,
        isClosed: () => closed,
        delay: Duration.zero,
      );

      // Let the poll suspend on `api.checkTx`, then flip the bloc state.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      closed = true;
      completer.complete(<String, dynamic>{});
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(ackCount, 0, reason: 'ack must not fire after bloc was torn down');
    });
  });
}
