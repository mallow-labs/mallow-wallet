import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/dto.dart' show Encoding;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../../core/config/environment.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/das_api_service.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/security_utils.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_executor.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../send/models/eth_gas.dart';
import '../models/on_chain_asset.dart';
import 'evm_artwork_transfer_service.dart';

part 'transfer_artwork_bloc.freezed.dart';

const _logTag = 'TransferArtworkBloc';

String _scrubEvmError(Object error) => error
    .toString()
    .replaceAll(RegExp(r'0x[a-fA-F0-9]{64,}'), '0x<hex>')
    .replaceAll(RegExp(r'0x[a-fA-F0-9]{40}'), '0x<address>');

@freezed
sealed class TransferArtworkEvent with _$TransferArtworkEvent {
  /// Kicks off the flow for [mintAccount]: resolves the on-chain token
  /// standard so unsupported types can be flagged before the user types a
  /// recipient. [chain] and [tokenStandard] (wire values, when known from the
  /// artwork model) let an EVM asset take the ERC-721/1155 path without a
  /// Solana-only DAS lookup. [evmHolder] is the EVM asset's on-chain owner —
  /// threaded to the transfer service so a non-active ETH holder signs with its
  /// own key (Solana ignores it and signs with the active wallet).
  /// [artworkName] / [imageUrl] are display-only: they ride into the EVM
  /// transfer's pending-transaction record so the Pending cell shows the
  /// artwork's title and thumbnail while the transfer is unconfirmed.
  const factory TransferArtworkEvent.started(
    String mintAccount, {
    String? chain,
    String? tokenStandard,
    String? evmHolder,
    String? artworkName,
    String? imageUrl,
  }) = TransferStarted;
  const factory TransferArtworkEvent.recipientChanged(String address) =
      TransferRecipientChanged;

  /// Sets the ERC-1155 transfer quantity (clamped to the owned balance).
  const factory TransferArtworkEvent.quantityChanged(int quantity) =
      TransferQuantityChanged;
  const factory TransferArtworkEvent.proceed() = TransferProceed;
  const factory TransferArtworkEvent.simulate() = TransferSimulate;

  /// Applies the fee the user picked on the Edit Gas Fee sheet (EVM only). The
  /// safety gate is fee-independent, so this re-points the in-flight fee display
  /// and the broadcast without re-simulating.
  const factory TransferArtworkEvent.setEthGasSelection(
    EthGasSelection selection,
  ) = TransferSetEthGasSelection;
  const factory TransferArtworkEvent.execute() = TransferExecute;
  const factory TransferArtworkEvent.reset() = TransferReset;
}

@freezed
sealed class TransferArtworkState with _$TransferArtworkState {
  const TransferArtworkState._();

  /// Recipient-entry stage. [isCheckingStandard] is true while the DAS
  /// lookup is in flight; [unsupportedReason] is non-null when the artwork's
  /// token standard can't be transferred (nft/pNFT/Core/cNFT/core-collection
  /// are supported — see [TransferArtworkBloc]). [advisoryNotice] is a
  /// non-blocking caution shown for consequential-but-allowed transfers (e.g. a
  /// collection hands over its update authority); it does not gate [canProceed].
  const factory TransferArtworkState.input({
    @Default('') String recipient,
    String? recipientError,
    @Default(true) bool isCheckingStandard,
    String? unsupportedReason,
    String? advisoryNotice,
    // EVM (erc721/erc1155): [isEvm] switches recipient validation + UI to
    // Ethereum; [maxQuantity] is the owned ERC-1155 balance (null for 721);
    // [quantity] is the chosen number of copies to send.
    @Default(false) bool isEvm,
    @Default(1) int quantity,
    int? maxQuantity,
  }) = TransferInput;

  /// Confirm stage. [simulatedNetSolLamports] is the total SOL the wallet
  /// spends on the transfer (validator fee + any destination-ATA rent),
  /// derived from a transaction simulation — this is the displayed network
  /// fee. Null while [isSimulating] or when simulation failed. For EVM
  /// transfers the network fee is [simulatedFeeWei] instead (ETH), and
  /// [recipientIsContract] flags a non-EOA recipient.
  const factory TransferArtworkState.ready({
    required String recipient,
    @Default(false) bool isSimulating,
    SimulationResult? simulationResult,
    int? simulatedNetSolLamports,
    @Default(false) bool isEvm,
    @Default(1) int quantity,
    BigInt? simulatedFeeWei,
    @Default(false) bool recipientIsContract,
    // EVM gas settings, mirroring the send flow: [ethGasMarket] is the live
    // fee market backing the Edit Gas Fee sheet (null → read-only default fee,
    // no Edit affordance); [ethGasSelection] is the tier/custom fee in effect,
    // driving [simulatedFeeWei] and signed at broadcast. [ethEstimatedGasUsed]
    // (raw gas) and [ethDefaultGasLimit] (padded) seed the Edit Gas Fee sheet.
    EthGasMarket? ethGasMarket,
    EthGasSelection? ethGasSelection,
    BigInt? ethEstimatedGasUsed,
    int? ethDefaultGasLimit,
  }) = TransferReady;

  const factory TransferArtworkState.signing() = TransferSigning;

  /// [pendingRegistered] is true once an EVM broadcast has been accepted by
  /// the node and handed to [PendingEvmTxTracker]. Until then the transfer can
  /// still fail without a pending row, so the pipeline must stay open to show
  /// that failure. Solana transfers never set it.
  const factory TransferArtworkState.broadcasting({
    @Default(false) bool pendingRegistered,
  }) = TransferBroadcasting;

  const factory TransferArtworkState.success({
    required String signature,
    required String explorerUrl,
  }) = TransferSuccess;

  /// [failure] is the classified failure behind [message], carried so the UI
  /// can tell a remote kill from an ordinary transfer error and present the
  /// operator's copy instead of a snackbar / the pipeline's generic "Transfer
  /// failed" body. Null for client-side
  /// validation errors emitted without an [AppFailure]; [message] stays the
  /// single source of display copy either way.
  const factory TransferArtworkState.error({
    required String message,
    String? previousRecipient,
    AppFailure? failure,
  }) = TransferError;

  /// True when the input stage is complete enough to advance to confirm.
  bool get canProceed => maybeMap(
    input: (s) =>
        s.recipient.isNotEmpty &&
        s.recipientError == null &&
        s.unsupportedReason == null &&
        !s.isCheckingStandard,
    orElse: () => false,
  );
}

/// The kill-switch cell an NFT transfer of this artwork belongs to.
///
/// An explicit **3-way** switch, never an `isEvm ? ethereum : solana` ternary:
/// Tezos is a first-class wallet chain and the transfer chooser lists `byOwner`
/// results with no chain filter, so a Tezos NFT does reach this flow. Folding it
/// onto `solana:nft-transfer` both masked the unimplemented-cell backstop
/// (`AppFlow.nftTransfer.chains` deliberately excludes Tezos, but the Solana
/// cell *is* implemented) and let a Solana kill collaterally block Tezos.
///
/// Shared by the entry gate in `transfer_artwork_flow.dart` and the signing
/// backstop below so both read the same cell.
///
/// [chain] is the artwork model's raw wire chain value (`Chain.toDbString()`),
/// null when the model didn't carry one and unparseable when the server names a
/// chain the app doesn't model — the mint-account shape is the only signal in
/// both cases.
FlowKey nftTransferFlowKey({required String mintAccount, String? chain}) {
  if (isEthereumArtwork(mintAccount: mintAccount, chain: chain)) {
    return const FlowKey(Chain.ethereum, AppFlow.nftTransfer);
  }
  if (Chain.tryParse(chain) == Chain.tezos || isTezosAsset(mintAccount)) {
    // Not in `AppFlow.nftTransfer.chains` → the gate reports to Sentry and
    // rejects with clear copy instead of dying in Solana fee simulation.
    return const FlowKey(Chain.tezos, AppFlow.nftTransfer);
  }
  return const FlowKey.solana(AppFlow.nftTransfer);
}

/// Drives the artwork-transfer flow: recipient validation, fee simulation and
/// the on-chain transfer.
///
/// The build path is per-standard:
///
///  * **Legacy Metaplex NFT** (`TokenStandard.nft`) — built **client-side** via
///    the same proven SPL-transfer path the Send flow uses
///    (`SolanaRpcService.buildSplTransferTx`).
///  * **pNFT / Core / cNFT** — built **server-side** by
///    `POST /v2/tx/assets/transfer` (mirrors the burn route; auth-rules /
///    mpl-core / Bubblegum are resolved on the backend). The route returns a
///    base64 unsigned tx the wallet signs.
///
/// Any other standard (e.g. Core *collections*) is flagged as unsupported up
/// front. The simulation is also a safety net: an unbuildable transfer fails to
/// simulate, so a broken transfer can never be broadcast.
@injectable
class TransferArtworkBloc
    extends Bloc<TransferArtworkEvent, TransferArtworkState> {
  TransferArtworkBloc(
    this._rpcService,
    this._walletManager,
    this._dasApi,
    this._priceService,
    this._executor,
    this._apiV2,
    this._evmService,
    this._prefs,
  ) : super(const TransferArtworkState.input()) {
    on<TransferStarted>(_onStarted);
    on<TransferRecipientChanged>(_onRecipientChanged);
    on<TransferQuantityChanged>(_onQuantityChanged);
    on<TransferProceed>(_onProceed);
    on<TransferSimulate>(_onSimulate);
    on<TransferSetEthGasSelection>(_onSetEthGasSelection);
    on<TransferExecute>(_onExecute);
    on<TransferReset>(_onReset);
  }

  final SolanaRpcService _rpcService;
  final WalletManager _walletManager;
  final DasApiService _dasApi;
  final TokenPriceService _priceService;
  final TransactionExecutor _executor;
  final MallowApiV2Client _apiV2;
  final EvmArtworkTransferService _evmService;
  final PreferencesService _prefs;

  /// Standards this flow can transfer. Legacy `nft` builds client-side; the
  /// rest go through the backend transfer route. A `coreCollection` "transfer"
  /// is really an update-authority reassignment (the backend builds it with
  /// `UpdateCollectionV1`); remaining standards are flagged unsupported in
  /// [_onStarted].
  static const _supportedStandards = {
    TokenStandard.nft,
    TokenStandard.pnft,
    TokenStandard.core,
    TokenStandard.cnft,
    TokenStandard.coreCollection,
  };

  String? _mint;

  /// The artwork's wire chain value from [TransferStarted], kept so the signing
  /// backstop resolves the same cell the entry gate did (see
  /// [nftTransferFlowKey]).
  String? _chain;

  String? _unsupportedReason;

  /// Non-blocking caution surfaced in the input stage for a supported-but-
  /// consequential transfer. Set for `coreCollection`, whose "transfer" is an
  /// update-authority reassignment rather than an ownership move.
  String? _advisoryNotice;

  /// Token standard resolved by the DAS lookup in [_onStarted]; `null` when the
  /// lookup failed (we then optimistically take the legacy client-side path and
  /// let simulation gate a broken transfer).
  TokenStandard? _tokenStandard;

  // ── EVM (erc721/erc1155) state ──────────────────────────────────────────
  bool _isEvm = false;
  TokenStandard? _evmStandard;
  String? _evmContract;
  String? _evmTokenId;

  /// The EVM asset's on-chain owner — the specific ETH wallet the transfer must
  /// be prepared + signed by (may not be the active ETH wallet). Null resolves
  /// to the active wallet in the service (backward compatible).
  String? _evmHolder;

  /// Display-only artwork title + image, forwarded to the pending-transaction
  /// record so the Pending cell can name and picture the in-flight transfer.
  String? _artworkName;
  String? _imageUrl;
  int _maxQuantity = 1;
  int _quantity = 1;

  /// Validated, ready-to-sign EVM transfer cached between simulate and execute,
  /// together with the recipient + quantity it was prepared for. The execute
  /// step refuses to sign when the cache no longer matches the live
  /// [TransferReady] — so a stale prepared left by a superseded review can never
  /// be signed while the confirm screen shows other values. Cleared on reset and
  /// on any blocking sim error (see [_clearEvmPrepared]). Mirrors [SendBloc]'s
  /// prepared-invalidation guard.
  PreparedEvmTransfer? _evmPrepared;
  String? _evmPreparedRecipient;
  int? _evmPreparedQuantity;

  /// Monotonic simulate-request id, bumped on every (re)simulate and on reset.
  /// A late-arriving simulate completion only commits its result — and its
  /// cached [_evmPrepared] — when its captured generation still matches, so a
  /// stale simulate for a superseded recipient/quantity can't stamp its
  /// fee/`recipientIsContract`/success onto a newer ready state.
  int _simGeneration = 0;

  /// Claim held while the EVM transfer waits for inclusion. If the user taps
  /// the pipeline's early "Done" action, closing this bloc releases the claim
  /// so the pending tracker can report the eventual outcome.
  PendingTxResolutionClaim? _resolutionClaim;

  /// Drop the cached prepared EVM transfer and the recipient/quantity it was
  /// built for. Called on reset and on any blocking sim error so the next
  /// execute can never sign a prepared the review has moved on from.
  void _clearEvmPrepared() {
    _evmPrepared = null;
    _evmPreparedRecipient = null;
    _evmPreparedQuantity = null;
  }

  /// True when the resolved standard must be built by the backend route rather
  /// than the client-side SPL path.
  bool get _useBackendBuilder =>
      _tokenStandard == TokenStandard.pnft ||
      _tokenStandard == TokenStandard.core ||
      _tokenStandard == TokenStandard.cnft ||
      _tokenStandard == TokenStandard.coreCollection;

  Future<void> _onStarted(
    TransferStarted event,
    Emitter<TransferArtworkState> emit,
  ) async {
    _mint = event.mintAccount;
    _chain = event.chain;
    emit(const TransferInput());

    // EVM asset (`<contract>-<tokenId>`, or chain hint from the artwork model)
    // takes the ERC-721/1155 path — no Solana DAS lookup.
    if (isEthereumArtwork(mintAccount: event.mintAccount, chain: event.chain)) {
      await _startEvm(event, emit);
      return;
    }

    // Resolve the token standard so non-legacy types are flagged before the
    // user invests effort entering a recipient. On a lookup failure we stay
    // optimistic — the fee simulation still gates a broken transfer.
    try {
      final asset = await _dasApi.getAsset(event.mintAccount);
      _tokenStandard = asset.tokenStandard;
      _unsupportedReason = _supportedStandards.contains(asset.tokenStandard)
          ? null
          : "This artwork type can't be transferred from the app yet.";
      _advisoryNotice = _advisoryNoticeFor(asset);
    } catch (_) {
      _tokenStandard = null;
      _unsupportedReason = null;
      _advisoryNotice = null;
    }

    final current = state;
    if (current is! TransferInput) return;
    emit(
      current.copyWith(
        isCheckingStandard: false,
        unsupportedReason: _unsupportedReason,
        advisoryNotice: _advisoryNotice,
      ),
    );
  }

  /// EVM entry path: resolve contract/tokenId/standard from the asset and, for
  /// ERC-1155, the owned balance that bounds the quantity picker. Unsupported
  /// EVM shapes (unknown standard) are flagged like the Solana path.
  Future<void> _startEvm(
    TransferStarted event,
    Emitter<TransferArtworkState> emit,
  ) async {
    _isEvm = true;
    _evmHolder = event.evmHolder;
    _artworkName = event.artworkName;
    _imageUrl = event.imageUrl;
    final parts = event.mintAccount.split('-');
    _evmContract = parts.isNotEmpty ? parts.first : null;
    _evmTokenId = parts.length > 1 ? parts[1] : null;
    _evmStandard = _tokenStandardFromWire(event.tokenStandard);

    final isSupported =
        _evmContract != null &&
        _evmTokenId != null &&
        (_evmStandard == TokenStandard.erc721 ||
            _evmStandard == TokenStandard.erc1155);
    if (!isSupported) {
      _unsupportedReason =
          "This artwork type can't be transferred from the app yet.";
      final current = state;
      if (current is! TransferInput) return;
      emit(
        current.copyWith(
          isCheckingStandard: false,
          isEvm: true,
          unsupportedReason: _unsupportedReason,
        ),
      );
      return;
    }

    // ERC-1155: the owned balance caps the quantity the user can send.
    if (_evmStandard == TokenStandard.erc1155) {
      try {
        final owned = await _evmService.ownedErc1155Amount(
          contract: _evmContract!,
          tokenId: BigInt.parse(_evmTokenId!),
          holder: _evmHolder,
        );
        if (owned <= BigInt.zero) {
          // The resolved source wallet holds zero copies of this token, so the
          // transfer can't succeed — the pre-sign simulation would hard-fail
          // ('did not show the artwork leaving your wallet'). Surface that up
          // front instead of clamping the picker to 1 and marching the user
          // into the dead end. (A read *failure* stays a soft fallback to 1
          // below — a transient RPC error must not block a real holder. This is
          // ERC-1155 only: ERC-721 tracks ownership per tokenId, not via a
          // balance count, so its else-branch never reads a balance.)
          _unsupportedReason =
              "This copy isn't held by a wallet you can transfer from.";
          final current = state;
          if (current is! TransferInput) return;
          emit(
            current.copyWith(
              isCheckingStandard: false,
              isEvm: true,
              unsupportedReason: _unsupportedReason,
            ),
          );
          return;
        }
        _maxQuantity = owned.toInt();
      } catch (_) {
        _maxQuantity = 1;
      }
    } else {
      _maxQuantity = 1;
    }
    _quantity = 1;

    final current = state;
    if (current is! TransferInput) return;
    emit(
      current.copyWith(
        isCheckingStandard: false,
        isEvm: true,
        quantity: _quantity,
        maxQuantity: _evmStandard == TokenStandard.erc1155
            ? _maxQuantity
            : null,
      ),
    );
  }

  static TokenStandard? _tokenStandardFromWire(String? wire) {
    if (wire == null) return null;
    for (final standard in TokenStandard.values) {
      if (standard.wireValue == wire) return standard;
    }
    return null;
  }

  /// The non-blocking caution for a supported asset, or null when none applies.
  /// A Core collection "transfer" reassigns its update authority to the
  /// recipient (see [_buildBackendTransferTx] / the backend `UpdateCollectionV1`
  /// path) — a consequential, one-way handover the ownership-framed UI would
  /// otherwise hide. Master editions (a collection with the print plugin) lose
  /// the ability to print further editions, matching the webapp's warning.
  static String? _advisoryNoticeFor(DigitalAsset asset) {
    if (asset.tokenStandard != TokenStandard.coreCollection) return null;
    return asset.hasMasterEditionPlugin
        ? 'This is a master edition. Transferring it hands the '
              "collection's update authority to the recipient — you won't be "
              'able to print editions from it afterward.'
        : "This is a collection. Transferring it hands over the collection's "
              'update authority to the recipient, so you will no longer control '
              'it or mint new items into it.';
  }

  void _onRecipientChanged(
    TransferRecipientChanged event,
    Emitter<TransferArtworkState> emit,
  ) {
    final current = state;
    if (current is! TransferInput) return;
    emit(
      current.copyWith(
        recipient: event.address,
        recipientError: _validateAddress(event.address),
      ),
    );
  }

  void _onQuantityChanged(
    TransferQuantityChanged event,
    Emitter<TransferArtworkState> emit,
  ) {
    final current = state;
    if (current is! TransferInput) return;
    final clamped = event.quantity.clamp(1, _maxQuantity);
    _quantity = clamped;
    emit(current.copyWith(quantity: clamped));
  }

  void _onProceed(TransferProceed event, Emitter<TransferArtworkState> emit) {
    final current = state;
    if (current is! TransferInput || !current.canProceed) return;
    emit(
      TransferReady(
        recipient: current.recipient,
        isEvm: current.isEvm,
        quantity: current.quantity,
      ),
    );
    add(const TransferArtworkEvent.simulate());
  }

  Future<void> _onSimulate(
    TransferSimulate event,
    Emitter<TransferArtworkState> emit,
  ) async {
    final current = state;
    final mint = _mint;
    if (current is! TransferReady || mint == null) return;

    // Each simulate is a fresh request: a later one supersedes any in-flight
    // earlier simulate, so a late completion for an outdated recipient/quantity
    // can't stamp its result onto this newer ready state.
    final generation = ++_simGeneration;

    if (_isEvm) {
      await _simulateEvm(current, generation, emit);
      return;
    }

    emit(
      current.copyWith(
        isSimulating: true,
        simulationResult: null,
        simulatedNetSolLamports: null,
      ),
    );

    try {
      final sourceAddress = await _walletManager.getAddress();

      // Snapshot pre-balance and simulate so the displayed fee is the actual
      // SOL spent (validator fee + destination-ATA rent). `lamportsDelta` is
      // post − pre; negate for spend. Backend-built standards simulate the
      // returned base64 tx; the legacy path simulates a locally-built message.
      final SimulationDelta sim;
      if (_useBackendBuilder) {
        final txBase64 = await _buildBackendTransferTx(
          authority: sourceAddress,
          recipient: current.recipient,
          mint: mint,
        );
        sim = await _rpcService.simulateWithDelta(
          address: sourceAddress,
          simulate: (inspect) => _rpcService.simulateEncodedTransaction(
            txBase64,
            inspectAccounts: inspect,
          ),
          requirePreBalance: true,
        );
      } else {
        final message = await _buildTransferMessage(
          sourceAddress: sourceAddress,
          recipient: current.recipient,
          mint: mint,
        );
        sim = await _rpcService.simulateWithDelta(
          address: sourceAddress,
          simulate: (inspect) =>
              _rpcService.simulateMessage(message, inspectAccounts: inspect),
          requirePreBalance: true,
        );
      }
      final netSol = sim.lamportsDelta == null ? null : -sim.lamportsDelta!;

      final latest = state;
      if (latest is! TransferReady || generation != _simGeneration) return;
      emit(
        latest.copyWith(
          isSimulating: false,
          simulationResult: sim.result,
          simulatedNetSolLamports: netSol,
        ),
      );
    } catch (e) {
      final latest = state;
      if (latest is! TransferReady || generation != _simGeneration) return;
      emit(
        latest.copyWith(
          isSimulating: false,
          simulationResult: SimulationResult(
            success: false,
            error: 'Simulation failed: $e',
          ),
        ),
      );
    }
  }

  /// Prepare (backend build + calldata assertion + estimate + simulation gate)
  /// an EVM transfer, caching the ready-to-sign result. Gate rejections and
  /// infra failures surface as a blocking simulation error that disables Send.
  Future<void> _simulateEvm(
    TransferReady current,
    int generation,
    Emitter<TransferArtworkState> emit,
  ) async {
    emit(
      current.copyWith(
        isSimulating: true,
        simulationResult: null,
        simulatedFeeWei: null,
      ),
    );
    try {
      // Kick the parameterless fee-market fetch off concurrently with prepare:
      // gasMarket consumes nothing from prepare's multi-RPC round-trips, so
      // awaiting them serially wastes a round-trip. Non-fatal: a failure degrades
      // to the read-only default fee (no Edit affordance); the inline onError
      // keeps the future handled even when prepare throws first.
      final marketFuture = _evmService.gasMarket().then<EthGasMarket?>(
        (m) => m,
        onError: (Object e) {
          AppLogger.error(
            _logTag,
            'EVM gas market failed (fee edit off): ${_scrubEvmError(e)}',
          );
          return null;
        },
      );
      final prepared = await _evmService.prepare(
        contract: _evmContract!,
        tokenId: _evmTokenId!,
        standard: _evmStandard!,
        recipient: current.recipient,
        amount: _quantity,
        holder: _evmHolder,
        artworkName: _artworkName,
        imageUrl: _imageUrl,
      );
      final market = await marketFuture;
      final selection = market == null
          ? null
          : EthGasSelection.resolveFromPrefs(
              prefs: _prefs,
              market: market,
              defaultGasLimit: prepared.gasLimit,
            );
      final latest = state;
      if (latest is! TransferReady || generation != _simGeneration) return;
      // Only cache the prepared once this simulate is confirmed current — never
      // stamp a prepared built for a superseded recipient/quantity onto the
      // newer review, and tag it so execute can re-check the match.
      _evmPrepared = prepared;
      _evmPreparedRecipient = current.recipient;
      _evmPreparedQuantity = current.quantity;
      emit(
        latest.copyWith(
          isSimulating: false,
          simulationResult: const SimulationResult(success: true),
          simulatedFeeWei: _evmFeeWei(prepared, selection, market),
          recipientIsContract: prepared.recipientIsContract,
          ethGasMarket: market,
          ethGasSelection: selection,
          ethEstimatedGasUsed: prepared.estimatedGasUsed,
          ethDefaultGasLimit: prepared.gasLimit,
        ),
      );
    } on EvmTransferBlockedException catch (e) {
      AppLogger.error(
        _logTag,
        'EVM simulation blocked: ${_scrubEvmError(e.message)}',
      );
      _emitEvmSimError(emit, generation, e.message);
    } on EvmTransferException catch (e) {
      AppLogger.error(
        _logTag,
        'EVM simulation preparation failed: ${_scrubEvmError(e.message)}',
      );
      _emitEvmSimError(emit, generation, e.message);
    } on EthereumRpcException catch (e) {
      AppLogger.error(
        _logTag,
        'EVM simulation RPC failed: ${_scrubEvmError(e.diagnosticMessage)}',
      );
      _emitEvmSimError(emit, generation, e.message);
    } catch (e) {
      AppLogger.error(
        _logTag,
        'EVM simulation failed unexpectedly: ${_scrubEvmError(e)}',
      );
      _emitEvmSimError(emit, generation, 'Simulation failed: $e');
    }
  }

  void _emitEvmSimError(
    Emitter<TransferArtworkState> emit,
    int generation,
    String message,
  ) {
    // A late failure from a superseded simulate must not clear the newer
    // review's cached prepared or stamp its error onto the newer ready state.
    if (generation != _simGeneration) return;
    _clearEvmPrepared();
    final latest = state;
    if (latest is! TransferReady) return;
    emit(
      latest.copyWith(
        isSimulating: false,
        simulationResult: SimulationResult(success: false, error: message),
      ),
    );
  }

  /// Apply the fee the user picked on the Edit Gas Fee sheet. The gate already
  /// passed (fee-independent), so this only re-points the fee display and the
  /// broadcast; persistence of the choice happens inside the sheet.
  void _onSetEthGasSelection(
    TransferSetEthGasSelection event,
    Emitter<TransferArtworkState> emit,
  ) {
    final current = state;
    final prepared = _evmPrepared;
    if (current is! TransferReady || prepared == null) return;
    emit(
      current.copyWith(
        ethGasSelection: event.selection,
        simulatedFeeWei: _evmFeeWei(
          prepared,
          event.selection,
          current.ethGasMarket,
        ),
      ),
    );
  }

  /// Expected network fee (wei) for the confirm display: gas used × the active
  /// selection's effective price, or the prepared node-default fee when no
  /// selection/market is available.
  BigInt _evmFeeWei(
    PreparedEvmTransfer prepared,
    EthGasSelection? selection,
    EthGasMarket? market,
  ) {
    if (selection == null || market == null) return prepared.feeWei;
    return prepared.estimatedGasUsed *
        selection.effectiveGasPrice(market.baseFeeWei);
  }

  Future<void> _onExecute(
    TransferExecute event,
    Emitter<TransferArtworkState> emit,
  ) async {
    final current = state;
    final mint = _mint;
    if (current is! TransferReady || mint == null) return;

    if (_isEvm) {
      await _executeEvm(current, emit);
      return;
    }

    final recipient = current.recipient;
    emit(const TransferArtworkState.signing());
    emit(const TransferArtworkState.broadcasting());

    final result = await Result.guard(() async {
      final String txBase64;
      if (_useBackendBuilder) {
        final sourceAddress = await _walletManager.getAddress();
        txBase64 = await _buildBackendTransferTx(
          authority: sourceAddress,
          recipient: recipient,
          mint: mint,
        );
      } else {
        txBase64 = await _rpcService.buildSplTransferTx(
          destination: recipient,
          tokenMint: mint,
          amount: 1,
        );
      }
      // An NFT has no cached price, so usdValueOfRaw returns null → the
      // executor's auth gate fail-closes and always requires confirmation,
      // which is the desired behaviour for sending an asset out.
      final usdValue = _priceService.usdValueOfRaw(1, mint);
      final execResult = await _executor.execute(
        txsBase64: [txBase64],
        usdValue: usdValue,
        // 3-way, not `isEvm ? … : solana` — a Tezos artwork must reach the
        // unimplemented-cell backstop, not sign as Solana.
        flow: nftTransferFlowKey(mintAccount: mint, chain: _chain),
      );
      return switch (execResult) {
        ResultSuccess(:final value) => value,
        ResultFailure(:final error) => throw error,
      };
    });

    switch (result) {
      case ResultSuccess(:final value):
        emit(
          TransferArtworkState.success(
            signature: value,
            explorerUrl: buildExplorerUrlFromPrefs(value),
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[TransferArtworkBloc] execute failed: ${error.message}');
        emit(
          TransferArtworkState.error(
            message: error.message,
            previousRecipient: recipient,
            failure: error,
          ),
        );
    }
  }

  /// Authorize, sign, and broadcast the cached prepared EVM transfer. Success
  /// links to Etherscan; auth-cancel / signing / broadcast failures surface as
  /// a transfer error.
  Future<void> _executeEvm(
    TransferReady current,
    Emitter<TransferArtworkState> emit,
  ) async {
    final prepared = _evmPrepared;
    final recipient = current.recipient;
    // Refuse to sign a prepared that doesn't match the live review: a null cache
    // (never simulated / cleared) or a mismatch against the current
    // recipient/quantity (a stale prepared left by a superseded, still-in-flight
    // simulate) must surface the not-ready error rather than broadcast the wrong
    // transfer. Mirrors [SendBloc]'s cache-match guard.
    if (prepared == null ||
        _evmPreparedRecipient != recipient ||
        _evmPreparedQuantity != current.quantity) {
      emit(
        TransferArtworkState.error(
          message: 'Transfer is not ready. Please try again.',
          previousRecipient: recipient,
        ),
      );
      return;
    }
    emit(const TransferArtworkState.signing());
    final result = await Result.guard(
      () => _evmService.execute(
        prepared,
        feeOverride: current.ethGasSelection,
        // Without this the sheet sat on "Approve in your wallet…" from the
        // moment the user authorised until the terminal state — through
        // signing, broadcast and the inclusion wait, ~60s on a busy block.
        // On an irreversible NFT move that reads as a hang and gets
        // force-quit mid-flight. `SendBloc._executeEthereum` has always
        // advanced here; this is the same state and the same copy.
        onBroadcasting: () => emit(const TransferArtworkState.broadcasting()),
        onBroadcastRegistered: (claim) {
          if (isClosed) {
            claim?.release();
            return;
          }
          _resolutionClaim = claim;
          emit(
            const TransferArtworkState.broadcasting(pendingRegistered: true),
          );
        },
      ),
    );
    // Tapping Done closes the flow while the EVM inclusion wait continues.
    // The tracker owns the pending transaction from that point, so there is
    // no remaining state surface for this bloc to update.
    if (isClosed) return;
    switch (result) {
      case ResultSuccess(:final value):
        emit(
          TransferArtworkState.success(
            signature: value,
            explorerUrl: '${Config.etherscanBaseUrl}/tx/$value',
          ),
        );
      case ResultFailure(:final error):
        AppLogger.error(
          _logTag,
          'EVM execute failed: ${_scrubEvmError(error.message)}',
        );
        emit(
          TransferArtworkState.error(
            message: error.message,
            previousRecipient: recipient,
            failure: error,
          ),
        );
    }
  }

  void _onReset(TransferReset event, Emitter<TransferArtworkState> emit) {
    // Dismissing the confirm step abandons the reviewed transfer — drop the
    // cached prepared and bump the generation so a still-in-flight simulate
    // can't stamp its result onto (or leave a stale prepared for) the review the
    // user returns to; a fresh proceed re-simulates.
    _clearEvmPrepared();
    _simGeneration++;
    final current = state;
    final recipient = switch (current) {
      TransferReady(:final recipient) => recipient,
      TransferError(:final previousRecipient) => previousRecipient ?? '',
      _ => '',
    };
    emit(
      TransferInput(
        recipient: recipient,
        isCheckingStandard: false,
        unsupportedReason: _unsupportedReason,
        advisoryNotice: _advisoryNotice,
        isEvm: _isEvm,
        quantity: _quantity,
        maxQuantity: _evmStandard == TokenStandard.erc1155
            ? _maxQuantity
            : null,
      ),
    );
  }

  /// Builds the SPL transfer message (amount 1) for *simulation*, creating the
  /// destination ATA when it doesn't exist yet. This is a separate simulation-
  /// side builder from the executed transaction ([SolanaRpcService
  /// .buildSplTransferTx]), but both now resolve the source account and its
  /// owning token program through the same live [findOwnedTokenAccount] read,
  /// so the simulated message can't diverge from what actually executes.
  Future<Message> _buildTransferMessage({
    required String sourceAddress,
    required String recipient,
    required String mint,
  }) async {
    final sourceKey = Ed25519HDPublicKey.fromBase58(sourceAddress);
    final destinationKey = Ed25519HDPublicKey.fromBase58(recipient);
    final mintKey = Ed25519HDPublicKey.fromBase58(mint);

    // Source account and its owning token program come from one live read of
    // the account the wallet actually holds (may be auxiliary/non-ATA), so the
    // program can't drift to classic SPL on an RPC hiccup and address the ixs
    // to the wrong program. A failure propagates into the simulation handler's
    // catch as a failed simulation.
    final holding = await _rpcService.requireOwnedTokenAccount(
      owner: sourceAddress,
      mint: mint,
    );
    final programType = holding.program;
    final sourceAta = Ed25519HDPublicKey.fromBase58(holding.address);
    final destinationAta = await findAssociatedTokenAddress(
      owner: destinationKey,
      mint: mintKey,
      tokenProgramType: programType,
    );

    final instructions = <Instruction>[];

    // base64 required: base58 (the RPC default) rejects the 165-byte token
    // account, so an existing destination ATA would fail this existence check.
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

    instructions.add(
      TokenInstruction.transfer(
        source: sourceAta,
        destination: destinationAta,
        owner: sourceKey,
        amount: 1,
        tokenProgram: programType,
      ),
    );

    return Message(instructions: instructions);
  }

  /// Fetches a base64 unsigned transfer tx from the backend for the non-legacy
  /// standards (pNFT / Core / cNFT). The backend resolves the per-standard
  /// accounts (auth-rules, mpl-core, Bubblegum proof) server-side, so the
  /// request is identical across standards apart from [_tokenStandard].
  Future<String> _buildBackendTransferTx({
    required String authority,
    required String recipient,
    required String mint,
  }) async {
    final response = await _apiV2.getTransferTx(
      TransferTxRequest(
        authority: authority,
        asset: mint,
        recipient: recipient,
        tokenStandard: _tokenStandard!.apiValue,
      ),
    );
    // Solana standards always return a base64 `tx` (EVM returns `evm` instead,
    // and never reaches this Solana-only builder).
    final tx = response.result.tx;
    if (tx == null) {
      throw StateError('backend returned no Solana transaction');
    }
    return tx;
  }

  String? _validateAddress(String address) {
    if (address.isEmpty) return null;
    if (_isEvm) {
      // EIP-55: a mixed-case address must match its checksum. A bare hex
      // shape test lets a single mistyped character through, and an NFT
      // transfer to a wrong address is unrecoverable.
      return evmRecipientError(address);
    }
    if (!SecurityUtils.isValidSolanaAddress(address)) {
      return 'Invalid Solana address';
    }
    return null;
  }

  /// Hand any still-held resolution claim back to the tracker when the user
  /// leaves the EVM pipeline before its inclusion wait finishes.
  @override
  Future<void> close() {
    _resolutionClaim?.release();
    _resolutionClaim = null;
    return super.close();
  }
}
