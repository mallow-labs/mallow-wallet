import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:solana/encoder.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/transaction_ledger.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/models/account.dart' show WalletType;
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/services/transaction_pipeline.dart';
import '../../../core/utils/token_amount.dart';
import '../../../shared/utils/chain.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/balance_optimistic_updater.dart';
import '../data/swap_repository.dart';

export '../../../core/services/transaction_flow_state.dart';

part 'swap_bloc.freezed.dart';

// Sentinel for SwapState.copyWith — lets callers explicitly pass null on
// nullable fields without conflating "leave unchanged" with "set to null".
const Object _sentinel = Object();

@freezed
sealed class SwapEvent with _$SwapEvent {
  /// Pushed by the sheet whenever [TokenBalanceBloc] emits — seeds the
  /// default sell/buy tokens on first load and keeps the selected tokens'
  /// balances fresh after a swap.
  const factory SwapEvent.balancesUpdated(List<TokenBalance> tokens) =
      SwapBalancesUpdated;
  const factory SwapEvent.setSellToken(TokenBalance token) = SwapSetSellToken;
  const factory SwapEvent.setBuyToken(TokenBalance token) = SwapSetBuyToken;
  const factory SwapEvent.setAmount(String amount) = SwapSetAmount;

  /// Re-read slippage / priority-fee settings from [PreferencesService]
  /// (dispatched after the settings sheet closes) and re-quote.
  const factory SwapEvent.settingsChanged() = SwapSettingsChanged;
  const factory SwapEvent.getQuote() = SwapGetQuote;
  const factory SwapEvent.execute() = SwapExecute;
  const factory SwapEvent.reset() = SwapReset;

  /// The funding wallet moved — dispatched by the sheet once the source-wallet
  /// picker has committed the signer switch. Voids everything derived for the
  /// previous wallet and re-quotes for the new one.
  const factory SwapEvent.sourceWalletChanged() = SwapSourceWalletChanged;

  /// Internal — emitted by the background indexer poll once it acks the
  /// swap tx. Drives [SwapSuccessData.indexed].
  const factory SwapEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = SwapIndexedAck;
}

/// Payload carried by [TxFlowReady] — the quote for one of the two routes and
/// the derived display data the sheet needs.
///
/// Exactly one of [order] and [classicQuote] is set. Most signers get an Ultra
/// [order]; a Keystone gets a [classicQuote], because an Ultra order expires
/// long before a QR round trip comes back (see
/// [SwapRepository.getClassicQuote]).
class SwapQuoteData extends Equatable {
  const SwapQuoteData({
    required this.outputAmount,
    required this.rate,
    required this.taker,
    this.order,
    this.classicQuote,
    double? inUsdValue,
    double? outUsdValue,
  }) : assert((order == null) != (classicQuote == null), 'exactly one route'),
       _inUsdValue = inUsdValue,
       _outUsdValue = outUsdValue;

  /// The Ultra order — Jupiter compiled the transaction and lands it.
  final UltraOrderResponseDto? order;

  /// The classic quote — the app builds, signs and broadcasts the swap
  /// itself through [TransactionExecutor].
  final ClassicSwapQuote? classicQuote;

  final double? _inUsdValue;
  final double? _outUsdValue;

  /// Buy-side amount in display units.
  final double outputAmount;

  /// Buy tokens per 1 sell token.
  final double rate;

  /// The wallet this order was built for. Jupiter compiles the transaction
  /// around the taker's accounts, so an order quoted for one wallet must never
  /// be signed by another (wallet-switching-rollout).
  final String taker;

  /// USD value of the sell side, when known.
  double? get inUsdValue => _inUsdValue ?? order?.inUsdValue?.toDouble();

  /// USD value of the buy side, when known.
  double? get outUsdValue => _outUsdValue ?? order?.outUsdValue?.toDouble();

  /// True when the quote can be executed: an Ultra order that came back with
  /// a signable transaction, or any classic quote (its transaction is built
  /// at execute time).
  bool get canExecute =>
      classicQuote != null || (order?.transaction ?? '').isNotEmpty;

  @override
  List<Object?> get props => [
    order,
    classicQuote,
    outputAmount,
    rate,
    taker,
    _inUsdValue,
    _outUsdValue,
  ];
}

/// Payload carried by [TxFlowSuccess] — what the success snackbar needs.
class SwapSuccessData extends Equatable {
  const SwapSuccessData({
    required this.inputAmount,
    required this.outputAmount,
    required this.inputSymbol,
    required this.outputSymbol,
    this.indexed,
  });

  final double inputAmount;
  final double outputAmount;
  final String inputSymbol;
  final String outputSymbol;

  /// Indexer-ack for the swap tx — `null` while polling, `true` on
  /// ack, `false` after retries exhaust.
  final bool? indexed;

  SwapSuccessData copyWith({Object? indexed = _sentinel}) => SwapSuccessData(
    inputAmount: inputAmount,
    outputAmount: outputAmount,
    inputSymbol: inputSymbol,
    outputSymbol: outputSymbol,
    indexed: identical(indexed, _sentinel) ? this.indexed : indexed as bool?,
  );

  @override
  List<Object?> get props => [
    inputAmount,
    outputAmount,
    inputSymbol,
    outputSymbol,
    indexed,
  ];
}

/// Generic alias for the unified flow state with swap-specific payloads.
typedef SwapFlowState = TransactionFlowState<SwapQuoteData, SwapSuccessData>;

/// Form + flow state. Form fields (sell/buy token, amount, settings) are
/// carried alongside the flow so they survive every flow phase.
class SwapState extends Equatable {
  const SwapState({
    this.sellToken,
    this.buyToken,
    this.amount = '',
    this.slippageBps,
    this.priorityFeeLamports,
    this.flow = const TxFlowIdle<SwapQuoteData, SwapSuccessData>(),
  });

  final TokenBalance? sellToken;
  final TokenBalance? buyToken;
  final String amount;

  /// Slippage tolerance in bps; `null` = Auto (Jupiter picks).
  final int? slippageBps;

  /// Priority fee in lamports; `null` = Auto (Jupiter picks).
  final int? priorityFeeLamports;
  final SwapFlowState flow;

  /// Convenience: the quote payload when the flow is in the ready state.
  SwapQuoteData? get quoteData =>
      flow is TxFlowReady<SwapQuoteData, SwapSuccessData>
      ? (flow as TxFlowReady<SwapQuoteData, SwapSuccessData>).data
      : null;

  /// True when the form holds everything needed to request a quote.
  bool get canQuote =>
      sellToken != null &&
      buyToken != null &&
      (double.tryParse(amount) ?? 0) > 0;

  SwapState copyWith({
    Object? sellToken = _sentinel,
    Object? buyToken = _sentinel,
    String? amount,
    Object? slippageBps = _sentinel,
    Object? priorityFeeLamports = _sentinel,
    SwapFlowState? flow,
  }) => SwapState(
    sellToken: identical(sellToken, _sentinel)
        ? this.sellToken
        : sellToken as TokenBalance?,
    buyToken: identical(buyToken, _sentinel)
        ? this.buyToken
        : buyToken as TokenBalance?,
    amount: amount ?? this.amount,
    slippageBps: identical(slippageBps, _sentinel)
        ? this.slippageBps
        : slippageBps as int?,
    priorityFeeLamports: identical(priorityFeeLamports, _sentinel)
        ? this.priorityFeeLamports
        : priorityFeeLamports as int?,
    flow: flow ?? this.flow,
  );

  @override
  List<Object?> get props => [
    sellToken,
    buyToken,
    amount,
    slippageBps,
    priorityFeeLamports,
    flow,
  ];
}

@injectable
class SwapBloc extends Bloc<SwapEvent, SwapState> {
  SwapBloc(
    this._repository,
    this._walletManager,
    this._authGate,
    this._pipeline,
    this._priceService,
    this._preferences,
    this._priorityFee,
    this._executor,
  ) : super(
        SwapState(
          slippageBps: _preferences.swapSlippageBps,
          priorityFeeLamports: _priorityFee.routerLamports,
        ),
      ) {
    on<SwapBalancesUpdated>(_onBalancesUpdated);
    on<SwapSetSellToken>(_onSetSellToken);
    on<SwapSetBuyToken>(_onSetBuyToken);
    on<SwapSetAmount>(_onSetAmount);
    on<SwapSettingsChanged>(_onSettingsChanged);
    on<SwapGetQuote>(_onGetQuote);
    on<SwapExecute>(_onExecute);
    on<SwapReset>(_onReset);
    on<SwapSourceWalletChanged>(_onSourceWalletChanged);
    on<SwapIndexedAck>(_onIndexedAck);
  }

  final SwapRepository _repository;
  final WalletManager _walletManager;
  final TransactionAuthGate _authGate;
  final TransactionPipeline _pipeline;
  final TokenPriceService _priceService;
  final PreferencesService _preferences;
  final PriorityFeeService _priorityFee;
  final TransactionExecutor _executor;

  /// Incremented on every funding-wallet switch. An order request captures the
  /// epoch it started under, so a `getOrder` that was already in flight for the
  /// previous taker is discarded instead of landing as the current quote — the
  /// mint/amount staleness checks below can't see a wallet change on their own.
  int _sourceEpoch = 0;

  /// Form-edit events are no-ops once the user has committed to the swap so
  /// a stray field change can't desync the in-flight tx from the displayed
  /// inputs. Idle/ready/failure are all editable — editing past a quote or
  /// an error just invalidates it.
  bool _isFormEditable() => switch (state.flow) {
    TxFlowIdle() || TxFlowReady() || TxFlowFailure() => true,
    _ => false,
  };

  /// [selected] as [held] reports it, at zero when [held] carries no matching
  /// row — the one rule for "the balance behind a selected token is the
  /// *signing* wallet's".
  ///
  /// Shared with the swap sheet's pickers, whose rows are summed across the
  /// whole session: a pick is narrowed through this on the way in so Half/Max
  /// and the Balance line can never offer a sibling wallet's funds, and the
  /// next balance push re-applies it here rather than re-deriving it.
  static TokenBalance narrowToHeld(
    TokenBalance selected,
    List<TokenBalance> held,
  ) => held.firstWhere(
    (t) => t.mint == selected.mint && t.isNative == selected.isNative,
    orElse: () => selected.copyWith(rawBalance: 0, uiBalance: 0),
  );

  void _onBalancesUpdated(SwapBalancesUpdated event, Emitter<SwapState> emit) {
    TokenBalance? refresh(TokenBalance? selected) =>
        selected == null ? null : narrowToHeld(selected, event.tokens);

    var sell = refresh(state.sellToken);
    var buy = refresh(state.buyToken);

    // First load — seed defaults: sell native SOL, buy mallowSOL (matching
    // the design), falling back so the two sides never collide.
    sell ??=
        event.tokens.where((t) => t.isNative).firstOrNull ??
        _zeroBalance(mallow_tokens.solMint);
    buy ??= sell.mint == mallow_tokens.mallowSolMint
        ? _zeroBalance(mallow_tokens.usdcMint)
        : refresh(_zeroBalance(mallow_tokens.mallowSolMint));

    if (sell == state.sellToken && buy == state.buyToken) return;
    emit(state.copyWith(sellToken: sell, buyToken: buy));
  }

  /// A zero-balance [TokenBalance] for a registry mint — used for buy-side
  /// tokens the user doesn't hold yet.
  static TokenBalance _zeroBalance(String mint) {
    final token = mallow_tokens.tokenByMint(mint)!;
    return TokenBalance(
      mint: token.mint,
      symbol: token.symbol,
      name: token.symbol,
      decimals: token.decimals,
      rawBalance: 0,
      uiBalance: 0,
      isNative: token.mint == mallow_tokens.solMint,
      isVerified: true,
    );
  }

  void _onSetSellToken(SwapSetSellToken event, Emitter<SwapState> emit) {
    if (!_isFormEditable()) return;
    // Selling what we were buying — swap the sides instead of colliding.
    final buy = event.token.mint == state.buyToken?.mint
        ? state.sellToken
        : state.buyToken;
    emit(
      state.copyWith(
        sellToken: event.token,
        buyToken: buy,
        flow: const TxFlowIdle<SwapQuoteData, SwapSuccessData>(),
      ),
    );
  }

  void _onSetBuyToken(SwapSetBuyToken event, Emitter<SwapState> emit) {
    if (!_isFormEditable()) return;
    final sell = event.token.mint == state.sellToken?.mint
        ? state.buyToken
        : state.sellToken;
    emit(
      state.copyWith(
        buyToken: event.token,
        sellToken: sell,
        flow: const TxFlowIdle<SwapQuoteData, SwapSuccessData>(),
      ),
    );
  }

  void _onSetAmount(SwapSetAmount event, Emitter<SwapState> emit) {
    if (!_isFormEditable()) return;
    if (event.amount == state.amount) return;
    // A changed amount invalidates any current quote.
    emit(
      state.copyWith(
        amount: event.amount,
        flow: const TxFlowIdle<SwapQuoteData, SwapSuccessData>(),
      ),
    );
  }

  void _onSettingsChanged(SwapSettingsChanged event, Emitter<SwapState> emit) {
    final slippage = _preferences.swapSlippageBps;
    final priorityFee = _priorityFee.routerLamports;
    if (slippage == state.slippageBps &&
        priorityFee == state.priorityFeeLamports) {
      return;
    }
    emit(
      state.copyWith(slippageBps: slippage, priorityFeeLamports: priorityFee),
    );
    if (_isFormEditable()) add(const SwapEvent.getQuote());
  }

  Future<void> _onGetQuote(SwapGetQuote event, Emitter<SwapState> emit) async {
    final current = state;
    if (!_isFormEditable()) return;
    if (!current.canQuote) {
      if (current.flow is! TxFlowIdle) {
        emit(
          current.copyWith(
            flow: const TxFlowIdle<SwapQuoteData, SwapSuccessData>(),
          ),
        );
      }
      return;
    }

    final sellToken = current.sellToken!;
    final buyToken = current.buyToken!;

    // Stale-while-revalidate: keep showing the previous quote during a
    // refresh; only show the preparing spinner when there's nothing yet.
    if (current.flow is! TxFlowReady<SwapQuoteData, SwapSuccessData>) {
      emit(current.copyWith(flow: const TxFlowPreparing()));
    }

    final rawAmount = TokenAmount.toInt(
      TokenAmount.parseTokenAmount(current.amount, sellToken.decimals),
    );

    final epoch = _sourceEpoch;
    final result = await Result.guard(() async {
      final taker = await _walletManager.getAddress();
      if (await _walletManager.walletTypeOf(taker) == WalletType.keystone) {
        final classic = await _repository.getClassicQuote(
          inputMint: sellToken.mint,
          outputMint: buyToken.mint,
          amount: rawAmount,
          slippageBps: current.slippageBps,
        );
        return (taker: taker, order: null, classic: classic);
      }
      final order = await _repository.getOrder(
        inputMint: sellToken.mint,
        outputMint: buyToken.mint,
        amount: rawAmount,
        taker: taker,
        slippageBps: current.slippageBps,
        priorityFeeLamports: current.priorityFeeLamports,
      );
      return (taker: taker, order: order, classic: null);
    });

    // The form may have changed (or the user committed to the swap, or the
    // funding wallet moved) while the order was in flight — a result for stale
    // inputs must not be surfaced.
    final committed = switch (state.flow) {
      TxFlowSigning() || TxFlowBroadcasting() || TxFlowSuccess() => true,
      _ => false,
    };
    if (committed ||
        epoch != _sourceEpoch ||
        state.amount != current.amount ||
        state.sellToken?.mint != sellToken.mint ||
        state.buyToken?.mint != buyToken.mint) {
      return;
    }

    switch (result) {
      case ResultSuccess(:final value):
        final inputAmount = double.tryParse(current.amount) ?? 0;
        final classic = value.classic;
        final rawOut = BigInt.parse(
          classic?.quote.outAmount ?? value.order!.outAmount,
        );
        final outputAmount = double.parse(
          TokenAmount.formatTokenAmount(rawOut, buyToken.decimals),
        );
        emit(
          state.copyWith(
            flow: TxFlowReady(
              SwapQuoteData(
                order: value.order,
                classicQuote: classic,
                outputAmount: outputAmount,
                rate: inputAmount > 0 ? outputAmount / inputAmount : 0,
                taker: value.taker,
                // The classic quote prices only the sell side (its
                // `swapUsdValue`); the buy side comes from the price cache.
                inUsdValue: classic == null
                    ? null
                    : double.tryParse('${classic.quote.raw['swapUsdValue']}'),
                outUsdValue: classic == null
                    ? null
                    : _priceService.usdValueOfRaw(
                        rawOut.toInt(),
                        buyToken.mint,
                      ),
              ),
            ),
          ),
        );
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            flow: TxFlowFailure(error.prefixedWith('Failed to get quote')),
          ),
        );
    }
  }

  Future<void> _onExecute(SwapExecute event, Emitter<SwapState> emit) async {
    final current = state;
    final ready = current.flow;
    if (ready is! TxFlowReady<SwapQuoteData, SwapSuccessData>) return;

    final quoteData = ready.data;
    final sellToken = current.sellToken;
    final buyToken = current.buyToken;
    if (sellToken == null || buyToken == null) return;

    // USD outflow for the step-up auth gate. The quote carries it; fall back
    // to the price cache, and let null mean "unknown → require auth"
    // (fail-closed).
    final usdOutflow =
        quoteData.inUsdValue ??
        _priceService.usdValueOfRaw(
          TokenAmount.toInt(
            TokenAmount.parseTokenAmount(current.amount, sellToken.decimals),
          ),
          sellToken.mint,
        );

    final classicQuote = quoteData.classicQuote;
    final order = quoteData.order;
    final Result<String, AppFailure> result;
    if (classicQuote != null) {
      emit(current.copyWith(flow: const TxFlowSigning()));
      result = await _executeClassic(
        quote: classicQuote,
        taker: quoteData.taker,
        usdOutflow: usdOutflow,
        current: current,
        emit: emit,
      );
    } else {
      final unsignedBase64 = order?.transaction;
      if (order == null || unsignedBase64 == null || unsignedBase64.isEmpty) {
        emit(
          current.copyWith(
            flow: TxFlowFailure(
              AppFailure.validation(
                order?.errorMessage ??
                    order?.error ??
                    'Unable to build swap transaction',
              ),
            ),
          ),
        );
        return;
      }
      emit(current.copyWith(flow: const TxFlowSigning()));
      result = await _executeUltra(
        order: order,
        unsignedBase64: unsignedBase64,
        taker: quoteData.taker,
        usdOutflow: usdOutflow,
        emit: emit,
      );
    }

    if (isClosed) return;

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          state.copyWith(
            flow: TxFlowSuccess(
              signature: value,
              result: SwapSuccessData(
                inputAmount: double.tryParse(current.amount) ?? 0,
                outputAmount: quoteData.outputAmount,
                inputSymbol: sellToken.symbol,
                outputSymbol: buyToken.symbol,
              ),
            ),
          ),
        );
        if (value.isNotEmpty) {
          unawaited(_reconcileBalances(value));
          _pipeline.runIndexerCheck(
            signature: value,
            onAck: (sig, ok) =>
                add(SwapEvent.indexedAck(signature: sig, ok: ok)),
            isClosed: () => isClosed,
          );
        }
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            flow: TxFlowFailure(error.prefixedWith('Swap failed')),
          ),
        );
    }
  }

  /// Ultra route: sign Jupiter's compiled order verbatim and hand it back to
  /// `/execute`, which lands it.
  Future<Result<String, AppFailure>> _executeUltra({
    required UltraOrderResponseDto order,
    required String unsignedBase64,
    required String taker,
    required double? usdOutflow,
    required Emitter<SwapState> emit,
  }) async {
    // Sign locally, then hand the signed tx back to Jupiter's /execute,
    // which broadcasts and confirms it. The compiled v0 transaction is
    // preserved verbatim (blockhash, ALTs, any RFQ maker signature) — the
    // auto-refresh keeps the order at most a few seconds old, and Ultra
    // owns transaction landing, so no client-side blockhash rewrite or
    // RPC broadcast happens here.
    return Result.guard(() async {
      // Last line of defence against a stale quote: the order was compiled for
      // `taker`, but the signature comes from whichever wallet is
      // active now. If a switch landed between the quote and this tap, refuse
      // rather than sign someone else's transaction.
      final signer = await _walletManager.getAddress();
      if (signer != taker) {
        throw const AppFailure.validation(
          'Wallet changed — refresh the quote before swapping',
        );
      }
      // An Ultra order would expire during a Keystone's QR exchange, after
      // the user approved it on the device. Quotes for a Keystone take the
      // classic route, so an Ultra order reaching here for one is a routing
      // bug — refuse before the user approves something that cannot land.
      if (await _walletManager.walletTypeOf(signer) == WalletType.keystone) {
        throw const AppFailure.validation(
          'Refresh the quote before swapping from a Keystone',
        );
      }
      final outcome = await _authGate.authorize(
        usdValue: usdOutflow,
        flow: const FlowKey.solana(AppFlow.tokenSwap),
      );
      final disabledMessage = outcome.disabledMessage;
      if (disabledMessage != null) {
        // A killed cell is NOT a user cancel: throwing the cancel type here
        // would land in the sheet's silent-cancel branch and swallow the
        // operator's message.
        throw TransactionFlowDisabledException(disabledMessage);
      }
      if (outcome != TransactionAuthOutcome.allowed) {
        throw TransactionAuthCancelledException(outcome);
      }
      final signed = await _walletManager.signCompiledTx(
        unsignedTx: SignedTx.fromBytes(base64Decode(unsignedBase64)),
      );
      if (!isClosed) emit(state.copyWith(flow: const TxFlowBroadcasting()));
      final response = await _repository.executeOrder(
        signedTransaction: signed.encode(),
        requestId: order.requestId,
      );
      if (!response.isSuccess) {
        throw AppFailure.network(response.error ?? 'Swap was not confirmed');
      }
      final signature = response.signature ?? '';
      // Jupiter lands this one, so the executor never sees it.
      recordSubmittedTransaction(
        chain: Chain.solana,
        flow: AppFlow.tokenSwap,
        signature: signature,
        walletAddress: () => signer,
        confirmation: TxConfirmation.confirmed,
      );
      return signature;
    });
  }

  /// Classic route: have Jupiter compile the swap for [taker], then sign,
  /// broadcast and confirm it through [TransactionExecutor] — the shared path
  /// that refreshes the blockhash before signing and, when a Keystone's
  /// signature comes back after it expired, re-asks for one on a fresh
  /// blockhash rather than failing.
  Future<Result<String, AppFailure>> _executeClassic({
    required ClassicSwapQuote quote,
    required String taker,
    required double? usdOutflow,
    required SwapState current,
    required Emitter<SwapState> emit,
  }) async {
    final built = await Result.guard(() async {
      // Same stale-quote defence as the Ultra route: the transaction is
      // compiled around the taker's accounts.
      final signer = await _walletManager.getAddress();
      if (signer != taker) {
        throw const AppFailure.validation(
          'Wallet changed — refresh the quote before swapping',
        );
      }
      return _repository.buildClassicSwapTx(
        quote: quote,
        taker: taker,
        slippageBps: current.slippageBps,
        priorityFeeLamports: current.priorityFeeLamports,
      );
    });
    final String tx;
    switch (built) {
      case ResultSuccess(:final value):
        tx = value;
      case ResultFailure():
        return built;
    }
    return _executor.execute(
      txsBase64: [tx],
      usdValue: usdOutflow,
      flow: const FlowKey.solana(AppFlow.tokenSwap),
      rpcOverride: _repository.rpcService,
      // Only a Keystone takes this route; there is no Ledger state to follow.
      useLedger: false,
      onStage: (event) {
        if (event.stage == ExecutorStage.broadcasting && !isClosed) {
          emit(state.copyWith(flow: const TxFlowBroadcasting()));
        }
      },
    );
  }

  /// Correct the local balances straight from the confirmed swap's own
  /// metadata. The sheet stays open after a swap, so both sides' balances are
  /// on screen: waiting on the indexer-backed refetch would show pre-swap
  /// numbers to a user lining up their next swap, and the tx's post-balances
  /// are exact (network fee, ATA rent and actual fill included).
  Future<void> _reconcileBalances(String signature) async {
    try {
      final address = await _walletManager.getAddress();
      await BalanceOptimisticUpdater.recordConfirmedTx(
        signature: signature,
        address: address,
      );
    } catch (e) {
      debugPrint('[SwapBloc] balance reconciliation failed: $e');
    }
  }

  void _onIndexedAck(SwapIndexedAck event, Emitter<SwapState> emit) {
    final flow = state.flow;
    if (flow is! TxFlowSuccess<SwapQuoteData, SwapSuccessData>) return;
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

  /// The picker committed a switch to a different funding wallet. Nothing
  /// computed for the previous wallet may survive it: the quote is dropped
  /// (which also disables the Swap CTA until a fresh one lands) and any order
  /// still in flight for the old taker is invalidated by the epoch bump.
  ///
  /// The sell-side balance and the Half/Max shortcuts derive from
  /// [TokenBalance]s the sheet pushes in via [SwapBalancesUpdated]; the sheet
  /// refreshes those alongside this event.
  void _onSourceWalletChanged(
    SwapSourceWalletChanged event,
    Emitter<SwapState> emit,
  ) {
    _sourceEpoch++;
    // A committed swap is already signed/broadcasting against the old wallet —
    // leave it alone rather than tearing its flow state down mid-flight.
    if (!_isFormEditable()) return;
    emit(
      state.copyWith(flow: const TxFlowIdle<SwapQuoteData, SwapSuccessData>()),
    );
    if (state.canQuote) add(const SwapEvent.getQuote());
  }

  void _onReset(SwapReset event, Emitter<SwapState> emit) {
    emit(
      SwapState(
        sellToken: state.sellToken,
        buyToken: state.buyToken,
        slippageBps: state.slippageBps,
        priorityFeeLamports: state.priorityFeeLamports,
      ),
    );
  }
}
