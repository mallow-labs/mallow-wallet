import 'package:equatable/equatable.dart';

import '../result/app_failure.dart';

/// Generic state machine for the "build tx → confirm → sign → broadcast →
/// confirm-on-chain" pattern used by every signing BLoC in the app.
///
/// Each variant maps to a phase emitted by [TransactionExecutor] (or its
/// surrounding prepare step). Hosts pick concrete types for the two
/// payloads:
///
/// * `TPrep` — data the confirm-sheet needs (transactions, fees, totals,
///   simulation result, etc.). Carried on [TxFlowReady].
/// * `TResult` — data the success UI needs (signature is provided
///   separately; this is for domain-specific fields like
///   `explorerUrl`, swap input/output amounts, indexed-ack flag).
///   Carried on [TxFlowSuccess].
///
/// Flows that don't need a payload can use `void` (or `Null`) for the
/// type parameter; flows with no confirm sheet (auction/fixed-price
/// pipeline runs end-to-end) skip [TxFlowReady] entirely.
sealed class TransactionFlowState<TPrep, TResult> extends Equatable {
  const TransactionFlowState();

  @override
  List<Object?> get props => const [];
}

/// Initial state — no flow in progress.
final class TxFlowIdle<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowIdle();
}

/// Building the tx (server call, rewards-description post, etc.).
final class TxFlowPreparing<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowPreparing();
}

/// Tx built; user confirmation sheet open. [data] carries whatever the
/// sheet needs to render — transactions, totals, simulation result, etc.
final class TxFlowReady<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowReady(this.data);

  final TPrep data;

  @override
  List<Object?> get props => [data];
}

/// User confirmed; wallet approval prompt in flight. [stage] is an
/// optional copy override (e.g. "Approve on your Ledger device") so
/// hosts that need per-wallet-type copy don't need a separate state.
final class TxFlowSigning<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowSigning({this.stage});

  final String? stage;

  @override
  List<Object?> get props => [stage];
}

/// Wallet returned a signed tx; broadcasting to the network. [label] is
/// an optional copy override (e.g. "Setting up listing… (1 of 2)") used
/// by multi-broadcast flows to disambiguate which broadcast is in
/// flight; single-broadcast flows leave it null and the sheet picks
/// default copy.
final class TxFlowBroadcasting<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowBroadcasting({this.label});

  final String? label;

  @override
  List<Object?> get props => [label];
}

/// Tx confirmed on-chain. [signature] is the on-chain signature; [result]
/// carries domain-specific data the success UI needs.
final class TxFlowSuccess<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowSuccess({required this.signature, required this.result});

  final String signature;
  final TResult result;

  @override
  List<Object?> get props => [signature, result];
}

/// Terminal failure. [failure] classifies the cause (cancel vs. network
/// vs. unknown) so the UI can branch on `failure.isCancelled` instead of
/// parsing message strings.
final class TxFlowFailure<TPrep, TResult>
    extends TransactionFlowState<TPrep, TResult> {
  const TxFlowFailure(this.failure);

  final AppFailure failure;

  @override
  List<Object?> get props => [failure];
}
