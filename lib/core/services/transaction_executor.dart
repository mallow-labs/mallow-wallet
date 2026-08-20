import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../config/remote_config.dart';
import '../network/solana_rpc_service.dart';
import '../result/app_failure.dart';
import '../result/result.dart';
import 'ledger_service.dart';
import 'stale_tx_tracker.dart';
import 'transaction_pipeline.dart';
import 'transaction_signing.dart' show hasPreAttachedSignature;

/// Coarse pipeline phase used to drive per-bloc UI copy.
///
/// The executor itself doesn't touch bloc state — emitting state is the
/// caller's job. Hosts subscribe to [ExecutorStage] events through the
/// [TransactionExecutor.execute] `onStage` callback and translate each
/// phase into the right copy for their flow (single-tx vs. multi-tx
/// progress, "Approve in your wallet" vs. "Sending transaction…" etc.).
enum ExecutorStage {
  /// Wallet approval prompt is open. Ledger flows transition to
  /// [ledgerAwaitingDevice] once the device-side confirmation begins.
  awaitingApproval,

  /// Ledger device is now awaiting user confirmation. Hosts that surface
  /// per-stage Ledger copy ("Approve on your Ledger device") swap to it
  /// here. Fires only when `useLedger` is true.
  ledgerAwaitingDevice,

  /// Wallet returned a signed tx; broadcasting + confirming on-chain.
  broadcasting,
}

class ExecutorStageEvent {
  const ExecutorStageEvent({
    required this.stage,
    required this.index,
    required this.total,
  });

  final ExecutorStage stage;

  /// Zero-based index of the tx in the batch. For single-tx flows this is
  /// always 0. Multi-tx flows (e.g. an edition buy with quantity > 1) emit
  /// per-tx events in submission order.
  final int index;

  /// Total number of txs in the batch.
  final int total;

  bool get isMulti => total > 1;
}

/// Unified entry-point for executing one or more server-built compiled
/// transactions.
///
/// Replaces the per-bloc `_onConfirmAndSign` skeleton that interleaves:
///
/// 1. Co-signed staleness recovery — re-asking the backend for a fresh
///    pre-signed tx when the user lingered on the confirmation sheet long
///    enough to risk "Blockhash not found".
/// 2. Sequential sign/broadcast of an ordered batch (single-tx flows
///    degenerate to a one-iteration loop).
/// 3. Cancel-vs-error classification via [Result] + [AppFailure].
///
/// The executor deliberately does NOT emit BLoC states — different flows
/// have different state shapes (sealed classes, single-state copyWith
/// patterns, pipeline-status enums) and centralising state emission
/// would force every caller onto a common state machine. Instead callers
/// translate [ExecutorStageEvent] into their own state via the [execute]
/// `onStage` callback, then branch on the returned [Result] to emit
/// success/error states.
///
/// For the matching `_runCheckTx` indexer poll see
/// [TransactionPipeline.runIndexerCheck] — kept as a separate fire-and-
/// forget call because it outlives the execute future.
@lazySingleton
class TransactionExecutor {
  TransactionExecutor(this._pipeline);

  final TransactionPipeline _pipeline;

  /// Execute [txsBase64] in order. Returns the last on-chain signature on
  /// success.
  ///
  /// **Multi-tx batches.** Each tx is signed/broadcast/confirmed before
  /// the next one starts so per-tx state (e.g. an edition buy's
  /// `currentSupply` increment) is observed by the next build. Only the
  /// first tx is gated by [TransactionAuthGate] via [usdValue] — subsequent
  /// txs in the same batch are continuations of the same user intent and
  /// should not re-prompt mid-loop, matching the prior inline behaviour
  /// in `market_bloc`.
  ///
  /// **Staleness recovery.** [tracker] is consulted only when the first
  /// tx in the batch is server-co-signed (has at least one non-zero
  /// signature). Non-co-signed flows can refresh blockhashes client-side
  /// via [TransactionPipeline] / [signSendConfirm], so the tracker would
  /// be redundant; passing one in is still safe — it just won't fire.
  /// If the tracked batch has aged past the staleness window the tracker
  /// re-runs its build closure, swaps the batch, and execution proceeds
  /// against the fresh txs.
  ///
  /// **Cancellation.** A user-cancelled biometric prompt or wallet reject
  /// surfaces as `Result.failure(AppFailure(kind: cancelled))`; callers
  /// branch on `failure.isCancelled` to render the cancel message
  /// verbatim instead of as a generic error. A remote kill is a separate
  /// kind — `AppFailureKind.flowDisabled` — so callers must run it
  /// through `handleFlowDisabled` rather than their cancel branch.
  /// [additionalSigners] are appended to the user's signature on every tx
  /// in the batch. Mint's create flow uses this for the ephemeral mint
  /// keypair; flows without extra signers should leave it empty.
  Future<Result<String, AppFailure>> execute({
    required List<String> txsBase64,
    required double? usdValue,
    required FlowKey flow,
    StaleTxTracker<List<String>>? tracker,
    void Function(ExecutorStageEvent)? onStage,
    bool useLedger = true,
    List<Ed25519HDKeyPair> additionalSigners = const [],
    SolanaRpcService? rpcOverride,
  }) async {
    if (txsBase64.isEmpty) {
      return const ResultFailure(
        AppFailure.validation('No transaction to execute'),
      );
    }

    var txs = txsBase64;

    // Staleness refresh for server-co-signed batches. A batch can be mixed:
    // the edition buy's on-chain-allowlist `setupTx` is signed only by the
    // buyer and leads a batch of print txs that DO carry the backend's
    // ephemeral print-mint signature. Those cannot have their blockhash
    // refreshed client-side, so if ANY tx is co-signed the whole batch has to
    // go back to the builder — checking only the first would silently strand
    // an expired print behind a fresh setup tx.
    if (tracker != null) {
      final anyCoSigned = txs.any(
        (tx) => hasPreAttachedSignature(SignedTx.fromBytes(base64Decode(tx))),
      );
      if (anyCoSigned) {
        final refreshResult = await Result.guard(tracker.refreshIfStale);
        switch (refreshResult) {
          case ResultSuccess(:final value):
            if (value != null) txs = value;
          case ResultFailure(:final error):
            return ResultFailure(error);
        }
      }
    }

    return Result.guard(() async {
      String? lastSignature;
      final total = txs.length;
      for (var i = 0; i < total; i++) {
        onStage?.call(
          ExecutorStageEvent(
            stage: ExecutorStage.awaitingApproval,
            index: i,
            total: total,
          ),
        );
        final txResult = await _pipeline.signAndBroadcast(
          unsignedTxBase64: txs[i],
          rpcOverride: rpcOverride,
          // Every tx in a batch belongs to the same cell — the kill check in
          // [TransactionAuthGate] is not the `usdValue` short-circuit below
          // and must run for continuations too.
          flow: flow,
          // Only the first tx in a multi-tx batch carries the user-intent
          // prompt; subsequent txs are continuations of the same
          // authorization and pass 0.0 to skip the gate.
          usdValue: i == 0 ? usdValue : 0.0,
          // An additional signer may be required by only SOME txs in the
          // batch — e.g. a lazily-created group keypair signs only the chunk
          // holding the `CreateGroupV1` ix. Passing it to a tx that doesn't
          // require it makes `signCompiledTx` throw, so filter to each tx's
          // required-signer set. (Single-tx callers already pre-filter, so
          // this is a no-op for them.)
          additionalSigners: requiredSignersForTx(txs[i], additionalSigners),
          useLedger: useLedger,
          onLedgerSigning: useLedger
              ? (s) {
                  if (s == LedgerSigningState.waitingForConfirmation) {
                    onStage?.call(
                      ExecutorStageEvent(
                        stage: ExecutorStage.ledgerAwaitingDevice,
                        index: i,
                        total: total,
                      ),
                    );
                  }
                }
              : null,
          onSigned: () => onStage?.call(
            ExecutorStageEvent(
              stage: ExecutorStage.broadcasting,
              index: i,
              total: total,
            ),
          ),
        );
        // Rethrow per-tx failures inside the surrounding [Result.guard] so
        // the outer switch classifies them uniformly (cancel vs. other).
        lastSignature = switch (txResult) {
          ResultSuccess(:final value) => value,
          ResultFailure(:final error) => throw error,
        };
      }
      return lastSignature!;
    });
  }
}

/// Filter [signers] to those that occupy a required-signer slot in
/// [txBase64]'s compiled message. `signCompiledTx` throws on a signer that
/// isn't required, so in a heterogeneous batch (e.g. a group keypair that signs
/// only the `CreateGroupV1` chunk) each tx must receive only the signers it
/// actually needs. On a decode failure, fall back to passing the full list
/// unchanged (preserves the prior single-tx behaviour).
List<Ed25519HDKeyPair> requiredSignersForTx(
  String txBase64,
  List<Ed25519HDKeyPair> signers,
) {
  if (signers.isEmpty) return signers;
  try {
    final msg = SignedTx.fromBytes(base64Decode(txBase64)).compiledMessage;
    final required = <String>{
      for (
        var i = 0;
        i < msg.requiredSignatureCount && i < msg.accountKeys.length;
        i++
      )
        msg.accountKeys[i].toBase58(),
    };
    return signers
        .where((s) => required.contains(s.publicKey.toBase58()))
        .toList(growable: false);
  } catch (_) {
    return signers;
  }
}
