import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../models/token_balance.dart';

/// Confirm-sheet payload for a fungible-token burn: the prepared (unsigned)
/// burn + closeAccount transaction plus the simulation-derived numbers the
/// sheet renders (network fee, reclaimed rent).
class TokenBurnPrep extends Equatable {
  const TokenBurnPrep({
    required this.txBase64,
    required this.estimatedFeeLamports,
    this.isSimulating = false,
    this.simulationResult,
    this.simulatedPayerLamportsDelta,
  });

  final String txBase64;
  final int estimatedFeeLamports;
  final bool isSimulating;
  final SimulationResult? simulationResult;

  /// Signed net lamport change for the payer under simulation (`post − pre`).
  /// Positive — the closed token account reclaims more rent than the tx fee
  /// costs — which is the normal burn outcome. Null until simulation lands.
  final int? simulatedPayerLamportsDelta;

  @override
  List<Object?> get props => [
    txBase64,
    estimatedFeeLamports,
    isSimulating,
    simulationResult,
    simulatedPayerLamportsDelta,
  ];
}

/// Success payload for a fungible-token burn — the explorer link for the
/// confirmed signature.
class TokenBurnSuccess extends Equatable {
  const TokenBurnSuccess({required this.explorerUrl});

  final String explorerUrl;

  @override
  List<Object?> get props => [explorerUrl];
}

typedef TokenBurnState = TransactionFlowState<TokenBurnPrep, TokenBurnSuccess>;

sealed class TokenBurnEvent {
  const TokenBurnEvent();
}

/// Build the burn + closeAccount tx for [token] and move to [TxFlowReady].
class TokenBurnPrepareRequested extends TokenBurnEvent {
  const TokenBurnPrepareRequested(this.token);

  final TokenBalance token;
}

/// Simulate the prepared tx to surface the reclaimed-rent figure.
class TokenBurnSimulateRequested extends TokenBurnEvent {
  const TokenBurnSimulateRequested();
}

/// Run the auth gate, then sign + broadcast the prepared tx.
class TokenBurnConfirmRequested extends TokenBurnEvent {
  const TokenBurnConfirmRequested();
}

/// Return to idle (sheet dismissed / retry).
class TokenBurnResetRequested extends TokenBurnEvent {
  const TokenBurnResetRequested();
}

/// Burns the entire balance of a fungible SPL token and closes its token
/// account, reclaiming the rent. Mirrors the NFT burn lifecycle
/// (prepare → confirm sheet → sign/broadcast → pipeline sheet) on top of the
/// shared [TransactionFlowState], building the tx client-side via
/// [SolanaRpcService] and routing sign/broadcast through [TransactionExecutor]
/// — the same path the send flow uses.
class TokenBurnBloc extends Bloc<TokenBurnEvent, TokenBurnState> {
  TokenBurnBloc(
    this._rpcService,
    this._walletManager,
    this._authGate,
    this._feeConfig,
    this._executor,
  ) : super(const TxFlowIdle()) {
    on<TokenBurnPrepareRequested>(_onPrepare);
    on<TokenBurnSimulateRequested>(_onSimulate);
    on<TokenBurnConfirmRequested>(_onConfirmAndSign);
    on<TokenBurnResetRequested>((_, emit) => emit(const TxFlowIdle()));
  }

  final SolanaRpcService _rpcService;
  final WalletManager _walletManager;
  final TransactionAuthGate _authGate;
  final FeeConfig _feeConfig;
  final TransactionExecutor _executor;

  TokenBalance? _token;

  /// Bumped on every prepare. A prepare can be re-issued mid-flow when the user
  /// switches the source wallet, and the two network round-trips (tx build vs.
  /// simulation) can land in either order — without this, a simulation started
  /// for the *previous* payer can emit its fee/rent numbers over the freshly
  /// prepared tx, leaving the sheet showing figures for a wallet that is no
  /// longer signing.
  int _prepGeneration = 0;

  Future<void> _onPrepare(
    TokenBurnPrepareRequested event,
    Emitter<TokenBurnState> emit,
  ) async {
    _token = event.token;
    final generation = ++_prepGeneration;
    emit(const TxFlowPreparing());

    final result = await Result.guard(
      () => _rpcService.buildBurnAndCloseTx(tokenMint: event.token.mint),
    );
    if (generation != _prepGeneration) return;
    switch (result) {
      case ResultSuccess(:final value):
        emit(
          TxFlowReady(
            TokenBurnPrep(
              txBase64: value,
              estimatedFeeLamports: _feeConfig.baseTxFeeLamports,
            ),
          ),
        );
        // Auto-simulate so the reclaimed-rent figure fills in without the
        // sheet having to drive it — the sheet mounts during preparing (to
        // show shimmers immediately), so its initState simulate would no-op.
        add(const TokenBurnSimulateRequested());
      case ResultFailure(:final error):
        emit(TxFlowFailure(error.prefixedWith('Failed to prepare burn')));
    }
  }

  Future<void> _onSimulate(
    TokenBurnSimulateRequested event,
    Emitter<TokenBurnState> emit,
  ) async {
    final current = state;
    if (current is! TxFlowReady<TokenBurnPrep, TokenBurnSuccess>) return;
    final prep = current.data;
    final generation = _prepGeneration;

    emit(
      TxFlowReady(
        TokenBurnPrep(
          txBase64: prep.txBase64,
          estimatedFeeLamports: prep.estimatedFeeLamports,
          isSimulating: true,
        ),
      ),
    );

    // Resolved per simulation, not cached: a source-wallet switch re-points the
    // active wallet, so the payer whose lamport delta we inspect must be read
    // again rather than carried over from the previous prepare.
    final payer = await _walletManager.getAddress();
    final sim = await _rpcService.simulateWithDelta(
      address: payer,
      simulate: (inspect) => _rpcService.simulateEncodedTransaction(
        prep.txBase64,
        inspectAccounts: inspect,
      ),
    );

    // Bail if the flow moved on (sheet dismissed, confirm tapped) mid-sim, or
    // if a newer prepare superseded this one (source wallet switched).
    final post = state;
    if (generation != _prepGeneration) return;
    if (post is! TxFlowReady<TokenBurnPrep, TokenBurnSuccess>) return;
    emit(
      TxFlowReady(
        TokenBurnPrep(
          txBase64: post.data.txBase64,
          estimatedFeeLamports: post.data.estimatedFeeLamports,
          simulationResult: sim.result,
          simulatedPayerLamportsDelta: sim.lamportsDelta,
        ),
      ),
    );
  }

  Future<void> _onConfirmAndSign(
    TokenBurnConfirmRequested event,
    Emitter<TokenBurnState> emit,
  ) async {
    final current = state;
    if (current is! TxFlowReady<TokenBurnPrep, TokenBurnSuccess>) return;
    final prep = current.data;
    final token = _token;
    if (token == null) {
      emit(const TxFlowFailure(AppFailure.unknown('No token to burn')));
      return;
    }

    // Burning permanently destroys the holding, so gate it on the value
    // leaving the wallet — high-value burns require biometric/PIN step-up.
    // A token the feed *affirmatively* prices at $0 is worth $0 to the gate
    // (burning known-worthless dust shouldn't demand auth); an unpriced token
    // leaves [totalUsdValue] null, which the gate treats as "unknown" and
    // fails closed on.
    final outcome = await _authGate.authorize(
      usdValue: token.hasKnownZeroValue ? 0 : token.totalUsdValue,
      flow: const FlowKey.solana(AppFlow.tokenBurn),
    );
    final disabledMessage = outcome.disabledMessage;
    if (disabledMessage != null) {
      // A killed cell is NOT a user cancel: as `cancelled` the operator's
      // message would be dropped by the pipeline step's generic "Burn failed"
      // body. The flow's host presents it.
      emit(TxFlowFailure(AppFailure.flowDisabled(disabledMessage)));
      return;
    }
    if (outcome != TransactionAuthOutcome.allowed) {
      emit(
        TxFlowFailure(
          AppFailure.cancelled(
            TransactionAuthCancelledException(outcome).toString(),
          ),
        ),
      );
      return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    emit(TxFlowSigning(stage: isLocal ? kLocalSigningLabel : null));

    final result = await _executor.execute(
      txsBase64: [prep.txBase64],
      flow: const FlowKey.solana(AppFlow.tokenBurn),
      // The auth gate already ran above; pass 0 so the executor's own gate is
      // a no-op (matches the send flow).
      usdValue: 0,
      onStage: (e) {
        if (emit.isDone) return;
        switch (e.stage) {
          case ExecutorStage.awaitingApproval:
            emit(TxFlowSigning(stage: isLocal ? kLocalSigningLabel : null));
          case ExecutorStage.ledgerAwaitingDevice:
            emit(const TxFlowSigning(stage: kLedgerSigningStage));
          case ExecutorStage.broadcasting:
            emit(const TxFlowBroadcasting());
        }
      },
    );

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          TxFlowSuccess(
            signature: value,
            result: TokenBurnSuccess(
              explorerUrl: buildExplorerUrlFromPrefs(value),
            ),
          ),
        );
      case ResultFailure(:final error):
        emit(TxFlowFailure(error));
    }
  }
}
