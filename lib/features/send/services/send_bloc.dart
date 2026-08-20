import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:solana/dto.dart' show Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/security_utils.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/token_amount.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show Chain, evmRecipientError;
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/utils/tezos_address.dart'
    show TezosTokenRef, isValidTezosAddress, parseTezosTokenRef;
import '../../activity/data/activity_repository.dart';
import '../../activity/services/activity_refresh_signal.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/balance_optimistic_updater.dart';
import '../models/eth_gas.dart';
import 'ethereum_transfer_service.dart';
import 'tezos_transfer_service.dart';

part 'send_bloc.freezed.dart';

/// Canonical SPL token account size. Token-2022 ATAs with extensions may be
/// larger, but most are still 165 bytes; the small discrepancy is accepted
/// as a pre-confirm estimate.
const int _ataAccountSize = 165;

/// Decimals of native XTZ (mutez): 1 XTZ = 1_000_000 mutez.
const int _xtzDecimals = 6;

/// Decimal places a Max built from a cached balance is truncated to when the
/// cached atomic balance was clamped ([TokenBalance.isRawBalanceClamped]) and
/// `uiBalance` is all we have. Six is far coarser than the double's ~1e-16
/// relative error, so truncating here is guaranteed to land at or below the
/// real balance — and a clamped row means the holding is already large enough
/// that a millionth of a token is invisible.
const int _clampedMaxDecimals = 6;

/// Most fraction digits `double.toStringAsFixed` accepts — it throws a
/// [RangeError] past this. A token's `decimals` is issuer-controlled metadata
/// (a u8 the backend passes through unclamped), so an airdropped spam token can
/// declare more than a double can be formatted to.
const int _maxFixedDigits = 20;

/// Decimals of native ETH (wei): 1 ETH = 10^18 wei.
const int _ethDecimals = 18;

/// Kill-switch cell for a send of [chain]'s native coin ([isNative]) or of one
/// of its tokens. Native and token sends are separate cells precisely so an
/// operator can kill one without the other on the same chain —
/// `tezos:token-send` isn't even implemented while `tezos:native-send` is.
///
/// Top-level rather than a bloc method because the entry gate needs the *same*
/// derivation the signing path uses: `showSendSheet` opens before the chain or
/// the native/token split is known, so the token picker and the confirm
/// step have to compute the cell themselves. Two derivations that could
/// disagree is exactly how a gate ends up reading the wrong cell.
FlowKey sendFlowKey(Chain chain, {required bool isNative}) =>
    FlowKey(chain, isNative ? AppFlow.nativeSend : AppFlow.tokenSend);

@freezed
sealed class SendEvent with _$SendEvent {
  const factory SendEvent.setRecipient(String address) = SendSetRecipient;
  const factory SendEvent.setAmount(String amount) = SendSetAmount;
  const factory SendEvent.setToken(TokenBalance? token) = SendSetToken;

  /// Tells the bloc which wallet/chain is funding the send, so recipient
  /// validation, fee math, and the build/sign/inject path branch correctly.
  /// [walletId] is required for Tezos (local ed25519 signing) and Ethereum
  /// (local secp256k1 signing); Solana ignores it and signs via the
  /// active-signer executor.
  const factory SendEvent.setSource({
    required Chain chain,
    required String address,
    String? walletId,
  }) = SendSetSource;

  const factory SendEvent.setMaxAmount() = SendSetMaxAmount;

  /// Applies the fee tier / custom fee the user picked on the Edit Gas Fee
  /// sheet (Ethereum only). Updates the confirm-step fee display and the fee
  /// signed at broadcast.
  const factory SendEvent.setEthGasSelection(EthGasSelection selection) =
      SendSetEthGasSelection;

  const factory SendEvent.estimateFee() = SendEstimateFee;
  const factory SendEvent.validateAndProceed() = SendValidateAndProceed;
  const factory SendEvent.simulate() = SendSimulate;
  const factory SendEvent.execute() = SendExecute;
  const factory SendEvent.reset() = SendReset;
}

@freezed
sealed class SendState with _$SendState {
  const SendState._();

  const factory SendState.input({
    @Default('') String recipient,
    @Default('') String amount,
    TokenBalance? token,
    String? recipientError,
    String? amountError,
    @Default(false) bool isValidating,
    @Default(kBaseSolanaTxFeeLamports) int estimatedFeeLamports,
    @Default(0) int ataRentLamports,
    @Default(false) bool isEstimatingFee,
  }) = SendInput;

  const factory SendState.ready({
    required String recipient,
    required String amountString,
    required double amount,
    required TokenBalance? token,
    required int estimatedFeeLamports,
    required double totalCost,
    @Default(0) int ataRentLamports,
    @Default(false) bool isSimulating,
    SimulationResult? simulationResult,
    int? simulatedNetSolLamports,

    /// Set for a Tezos send — carries the XTZ fee, gas/storage, and reveal flag
    /// the confirm step renders instead of the Solana lamport fee. Null on the
    /// Solana path.
    TezosSendEstimate? tezosEstimate,

    /// Set for an Ethereum send — carries the EIP-1559 gas/fee estimate the
    /// confirm step renders instead of the Solana lamport fee. Null off the
    /// Ethereum path. [token] is preserved (unlike the Tezos/native-SOL null
    /// collapse) so an ERC-20 send keeps its symbol/decimals for display.
    EthereumSendEstimate? ethereumEstimate,

    /// Live fee market (tiers, base fee, priority range, congestion) backing the
    /// Edit Gas Fee sheet. Set alongside [ethereumEstimate] at Ethereum review.
    EthGasMarket? ethGasMarket,

    /// The fee tier / custom fee currently in effect — drives the confirm-step
    /// fee display and is signed at broadcast. Defaults from the user's
    /// persisted choice (or Market); updated by [SendSetEthGasSelection].
    EthGasSelection? ethGasSelection,
  }) = SendReady;

  /// [isLocal] distinguishes local key signing from social/external signing.
  /// [onLedger] is set once the executor reaches
  /// [ExecutorStage.ledgerAwaitingDevice] so the pipeline can swap the generic
  /// external approval copy for the Ledger-device prompt — matching
  /// every other signing flow (mint/burn/market/auction/fixed-price).
  const factory SendState.signing({
    @Default(true) bool isLocal,
    @Default(false) bool onLedger,
  }) = SendSigning;

  /// [pendingRegistered] flips true once an EVM broadcast has been accepted by
  /// the node and handed to `PendingEvmTxTracker`. Before that the transaction
  /// may still fail (`sendRawTransaction` throwing), and this bloc is the only
  /// surface that failure can reach — so it gates the pipeline's early-exit
  /// "Done" affordance. Solana/Tezos never set it: they have no tracker to hand
  /// confirmation to, so leaving early is never safe there.
  const factory SendState.broadcasting({
    @Default(false) bool pendingRegistered,
  }) = SendBroadcasting;

  const factory SendState.success({
    required String signature,
    required String explorerUrl,
  }) = SendSuccess;

  /// [unconfirmed] marks the *indeterminate* end state: the transaction was
  /// broadcast but never observed as confirmed before its blockhash expired
  /// ([SolanaTransactionUnconfirmedException]). It is not a failure — it may
  /// still land — so the pipeline must not offer a blind "Try again", which is
  /// precisely how the user ends up sending twice.
  const factory SendState.error({
    required String message,
    SendInput? previousState,
    @Default(false) bool unconfirmed,
  }) = SendError;

  bool get canSubmit => maybeMap(
    input: (s) =>
        s.recipient.isNotEmpty &&
        s.amount.isNotEmpty &&
        s.recipientError == null &&
        s.amountError == null,
    orElse: () => false,
  );
}

@injectable
class SendBloc extends Bloc<SendEvent, SendState> {
  SendBloc(
    this._rpcService,
    this._walletManager,
    this._authGate,
    this._priceService,
    this._feeConfig,
    this._executor,
    this._tezos,
    this._ethereum,
    this._prefs,
  ) : super(const SendState.input()) {
    on<SendSetRecipient>(_onSetRecipient);
    on<SendSetAmount>(_onSetAmount);
    on<SendSetToken>(_onSetToken);
    on<SendSetSource>(_onSetSource);
    on<SendSetMaxAmount>(_onSetMaxAmount);
    on<SendSetEthGasSelection>(_onSetEthGasSelection);
    on<SendEstimateFee>(_onEstimateFee);
    on<SendValidateAndProceed>(_onValidateAndProceed);
    on<SendSimulate>(_onSimulate);
    on<SendExecute>(_onExecute);
    on<SendReset>(_onReset);
  }

  final SolanaRpcService _rpcService;
  final WalletManager _walletManager;
  final TransactionAuthGate _authGate;
  final TokenPriceService _priceService;
  final FeeConfig _feeConfig;
  final TransactionExecutor _executor;
  final TezosTransferService _tezos;
  final EthereumTransferService _ethereum;
  final PreferencesService _prefs;

  /// The funding wallet's chain. Drives recipient validation, decimals, fee
  /// math, and the build/sign/inject path. Defaults to Solana; the send sheet
  /// dispatches [SendSetSource] once it resolves the source wallet.
  Chain _chain = Chain.solana;

  /// The funding wallet's address + id, set alongside [_chain]. [_walletId] is
  /// required for the Tezos/Ethereum local-signing paths; the Solana path signs
  /// via the active signer through [_executor] and leaves these null.
  String? _sourceAddress;
  String? _walletId;

  /// The validated, ready-to-sign Ethereum transfer produced by the review
  /// step's safety gate ([EthereumTransferService.prepare]), together with the
  /// recipient + raw amount it was built for. Cached so the execute step signs
  /// the exact calldata the gate approved; re-derived at execute time when
  /// absent (e.g. a restored [SendReady]) or when the cache no longer matches
  /// the live [SendReady] state — so a stale prepared left by a superseded
  /// review can never be signed while the confirm screen shows other values.
  /// Cleared on reset and on any recipient/amount/token edit that invalidates
  /// it (see [_clearEthPrepared]).
  PreparedEthTransfer? _ethPrepared;
  String? _ethPreparedRecipient;
  BigInt? _ethPreparedAmountRaw;

  /// Native-SOL balance (lamports) of the funding wallet, read from chain and
  /// cached for the amount-field guard. Null until the first read lands (or
  /// when every read has failed), in which case the guard stays quiet rather
  /// than blocking a legitimate amount — the same "don't false-disable" rule
  /// the ETH/XTZ confirm-time balance checks follow.
  int? _solLamports;

  /// The claim the EVM send funnel took out on the broadcast nonce, held while
  /// this bloc is the surface that will report the outcome. Handed back in
  /// [close] — see there for why.
  PendingTxResolutionClaim? _resolutionClaim;

  /// The compute-budget prefix a native-SOL Max priced its amount against, with
  /// the recipient and amount string that pricing produced.
  ///
  /// A Max is `balance − fee`, so the amount and the fee are one decision: the
  /// transfer must be built with *this* prefix or the fee moves and the account
  /// is left holding dust the runtime rejects (see [_solMaxSendable]). Cleared
  /// by any edit that invalidates the pricing, so a stale plan can never be
  /// signed against values the user has since changed.
  ComputeBudgetPlan? _solMaxBudget;
  String? _solMaxRecipient;
  String? _solMaxAmount;

  bool get _isTezos => _chain == Chain.tezos;
  bool get _isEthereum => _chain == Chain.ethereum;

  void _clearSolMaxPlan() {
    _solMaxBudget = null;
    _solMaxRecipient = null;
    _solMaxAmount = null;
  }

  /// Whether [amount] is the drain-the-account amount this bloc priced — the
  /// one send allowed to leave the account at zero rather than at or above the
  /// rent-exempt minimum. The plan is dropped whenever the recipient changes,
  /// so inside the bloc the amount alone identifies it.
  bool _isPinnedSolMax(String amount) =>
      _solMaxBudget != null && _solMaxAmount == amount;

  /// [_isPinnedSolMax] for the confirm-time gate, which has to re-check the
  /// recipient it is about to send to rather than trust the bloc's own.
  bool isSolMaxAmount(String amount, String recipient) =>
      _isPinnedSolMax(amount) && _solMaxRecipient == recipient;

  /// Drop the cached prepared Ethereum transfer and the recipient/amount it was
  /// built for. Called on reset and on any recipient/amount/token edit so the
  /// next execute re-prepares from the current state rather than reusing a
  /// prepared the user has since edited away from.
  void _clearEthPrepared() {
    _ethPrepared = null;
    _ethPreparedRecipient = null;
    _ethPreparedAmountRaw = null;
  }

  void _onSetRecipient(SendSetRecipient event, Emitter<SendState> emit) {
    final current = state;
    if (current is! SendInput) return;

    // A new recipient invalidates any prepared Ethereum transfer cached at the
    // last review — it was built for the old recipient's calldata — and the
    // Solana Max plan, whose fee was simulated against the old destination.
    _clearEthPrepared();
    _clearSolMaxPlan();
    final error = _validateAddress(event.address);
    // Reset rent estimate when the recipient changes — it's keyed to the
    // destination ATA so a different recipient invalidates the prior fetch.
    emit(
      current.copyWith(
        recipient: event.address,
        recipientError: error,
        ataRentLamports: 0,
        estimatedFeeLamports: _feeConfig.baseTxFeeLamports,
      ),
    );
    if (error == null && event.address.isNotEmpty && current.token != null) {
      add(const SendEvent.estimateFee());
    }
  }

  void _onSetAmount(SendSetAmount event, Emitter<SendState> emit) {
    final current = state;
    if (current is! SendInput) return;

    // A new amount invalidates any prepared Ethereum transfer cached at the last
    // review — it was built for the old raw amount.
    _clearEthPrepared();
    // Typing anything other than the priced Max amount gives up the plan that
    // priced it: any other amount has to leave the account rent-exempt, which
    // is the ordinary reserve, not this one.
    if (event.amount != _solMaxAmount) _clearSolMaxPlan();
    final error = _validateAmount(event.amount, current.token);
    emit(current.copyWith(amount: event.amount, amountError: error));
  }

  void _onSetToken(SendSetToken event, Emitter<SendState> emit) {
    final current = state;
    if (current is! SendInput) return;

    // Switching token (and clearing the amount) invalidates any prepared
    // Ethereum transfer cached at the last review, and any Solana Max plan.
    _clearEthPrepared();
    _clearSolMaxPlan();
    emit(
      current.copyWith(
        token: event.token,
        amount: '',
        amountError: null,
        // Token swap invalidates the previously-known ATA rent — the new
        // mint may use a different program/derivation entirely.
        ataRentLamports: 0,
        estimatedFeeLamports: _feeConfig.baseTxFeeLamports,
      ),
    );
    if (event.token != null &&
        current.recipient.isNotEmpty &&
        _validateAddress(current.recipient) == null) {
      add(const SendEvent.estimateFee());
    }
  }

  void _onSetSource(SendSetSource event, Emitter<SendState> emit) {
    _chain = event.chain;
    _sourceAddress = event.address;
    _walletId = event.walletId;
    if (kDebugMode) {
      debugPrint(
        '[SendBloc] setSource chain=${event.chain.toDbString()} '
        'address=${event.address} walletId=${event.walletId}',
      );
    }
    // Re-validate any already-typed recipient under the new chain — switching a
    // Tezos source must reject a Solana address that was valid a moment ago.
    final current = state;
    if (current is SendInput && current.recipient.isNotEmpty) {
      emit(
        current.copyWith(recipientError: _validateAddress(current.recipient)),
      );
    }
    // Prime the native-SOL balance the amount guard reads. The source is
    // chosen two steps before the amount is typed, so this has landed by the
    // time it matters; if it hasn't, the guard simply stays quiet.
    if (_chain == Chain.solana) unawaited(_primeSolBalance());
  }

  /// Read (and cache) the funding wallet's native-SOL balance, then re-run
  /// amount validation against it.
  ///
  /// Re-validation goes through [SendSetAmount] rather than an emit from here:
  /// this runs outside an event handler, where the emitter is not ours to use.
  Future<void> _primeSolBalance() async {
    try {
      final address = await _walletManager.getAddress();
      _solLamports = await _rpcService.getBalanceForAddress(address);
    } catch (_) {
      return;
    }
    // Both reads above are awaited outside an event handler, so the send screen
    // may have been popped — and this bloc closed — while they ran. Adding to a
    // closed bloc throws, and there is no form left to re-validate anyway.
    if (isClosed) return;
    final current = state;
    if (current is SendInput && current.amount.isNotEmpty) {
      add(SendEvent.setAmount(current.amount));
    }
  }

  Future<void> _onEstimateFee(
    SendEstimateFee event,
    Emitter<SendState> emit,
  ) async {
    // ATA-rent pre-estimate is a Solana concept; the Tezos/Ethereum fee is
    // computed at review via the chain's transfer service.
    if (_isTezos || _isEthereum) return;
    final current = state;
    if (current is! SendInput) return;
    final token = current.token;
    final recipient = current.recipient;
    if (token == null ||
        recipient.isEmpty ||
        _validateAddress(recipient) != null) {
      return;
    }

    emit(current.copyWith(isEstimatingFee: true));
    final rent = await _fetchAtaRentIfMissing(
      recipient: recipient,
      token: token,
    );

    // Bail if the recipient/token changed under us (e.g. fast retyping).
    final latest = state;
    if (latest is! SendInput) return;
    if (latest.recipient != recipient || latest.token?.mint != token.mint) {
      return;
    }
    final ataRent = rent ?? 0;
    emit(
      latest.copyWith(
        isEstimatingFee: false,
        ataRentLamports: ataRent,
        estimatedFeeLamports: _feeConfig.baseTxFeeLamports + ataRent,
      ),
    );
  }

  /// Returns the rent-exempt minimum for the destination ATA when it does
  /// not exist yet, or `0` when it already exists. Returns `null` on lookup
  /// failure so callers can fall back to the static base fee.
  Future<int?> _fetchAtaRentIfMissing({
    required String recipient,
    required TokenBalance token,
  }) async {
    try {
      final destKey = Ed25519HDPublicKey.fromBase58(recipient);
      final mintKey = Ed25519HDPublicKey.fromBase58(token.mint);
      final programType = await _rpcService.getTokenProgramTypeForMint(
        token.mint,
      );
      final ata = await findAssociatedTokenAddress(
        owner: destKey,
        mint: mintKey,
        tokenProgramType: programType,
      );
      // base64 required: base58 (the RPC default) rejects the 165-byte token
      // account, throwing for any recipient that already holds an ATA.
      final info = await _rpcService.getAccountInfo(
        ata.toBase58(),
        encoding: Encoding.base64,
      );
      if (info.value != null) return 0;
      return _rpcService.getMinimumBalanceForRentExemption(_ataAccountSize);
    } catch (_) {
      return null;
    }
  }

  Future<void> _onSetMaxAmount(
    SendSetMaxAmount event,
    Emitter<SendState> emit,
  ) async {
    final current = state;
    if (current is! SendInput) return;

    // Max recomputes the amount, invalidating any prepared Ethereum transfer
    // cached at the last review.
    _clearEthPrepared();

    String maxAmount;

    if (_isTezos) {
      final token = current.token;
      if (token != null && !token.isNative) {
        // FA token: the whole balance — the fee is paid in XTZ, not in the
        // token, so nothing is held back. Preferred source is the cached atomic
        // [TokenBalance.rawBalance] rather than the double `uiBalance`, which
        // rounds *up* past what is held and would make Max fail on-chain after
        // the user has signed (the same trap the SPL and ERC-20 branches below
        // were hardened against).
        //
        // 18-decimal FA1.2s (kUSD, PLY) overflow the model's int64 clamp past
        // ~9.22 tokens, and there is no cheap client-side read of an FA balance
        // to fall back to — it lives in a contract bigmap, not in an account.
        // So a clamped row falls back to `uiBalance` (derived from the exact
        // BigInt, good to ~16 significant digits) truncated to
        // [_clampedMaxDecimals]: `parseTokenAmount` truncates rather than
        // rounds, and dropping a millionth of a token dwarfs the double's
        // ~1e-16 relative error, so the offered Max is always at or below what
        // is held. Leaving dust behind beats a Max the chain rejects.
        //
        // [_cachedMaxAmount] fails soft to '0' the way the XTZ/ETH/SOL
        // branches below do, so a hostile `decimals` cannot throw out of this
        // branch — it carries the guard rather than repeating it at both call
        // sites.
        maxAmount = _cachedMaxAmount(token);
        emit(current.copyWith(amount: maxAmount, amountError: null));
        return;
      }
      // Native XTZ: the full balance less what this exact transfer costs —
      // baker fee, any one-time reveal, and the storage burn a fresh
      // destination is allocated with — simulated against the recipient rather
      // than guessed at with flat headroom (fees are paid in XTZ).
      try {
        final source = _sourceAddress;
        final walletId = _walletId;
        final spendable = source == null || walletId == null
            ? BigInt.zero
            : await _tezos.maxNativeSendable(
                walletId: walletId,
                source: source,
                destination: current.recipient,
              );
        // Formatted off the BigInt, not `toDouble() / 1e6`: the mutez figure is
        // now exact to the last unit, and a double round-trip can only round it
        // back *up* past what the account holds.
        maxAmount = spendable > BigInt.zero
            ? TokenAmount.formatTokenAmount(spendable, _xtzDecimals)
            : '0';
      } catch (_) {
        maxAmount = '0';
      }
      emit(current.copyWith(amount: maxAmount, amountError: null));
      return;
    }

    if (_isEthereum) {
      // Fees are paid in ETH. Native ETH: full spendable balance less a
      // worst-case gas reserve. ERC-20: the full token balance (gas is paid in
      // ETH, not the token). Both read full-precision wei/base-units from chain
      // rather than the cached balance, whose double `uiBalance` /
      // int64-clamped `rawBalance` would round Max past what's actually held.
      final token = current.token;
      final decimals = token?.decimals ?? _ethDecimals;
      try {
        final source = _sourceAddress;
        final BigInt raw;
        if (source == null) {
          raw = BigInt.zero;
        } else if (token == null) {
          raw = await _maxNativeSendable(source, current.recipient);
        } else {
          raw = await _ethereum.tokenBalance(source, token.mint);
        }
        maxAmount = raw > BigInt.zero
            ? TokenAmount.formatTokenAmount(raw, decimals)
            : '0';
      } catch (_) {
        maxAmount = '0';
      }
      emit(current.copyWith(amount: maxAmount, amountError: null));
      return;
    }

    final splToken = current.token;
    if (splToken != null) {
      // SPL token: the full balance (fees are paid in SOL) — but read the raw
      // base-unit amount off the token account rather than the cached
      // `uiBalance`, which is a `double` and rounds *up* past what is actually
      // held for large or high-decimal balances. A Max that exceeds the true
      // raw balance fails on-chain after the user has signed. The EVM branch
      // above was hardened for exactly this; this is the same fix.
      // `requireOwnedTokenAccount` already carries that raw amount from its own
      // live read, so no second RPC is issued here — a follow-up
      // `getTokenAccountAmount` swallows its errors and returns 0, which would
      // make the catch below unreachable and fill Max with '0' on a blip.
      try {
        final source = await _walletManager.getAddress();
        final holding = await _rpcService.requireOwnedTokenAccount(
          owner: source,
          mint: splToken.mint,
        );
        final raw = holding.amount;
        maxAmount = raw > 0
            ? TokenAmount.formatTokenAmount(BigInt.from(raw), splToken.decimals)
            : '0';
      } catch (_) {
        // No live read — fall back to the cached balance via the same helper
        // the FA branch uses: the exact atomic `rawBalance`, or a truncated
        // `uiBalance` when that figure was clamped away. This used to be
        // `uiBalance × 10^decimals` floored into an int, which overflows int64
        // for a large or high-decimal holding and fills Max with a number
        // unrelated to the balance rather than failing.
        maxAmount = _cachedMaxAmount(splToken);
      }
    } else {
      maxAmount = await _solMaxSendable(current.recipient);
    }

    emit(current.copyWith(amount: maxAmount, amountError: null));
  }

  /// The native-SOL Max amount for a transfer to [recipient]: the whole balance
  /// less the transaction's **exact** fee, so the account is left holding
  /// nothing at all. Pins the plan that priced it ([_solMaxBudget]) for the
  /// execute step, and returns '0' when the balance can't cover a transfer.
  ///
  /// Exactness is not a nicety here. Solana rejects any transaction that leaves
  /// a writable account *rent-paying* — holding less than the ~0.00089 SOL
  /// rent-exempt minimum but more than nothing — with `InsufficientFundsForRent`
  /// at preflight, i.e. after the user has signed. So the residue has to be
  /// either zero or a further 0.00089 SOL, and only one of those is a Max. That
  /// rules out reserving the worst-case fee and living with the difference: the
  /// difference *is* the dust that gets the transaction rejected.
  ///
  /// A balance that changes between here and broadcast reopens the same window
  /// (an incoming lamport becomes the residue). Nothing can close that race from
  /// the client; preflight catches it before the transfer lands.
  Future<String> _solMaxSendable(String recipient) async {
    _clearSolMaxPlan();
    try {
      final address = await _walletManager.getAddress();
      final balance = await _rpcService.getBalanceForAddress(address);
      _solLamports = balance;
      // Sizes the fee simulation only — the compute cost of a transfer does not
      // depend on the amount. Kept rent-exempt on both sides so the probe
      // itself isn't rejected by the very rule this method exists to respect.
      final provisional =
          balance - worstCaseSolTxFeeLamports - kSolRentExemptMinimumLamports;
      final plan = await _rpcService.planSolTransferFee(
        destination: recipient,
        provisionalLamports: provisional > 0 ? provisional : 1,
      );
      final maxLamports = balance - plan.feeLamports;
      if (maxLamports <= 0) return '0';
      // Formatted off the integer: a `lamports / 1e9` round-trip can land a
      // lamport high, and a lamport high is a transfer the runtime rejects.
      final amount = TokenAmount.lamportsToSol(BigInt.from(maxLamports));
      _solMaxBudget = plan.budget;
      _solMaxRecipient = recipient;
      _solMaxAmount = amount;
      return amount;
    } catch (e) {
      debugPrint('[SendBloc] SOL Max pricing failed: $e');
      // No exact fee — so no emptying the account, because an inexact one
      // leaves dust the runtime rejects. Fall back to the largest *partial*
      // send instead: the worst-case fee plus a rent-exempt residue, which
      // always lands. A Max that moves all but 0.0009 SOL beats a dead button.
      return _solPartialMax();
    }
  }

  /// The largest native-SOL amount that can be sent while leaving the account
  /// rent-exempt — the fallback when [_solMaxSendable] can't price the fee.
  String _solPartialMax() {
    final balance = _solLamports;
    if (balance == null) return '0';
    final spendable =
        balance - worstCaseSolTxFeeLamports - kSolRentExemptMinimumLamports;
    return spendable > 0
        ? TokenAmount.lamportsToSol(BigInt.from(spendable))
        : '0';
  }

  /// The whole of a *cached* [token] balance, as a Max amount string — the
  /// Tezos FA branch of [_onSetMaxAmount] and the SPL fallback when the live
  /// token-account read fails.
  ///
  /// Always derived from the atomic [TokenBalance.rawBalance], never from
  /// `uiBalance × 10^decimals`: that product overflows int64 for a large or
  /// high-decimal holding, and `double.floor()` neither throws nor saturates
  /// predictably there (1e19 floors to int64's max, 1e30 to
  /// 5_076_944_270_305_263_616), so Max silently filled with a number that had
  /// nothing to do with the balance. Only a clamped row — where the exact
  /// atomic figure was discarded at parse time — falls back to `uiBalance`,
  /// truncated so it still lands at or below what is held.
  ///
  /// Never throws: every failure degrades to '0'. The double formatting below
  /// can raise on issuer-controlled metadata, and this runs on branches that
  /// have no other guard — a Max of '0' is recoverable (the user can type an
  /// amount), an error escaping the handler leaves the field untouched and
  /// makes Max look dead.
  String _cachedMaxAmount(TokenBalance token) {
    try {
      if (!token.isRawBalanceClamped) {
        return token.rawBalance > 0
            ? TokenAmount.formatTokenAmount(
                BigInt.from(token.rawBalance),
                token.decimals,
              )
            : '0';
      }
      if (token.uiBalance <= 0) return '0';
      // toStringAsFixed expands the double; parseTokenAmount then *truncates*
      // the excess places, so the round-trip can only ever go down. The digit
      // count is capped at [_maxFixedDigits] because `decimals` is
      // issuer-controlled and toStringAsFixed throws past that; any cap far
      // above [_clampedMaxDecimals] leaves the truncation, not the rounding at
      // the last formatted place, in charge of the result.
      //
      // A `uiBalance` at or above 1e21 still formats in exponent notation
      // ('1e+21'), which parseTokenAmount rejects — that is what the catch
      // below is for.
      final truncated = TokenAmount.parseTokenAmount(
        token.uiBalance.toStringAsFixed(
          math.min(token.decimals, _maxFixedDigits),
        ),
        _clampedMaxDecimals,
      );
      return truncated > BigInt.zero
          ? TokenAmount.formatTokenAmount(truncated, _clampedMaxDecimals)
          : '0';
    } catch (_) {
      return '0';
    }
  }

  /// Spendable native ETH for a Max send to [destination], reserving gas at the
  /// exact limit AND fee [_executeEthereum] will sign. When the Edit-Gas fee
  /// market resolves, that is the persisted tier/custom selection's
  /// `gasLimit × maxFeePerGas` — the same [EthGasSelection.resolveFromPrefs] the
  /// review step applies — over the *per-recipient* padded gas limit
  /// ([EthereumTransferService.nativeSendGasLimitFor], matching prepare's own
  /// estimate). Reserving the real recipient limit rather than the flat EOA
  /// [EthereumTransferService.nativeSendGasLimit] is what keeps a contract-wallet
  /// recipient (Safe/Argent, whose receive/fallback burns more than 21 000 gas)
  /// broadcastable: `value + signedGasLimit × cap` stays at or under the balance,
  /// so the send can never be rejected for "insufficient funds for gas * price +
  /// value" after review + biometric auth. If the market is unavailable the
  /// review step likewise resolves no selection and `execute` refreshes the node
  /// fee at broadcast, so the reserve falls back to the service's getFeeData-based
  /// [EthereumTransferService.maxNativeSendable] to match. Any residual mismatch
  /// (a fee cap that spiked between Max and review/broadcast) is caught fail-closed
  /// before signing by the native budget guard in [signAndBroadcastEvmTransfer].
  Future<BigInt> _maxNativeSendable(String source, String destination) async {
    try {
      final results = await Future.wait<Object>([
        _ethereum.gasMarket(),
        _ethereum.nativeBalance(source),
        _ethereum.nativeSendGasLimitFor(
          source: source,
          destination: destination,
        ),
      ]);
      final market = results[0] as EthGasMarket;
      final balance = results[1] as BigInt;
      final gasLimit = results[2] as int;
      final selection = EthGasSelection.resolveFromPrefs(
        prefs: _prefs,
        market: market,
        defaultGasLimit: gasLimit,
      );
      final reserve = BigInt.from(selection.gasLimit) * selection.maxFeePerGas;
      final spendable = balance - reserve;
      return spendable > BigInt.zero ? spendable : BigInt.zero;
    } catch (_) {
      return _ethereum.maxNativeSendable(source);
    }
  }

  Future<void> _onValidateAndProceed(
    SendValidateAndProceed event,
    Emitter<SendState> emit,
  ) async {
    final current = state;
    if (current is! SendInput) return;

    emit(current.copyWith(isValidating: true));

    if (_isTezos) {
      await _validateAndProceedTezos(current, emit);
      return;
    }

    if (_isEthereum) {
      await _validateAndProceedEthereum(current, emit);
      return;
    }

    final result = await Result.guard(() async {
      final amount = double.tryParse(current.amount) ?? 0;
      // Refresh ATA rent on review so we always commit on the most recent
      // signal — the input-state estimate could be stale if the recipient
      // funded their ATA between typing and tapping Review.
      var ataRent = current.ataRentLamports;
      if (current.token != null) {
        final fetched = await _fetchAtaRentIfMissing(
          recipient: current.recipient,
          token: current.token!,
        );
        if (fetched != null) ataRent = fetched;
      }
      final estimatedFee = _feeConfig.baseTxFeeLamports + ataRent;
      final totalCost = current.token == null
          ? amount + (estimatedFee / 1e9)
          : amount;
      return SendState.ready(
        recipient: current.recipient,
        amountString: current.amount,
        amount: amount,
        token: current.token,
        estimatedFeeLamports: estimatedFee,
        totalCost: totalCost,
        ataRentLamports: ataRent,
      );
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(value);
      case ResultFailure(:final error):
        emit(current.copyWith(isValidating: false));
        emit(SendState.error(message: error.message, previousState: current));
    }
  }

  /// The `KT1…` + token id behind a non-native Tezos holding, or a throw naming
  /// why it can't be sent.
  ///
  /// Native XTZ collapses to a null token the same way native SOL/ETH do, so
  /// this is only reached for a real FA holding — which means an unparseable
  /// mint (a row cached before the balance mapper stopped lower-casing Tezos
  /// contracts, unrecoverable from the string alone) has to become an error
  /// here. Falling back to the native path would move XTZ instead.
  TezosTokenRef _requireTezosToken(TokenBalance token) {
    final ref = parseTezosTokenRef(token.mint);
    if (ref == null) {
      throw TezosUnsupportedTokenException(
        token.mint,
        'its token contract could not be read — pull to refresh the tokens '
        'list and try again',
      );
    }
    return ref;
  }

  /// Tezos review: simulate the transfer for its fee/gas/storage/reveal and
  /// move to [SendReady] carrying the [TezosSendEstimate]. Covers native XTZ
  /// (null token) and FA1.2/FA2 tokens; the fee is quoted in XTZ either way.
  Future<void> _validateAndProceedTezos(
    SendInput current,
    Emitter<SendState> emit,
  ) async {
    final walletId = _walletId;
    final source = _sourceAddress;
    if (walletId == null || source == null) {
      if (kDebugMode) {
        debugPrint(
          '[SendBloc] Tezos proceed BLOCKED walletId=$walletId '
          'source=$source chain=${_chain.toDbString()}',
        );
      }
      emit(current.copyWith(isValidating: false));
      emit(
        SendState.error(
          message: 'No Tezos wallet available to send from',
          previousState: current,
        ),
      );
      return;
    }

    final token = current.token;
    final isNativeXtz = token == null || token.isNative;

    final result = await Result.guard(() async {
      final amount = double.tryParse(current.amount) ?? 0;
      if (!isNativeXtz) {
        // FA1.2 / FA2: the raw amount is in the token's own decimals and the
        // operation moves zero XTZ — only the fee and the storage the contract
        // writes are paid in XTZ, so the total cost is the amount alone.
        final estimate = await _tezos.estimateTokenTransfer(
          walletId: walletId,
          source: source,
          destination: current.recipient,
          token: _requireTezosToken(token),
          amountRaw: TokenAmount.parseTokenAmount(
            current.amount,
            token.decimals,
          ),
        );
        return SendState.ready(
          recipient: current.recipient,
          amountString: current.amount,
          amount: amount,
          // Preserved (unlike the native collapse below) so the confirm step
          // shows the token's own symbol/name instead of XTZ/Tezos.
          token: token,
          estimatedFeeLamports: 0,
          totalCost: amount,
          tezosEstimate: estimate,
        );
      }
      final amountMutez = TokenAmount.parseTokenAmount(
        current.amount,
        _xtzDecimals,
      );
      final estimate = await _tezos.estimateNativeTransfer(
        walletId: walletId,
        source: source,
        destination: current.recipient,
        amountMutez: amountMutez,
      );
      return SendState.ready(
        recipient: current.recipient,
        amountString: current.amount,
        amount: amount,
        // Native XTZ collapses to a null token on the Solana-shaped state, same
        // as native SOL; [_chain] disambiguates the two.
        token: null,
        estimatedFeeLamports: 0,
        // Fee + storage burn: a fresh destination costs 0.06425 XTZ to
        // allocate, which the baker fee alone does not cover.
        totalCost: amount + estimate.totalCostXtz,
        tezosEstimate: estimate,
      );
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(value);
      case ResultFailure(:final error):
        emit(current.copyWith(isValidating: false));
        emit(SendState.error(message: error.message, previousState: current));
    }
  }

  /// Ethereum review: estimate the transfer's EIP-1559 gas/fee and move to
  /// [SendReady] carrying the [EthereumSendEstimate]. Native ETH (null token)
  /// and ERC-20 (non-null token) both flow here; the token is preserved on the
  /// ready state so an ERC-20 keeps its symbol/decimals for display.
  Future<void> _validateAndProceedEthereum(
    SendInput current,
    Emitter<SendState> emit,
  ) async {
    final source = _sourceAddress;
    if (_walletId == null || source == null) {
      emit(current.copyWith(isValidating: false));
      emit(
        SendState.error(
          message: 'No Ethereum wallet available to send from',
          previousState: current,
        ),
      );
      return;
    }

    final walletId = _walletId!;
    final result = await Result.guard(() async {
      final amount = double.tryParse(current.amount) ?? 0;
      final decimals = current.token?.decimals ?? _ethDecimals;
      // Keep the raw amount as BigInt end-to-end — an 18-decimal ETH amount
      // overflows int, so it must never round-trip through [TokenAmount.toInt].
      final amountRaw = TokenAmount.parseTokenAmount(current.amount, decimals);
      // Kick the parameterless fee-market fetch off concurrently with prepare:
      // gasMarket consumes nothing from prepare's multi-RPC round-trips, so
      // awaiting them serially wastes a round-trip. It stays non-fatal — a
      // feeHistory failure degrades to the read-only default fee (no Edit
      // affordance) rather than blocking the send — and the inline onError keeps
      // the future handled even when prepare throws first.
      final marketFuture = _ethereum.gasMarket().then<EthGasMarket?>(
        (m) => m,
        onError: (Object e) {
          debugPrint('[SendBloc] gasMarket failed (fee edit disabled): $e');
          return null;
        },
      );
      // Backend builds the calldata; the safety gate (calldata assertion +
      // state-change simulation) runs here and throws an
      // EthTransferBlockedException on any mismatch, surfaced below as a hard
      // SendError. The validated transfer is cached — with the recipient/amount
      // it was built for — for the execute step.
      final prepared = await _ethereum.prepare(
        walletId: walletId,
        source: source,
        destination: current.recipient,
        amountRaw: amountRaw,
        token: current.token,
      );
      _ethPrepared = prepared;
      _ethPreparedRecipient = current.recipient;
      _ethPreparedAmountRaw = amountRaw;
      final estimate = prepared.estimate;
      final market = await marketFuture;
      final selection = market == null
          ? null
          : EthGasSelection.resolveFromPrefs(
              prefs: _prefs,
              market: market,
              defaultGasLimit: estimate.gasLimit,
            );
      // Native ETH pays its fee out of the sent balance (add it); an ERC-20's
      // fee is paid separately in ETH, so the token total is just the amount.
      final totalCost = current.token == null
          ? amount + estimate.feeEth
          : amount;
      return SendState.ready(
        recipient: current.recipient,
        amountString: current.amount,
        amount: amount,
        token: current.token,
        estimatedFeeLamports: 0,
        totalCost: totalCost,
        ethereumEstimate: estimate,
        ethGasMarket: market,
        ethGasSelection: selection,
      );
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(value);
      case ResultFailure(:final error):
        emit(current.copyWith(isValidating: false));
        emit(SendState.error(message: error.message, previousState: current));
    }
  }

  /// Apply the fee the user picked on the Edit Gas Fee sheet. Persistence of
  /// the choice (mode + custom knobs) happens in the sheet itself, mirroring the
  /// swap-settings pattern; here we only re-point the in-flight [SendReady] so
  /// the confirm fee display and the broadcast use it.
  void _onSetEthGasSelection(
    SendSetEthGasSelection event,
    Emitter<SendState> emit,
  ) {
    final current = state;
    if (current is! SendReady) return;
    emit(current.copyWith(ethGasSelection: event.selection));
  }

  /// Kill-switch cell for this send. The picker normalises a native selection
  /// to `token == null` (`send_sheet.dart` dispatches
  /// `SendEvent.setToken(token.isNative ? null : token)`), which is the same
  /// discriminator every execute path already branches on — see [sendFlowKey]
  /// for why the derivation is shared with the entry gate.
  FlowKey _sendFlow(Chain chain, TokenBalance? token) =>
      sendFlowKey(chain, isNative: token == null);

  /// The kill-switch failure behind the current [SendError], or null when that
  /// error is a real failure.
  ///
  /// [SendState.error] carries only a `String message`, and the *kind* is what
  /// decides the presentation: a kill gets [FlowUnavailableSheet] with the
  /// operator's copy, never the pipeline step's generic "Transaction failed"
  /// body, which drops the message entirely.
  /// Widening the freezed state would be the cleaner home for it; this side
  /// channel is written immediately before the error emit it describes and
  /// cleared on every new execute and reset, so a listener reacting to a
  /// [SendError] always reads the failure that produced it.
  AppFailure? get killFailure => _killFailure;
  AppFailure? _killFailure;

  /// Kill-switch stop at the gate: record it for the surface, then emit the
  /// operator's message verbatim (never "Send failed: …") so the sheet still has
  /// something to show if it ever falls through to generic error handling.
  void _emitFlowDisabled(
    Emitter<SendState> emit,
    String message,
    SendInput previous,
  ) {
    _killFailure = AppFailure.flowDisabled(message);
    emit(SendState.error(message: message, previousState: previous));
  }

  Future<void> _onExecute(SendExecute event, Emitter<SendState> emit) async {
    final current = state;
    debugPrint('[SendBloc] _onExecute — current state=${current.runtimeType}');
    if (current is! SendReady) {
      debugPrint('[SendBloc] _onExecute aborted — not in SendReady');
      return;
    }
    // A previous attempt's kill must not be read as this one's outcome.
    _killFailure = null;

    if (_isTezos) {
      await _executeTezos(current, emit);
      return;
    }

    if (_isEthereum) {
      await _executeEthereum(current, emit);
      return;
    }

    // USD outflow for the step-up auth gate. SOL transfers price the
    // total lamports out (transferred SOL + the static validator fee +
    // any ATA rent that would be created); SPL transfers price the
    // raw token amount in its mint. usdValueOfRaw returns null when
    // the price isn't cached → the gate treats that as "unknown" and
    // fail-closes (always requires auth, per the AC). The one exception is a
    // token the balance feed affirmatively prices at $0: it is known to be
    // worthless, so it's worth $0 to the gate rather than "unknown".
    double? usdOutflow;
    if (current.token?.hasKnownZeroValue == true) {
      usdOutflow = 0;
    } else if (current.token == null) {
      final lamports = TokenAmount.toInt(
        TokenAmount.solToLamports(current.amountString),
      );
      final totalLamports = lamports + current.estimatedFeeLamports;
      usdOutflow = _priceService.usdValueOfRaw(totalLamports, solMint);
    } else {
      final rawAmount = TokenAmount.toInt(
        TokenAmount.parseTokenAmount(
          current.amountString,
          current.token!.decimals,
        ),
      );
      usdOutflow = _priceService.usdValueOfRaw(rawAmount, current.token!.mint);
    }

    SendInput previousInput() => SendInput(
      recipient: current.recipient,
      amount: current.amountString,
      token: current.token,
      ataRentLamports: current.ataRentLamports,
      estimatedFeeLamports: current.estimatedFeeLamports,
    );

    final outcome = await _authGate.authorize(
      usdValue: usdOutflow,
      flow: _sendFlow(Chain.solana, current.token),
    );
    final disabledMessage = outcome.disabledMessage;
    if (disabledMessage != null) {
      // A killed cell is NOT a user cancel: it carries copy the user
      // needs to read, so it is kept distinguishable for the sheet.
      _emitFlowDisabled(emit, disabledMessage, previousInput());
      return;
    }
    if (outcome != TransactionAuthOutcome.allowed) {
      // Cancel renders verbatim, not as "Send failed: …" — matches the
      // unified pipeline cancel semantics in [TransactionPipeline].
      emit(
        SendState.error(
          message: TransactionAuthCancelledException(outcome).toString(),
          previousState: previousInput(),
        ),
      );
      return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    emit(SendState.signing(isLocal: isLocal));

    // Build the transfer tx client-side, then route sign → broadcast →
    // confirm through the shared [TransactionExecutor] — the single signing
    // path every other bloc uses. The biometric gate already ran above, so
    // the executor's own gate is a no-op here (pass usdValue 0). The send tx
    // isn't server-co-signed, so no [StaleTxTracker] is needed — the pipeline
    // refreshes the blockhash client-side before signing.
    //
    // Drive the signing → broadcasting transition off the executor's stage
    // callback rather than emitting broadcasting up front: a Ledger sign sits
    // in [ledgerAwaitingDevice] until the user approves on the device, so an
    // eager broadcasting emit made the sheet read "Confirming transaction"
    // while the device was still waiting to be signed.
    final result = await Result.guard(() async {
      final String txBase64;
      if (current.token == null) {
        debugPrint('[SendBloc] building SOL transfer tx');
        final lamports = TokenAmount.solToLamports(current.amountString);
        txBase64 = await _rpcService.buildSolTransferTx(
          destination: current.recipient,
          lamports: TokenAmount.toInt(lamports),
          // A Max was priced as `balance − fee` against this exact prefix, so
          // the transfer has to carry it. Re-probing here would re-price the
          // fee under an amount that can no longer absorb the difference.
          pinnedBudget: isSolMaxAmount(current.amountString, current.recipient)
              ? _solMaxBudget
              : null,
        );
      } else {
        debugPrint('[SendBloc] building SPL transfer tx');
        final rawAmount = TokenAmount.parseTokenAmount(
          current.amountString,
          current.token!.decimals,
        );
        txBase64 = await _rpcService.buildSplTransferTx(
          destination: current.recipient,
          tokenMint: current.token!.mint,
          amount: TokenAmount.toInt(rawAmount),
        );
      }
      final execResult = await _executor.execute(
        txsBase64: [txBase64],
        usdValue: 0.0,
        flow: _sendFlow(Chain.solana, current.token),
        onStage: (e) {
          switch (e.stage) {
            case ExecutorStage.awaitingApproval:
              emit(SendState.signing(isLocal: isLocal));
            case ExecutorStage.ledgerAwaitingDevice:
              emit(const SendState.signing(onLedger: true));
            case ExecutorStage.broadcasting:
              emit(const SendState.broadcasting());
          }
        },
      );
      return switch (execResult) {
        ResultSuccess(:final value) => value,
        ResultFailure(:final error) => throw error,
      };
    });

    switch (result) {
      case ResultSuccess(:final value):
        // Fire-and-forget — never block the success emit on cache plumbing.
        // The updater swallows its own errors and signals TokenBalanceBloc
        // to refresh from the freshly-mutated cache.
        unawaited(_applyOptimisticDeltas(current));
        _trackSendCompleted(
          current.token,
          signature: value,
          usdValue: usdOutflow,
        );
        // Publish the row locally before asking the server for a refresh. The
        // indexer can lag a confirmed transaction, so a refresh signal alone
        // would leave the activity sheet empty until the next open.
        _publishOptimisticSend(current, Chain.solana, value);
        emit(
          SendState.success(
            signature: value,
            explorerUrl: buildExplorerUrlFromPrefs(value),
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[SendBloc] _onExecute caught: ${error.message}');
        _trackSendFailed(current.token, error);
        // A kill can also arrive here, from the executor's own backstop
        // rather than the gate above — the surface must present it as a kill
        // either way.
        if (error.isFlowDisabled) _killFailure = error;
        // Cancel and other failures render the same message verbatim —
        // matches the prior behaviour but goes through [AppFailure] so
        // future Result-aware UI can branch on `isCancelled`.
        //
        // An unconfirmed broadcast is neither success nor failure: it is
        // surfaced as an error state (never as success) but flagged
        // so the pipeline drops the retry affordance.
        emit(
          SendState.error(
            message: error.message,
            previousState: previousInput(),
            unconfirmed: error.cause is SolanaTransactionUnconfirmedException,
          ),
        );
    }
  }

  /// Tezos execute: biometric gate → forge → sign → inject → confirm, via
  /// [TezosTransferService]. Native XTZ and FA1.2/FA2 tokens; the Solana
  /// executor is untouched.
  Future<void> _executeTezos(SendReady current, Emitter<SendState> emit) async {
    final walletId = _walletId;
    final source = _sourceAddress;

    SendInput previousInput() => SendInput(
      recipient: current.recipient,
      amount: current.amountString,
      token: current.token,
    );

    if (walletId == null || source == null) {
      emit(
        SendState.error(
          message: 'No Tezos wallet available to send from',
          previousState: previousInput(),
        ),
      );
      return;
    }

    // The XTZ price isn't reliably cached under the native sentinel, so the
    // auth gate receives a null USD outflow and fail-closes — every Tezos send
    // requires biometric auth, which is the safe default. An FA2
    // token the balance feed affirmatively prices at $0 is the one exception:
    // it is known worthless, so it passes $0 instead of "unknown".
    final outcome = await _authGate.authorize(
      usdValue: current.token?.hasKnownZeroValue == true ? 0 : null,
      flow: _sendFlow(Chain.tezos, current.token),
    );
    final disabledMessage = outcome.disabledMessage;
    if (disabledMessage != null) {
      // Killed cell, not a user cancel.
      _emitFlowDisabled(emit, disabledMessage, previousInput());
      return;
    }
    if (outcome != TransactionAuthOutcome.allowed) {
      emit(
        SendState.error(
          message: TransactionAuthCancelledException(outcome).toString(),
          previousState: previousInput(),
        ),
      );
      return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    emit(SendState.signing(isLocal: isLocal));

    final result = await Result.guard(() async {
      final token = current.token;
      if (token != null && !token.isNative) {
        return _tezos.sendTokenTransfer(
          walletId: walletId,
          source: source,
          destination: current.recipient,
          token: _requireTezosToken(token),
          amountRaw: TokenAmount.parseTokenAmount(
            current.amountString,
            token.decimals,
          ),
          onBroadcasting: () => emit(const SendState.broadcasting()),
        );
      }
      final amountMutez = TokenAmount.parseTokenAmount(
        current.amountString,
        _xtzDecimals,
      );
      return _tezos.sendNativeTransfer(
        walletId: walletId,
        source: source,
        destination: current.recipient,
        amountMutez: amountMutez,
        onBroadcasting: () => emit(const SendState.broadcasting()),
      );
    });

    switch (result) {
      case ResultSuccess(:final value):
        // Fire-and-forget, as on the Solana path — never block the success
        // emit on cache plumbing. Without it nothing re-read the Tezos cache
        // after a confirmed send, so the tokens tab and the XTZ detail sheet
        // both sat on the pre-send balance until a pull-to-refresh.
        //
        // Safe to refresh here only because [sendNativeTransfer] now throws
        // rather than returning on an inclusion timeout: refetching against a
        // still-in-flight operation would write the pre-send balance back.
        unawaited(
          BalanceOptimisticUpdater.recordNonSolanaTransfer(
            chain: Chain.tezos,
            senderAddress: source,
            recipientAddress: current.recipient,
          ),
        );
        _trackSendCompleted(current.token, signature: value);
        // The indexer can lag a confirmed transaction, so publish the row
        // locally before the activity refresh waits for the server.
        _publishOptimisticSend(current, Chain.tezos, value);
        emit(
          SendState.success(
            signature: value,
            explorerUrl: buildTxExplorerUrlForChain(value, Chain.tezos),
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[SendBloc] _executeTezos caught: ${error.message}');
        _trackSendFailed(current.token, error);
        if (error.isFlowDisabled) _killFailure = error; // As above.
        // An injected-but-unobserved operation lands here rather than in the
        // success branch. Flag it so the pipeline drops the retry
        // affordance — re-injecting an in-flight XTZ transfer sends twice.
        emit(
          SendState.error(
            message: error.message,
            previousState: previousInput(),
            unconfirmed: error.isUnconfirmed,
          ),
        );
    }
  }

  /// Ethereum execute: biometric gate → build → sign → broadcast → confirm, via
  /// [EthereumTransferService]. Native ETH and ERC-20; the Solana executor is
  /// untouched.
  Future<void> _executeEthereum(
    SendReady current,
    Emitter<SendState> emit,
  ) async {
    final walletId = _walletId;
    final source = _sourceAddress;

    SendInput previousInput() => SendInput(
      recipient: current.recipient,
      amount: current.amountString,
      token: current.token,
    );

    if (walletId == null || source == null) {
      emit(
        SendState.error(
          message: 'No Ethereum wallet available to send from',
          previousState: previousInput(),
        ),
      );
      return;
    }

    // The ETH/ERC-20 price isn't reliably cached, so the auth gate receives a
    // null USD outflow and fail-closes — every Ethereum send requires biometric
    // auth, which is the safe default. An ERC-20 the balance feed
    // affirmatively prices at $0 is the one exception: it is known worthless,
    // so it passes $0 instead of "unknown".
    final outcome = await _authGate.authorize(
      usdValue: current.token?.hasKnownZeroValue == true ? 0 : null,
      flow: _sendFlow(Chain.ethereum, current.token),
    );
    final disabledMessage = outcome.disabledMessage;
    if (disabledMessage != null) {
      // Killed cell, not a user cancel.
      _emitFlowDisabled(emit, disabledMessage, previousInput());
      return;
    }
    if (outcome != TransactionAuthOutcome.allowed) {
      emit(
        SendState.error(
          message: TransactionAuthCancelledException(outcome).toString(),
          previousState: previousInput(),
        ),
      );
      return;
    }

    final isLocal = await _walletManager.isLocalSigner();
    emit(SendState.signing(isLocal: isLocal));

    final result = await Result.guard(() async {
      final decimals = current.token?.decimals ?? _ethDecimals;
      final amountRaw = TokenAmount.parseTokenAmount(
        current.amountString,
        decimals,
      );
      // Sign the transfer the review step's safety gate validated only when the
      // cache still matches the live ready state (same recipient + raw amount).
      // A null cache (a restored ready state) or any mismatch (a stale prepared
      // left by a superseded review) re-prepares now — re-running the gate
      // against current chain state — so the signed tx always matches what the
      // confirm screen shows, and an unvalidated or stale tx is never signed.
      var prepared = _ethPrepared;
      if (prepared == null ||
          _ethPreparedRecipient != current.recipient ||
          _ethPreparedAmountRaw != amountRaw) {
        prepared = await _ethereum.prepare(
          walletId: walletId,
          source: source,
          destination: current.recipient,
          amountRaw: amountRaw,
          token: current.token,
        );
      }
      return _ethereum.execute(
        prepared,
        feeOverride: current.ethGasSelection,
        onBroadcasting: () => emit(const SendState.broadcasting()),
        // Only now may the pipeline offer its early exit — the tracker owns the
        // nonce, so a later inclusion-wait timeout can no longer lose the tx.
        // Taking that exit closes this bloc, which is why the funnel's claim on
        // the outcome is held here rather than left to the funnel alone.
        onBroadcastRegistered: (claim) {
          // The Ethereum pipeline may be dismissed while the inclusion wait is
          // still running. In that case this bloc is closed before it can emit
          // SendSuccess, and the sheet's success listener cannot persist the
          // recipient. The broadcast has already been accepted and handed to
          // the pending tracker here, so record the address at this boundary.
          // The success listener remains as a fallback for mocked/restored
          // flows that reach success without this callback.
          unawaited(_prefs.saveRecentSendAddress(current.recipient));
          _resolutionClaim = claim;
          emit(const SendState.broadcasting(pendingRegistered: true));
        },
      );
    });

    // The user may have taken the pipeline's early exit while the inclusion wait
    // ran, which tears down the sheet and closes this bloc. Emitting into it
    // then throws, and there is nothing left to show the state to; the tracker
    // already owns the transaction.
    if (isClosed) return;

    switch (result) {
      case ResultSuccess(:final value):
        // No balance refresh here, unlike the Tezos path above: success on this
        // branch does *not* mean the transaction landed. The EVM funnel returns
        // the hash normally on an inclusion-wait timeout (the tx is still in the
        // mempool), so refetching now would write the pre-send balance back into
        // the cache and signal it as post-send. `PendingEvmTxTracker` owns the
        // refresh instead — it only resolves a slot against a receipt, and the
        // inclusion case reaches it in this same turn via the claim's
        // `reported()` → `refreshNow()`.
        _trackSendCompleted(current.token, signature: value);
        // The pending tracker owns eventual confirmation, but the activity
        // sheet should still show the send immediately after this flow reports
        // success while the server/indexer catches up.
        _publishOptimisticSend(current, Chain.ethereum, value);
        emit(
          SendState.success(
            signature: value,
            explorerUrl: buildTxExplorerUrlForChain(value, Chain.ethereum),
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[SendBloc] _executeEthereum caught: ${error.message}');
        _trackSendFailed(current.token, error);
        if (error.isFlowDisabled) _killFailure = error; // As above.
        emit(
          SendState.error(
            message: error.message,
            previousState: previousInput(),
          ),
        );
    }
  }

  void _onReset(SendReset event, Emitter<SendState> emit) {
    final current = state;
    // The error it described is being dismissed — a later, unrelated error must
    // not inherit it.
    _killFailure = null;
    // Dismissing the confirm sheet abandons the reviewed transfer — drop the
    // cached prepared so a later execute can never sign it against a since-edited
    // state; a fresh review re-prepares.
    _clearEthPrepared();
    // Dispatched when the confirmation sheet is dismissed. The screen's text
    // controllers still hold the typed recipient/amount, so preserve them in
    // the bloc state too — otherwise re-tapping Review proceeds with empty
    // values and simulation fails decoding the recipient pubkey.
    if (current is SendReady) {
      emit(
        SendState.input(
          recipient: current.recipient,
          amount: current.amountString,
          token: current.token,
          // Preserve the most recent rent estimate so the screen's
          // Estimated Fee pill reflects what was shown on Review without a
          // re-fetch on every sheet dismissal.
          ataRentLamports: current.ataRentLamports,
          estimatedFeeLamports: current.estimatedFeeLamports,
        ),
      );
      return;
    }
    if (current is SendError && current.previousState != null) {
      emit(current.previousState!);
      return;
    }
    emit(const SendState.input());
  }

  Future<void> _onSimulate(SendSimulate event, Emitter<SendState> emit) async {
    final current = state;
    if (current is! SendReady) return;
    // Tezos/Ethereum fees are computed at review; there is no separate
    // Solana-style balance-delta simulation step for those chains.
    if (_isTezos || _isEthereum) return;

    emit(
      current.copyWith(
        isSimulating: true,
        simulationResult: null,
        simulatedNetSolLamports: null,
      ),
    );

    try {
      final sourceAddress = await _walletManager.getAddress();
      final sourceKey = Ed25519HDPublicKey.fromBase58(sourceAddress);
      final destinationKey = Ed25519HDPublicKey.fromBase58(current.recipient);

      Message message;
      if (current.token == null) {
        // SOL transfer
        final lamports = TokenAmount.solToLamports(current.amountString);
        final instruction = SystemInstruction.transfer(
          fundingAccount: sourceKey,
          recipientAccount: destinationKey,
          lamports: TokenAmount.toInt(lamports),
        );
        // A Max is priced to leave the account at exactly zero, and that only
        // holds for the fee its pinned prefix bids. Simulating the bare
        // transfer would charge the base fee alone and leave the priority fee
        // behind as dust — which the runtime rejects as rent-paying, turning
        // every Max into a spurious "simulation failed" banner and a fee
        // display that falls back to the base fee.
        final pinned = isSolMaxAmount(current.amountString, current.recipient)
            ? _solMaxBudget
            : null;
        message = pinned == null
            ? Message.only(instruction)
            : Message(instructions: [...pinned.instructions, instruction]);
      } else {
        // SPL / SPL-2022 token transfer — source account and its owning token
        // program come from one live [findOwnedTokenAccount] read, mirroring the
        // execution path in [SolanaRpcService.buildSplTransferTx]. The wallet
        // may hold an auxiliary (non-ATA) account, so we spend from
        // `holding.address`; the destination ATA and transfer ix use
        // `holding.program`. A resolution failure propagates into the enclosing
        // catch as a failed simulation rather than silently guessing classic
        // SPL and simulating a wrong-program transaction.
        final mintKey = Ed25519HDPublicKey.fromBase58(current.token!.mint);
        final holding = await _rpcService.requireOwnedTokenAccount(
          owner: sourceAddress,
          mint: current.token!.mint,
        );
        final programType = holding.program;
        final sourceAta = Ed25519HDPublicKey.fromBase58(holding.address);
        final destinationAta = await findAssociatedTokenAddress(
          owner: destinationKey,
          mint: mintKey,
          tokenProgramType: programType,
        );

        final instructions = <Instruction>[];

        // Check if destination ATA exists. base64 encoding is required: the
        // RPC default (base58) rejects account data over 128 bytes, and a
        // token account is 165, so an existing ATA would fail the fetch.
        final destAtaInfo = await _rpcService.getAccountInfo(
          destinationAta.toBase58(),
          encoding: Encoding.base64,
        );
        if (destAtaInfo.value == null) {
          instructions.add(
            AssociatedTokenAccountInstruction.createAccount(
              funder: sourceKey,
              address: destinationAta,
              owner: destinationKey,
              mint: mintKey,
              tokenProgramId: programType.id,
            ),
          );
        }

        final rawAmount = TokenAmount.parseTokenAmount(
          current.amountString,
          current.token!.decimals,
        );
        instructions.add(
          TokenInstruction.transfer(
            source: sourceAta,
            destination: destinationAta,
            owner: sourceKey,
            amount: TokenAmount.toInt(rawAmount),
            tokenProgram: programType,
          ),
        );

        message = Message(instructions: instructions);
      }

      // Snapshot pre-balance and simulate so we can derive the actual SOL the
      // user spends (validator fee + ATA rent + transferred SOL for native
      // sends). `lamportsDelta` is post−pre; negate for spend (pre−post).
      final sim = await _rpcService.simulateWithDelta(
        address: sourceAddress,
        simulate: (inspect) =>
            _rpcService.simulateMessage(message, inspectAccounts: inspect),
        // Send treats a pre-balance fetch failure as a failed simulation
        // (prior behavior) rather than degrading to a null delta.
        requirePreBalance: true,
      );
      final netSol = sim.lamportsDelta == null ? null : -sim.lamportsDelta!;

      emit(
        current.copyWith(
          isSimulating: false,
          simulationResult: sim.result,
          simulatedNetSolLamports: netSol,
        ),
      );
    } catch (e) {
      emit(
        current.copyWith(
          isSimulating: false,
          simulationResult: SimulationResult(
            success: false,
            error: 'Simulation failed: $e',
          ),
        ),
      );
    }
  }

  /// Makes a local activity row for a successful send, then asks the activity
  /// sheet to refresh against the server. The row is also written to the
  /// activity cache so opening the sheet after the send still shows it before
  /// the indexer has caught up.
  void _publishOptimisticSend(SendReady ready, Chain chain, String signature) {
    final token = ready.token ?? TokenBalance.nativeForChain(chain);
    final activity = api.Activity(
      id: signature,
      type: api.ActivityType.send,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      signature: signature,
      status: api.ActivityStatus.confirmed,
      data: {
        'token': {
          'mint': token.mint,
          'symbol': token.symbol,
          'amount': ready.amount,
          'decimals': token.decimals,
          if (token.logoUrl?.isNotEmpty == true) 'logoUrl': token.logoUrl,
        },
        'counterparty': {'address': ready.recipient},
        'isNft': false,
        'transferDirection': 'out',
      },
    );

    final repository = sl.isRegistered<ActivityRepository>()
        ? sl<ActivityRepository>()
        : null;
    if (repository != null) {
      final addresses = sl.isRegistered<SessionManager>()
          ? sl<SessionManager>().apiOwnerAddresses
          : [?_sourceAddress];
      if (addresses.isNotEmpty) {
        unawaited(
          repository.cacheOptimisticActivity(
            addresses: addresses,
            activity: activity,
          ),
        );
      }
    }

    notifyActivityRefresh(optimisticActivity: activity);
  }

  /// Best-effort optimistic balance update after a confirmed transfer.
  /// Prefers the simulated post-balance lamport delta (exact) and falls
  /// back to `estimatedFeeLamports` when simulation didn't run.
  Future<void> _applyOptimisticDeltas(SendReady ready) async {
    try {
      final sender = await _walletManager.getAddress();
      if (ready.token == null) {
        final amountLamports = TokenAmount.toInt(
          TokenAmount.solToLamports(ready.amountString),
        );
        final totalOut =
            ready.simulatedNetSolLamports ??
            (amountLamports + ready.estimatedFeeLamports);
        await BalanceOptimisticUpdater.recordTransfer(
          senderAddress: sender,
          recipientAddress: ready.recipient,
          token: null,
          amountLamports: amountLamports,
          solTotalOutLamports: totalOut,
        );
      } else {
        final rawAmount = TokenAmount.toInt(
          TokenAmount.parseTokenAmount(
            ready.amountString,
            ready.token!.decimals,
          ),
        );
        final feeLamports =
            ready.simulatedNetSolLamports ?? ready.estimatedFeeLamports;
        await BalanceOptimisticUpdater.recordTransfer(
          senderAddress: sender,
          recipientAddress: ready.recipient,
          token: ready.token,
          amountRaw: rawAmount,
          solFeeLamports: feeLamports,
        );
      }
    } catch (e) {
      debugPrint('[SendBloc] optimistic delta skipped: $e');
    }
  }

  // ── Analytics ──────────────────────────────────────────────────────────────

  /// Fire `Send Completed` at a confirmed on-chain broadcast. [signature] is
  /// the tx id/hash the flow broadcast; [usdValue] is the priced outflow when
  /// cached (Solana), else null. No PII — only chain, asset kind, usd, and the
  /// token symbol ride along.
  void _trackSendCompleted(
    TokenBalance? token, {
    required String signature,
    double? usdValue,
  }) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().trackTransaction(
        AnalyticsEvent.sendCompleted,
        txType: TxType.send,
        signature: signature,
        properties: {
          AnalyticsProp.chain: _analyticsChain.wire,
          AnalyticsProp.assetKind: _assetKind(token).wire,
          AnalyticsProp.usdValue: usdValue,
          if (token != null) AnalyticsProp.symbol: token.symbol,
        },
        entryPoint: EntryPoint.sendButton,
      ),
    );
  }

  /// Fire `Send Failed` for a broadcast/execution failure only (called from the
  /// execute-path failure branches, never from input validation).
  void _trackSendFailed(TokenBalance? token, AppFailure error) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    // A kill-switch stop is not a send failure: it
    // has its own `flow_disabled_hit`, emitted where it is presented, and
    // recording it here would bucket an operator action into the failure
    // taxonomy (as `unknown`) and corrupt the rate.
    if (error.isFlowDisabled) return;
    unawaited(
      sl<AnalyticsService>().trackTransaction(
        AnalyticsEvent.sendFailed,
        txType: TxType.send,
        // Nothing landed on-chain: these branches are reached from a build,
        // sign or broadcast failure, so there is no signature to attach.
        isOnchainTx: false,
        properties: {
          AnalyticsProp.chain: _analyticsChain.wire,
          AnalyticsProp.assetKind: _assetKind(token).wire,
          AnalyticsProp.reason: FailureReason.fromAppFailureKind(
            error.kind,
          ).wire,
        },
        entryPoint: EntryPoint.sendButton,
      ),
    );
  }

  AnalyticsChain get _analyticsChain => switch (_chain) {
    Chain.solana => AnalyticsChain.solana,
    Chain.ethereum => AnalyticsChain.ethereum,
    Chain.tezos => AnalyticsChain.tezos,
  };

  /// Native (null token) → the chain's coin; a token → the chain's fungible
  /// kind.
  AssetKind _assetKind(TokenBalance? token) {
    if (token == null) {
      return switch (_chain) {
        Chain.solana => AssetKind.sol,
        Chain.ethereum => AssetKind.eth,
        Chain.tezos => AssetKind.xtz,
      };
    }
    return switch (_chain) {
      Chain.solana => AssetKind.splToken,
      Chain.ethereum => AssetKind.evmToken,
      Chain.tezos => AssetKind.faToken,
    };
  }

  String? _validateAddress(String address) {
    if (address.isEmpty) return null;
    if (_isTezos) {
      return isValidTezosAddress(address) ? null : 'Invalid Tezos address';
    }
    if (_isEthereum) {
      // Checksum-aware (EIP-55), not just `0x` + 40 hex: this is the only
      // recipient guard on the ETH path — the calldata assertion compares the
      // backend's calldata against this same string and the Alchemy simulation
      // only checks the amount, so a mistyped character reaches the chain.
      return evmRecipientError(address);
    }
    if (!SecurityUtils.isValidSolanaAddress(address)) {
      return 'Invalid Solana address';
    }
    return null;
  }

  /// Amount-field guard. Returns null when the amount is acceptable *or* when
  /// the balance it would be checked against isn't known yet — an advisory
  /// check must never false-disable a legitimate send.
  ///
  /// A [token] is checked against its cached balance. A null [token] is the
  /// chain's native coin, and only Solana is guarded here: the native ETH and
  /// XTZ balances live in their transfer services and are checked at review.
  /// Before this existed the native branch's max was `double.infinity`, so
  /// overspending SOL sailed through the form and surfaced as a snackbar on
  /// the confirm sheet — after the user had committed to the amount.
  String? _validateAmount(String amount, TokenBalance? token) {
    if (amount.isEmpty) return null;
    final value = double.tryParse(amount);
    if (value == null || value <= 0) {
      return 'Enter a valid amount';
    }
    if (token != null) {
      return value > token.uiBalance ? 'Insufficient balance' : null;
    }
    if (_chain != Chain.solana) return null;
    final lamports = _solLamports;
    if (lamports == null) return null;
    if (value > lamports / 1e9) return 'Insufficient balance';
    // The Max amount is `balance − exact fee`, priced by [_solMaxSendable] and
    // signed against the plan that priced it. It leaves the account at zero,
    // which the runtime allows, and it necessarily sits above the partial-send
    // ceiling below — so it has to be recognised here or the guard would flag
    // the one amount the Max button just offered.
    if (_isPinnedSolMax(amount)) return null;
    // Any *partial* send has to leave the account rent-exempt: the runtime
    // rejects a residue between 1 lamport and the rent-exempt minimum outright
    // (`InsufficientFundsForRent`), and it does so at preflight, after signing.
    // So the field, not the chain, is where that has to be said.
    final spendable =
        lamports - worstCaseSolTxFeeLamports - kSolRentExemptMinimumLamports;
    if (value > (spendable > 0 ? spendable : 0) / 1e9) {
      return 'Send the max, or leave 0.0009 SOL for fees and rent';
    }
    return null;
  }

  /// Hand any still-held resolution claim back to the tracker.
  ///
  /// This bloc closing while a claim is held means the user took the pipeline's
  /// "Done" early exit: the success step will never render, so the tracker's
  /// app-wide toast is the only report of the outcome the user can get. A claim
  /// the funnel already reported through is gone by now, so a completed send
  /// passes through here without resurrecting its toast.
  @override
  Future<void> close() {
    _resolutionClaim?.release();
    _resolutionClaim = null;
    return super.close();
  }
}
