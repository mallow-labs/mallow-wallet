import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/services/marketplace_action_flow.dart';
import '../../../core/services/stale_tx_tracker.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../data/raffle_repository.dart';

part 'raffle_bloc.freezed.dart';

/// Events for the rafffle program flows. Mirrors `MarketBloc` but kept
/// separate because the raffle lifecycle (selling → awaiting-draw →
/// drawn-unclaimed → ended) doesn't fit the buy/sell shape.
@freezed
sealed class RaffleEvent with _$RaffleEvent {
  /// Buy [ticketCount] tickets on the raffle identified by [raffleKey].
  const factory RaffleEvent.buyTickets({
    required String raffleKey,
    required int ticketCount,
  }) = RaffleBuyTickets;

  /// Owner cancels a raffle (program enforces "no tickets sold").
  const factory RaffleEvent.cancel({required String raffleKey}) = RaffleCancel;

  /// Winner claims the NFT, OR creator reclaims after a no-winner draw —
  /// backend distinguishes via `raffle.winner`.
  const factory RaffleEvent.claimNft({required String raffleKey}) =
      RaffleClaimNft;

  /// Creator claims proceeds from a successful raffle.
  const factory RaffleEvent.claimProceeds({required String raffleKey}) =
      RaffleClaimProceeds;

  const factory RaffleEvent.confirmAndSign() = RaffleConfirmAndSign;
  const factory RaffleEvent.reset() = RaffleReset;

  /// Internal — emitted by the background `_runCheckTx` poll once the
  /// indexer acks the raffle tx. Drives [RaffleSuccess.indexed].
  const factory RaffleEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = RaffleIndexedAck;
}

@freezed
sealed class RaffleState with _$RaffleState {
  const factory RaffleState.initial() = RaffleInitial;
  const factory RaffleState.loading() = RaffleLoading;
  const factory RaffleState.readyToSign({
    required String transactionBase64,
    required String raffleKey,
    required String actionType,

    /// Kill-switch cell for the prepared action. Carried on the state because
    /// the sign step happens in a separate event from the prepare that chose
    /// it, and the four raffle actions are four independent cells —
    /// the claim/cancel escape hatches must stay signable when
    /// `raffle-buy-tickets` is killed.
    required AppFlow flow,
  }) = RaffleReadyToSign;
  const factory RaffleState.signing() = RaffleSigning;
  const factory RaffleState.broadcasting() = RaffleBroadcasting;
  const factory RaffleState.success({
    required String signature,
    required String actionType,

    /// Indexer-ack for the raffle tx. `null` while polling, `true` on
    /// ack, `false` after retries exhaust. Listeners gate "Refetch
    /// raffle state" actions on this.
    bool? indexed,
  }) = RaffleSuccess;

  /// [failure] is the classified failure behind [message], carried so the UI
  /// can tell a remote kill from an ordinary error and present the operator's
  /// copy instead of a generic snackbar. Null for
  /// the few errors emitted without an [AppFailure] behind them; [message]
  /// stays the single source of display copy either way.
  const factory RaffleState.error(String message, {AppFailure? failure}) =
      RaffleError;
}

/// Carries the raffle-specific fields from the prepare phase into [onReady].
class _RafflePrep {
  const _RafflePrep(this.txBase64, this.raffleKey, this.actionType, this.flow);
  final String txBase64;
  final String raffleKey;
  final String actionType;
  final AppFlow flow;
}

@injectable
class RaffleBloc extends Bloc<RaffleEvent, RaffleState> {
  RaffleBloc(this._repo, this._flow) : super(const RaffleState.initial()) {
    on<RaffleBuyTickets>(_onBuyTickets);
    on<RaffleCancel>(_onCancel);
    on<RaffleClaimNft>(_onClaimNft);
    on<RaffleClaimProceeds>(_onClaimProceeds);
    on<RaffleConfirmAndSign>(_onConfirmAndSign);
    on<RaffleIndexedAck>(_onIndexedAck);
    on<RaffleReset>(_onReset);
  }

  final RaffleRepository _repo;
  final MarketplaceActionFlow _flow;

  /// Stale-blockhash recovery for server-co-signed raffle txs. See
  /// [StaleTxTracker] for the rationale. Single-tx raffle flows wrap
  /// the one server-built tx in a one-element list so the tracker can
  /// share the [TransactionExecutor] tracker type used by multi-tx
  /// flows like market edition buys.
  final _txTracker = StaleTxTracker<List<String>>();

  ActionFlowSink<_RafflePrep, String> _sink(
    Emitter<RaffleState> emit,
  ) => ActionFlowSink(
    onPreparing: () => emit(const RaffleState.loading()),
    onReady: (prep) => emit(
      RaffleState.readyToSign(
        transactionBase64: prep.txBase64,
        raffleKey: prep.raffleKey,
        actionType: prep.actionType,
        flow: prep.flow,
      ),
    ),
    // Raffle UI shows a single "Signing" state regardless of stage copy.
    onSigning: (_) => emit(const RaffleState.signing()),
    onBroadcasting: () => emit(const RaffleState.broadcasting()),
    onSuccess: (sig, actionType) =>
        emit(RaffleState.success(signature: sig, actionType: actionType)),
    // `prefixedWith` already no-ops on cancelled failures so `failure.message`
    // is the raw cancel copy for cancellations and the prefixed copy otherwise —
    // matching the previous `error.isCancelled ? ... : '...: ...'` pattern.
    onFailure: (failure) =>
        emit(RaffleState.error(failure.message, failure: failure)),
  );

  Future<void> _runPrepare({
    required Emitter<RaffleState> emit,
    required Future<String> Function(String me) build,
    required String raffleKey,
    required String actionType,
    required AppFlow flow,
    required String errorPrefix,
  }) => _flow.prepare(
    sink: _sink(emit),
    tracker: _txTracker,
    build: (me) async => [await build(me)],
    toPrep: (txs, _) => _RafflePrep(txs.single, raffleKey, actionType, flow),
    errorPrefix: errorPrefix,
  );

  Future<void> _onBuyTickets(
    RaffleBuyTickets event,
    Emitter<RaffleState> emit,
  ) => _runPrepare(
    emit: emit,
    build: (me) => _repo.getBuyTicketsTx(
      buyer: me,
      raffleKey: event.raffleKey,
      ticketCount: event.ticketCount,
    ),
    raffleKey: event.raffleKey,
    actionType: 'buy-tickets',
    flow: AppFlow.raffleBuyTickets,
    errorPrefix: 'Failed to prepare ticket purchase',
  );

  Future<void> _onCancel(RaffleCancel event, Emitter<RaffleState> emit) =>
      _runPrepare(
        emit: emit,
        build: (me) =>
            _repo.getCancelRaffleTx(creator: me, raffleKey: event.raffleKey),
        raffleKey: event.raffleKey,
        actionType: 'cancel-raffle',
        flow: AppFlow.raffleCancel,
        errorPrefix: 'Failed to prepare cancel',
      );

  Future<void> _onClaimNft(RaffleClaimNft event, Emitter<RaffleState> emit) =>
      _runPrepare(
        emit: emit,
        build: (me) =>
            _repo.getClaimNftTx(caller: me, raffleKey: event.raffleKey),
        raffleKey: event.raffleKey,
        actionType: 'claim-nft',
        flow: AppFlow.raffleClaimPrize,
        errorPrefix: 'Failed to prepare claim',
      );

  Future<void> _onClaimProceeds(
    RaffleClaimProceeds event,
    Emitter<RaffleState> emit,
  ) => _runPrepare(
    emit: emit,
    build: (me) =>
        _repo.getClaimProceedsTx(creator: me, raffleKey: event.raffleKey),
    raffleKey: event.raffleKey,
    actionType: 'claim-proceeds',
    flow: AppFlow.raffleClaimProceeds,
    errorPrefix: 'Failed to prepare claim',
  );

  Future<void> _onConfirmAndSign(
    RaffleConfirmAndSign event,
    Emitter<RaffleState> emit,
  ) async {
    final current = state;
    if (current is! RaffleReadyToSign) return;

    // Ticket cost isn't exposed in the bloc state — it's baked into the
    // backend-built tx. Pass null for buy-tickets so the gate fail-closes
    // (always prompts above-threshold even though we can't classify
    // precisely). Cancel/claim flows have no SOL/token outflow beyond
    // the network fee, so pass 0.0 to skip the prompt.
    final usdOutflow = current.actionType == 'buy-tickets' ? null : 0.0;

    await _flow.execute(
      sink: _sink(emit),
      tracker: _txTracker,
      txsBase64: [current.transactionBase64],
      usdValue: usdOutflow,
      flow: FlowKey.solana(current.flow),
      toSuccess: (_) => current.actionType,
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(RaffleEvent.indexedAck(signature: sig, ok: ok)),
      // Gate the indexed-ack on the raffle's marketplace entry (BuyTicket /
      // Delist / ClaimProceeds), not just the tx-level checkTx — the artwork
      // screen reads raffle slots / owner off indexed state, so refreshing
      // before the entry lands would read pre-action data (raffle gating).
      // The screen defers its refresh to the indexed flip.
      requireEntry: true,
      // Raffle txs are server-co-signed so [_txTracker] gates blockhash
      // refresh via the backend. UI doesn't surface per-stage Ledger copy
      // (useLedger: false), so the executor only flips broadcasting on
      // wallet-return.
      useLedger: false,
    );
  }

  void _onIndexedAck(RaffleIndexedAck event, Emitter<RaffleState> emit) {
    final current = state;
    if (current is RaffleSuccess && current.signature == event.signature) {
      emit(current.copyWith(indexed: event.ok));
      // `cancel-raffle` returns the raffled NFT to the creator and `claim-nft`
      // hands it to the winner — both change an owner's My Art set. Ticket
      // purchases / proceeds claims don't, so they're excluded.
      if (current.actionType == 'cancel-raffle' ||
          current.actionType == 'claim-nft') {
        notifyPortfolioRefresh();
      }
    }
  }

  void _onReset(RaffleReset event, Emitter<RaffleState> emit) {
    _txTracker.clear();
    emit(const RaffleState.initial());
  }
}
