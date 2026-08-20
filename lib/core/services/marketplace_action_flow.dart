import 'package:flutter/foundation.dart' show debugPrint;
import 'package:injectable/injectable.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../config/remote_config.dart';
import '../network/auth_service.dart';
import '../network/solana_rpc_service.dart';
import '../result/app_failure.dart';
import '../result/result.dart';
import 'stale_tx_tracker.dart';
import 'transaction_executor.dart';
import 'transaction_flow_state.dart';
import 'transaction_pipeline.dart';

/// Lifecycle callbacks a marketplace BLoC maps to its own state shape.
///
/// The marketplace blocs do **not** share a single state type:
///
///  * `market` emits [TransactionFlowState] directly,
///  * `auction` / `fixed_price` / `swap` wrap it in a composite state's
///    `flow` field (`state.copyWith(flow: …)`),
///  * `raffle` uses a bespoke sealed `RaffleState` with no
///    [TransactionFlowState] at all.
///
/// So [MarketplaceActionFlow] cannot hard-code emitting a common state —
/// mirroring why [TransactionExecutor] / [TransactionPipeline] deliberately
/// don't emit BLoC state. Each bloc supplies an [ActionFlowSink] translating
/// the six lifecycle edges into its own `emit`. Blocs already on
/// [TransactionFlowState] get the [txFlowSink] adapter for free.
class ActionFlowSink<P, S> {
  const ActionFlowSink({
    required this.onPreparing,
    required this.onReady,
    required this.onSigning,
    required this.onBroadcasting,
    required this.onSuccess,
    required this.onFailure,
  });

  /// Build started (tx not yet ready). Maps to a "preparing/loading" state.
  final void Function() onPreparing;

  /// Tx(s) built and ready for the confirmation sheet. [prep] is the
  /// feature's ready-payload built by the caller's `toPrep`.
  final void Function(P prep) onReady;

  /// Signing in progress. [stage] is optional per-tx copy (ledger / multi-tx
  /// progress / local-send) — `null` when the host renders its own default.
  final void Function(String? stage) onSigning;

  /// Wallet returned a signature; broadcasting + confirming on-chain.
  final void Function() onBroadcasting;

  /// On-chain confirmation succeeded. [success] is the feature's
  /// success-payload built by the caller's `toSuccess`.
  final void Function(String signature, S success) onSuccess;

  /// Prepare or execute failed. Already error-prefixed / cancel-aware.
  final void Function(AppFailure failure) onFailure;
}

/// Adapter for blocs whose state is (or wraps) [TransactionFlowState].
///
/// [emit] is the bloc's emit of the flow state — either directly
/// (`market`, whose state *is* `TransactionFlowState<P, S>`) or wrapped
/// (`auction`/`swap`/`fixed_price`, via `(flow) => emit(state.copyWith(flow:
/// flow))`).
ActionFlowSink<P, S> txFlowSink<P, S>(
  void Function(TransactionFlowState<P, S> flow) emit,
) => ActionFlowSink<P, S>(
  // Type args are explicit: the parameterless states would otherwise infer
  // `<Never, Never>` here (no value to drive P/S inference), and the bloc's
  // emitted state type must match `TransactionFlowState<P, S>` exactly.
  onPreparing: () => emit(TxFlowPreparing<P, S>()),
  onReady: (prep) => emit(TxFlowReady<P, S>(prep)),
  onSigning: (stage) => emit(TxFlowSigning<P, S>(stage: stage)),
  onBroadcasting: () => emit(TxFlowBroadcasting<P, S>()),
  onSuccess: (signature, success) =>
      emit(TxFlowSuccess<P, S>(signature: signature, result: success)),
  onFailure: (failure) => emit(TxFlowFailure<P, S>(failure)),
);

/// Owns the `prepare → ready → execute → indexer-poll` choreography shared by
/// the marketplace blocs (`market`, `auction`, `fixed_price`, `raffle`,
/// `swap`). Built on the shared [TransactionExecutor] (signing) and
/// [TransactionPipeline] (post-execute indexer poll).
///
/// The flow itself is stateless — it never holds the bloc's state. It drives
/// the bloc through the [ActionFlowSink] callbacks and owns:
///
///  * wallet resolution (the repeated "No wallet connected" guard),
///  * [StaleTxTracker] build + clear,
///  * error wrapping via C1's [AppFailure.prefixedWith],
///  * the [ExecutorStageEvent] → sink mapping,
///  * the fire-and-forget [TransactionPipeline.runIndexerCheck].
@lazySingleton
class MarketplaceActionFlow {
  MarketplaceActionFlow(this._authService, this._executor, this._pipeline);

  final AuthService _authService;
  final TransactionExecutor _executor;
  final TransactionPipeline _pipeline;

  /// Emit `preparing`, optionally resolve the wallet, build + track the tx(s),
  /// then emit `ready` (with the caller's [toPrep] payload) or a
  /// `[errorPrefix]`-prefixed failure.
  ///
  /// [build] receives the resolved wallet address (empty string when
  /// [requireWallet] is false — flows like a fixed-price buy build without it).
  /// On any build error the [tracker] is cleared so a later retry rebuilds
  /// from scratch.
  Future<void> prepare<P, S>({
    required ActionFlowSink<P, S> sink,
    required StaleTxTracker<List<String>> tracker,
    required Future<List<String>> Function(String wallet) build,
    required P Function(List<String> txs, String wallet) toPrep,
    required String errorPrefix,
    bool requireWallet = true,
    String walletErrorMessage = 'No wallet connected',
  }) async {
    sink.onPreparing();

    var wallet = '';
    if (requireWallet) {
      final address = _authService.currentAddress;
      if (address == null || address.isEmpty) {
        sink.onFailure(AppFailure.unknown(walletErrorMessage));
        return;
      }
      wallet = address;
    }

    final result = await Result.guard(
      () => tracker.buildAndTrack(() => build(wallet)),
    );
    switch (result) {
      case ResultSuccess(:final value):
        sink.onReady(toPrep(value, wallet));
      case ResultFailure(:final error):
        tracker.clear();
        // The sheets only show the classified message — log the raw
        // failure (incl. cause) so `flutter run` output identifies it.
        debugPrint(
          '[MarketplaceActionFlow] $errorPrefix: $error '
          '(cause: ${error.cause})',
        );
        sink.onFailure(error.prefixedWith(errorPrefix));
    }
  }

  /// Sign + broadcast [txsBase64] through [TransactionExecutor], emitting
  /// `signing` / `broadcasting` along the way, then on success emit `success`
  /// (with the caller's [toSuccess] payload) and kick off the background
  /// indexer poll; on failure emit a `[failurePrefix]`-prefixed (cancel-aware)
  /// failure.
  ///
  /// [stageFor] supplies the per-tx signing copy: `(index, total, ledger)`
  /// where `ledger` is true for the Ledger-device confirmation edge. Return
  /// `null` to leave the stage host-default. [usdValue] gates only the first
  /// tx (continuations skip the prompt — see [TransactionExecutor.execute]).
  Future<void> execute<P, S>({
    required ActionFlowSink<P, S> sink,
    required List<String> txsBase64,
    required double? usdValue,
    required FlowKey flow,
    required S Function(String signature) toSuccess,
    required bool Function() isClosed,
    required void Function(String signature, bool ok) onIndexedAck,
    StaleTxTracker<List<String>>? tracker,
    String? Function(int index, int total, bool ledger)? stageFor,
    bool useLedger = true,
    bool requireEntry = false,
    String emptyTxMessage = 'No transaction to sign',
    String failurePrefix = 'Transaction failed',
    List<Ed25519HDKeyPair> additionalSigners = const [],
    SolanaRpcService? rpcOverride,
  }) async {
    if (txsBase64.isEmpty) {
      sink.onFailure(AppFailure.unknown(emptyTxMessage));
      return;
    }

    sink.onSigning(stageFor?.call(0, txsBase64.length, false));

    final signResult = await _executor.execute(
      txsBase64: txsBase64,
      usdValue: usdValue,
      flow: flow,
      tracker: tracker,
      useLedger: useLedger,
      additionalSigners: additionalSigners,
      rpcOverride: rpcOverride,
      onStage: (event) {
        switch (event.stage) {
          case ExecutorStage.awaitingApproval:
            sink.onSigning(stageFor?.call(event.index, event.total, false));
          case ExecutorStage.ledgerAwaitingDevice:
            sink.onSigning(stageFor?.call(event.index, event.total, true));
          case ExecutorStage.broadcasting:
            sink.onBroadcasting();
        }
      },
    );

    switch (signResult) {
      case ResultSuccess(:final value):
        tracker?.clear();
        sink.onSuccess(value, toSuccess(value));
        // Fire-and-forget — outlives this future, so it is not awaited.
        _pipeline.runIndexerCheck(
          signature: value,
          requireEntry: requireEntry,
          onAck: onIndexedAck,
          isClosed: isClosed,
        );
      case ResultFailure(:final error):
        tracker?.clear();
        debugPrint(
          '[MarketplaceActionFlow] $failurePrefix: $error '
          '(cause: ${error.cause})',
        );
        sink.onFailure(error.prefixedWith(failurePrefix));
    }
  }
}
