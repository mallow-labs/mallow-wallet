import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/services/marketplace_action_flow.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/services/tx_landed_slots.dart';
import '../../../core/utils/token_amount.dart';
import '../data/epoch_progress.dart';
import '../data/staking_repository.dart';
import '../data/staking_tx_builder.dart';
import '../staking_constants.dart';
import 'stake_mutation_journal.dart';

export '../../../core/services/transaction_flow_state.dart';

part 'staking_bloc.freezed.dart';

const Object _sentinel = Object();

/// mallowSOL uses 9 decimals, like SOL.
const int _mallowSolDecimals = 9;

/// Which tab of the stake sheet is active.
enum StakeTab { stake, unstake, leaderboard }

/// Native (delegated stake account) vs liquid (mallowSOL via Jupiter).
enum StakeType { native, liquid }

/// Kill-switch cell for a staking submit. Native stake and unstake are distinct
/// builders — and unstake is an escape hatch, so
/// it must stay signable when `stake-native` is killed. Both liquid directions
/// are the same Jupiter swap builder, hence one cell.
///
/// Top-level so the form's entry gate reads the same cell the signing backstop
/// will: `showStakeSheet` is one entry for four builders, so gating the sheet
/// would collapse all four into one switch.
AppFlow stakingSubmitFlow({
  required StakeType stakeType,
  required StakeTab tab,
}) => switch (stakeType) {
  StakeType.liquid => AppFlow.stakeLiquid,
  StakeType.native =>
    tab == StakeTab.stake ? AppFlow.stakeNative : AppFlow.unstakeNative,
};

@freezed
sealed class StakingEvent with _$StakingEvent {
  /// Load (or reload) `/v1/staking`.
  const factory StakingEvent.loadData() = StakingLoadData;

  /// Latest SOL + mallowSOL balances, pushed in by the UI watching
  /// [TokenBalanceBloc]. All in lamports/raw units.
  const factory StakingEvent.balancesUpdated({
    required int solLamports,
    required int mallowSolLamports,
  }) = StakingBalancesUpdated;

  const factory StakingEvent.setTab(StakeTab tab) = StakingSetTab;
  const factory StakingEvent.setStakeType(StakeType type) = StakingSetStakeType;
  const factory StakingEvent.setAmount(String amount) = StakingSetAmount;
  const factory StakingEvent.setHalf() = StakingSetHalf;
  const factory StakingEvent.setMax() = StakingSetMax;

  /// Re-fetch the liquid (Jupiter) quote for the current amount — dispatched
  /// debounced by the UI as the user types on a liquid tab.
  const factory StakingEvent.refreshLiquidQuote() = StakingRefreshLiquidQuote;

  /// Execute the primary action (stake or unstake, native or liquid).
  const factory StakingEvent.submit() = StakingSubmit;

  /// Withdraw all claimable (inactive) native stake.
  const factory StakingEvent.claim() = StakingClaim;

  /// Claim (decompress) the wallet's season SMORES rewards.
  const factory StakingEvent.claimRewards() = StakingClaimRewards;

  const factory StakingEvent.reset() = StakingReset;

  /// Internal — indexer ack for the submitted tx.
  const factory StakingEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = StakingIndexedAck;

  /// Internal — [StakeMutationJournal] recorded, corrected or dropped a
  /// pending mutation, so the overlaid breakdown has to be re-derived. Fired
  /// for mutations made by the *other* [StakingBloc] too, which is how a stake
  /// in the sheet reaches the tokens portfolio's cells.
  const factory StakingEvent.mutationsChanged() = StakingMutationsChanged;
}

/// Unused confirmation payload. Staking *does* review before signing —
/// `showStakeConfirmSheet`, opened by the form's CTA — but that sheet renders
/// from the form state the user just filled in and returns a plain bool; it
/// never builds a tx, so there is nothing to carry through `TxFlowReady`. The
/// flow still enters at [TxFlowPreparing]. This exists only because
/// [TransactionFlowState] is generic over a prep type.
class StakePrep extends Equatable {
  const StakePrep();
  @override
  List<Object?> get props => const [];
}

/// Success payload for [TxFlowSuccess].
class StakeSuccessData extends Equatable {
  const StakeSuccessData({
    required this.message,
    required this.amount,
    required this.symbol,
    this.indexed,
  });

  /// User-facing success line, e.g. "Stake is now activating".
  final String message;
  final double amount;
  final String symbol;

  /// Indexer ack — null while polling, true on ack, false after retries.
  final bool? indexed;

  StakeSuccessData copyWith({Object? indexed = _sentinel}) => StakeSuccessData(
    message: message,
    amount: amount,
    symbol: symbol,
    indexed: identical(indexed, _sentinel) ? this.indexed : indexed as bool?,
  );

  @override
  List<Object?> get props => [message, amount, symbol, indexed];
}

typedef StakingFlowState = TransactionFlowState<StakePrep, StakeSuccessData>;

/// Form + flow state for the stake sheet.
class StakingState extends Equatable {
  const StakingState({
    this.data,
    this.myAddress,
    this.isLoading = true,
    this.loadError,
    this.tab = StakeTab.stake,
    // The sheet opens on the unlocked path. `StakingBloc` is a DI factory, so
    // every `showStakeSheet` starts here — and Liquid asks nothing of the user
    // that Native does: no ~2-day epoch wait before the stake is earning, no
    // 1 SOL minimum, no claim step to come back for. It also leads the type
    // selector, so the default and the first row agree.
    this.stakeType = StakeType.liquid,
    this.amount = '',
    this.solLamports = 0,
    this.mallowSolLamports = 0,
    this.liquidQuote,
    this.isQuoting = false,
    this.epochProgress,
    this.smoresClaimableRaw = 0,
    this.nativeStakeOverride,
    this.flow = const TxFlowIdle<StakePrep, StakeSuccessData>(),
  });

  /// `/v1/staking` payload (null until first load completes).
  final StakingDataResponse? data;

  /// The signed-in wallet address — used to locate the user's leaderboard row.
  final String? myAddress;
  final bool isLoading;
  final AppFailure? loadError;

  final StakeTab tab;
  final StakeType stakeType;
  final String amount;

  /// Spendable SOL balance, in lamports (from [TokenBalanceBloc]).
  final int solLamports;

  /// mallowSOL balance, in lamports.
  final int mallowSolLamports;

  /// Latest classic Jupiter quote for the liquid tab (null on native / when
  /// cleared). Raw-map passthrough — see [JupiterClassicQuote].
  final JupiterClassicQuote? liquidQuote;
  final bool isQuoting;

  /// Current Solana epoch progress, for the unstake tab's epoch-progress and
  /// claim-countdown cards (null until the first on-chain read completes).
  final EpochProgress? epochProgress;

  /// Unclaimed season rewards, in raw SMORES units (6 decimals). Read from the
  /// wallet's ZK-compressed balance, not from `/v1/staking` — the payload's
  /// season fields say what was *earned*, this says what is still sitting
  /// compressed and therefore claimable. 0 means the cell is hidden.
  final int smoresClaimableRaw;

  /// [StakeMutationJournal]'s overlay, when one of our own transactions is
  /// still unconfirmed by the payload. Null the rest of the time, which is
  /// almost always — read [nativeStake], not this.
  final NativeStakeBreakdown? nativeStakeOverride;

  final StakingFlowState flow;

  /// The native-stake breakdown every surface renders: `/v1/staking`'s
  /// figures, superseded by the optimistic overlay while one of our own
  /// stake/unstake/claim transactions is still ahead of the payload.
  ///
  /// 🛑 Read this, never `data!.userData.nativeStake` — the payload is the
  /// *pre-transaction* snapshot for as long as the backend's
  /// `getProgramAccounts` node lags the slot our transaction landed in, which
  /// is exactly the window the status cells have to be right in. Null until
  /// the first load completes.
  NativeStakeBreakdown? get nativeStake =>
      nativeStakeOverride ?? data?.userData.nativeStake;

  /// Mint the active form spends (SOL for staking / liquid; mallowSOL for a
  /// liquid unstake).
  String get inputMint =>
      tab == StakeTab.unstake && stakeType == StakeType.liquid
      ? StakingConstants.mallowSolMint
      : StakingConstants.solMint;

  /// Balance (lamports) the amount input is bounded by, given tab + type.
  int get availableLamports {
    if (tab == StakeTab.stake) return solLamports;
    // Unstake:
    if (stakeType == StakeType.liquid) return mallowSolLamports;
    return availableNativeLamports;
  }

  /// Native stake the unstake builder can actually deactivate — active **and**
  /// activating. The Native row's `Bal:` line renders this, so it can't be
  /// derived twice: an active-only figure read as a cap that Half/Max, which
  /// fill from [availableLamports], then exceeded.
  int get availableNativeLamports =>
      (nativeStake?.activeLamports ?? 0) +
      (nativeStake?.activatingLamports ?? 0);

  /// Whether this unstake's funds come back the moment the tx lands, instead
  /// of at the next epoch boundary.
  ///
  /// Deactivating an account that is still *activating* leaves
  /// `deactivationEpoch == activationEpoch`, which Solana short-circuits to
  /// "no stake at all" — the account is inactive, and claimable, immediately.
  /// [StakingTxBuilder.classifyStakeState] already reads it that way.
  ///
  /// Only true when the user holds **no** active stake:
  /// `buildNativeUnstakeTx` selects largest-first across active *and*
  /// activating accounts, so with both present nothing here can tell which the
  /// tx will touch — and promising "immediately" for funds that then lock for
  /// ~2 days is the worse of the two errors.
  bool get deactivatesImmediately {
    if (tab != StakeTab.unstake || stakeType != StakeType.native) return false;
    final native = nativeStake;
    if (native == null) return false;
    return native.activeLamports == 0 && native.activatingLamports > 0;
  }

  /// Max selectable lamports — SOL leaves a rent/fee reserve; tokens don't.
  int get maxLamports {
    final available = availableLamports;
    if (inputMint == StakingConstants.solMint && tab == StakeTab.stake) {
      final capped = available - StakingConstants.maxReserveLamports;
      return capped > 0 ? capped : 0;
    }
    return available;
  }

  bool get isBusy =>
      flow is TxFlowSigning<StakePrep, StakeSuccessData> ||
      flow is TxFlowBroadcasting<StakePrep, StakeSuccessData> ||
      flow is TxFlowPreparing<StakePrep, StakeSuccessData>;

  /// The native Stake action — the only flow the 1 SOL minimum applies to
  /// (liquid staking and every unstake are exempt).
  bool get isNativeStake =>
      tab == StakeTab.stake && stakeType == StakeType.native;

  /// Raw lamports currently typed into the amount field.
  int get typedLamports => TokenAmount.toInt(
    TokenAmount.parseTokenAmount(amount, _mallowSolDecimals),
  );

  /// The liquid quote, but only when it priced exactly the amount currently
  /// typed. Webapp parity (`StakingSection`): a quote fetched for a
  /// previous amount must never be shown as *this* trade's receive amount /
  /// rate, or the disclosure lies about what will be signed.
  JupiterClassicQuote? get displayQuote {
    final quote = liquidQuote;
    if (quote == null) return null;
    return quote.inAmount == '$typedLamports' ? quote : null;
  }

  /// A positive native-stake amount below the 1 SOL minimum — drives the inline
  /// warning and blocks submit.
  bool get belowNativeMinimum =>
      isNativeStake &&
      typedLamports > 0 &&
      typedLamports < StakingConstants.minNativeStakeLamports;

  /// Lamports the built tx actually sends. A native stake is floored at
  /// [StakingConstants.minNativeStakeSendLamports] (1.0023 SOL) so a 1 SOL
  /// request funds the stake account's rent; larger requests and every other
  /// flow send the typed amount unchanged.
  int get submitLamports {
    final typed = typedLamports;
    if (isNativeStake && typed > StakingConstants.minNativeStakeSendLamports) {
      return typed;
    }
    if (isNativeStake) return StakingConstants.minNativeStakeSendLamports;
    return typed;
  }

  bool get canSubmit {
    if (isBusy) return false;
    if (typedLamports <= 0) return false;
    if (belowNativeMinimum) return false;
    // Bound by [maxLamports], not the raw balance: a native stake sends
    // `submitLamports + rent` on top of the network fee, so anything that eats
    // into the reserve is a guaranteed-failure tx.
    return submitLamports <= maxLamports;
  }

  StakingState copyWith({
    Object? data = _sentinel,
    Object? myAddress = _sentinel,
    bool? isLoading,
    Object? loadError = _sentinel,
    StakeTab? tab,
    StakeType? stakeType,
    String? amount,
    int? solLamports,
    int? mallowSolLamports,
    Object? liquidQuote = _sentinel,
    bool? isQuoting,
    Object? epochProgress = _sentinel,
    int? smoresClaimableRaw,
    Object? nativeStakeOverride = _sentinel,
    StakingFlowState? flow,
  }) => StakingState(
    data: identical(data, _sentinel) ? this.data : data as StakingDataResponse?,
    myAddress: identical(myAddress, _sentinel)
        ? this.myAddress
        : myAddress as String?,
    isLoading: isLoading ?? this.isLoading,
    loadError: identical(loadError, _sentinel)
        ? this.loadError
        : loadError as AppFailure?,
    tab: tab ?? this.tab,
    stakeType: stakeType ?? this.stakeType,
    amount: amount ?? this.amount,
    solLamports: solLamports ?? this.solLamports,
    mallowSolLamports: mallowSolLamports ?? this.mallowSolLamports,
    liquidQuote: identical(liquidQuote, _sentinel)
        ? this.liquidQuote
        : liquidQuote as JupiterClassicQuote?,
    isQuoting: isQuoting ?? this.isQuoting,
    epochProgress: identical(epochProgress, _sentinel)
        ? this.epochProgress
        : epochProgress as EpochProgress?,
    smoresClaimableRaw: smoresClaimableRaw ?? this.smoresClaimableRaw,
    nativeStakeOverride: identical(nativeStakeOverride, _sentinel)
        ? this.nativeStakeOverride
        : nativeStakeOverride as NativeStakeBreakdown?,
    flow: flow ?? this.flow,
  );

  @override
  List<Object?> get props => [
    data,
    myAddress,
    isLoading,
    loadError,
    tab,
    stakeType,
    amount,
    solLamports,
    mallowSolLamports,
    liquidQuote,
    isQuoting,
    epochProgress,
    smoresClaimableRaw,
    nativeStakeOverride,
    flow,
  ];
}

@injectable
class StakingBloc extends Bloc<StakingEvent, StakingState> {
  StakingBloc(
    this._repository,
    this._txBuilder,
    this._flow,
    this._priceService,
    this._walletManager,
    this._journal,
    this._landedSlots,
  ) : super(const StakingState()) {
    on<StakingLoadData>(_onLoadData);
    on<StakingBalancesUpdated>(_onBalancesUpdated);
    on<StakingSetTab>(_onSetTab);
    on<StakingSetStakeType>(_onSetStakeType);
    on<StakingSetAmount>(_onSetAmount);
    on<StakingSetHalf>(_onSetHalf);
    on<StakingSetMax>(_onSetMax);
    on<StakingRefreshLiquidQuote>(_onRefreshLiquidQuote);
    on<StakingSubmit>(_onSubmit);
    on<StakingClaim>(_onClaim);
    on<StakingClaimRewards>(_onClaimRewards);
    on<StakingReset>(_onReset);
    on<StakingIndexedAck>(_onIndexedAck);
    on<StakingMutationsChanged>(_onMutationsChanged);
    _journalSub = _journal.changes.listen((_) {
      if (!isClosed) add(const StakingEvent.mutationsChanged());
    });
  }

  final StakingRepository _repository;
  final StakingTxBuilder _txBuilder;
  final MarketplaceActionFlow _flow;
  final TokenPriceService _priceService;
  final WalletManager _walletManager;
  final StakeMutationJournal _journal;
  final TxLandedSlots _landedSlots;

  late final StreamSubscription<void> _journalSub;

  bool get _formEditable => state.flow is TxFlowIdle;

  @override
  Future<void> close() {
    _journalSub.cancel();
    return super.close();
  }

  Future<void> _onLoadData(
    StakingLoadData event,
    Emitter<StakingState> emit,
  ) async {
    emit(state.copyWith(isLoading: true, loadError: null));
    // Always re-read the active signer's address so a reload after a source
    // wallet switch (the "Your wallet · Switch" line) picks up the new wallet.
    final address = await Result.guard(_walletManager.getAddress);
    if (address case ResultSuccess(:final value)) {
      emit(state.copyWith(myAddress: value));
    }
    // Fetch the staking payload, the epoch snapshot and the claimable-rewards
    // balance concurrently. The two on-chain reads are best-effort — their
    // failure must not block the staking data, so on failure we keep whatever
    // we already had.
    final (dataResult, epochResult, smoresResult) = await (
      Result.guard(_repository.getStakingData),
      Result.guard(_txBuilder.getEpochProgress),
      Result.guard(
        () => _txBuilder.fetchClaimableCompressedBalance(
          mint: StakingConstants.smoresMint,
        ),
      ),
    ).wait;
    final epoch = switch (epochResult) {
      ResultSuccess(:final value) => value,
      _ => state.epochProgress,
    };
    final smores = switch (smoresResult) {
      ResultSuccess(:final value) => value,
      _ => state.smoresClaimableRaw,
    };
    switch (dataResult) {
      case ResultSuccess(:final value):
        final override = await _reconciledOverride(value.userData.nativeStake);
        emit(
          state.copyWith(
            data: value,
            isLoading: false,
            epochProgress: epoch,
            smoresClaimableRaw: smores,
            nativeStakeOverride: override,
          ),
        );
      case ResultFailure(:final error):
        emit(state.copyWith(isLoading: false, loadError: error));
    }
  }

  /// The overlay [server]'s figures must be rendered under, or null when they
  /// can be trusted as they are.
  ///
  /// While a mutation of ours is unconfirmed, [server] may still be the
  /// pre-transaction snapshot — the payload is computed from a live
  /// `getProgramAccounts` on the backend's node, which lags independently of
  /// the transaction index `onIndexedAck` waits on. So before trusting it:
  ///
  /// - re-read the user's own stake accounts with `minContextSlot` set to the
  ///   slot our transaction landed in. That read cannot be answered from a
  ///   view older than the transaction — if the node is behind it throws, and
  ///   a throw is "not caught up", never "no stake";
  /// - hand the result to the journal as ground truth, then let the journal
  ///   decide whether [server] has caught up enough to drop the overlay.
  ///
  /// The re-read costs a `getProgramAccounts` and only runs while something is
  /// actually pending, so the ordinary refresh — including every non-staker's
  /// portfolio load — is untouched.
  Future<NativeStakeBreakdown?> _reconciledOverride(
    NativeStakeBreakdown server,
  ) async {
    final address = state.myAddress;
    if (address == null || !_journal.hasPending(address)) return null;

    final floor = _journal.floorSlot(address);
    final onChain = await Result.guard(
      () => _txBuilder.fetchNativeStakeBreakdown(
        validatorVoteAddress: StakingConstants.validatorVoteAddress,
        minContextSlot: floor > 0 ? floor : null,
      ),
    );
    if (onChain case ResultSuccess(:final value)) {
      _journal.adoptChainTruth(address, value);
    }
    _journal.reconcile(address, server);
    return _overrideFor(server);
  }

  /// Re-derive the overlay after the journal changed under us — including when
  /// the change came from the *other* [StakingBloc].
  void _onMutationsChanged(
    StakingMutationsChanged event,
    Emitter<StakingState> emit,
  ) {
    final server = state.data?.userData.nativeStake;
    if (server == null) return;
    emit(state.copyWith(nativeStakeOverride: _overrideFor(server)));
  }

  /// Null when the journal has nothing to say about [server] — the payload is
  /// then rendered directly, which is the steady state.
  NativeStakeBreakdown? _overrideFor(NativeStakeBreakdown server) {
    final overlaid = _journal.overlay(state.myAddress, server);
    return identical(overlaid, server) ? null : overlaid;
  }

  /// Journal the movement a just-confirmed transaction caused, so every
  /// surface reflects it now rather than whenever the backend's node catches
  /// up. No-op for anything that leaves native stake untouched (both liquid
  /// paths, the SMORES rewards claim) or that did not land.
  void _recordMutation(NativeStakeDelta delta) {
    if (delta.isEmpty) return;
    final flow = state.flow;
    if (flow is! TxFlowSuccess<StakePrep, StakeSuccessData>) return;
    final address = state.myAddress;
    // The *server's* figures, not the overlaid ones: the journal's baseline is
    // what `/v1/staking` was last saying, which is what it has to be seen to
    // move away from before the overlay can be dropped. A mutation landing on
    // top of another composes onto its expectation inside the journal.
    final baseline = state.data?.userData.nativeStake;
    if (address == null || baseline == null) return;
    _journal.record(
      address: address,
      signature: flow.signature,
      // 0 when the confirmation never reported a slot — the re-read then runs
      // unguarded, which is no worse than the server payload it replaces.
      landedSlot: _landedSlots.slotFor(flow.signature) ?? 0,
      baseline: baseline,
      delta: delta,
    );
  }

  void _onBalancesUpdated(
    StakingBalancesUpdated event,
    Emitter<StakingState> emit,
  ) {
    emit(
      state.copyWith(
        solLamports: event.solLamports,
        mallowSolLamports: event.mallowSolLamports,
      ),
    );
  }

  void _onSetTab(StakingSetTab event, Emitter<StakingState> emit) {
    if (!_formEditable) return;
    emit(state.copyWith(tab: event.tab, amount: '', liquidQuote: null));
  }

  /// Switching Native ↔ Liquid **keeps the typed amount** — the toggle picks how
  /// the same amount is staked, so clearing the field made the user retype it to
  /// compare the two paths. Only the quote is dropped: it priced the other
  /// path's mints and must never be shown (or signed) as this one's.
  ///
  /// The carried value is re-clamped against the new path's maximum, which is
  /// the same rewrite typing it fresh would produce — on the unstake tab native
  /// spends staked SOL while liquid spends mallowSOL, so the ceiling moves with
  /// the toggle.
  void _onSetStakeType(StakingSetStakeType event, Emitter<StakingState> emit) {
    if (!_formEditable) return;
    // Re-tapping the selected row is not an edit — don't throw away a good quote
    // and re-fetch it.
    if (event.type == state.stakeType) return;
    final next = state.copyWith(stakeType: event.type, liquidQuote: null);
    emit(next.copyWith(amount: _clamped(next.amount, next.maxLamports)));
  }

  void _onSetAmount(StakingSetAmount event, Emitter<StakingState> emit) {
    if (!_formEditable) return;
    emit(
      state.copyWith(
        amount: _clamped(event.amount, state.maxLamports),
        liquidQuote: null,
      ),
    );
  }

  /// Hard-clamp typed input to the same reserve-adjusted maximum the Max button
  /// uses, mirroring the webapp's `onChange` clamp
  /// (`StakingSection`, `Math.min(numValue, uiMaxAmount)`).
  ///
  /// Without it "stake everything" types the full SOL balance and a native
  /// stake then sends `typed + rent` — a tx that cannot land. Trailing decimal
  /// points are left alone so "1." stays typeable (webapp does the same).
  String _clamped(String input, int max) {
    // A zero maximum is indistinguishable from "balances haven't landed yet":
    // `solLamports` starts at 0 and is only filled by [StakingBalancesUpdated],
    // which the sheet pushes from a fire-and-forget fetch that returns silently
    // on a cold cache or a thrown read. Clamping against it rewrites every
    // keystroke to "0" — the UI mirrors `state.amount` back into the
    // controller, so the field visibly refuses all input with no error shown.
    // Typing stays free until a real maximum is known; [StakingState.canSubmit]
    // is the backstop that still blocks submitting more than the balance.
    if (max <= 0) return input;
    final typed = TokenAmount.parseTokenAmount(input, _mallowSolDecimals);
    if (typed <= BigInt.from(max)) return input;
    return TokenAmount.lamportsToSol(BigInt.from(max));
  }

  void _onSetHalf(StakingSetHalf event, Emitter<StakingState> emit) {
    if (!_formEditable) return;
    final half = state.availableLamports ~/ 2;
    emit(
      state.copyWith(
        amount: TokenAmount.lamportsToSol(BigInt.from(half)),
        liquidQuote: null,
      ),
    );
  }

  void _onSetMax(StakingSetMax event, Emitter<StakingState> emit) {
    if (!_formEditable) return;
    emit(
      state.copyWith(
        amount: TokenAmount.lamportsToSol(BigInt.from(state.maxLamports)),
        liquidQuote: null,
      ),
    );
  }

  Future<void> _onRefreshLiquidQuote(
    StakingRefreshLiquidQuote event,
    Emitter<StakingState> emit,
  ) async {
    if (state.stakeType != StakeType.liquid) return;
    final rawIn = TokenAmount.toInt(
      TokenAmount.parseTokenAmount(state.amount, _mallowSolDecimals),
    );
    if (rawIn <= 0) {
      emit(state.copyWith(liquidQuote: null, isQuoting: false));
      return;
    }

    emit(state.copyWith(isQuoting: true));
    final (input, output) = _liquidMints;
    final result = await Result.guard(
      () => _txBuilder.getQuote(
        inputMint: input,
        outputMint: output,
        amount: rawIn,
      ),
    );
    // Bail if inputs changed while in flight. The stake-type check matters now
    // that the toggle keeps the amount: a quote landing after a switch to native
    // would otherwise sit in state, priced for the path the user left.
    if (state.amount.isEmpty ||
        state.stakeType != StakeType.liquid ||
        !_formEditable) {
      emit(state.copyWith(isQuoting: false));
      return;
    }
    switch (result) {
      case ResultSuccess(:final value):
        emit(state.copyWith(liquidQuote: value, isQuoting: false));
      case ResultFailure():
        emit(state.copyWith(liquidQuote: null, isQuoting: false));
    }
  }

  /// (input, output) mints for the current liquid action.
  (String, String) get _liquidMints => state.tab == StakeTab.stake
      ? (StakingConstants.solMint, StakingConstants.mallowSolMint)
      : (StakingConstants.mallowSolMint, StakingConstants.solMint);

  /// Kill-switch cell for the current submit — see [stakingSubmitFlow], which
  /// the form's entry gate shares so the CTA and the backstop can never
  /// disagree about which of the four staking cells a submit belongs to.
  AppFlow get _submitFlow =>
      stakingSubmitFlow(stakeType: state.stakeType, tab: state.tab);

  Future<void> _onSubmit(
    StakingSubmit event,
    Emitter<StakingState> emit,
  ) async {
    if (!state.canSubmit) return;
    // Native stake floors at 1.0023 SOL (rent buffer); every other flow sends
    // exactly what was typed. See [StakingState.submitLamports].
    final rawLamports = state.submitLamports;

    emit(state.copyWith(flow: const TxFlowPreparing()));

    // Build the tx(s). Native flows are built client-side; liquid flows go
    // through Jupiter (SOL<->mallowSOL swap), reusing the swap infra.
    final prep = await Result.guard(
      () => _buildSubmission(rawLamports: rawLamports),
    );
    final _Submission submission;
    switch (prep) {
      case ResultSuccess(:final value):
        submission = value;
      case ResultFailure(:final error):
        emit(
          state.copyWith(flow: TxFlowFailure(error.prefixedWith(_actionVerb))),
        );
        return;
    }

    // Outflow USD gates the auth prompt on stake; unstake returns funds (0).
    final usdValue = state.tab == StakeTab.stake
        ? _priceService.usdValueOfRaw(rawLamports, StakingConstants.solMint)
        : 0.0;

    final amountSol = double.tryParse(state.amount) ?? 0;
    final isLocal = await _walletManager.isLocalSigner();
    await _flow.execute(
      sink: txFlowSink<StakePrep, StakeSuccessData>(
        (flow) => emit(state.copyWith(flow: flow)),
      ),
      txsBase64: submission.txs,
      usdValue: usdValue,
      flow: FlowKey.solana(_submitFlow),
      additionalSigners: submission.signers,
      toSuccess: (_) => StakeSuccessData(
        message: submission.successMessage,
        amount: amountSol,
        symbol: submission.symbol,
      ),
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(StakingEvent.indexedAck(signature: sig, ok: ok)),
      stageFor: (_, _, _) => isLocal ? kLocalSigningLabel : null,
      useLedger: false,
      failurePrefix: _actionVerb,
      // Staking is mainnet-only; broadcast on the same mainnet RPC the tx was
      // built and simulated against.
      rpcOverride: _txBuilder.rpcService,
    );

    _recordMutation(submission.delta);
    if (!isClosed) add(const StakingEvent.loadData());
  }

  String get _actionVerb =>
      state.tab == StakeTab.stake ? 'Stake failed' : 'Unstake failed';

  Future<_Submission> _buildSubmission({required int rawLamports}) async {
    final isStake = state.tab == StakeTab.stake;
    if (state.stakeType == StakeType.native) {
      final built = isStake
          ? await _txBuilder.buildNativeStakeTx(
              stakeLamports: rawLamports,
              validatorVoteAddress: StakingConstants.validatorVoteAddress,
              feeAccountAddress: StakingConstants.feeAccountAddress,
            )
          : await _txBuilder.buildNativeUnstakeTx(
              lamports: rawLamports,
              validatorVoteAddress: StakingConstants.validatorVoteAddress,
              feeAccountAddress: StakingConstants.feeAccountAddress,
            );
      return _Submission(
        txs: [built.txBase64],
        signers: built.extraSigners,
        symbol: 'SOL',
        successMessage: isStake
            ? 'Stake is now activating'
            : 'Unstake is now deactivating',
        delta: built.delta,
      );
    }

    // Liquid — SOL<->mallowSOL via classic Jupiter swap-instructions,
    // composed client-side with the FEE_ACCOUNT marker (webapp parity).
    final (input, output) = _liquidMints;
    final quote =
        state.liquidQuote ??
        await _txBuilder.getQuote(
          inputMint: input,
          outputMint: output,
          amount: rawLamports,
        );
    final tx = await _txBuilder.buildLiquidSwapTx(
      quote: quote,
      feeAccountAddress: StakingConstants.feeAccountAddress,
    );
    return _Submission(
      txs: [tx],
      signers: const [],
      symbol: isStake ? 'mallowSOL' : 'SOL',
      successMessage: isStake ? 'Staked successfully' : 'Unstaked successfully',
    );
  }

  Future<void> _onClaim(StakingClaim event, Emitter<StakingState> emit) async {
    if (state.isBusy) return;
    emit(state.copyWith(flow: const TxFlowPreparing()));

    final built = await Result.guard(
      () => _txBuilder.buildWithdrawStakeTx(
        validatorVoteAddress: StakingConstants.validatorVoteAddress,
      ),
    );
    final BuiltStakeTx? tx;
    switch (built) {
      case ResultSuccess(:final value):
        tx = value;
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            flow: TxFlowFailure(error.prefixedWith('Claim failed')),
          ),
        );
        return;
    }
    if (tx == null) {
      emit(
        state.copyWith(
          flow: const TxFlowFailure(AppFailure.unknown('Nothing to claim')),
        ),
      );
      return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    await _flow.execute(
      sink: txFlowSink<StakePrep, StakeSuccessData>(
        (flow) => emit(state.copyWith(flow: flow)),
      ),
      txsBase64: [tx.txBase64],
      usdValue: 0,
      flow: const FlowKey.solana(AppFlow.withdrawStake),
      toSuccess: (_) => const StakeSuccessData(
        message: 'Claimed successfully',
        amount: 0,
        symbol: 'SOL',
      ),
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(StakingEvent.indexedAck(signature: sig, ok: ok)),
      stageFor: (_, _, _) => isLocal ? kLocalSigningLabel : null,
      useLedger: false,
      failurePrefix: 'Claim failed',
      rpcOverride: _txBuilder.rpcService,
    );

    _recordMutation(tx.delta);
    if (!isClosed) add(const StakingEvent.loadData());
  }

  /// Claim the season's SMORES rewards — a decompress of the wallet's
  /// ZK-compressed balance into its SMORES associated token account.
  ///
  /// The only staking transaction built server-side: composing a decompress
  /// needs a validity proof and token-pool accounts from a Photon indexer, so
  /// `/v1/staking/getClaimTx` returns the v0 tx and the app only signs it.
  /// [StakingState.smoresClaimableRaw] is exactly the amount sent — a stale
  /// (larger) figure would make the backend select inputs it cannot cover.
  Future<void> _onClaimRewards(
    StakingClaimRewards event,
    Emitter<StakingState> emit,
  ) async {
    if (state.isBusy) return;
    final amount = state.smoresClaimableRaw;
    if (amount <= 0) {
      emit(
        state.copyWith(
          flow: const TxFlowFailure(AppFailure.unknown('Nothing to claim')),
        ),
      );
      return;
    }

    emit(state.copyWith(flow: const TxFlowPreparing()));
    final built = await Result.guard(
      () => _repository.getClaimTx(amount: amount),
    );
    final String txBase64;
    switch (built) {
      case ResultSuccess(:final value):
        txBase64 = value;
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            flow: TxFlowFailure(error.prefixedWith('Claim failed')),
          ),
        );
        return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    await _flow.execute(
      sink: txFlowSink<StakePrep, StakeSuccessData>(
        (flow) => emit(state.copyWith(flow: flow)),
      ),
      txsBase64: [txBase64],
      // Nothing leaves the wallet — a decompress moves the user's own tokens
      // into their ATA, so there is no outflow to gate the auth prompt on.
      usdValue: 0,
      // Shares the `withdraw-stake` cell rather than carrying its own: `AppFlow`
      // is pinned set-equal to the backend's `MobileFlow` enum
      // (`remote_config_test.dart`), so a client-only cell would be a kill
      // switch that silently does nothing — which is what that pin exists to
      // prevent. Both are 🔓 escape hatches moving the
      // user's own assets out, so the coupling is safe until the contract gains
      // a `stake-rewards-claim` cell.
      flow: const FlowKey.solana(AppFlow.withdrawStake),
      toSuccess: (_) => StakeSuccessData(
        message: 'Claimed successfully',
        amount: amount / StakingConstants.smoresUnitsPerToken,
        symbol: 'SMORES',
      ),
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(StakingEvent.indexedAck(signature: sig, ok: ok)),
      stageFor: (_, _, _) => isLocal ? kLocalSigningLabel : null,
      useLedger: false,
      failurePrefix: 'Claim failed',
      rpcOverride: _txBuilder.rpcService,
    );

    if (!isClosed) add(const StakingEvent.loadData());
  }

  /// The ack is the sheet's second refresh trigger, and the earliest one with
  /// any chance of returning post-transaction figures.
  ///
  /// [MarketplaceActionFlow.execute] returns the moment the tx confirms on
  /// chain — the indexer poll it starts is deliberately not awaited — so the
  /// reload at the end of [_onSubmit] / [_onClaim] reads the *pre-transaction*
  /// snapshot. Re-read here, where the server has at least told us it can see
  /// the tx.
  ///
  /// 🛑 It is not a *guarantee* of fresh figures, which is why the journal
  /// exists: this acks mallow's transaction index, while
  /// `userData.nativeStake` is computed from a live `getProgramAccounts` on a
  /// different node that lags on its own schedule. Do not treat an ack as
  /// permission to drop the overlay — [StakeMutationJournal.reconcile] decides
  /// that, from the figures themselves.
  ///
  /// Ahead of the [TxFlowSuccess] guard on purpose: the pipeline sheet resets
  /// the flow to idle ~1.4s after success while the ack polls on a 1s cycle,
  /// so gating the refresh on the success body still being up would drop it in
  /// the common case. Fired on `ok: false` too — [checkTransaction] gives up
  /// after 10 attempts but the indexer may have caught up since, and a stale
  /// sheet is the worse failure.
  void _onIndexedAck(StakingIndexedAck event, Emitter<StakingState> emit) {
    add(const StakingEvent.loadData());

    final flow = state.flow;
    if (flow is! TxFlowSuccess<StakePrep, StakeSuccessData>) return;
    if (flow.signature != event.signature) return;
    emit(
      state.copyWith(
        flow: TxFlowSuccess(
          signature: flow.signature,
          result: flow.result.copyWith(indexed: event.ok),
        ),
      ),
    );
  }

  void _onReset(StakingReset event, Emitter<StakingState> emit) {
    // Keep loaded data + balances; just clear the form/flow.
    emit(
      state.copyWith(amount: '', liquidQuote: null, flow: const TxFlowIdle()),
    );
  }
}

/// Internal bundle returned by [StakingBloc._buildSubmission].
class _Submission {
  const _Submission({
    required this.txs,
    required this.signers,
    required this.symbol,
    required this.successMessage,
    this.delta = NativeStakeDelta.none,
  });

  final List<String> txs;
  final List<Ed25519HDKeyPair> signers;
  final String symbol;
  final String successMessage;

  /// Native-stake movement to journal once this lands. Empty on the liquid
  /// paths — a mallowSOL swap touches no stake account.
  final NativeStakeDelta delta;
}
