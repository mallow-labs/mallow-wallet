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
import 'transaction_signing.dart'
    show createsLookupTable, hasPreAttachedSignature;

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
  /// **Staleness recovery.** [tracker] is consulted whenever the pending
  /// work cannot be made fresh client-side — see [needsBuilderRebuild].
  /// That is two cases: a server-co-signed tx (a blockhash rewrite would
  /// invalidate the backend's signature) and a tx that creates an address
  /// lookup table (its baked `recent_slot` ages out on its own clock, which
  /// a blockhash refresh does not touch). Everything else can refresh
  /// client-side via [TransactionPipeline] / [signSendConfirm], so the
  /// tracker is redundant there; passing one in is still safe — it just
  /// won't fire. If the tracked batch has aged past the staleness window the
  /// tracker re-runs its build closure, swaps the batch, and execution
  /// proceeds against the fresh txs.
  ///
  /// **[rebuildsRemainingWork] — mid-batch staleness.** By default the
  /// tracker is consulted only *before the first* tx. That is deliberate and
  /// must stay the default: most build closures are keyed on user intent, not
  /// on chain state. An edition buy of quantity 3 re-asks for three prints —
  /// re-running it after print 1 landed would buy three more (see
  /// `market_bloc`'s `buyEditionTx` closure). Re-asking mid-batch is only
  /// sound when the builder recomputes from authoritative on-chain state and
  /// returns *only the work still outstanding*; a caller asserts exactly that
  /// by passing `rebuildsRemainingWork: true`, and then the tracker is also
  /// consulted before every subsequent tx.
  ///
  /// Why that matters: a batch is signed, broadcast and **confirmed** one tx
  /// at a time, and each tx needs its own user approval, so a batch of N
  /// chunks compiled by the backend against ONE blockhash (as
  /// `/v2/tx/nft/edit-collection-artworks` does) routinely outlives it. When
  /// such a batch is server-co-signed the blockhash cannot be refreshed
  /// client-side, so chunk k > 0 fails with "Blockhash not found" and the
  /// edit is left **partially applied** with no recovery. The pre-loop check
  /// alone can never see that — the clock runs out inside the loop.
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
    bool rebuildsRemainingWork = false,
  }) async {
    if (txsBase64.isEmpty) {
      return const ResultFailure(
        AppFailure.validation('No transaction to execute'),
      );
    }

    return Result.guard(() async {
      // Work still to submit, in order. A staleness rebuild replaces this
      // wholesale with whatever the builder says is left.
      var pending = txsBase64;
      // Txs confirmed so far. Doubles as the next tx's batch index, so a
      // mid-flight rebuild renumbers the "(k of n)" progress copy without ever
      // letting it run backwards.
      var completed = 0;
      var total = pending.length;
      String? lastSignature;

      while (pending.isNotEmpty) {
        // Staleness refresh. Before the first tx this fires for any batch the
        // client cannot freshen itself; after it, only for callers that
        // asserted their builder returns just the remaining work.
        //
        // A batch can be mixed: the edition buy's on-chain-allowlist `setupTx`
        // is signed only by the buyer and leads a batch of print txs that DO
        // carry the backend's ephemeral print-mint signature. Those cannot
        // have their blockhash refreshed client-side, so if ANY pending tx
        // needs the builder the whole remainder goes back to it — checking
        // only the first would silently strand an expired print behind a fresh
        // setup tx.
        if (tracker != null &&
            (completed == 0 || rebuildsRemainingWork) &&
            needsBuilderRebuild(pending)) {
          final fresh = await tracker.refreshIfStale();
          if (fresh != null) {
            pending = fresh;
            // The rebuild speaks for the remainder only; the txs already
            // confirmed still count toward the batch the user is watching.
            total = completed + pending.length;
            // The builder can legitimately answer "nothing left" — every
            // outstanding move already landed. Stop rather than loop.
            if (pending.isEmpty) break;
          }
        }

        final index = completed;
        onStage?.call(
          ExecutorStageEvent(
            stage: ExecutorStage.awaitingApproval,
            index: index,
            total: total,
          ),
        );
        final txResult = await _pipeline.signAndBroadcast(
          unsignedTxBase64: pending.first,
          rpcOverride: rpcOverride,
          // Every tx in a batch belongs to the same cell — the kill check in
          // [TransactionAuthGate] is not the `usdValue` short-circuit below
          // and must run for continuations too.
          flow: flow,
          // Only the first tx in a multi-tx batch carries the user-intent
          // prompt; subsequent txs are continuations of the same
          // authorization and pass 0.0 to skip the gate.
          usdValue: index == 0 ? usdValue : 0.0,
          // An additional signer may be required by only SOME txs in the
          // batch — e.g. a lazily-created group keypair signs only the chunk
          // holding the `CreateGroupV1` ix. Passing it to a tx that doesn't
          // require it makes `signCompiledTx` throw, so filter to each tx's
          // required-signer set. (Single-tx callers already pre-filter, so
          // this is a no-op for them.)
          additionalSigners: requiredSignersForTx(
            pending.first,
            additionalSigners,
          ),
          useLedger: useLedger,
          onLedgerSigning: useLedger
              ? (s) {
                  if (s == LedgerSigningState.waitingForConfirmation) {
                    onStage?.call(
                      ExecutorStageEvent(
                        stage: ExecutorStage.ledgerAwaitingDevice,
                        index: index,
                        total: total,
                      ),
                    );
                  }
                }
              : null,
          onSigned: () => onStage?.call(
            ExecutorStageEvent(
              stage: ExecutorStage.broadcasting,
              index: index,
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
        completed++;
        pending = pending.sublist(1);
      }

      if (lastSignature == null) {
        // Only reachable when a rebuild emptied the batch before anything was
        // submitted. Nothing landed, so there is no signature to return and
        // the non-nullable success contract cannot be honoured — report it the
        // same way an empty input is reported rather than throwing a null
        // check the caller cannot read.
        throw const AppFailure.validation('No transaction to execute');
      }
      return lastSignature;
    });
  }
}

/// `true` when any tx in [txsBase64] cannot be made fresh client-side and so
/// has to be re-asked from the builder once it goes stale.
///
/// Two independent reasons, both of which survive a client-side blockhash
/// rewrite:
///
///  * **Server-co-signed** — the backend already signed over the original
///    message bytes, so [signSendConfirm] must leave them alone and the
///    blockhash it was built with is the one that expires.
///  * **Creates a lookup table** — `create_lookup_table` bakes a `recent_slot`
///    the runtime only recognises for ~512 slots (~3.4 min). The blockhash
///    refresh keeps the tx *looking* fresh while that slot dies, so the wallet
///    would send a LUT `setupTx` that fails on-chain for a reason nothing on
///    screen explains. See `createsLookupTable`.
///
/// A tx whose bytes will not decode is not counted: it cannot be inspected,
/// and signing it a moment later fails with a real error rather than an
/// unhandled decode throw out of [TransactionExecutor.execute].
bool needsBuilderRebuild(List<String> txsBase64) => txsBase64.any((tx) {
  try {
    final decoded = SignedTx.fromBytes(base64Decode(tx));
    return hasPreAttachedSignature(decoded) || createsLookupTable(decoded);
  } catch (_) {
    return false;
  }
});

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
