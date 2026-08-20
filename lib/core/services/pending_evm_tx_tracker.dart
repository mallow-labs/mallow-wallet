import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';
// web3dart 3.x re-homed EthereumAddress in package:wallet; it imports the type
// but does not re-export it.
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:web3dart/web3dart.dart' show TransactionReceipt;

import '../../di.dart';
import '../../features/activity/services/activity_refresh_signal.dart';
import '../../features/portfolio/services/balance_optimistic_updater.dart';
import '../../features/portfolio/services/portfolio_refresh_signal.dart';
import '../../features/send/models/eth_gas.dart';
import '../../shared/utils/chain.dart' show Chain, apiOwnerAddress;
import '../crypto/wallet_manager.dart';
import '../database/database.dart';
import '../network/ethereum_rpc_service.dart';
import '../network/evm_transfer_core.dart';
import '../observability/app_logger.dart';
import '../session/session_manager.dart';
import 'pending_evm_tx.dart';

export 'pending_evm_tx.dart';

const _tag = 'PendingEvmTx';

/// Owns the app's view of unresolved EVM nonces: what is pending, when it
/// resolves, and how to replace it.
///
/// Three jobs:
///
///  1. **Record** every broadcast the `signAndBroadcastEvmTransfer` funnel
///     makes, keyed by (wallet, nonce), so a transaction that outlives the send
///     pipeline's 60 s wait — or the app process — is still actionable.
///  2. **Watch** each session EVM wallet's `latest` vs `pending` nonce every
///     [_pollInterval] while foregrounded, resolving rows whose slot got
///     consumed and synthesising `external` entries for gaps left by a
///     transaction broadcast from another device.
///  3. **Replace** a stuck transaction — [speedUp] re-signs the stored payload
///     at a higher fee, [cancel] replaces it with a 0-ETH self-send — always on
///     the same nonce, always above the node's 10% bump.
///
/// Ethereum mainnet only, matching the rest of the EVM surface.
@lazySingleton
class PendingEvmTxTracker with WidgetsBindingObserver {
  PendingEvmTxTracker(this._db, this._rpc, this._session, this._walletManager);

  final MallowDatabase _db;
  final EthereumRpcService _rpc;
  final SessionManager _session;
  final WalletManager _walletManager;

  /// Foreground poll cadence. publicnode is free and the pass is two nonce
  /// reads per wallet, so 8 s buys near-immediate resolution cheaply.
  static const Duration _pollInterval = Duration(seconds: 8);

  Timer? _timer;
  bool _started = false;
  bool _backgrounded = false;
  bool _passInFlight = false;

  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<List<PendingEvmTx>> _entriesController =
      StreamController<List<PendingEvmTx>>.broadcast();
  // ignore: close_sinks
  final StreamController<PendingTxResolution> _resolutionsController =
      StreamController<PendingTxResolution>.broadcast();

  List<PendingEvmTx> _entries = const [];

  /// Gap nonces seen on the previous pass, per wallet. A gap must appear on two
  /// consecutive passes before it is surfaced: publicnode's mempool view is
  /// partial, so a transaction broadcast elsewhere makes the gap flicker for a
  /// second or two before the node catches up.
  final Map<String, Set<int>> _gapsSeenLastPass = {};

  /// Gap nonces currently surfaced (already past the debounce), per wallet.
  final Map<String, Set<int>> _surfacedGaps = {};

  /// Slots a live flow is awaiting inclusion of and will report the outcome of
  /// itself, keyed by (lowercased wallet, nonce). See [claimResolution].
  ///
  /// An entry is dropped when the slot resolves or the claim is handed back, so
  /// the only way one outlives its flow is a transaction that never resolves at
  /// all — in which case there is nothing to announce anyway.
  final Map<_Slot, _SlotClaim> _claims = {};

  /// Pending entries for the current session's wallets, sorted in mining order
  /// (session wallet order, then nonce ascending — nonce N+1 cannot mine before
  /// N). Emits the current snapshot immediately on subscribe.
  ///
  /// Subscribing starts the watcher; it stops when the app backgrounds and
  /// resumes (with an immediate pass) on foreground.
  Stream<List<PendingEvmTx>> watch() async* {
    _ensureStarted();
    yield _entries;
    yield* _entriesController.stream;
  }

  /// The latest snapshot without subscribing — the same list [watch] would
  /// emit first.
  List<PendingEvmTx> get entries => _entries;

  /// Resolutions as they happen, for the app-wide toast. Broadcast, so a
  /// resolution with no listener is dropped rather than queued.
  Stream<PendingTxResolution> get resolutions => _resolutionsController.stream;

  /// Run one watcher pass now — app start, resume, or activity-sheet open.
  Future<void> refreshNow() => _runPass();

  /// Begin polling and observing app lifecycle. Idempotent; called implicitly
  /// by [watch].
  void start() => _ensureStarted();

  /// Stop polling and detach the lifecycle observer.
  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Whether the poll timer is currently armed — the watcher's whole running
  /// cost, so "an idle wallet is not polled" is only testable through it.
  @visibleForTesting
  bool get isPolling => _timer != null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      // The pass re-arms the timer if it finds anything to watch.
      unawaited(_runPass());
    } else {
      // Nothing to poll for in the background: a resolution the user cannot see
      // has no UI to update, and the resume pass catches up in one round-trip.
      _backgrounded = true;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_runPass());
  }

  /// Arm the poll timer only while there is something to watch. With no pending
  /// row and no gap sighting, an 8 s tick is two nonce reads that can only
  /// answer "nothing changed" — ~900 requests an hour per wallet for nothing.
  ///
  /// A gap seen last pass counts as work even though it is not yet surfaced:
  /// surfacing needs a second consecutive sighting, and dropping the timer here
  /// would strand the debounce.
  ///
  /// Every path that can create work ([register], [refreshNow], resume) ends in
  /// [_emitEntries], which calls this, so polling resumes on the same turn the
  /// work appears.
  void _syncTimer() {
    final hasWork =
        _entries.isNotEmpty ||
        _gapsSeenLastPass.values.any((gaps) => gaps.isNotEmpty);
    if (_started && !_backgrounded && hasWork) {
      _timer ??= Timer.periodic(_pollInterval, (_) => unawaited(_runPass()));
      return;
    }
    _timer?.cancel();
    _timer = null;
  }

  @disposeMethod
  void dispose() {
    stop();
    _entriesController.close();
    _resolutionsController.close();
  }

  // ==========================================================================
  // Registration
  // ==========================================================================

  /// Persist a broadcast. An `original` opens a nonce slot; a `speedup` or
  /// `cancel` appends a candidate to the slot already there (and a `cancel`
  /// flips it to `cancelling`), because a replacement is another live hash for
  /// the same transaction, not a second pending transaction.
  ///
  /// A `cancel` against a slot with no row — the blind cancel of an external
  /// nonce gap — creates the row, which is exactly when a derived gap entry
  /// becomes durable.
  Future<void> register(PendingEvmBroadcast broadcast) async {
    final wallet = apiOwnerAddress(broadcast.walletAddress);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final candidate = PendingTxCandidate(
      hash: broadcast.hash,
      role: broadcast.role.name,
      maxFeePerGas: broadcast.maxFeePerGas,
      maxPriorityFeePerGas: broadcast.maxPriorityFeePerGas,
      broadcastAt: now,
    );

    final existing = await _db.getPendingEvmTransaction(
      wallet,
      broadcast.nonce,
    );
    if (existing != null) {
      final candidates = [
        ...PendingTxCandidate.decodeList(existing.candidatesJson),
        candidate,
      ];
      await _db.updatePendingEvmTransaction(
        wallet,
        broadcast.nonce,
        PendingEvmTransactionsCompanion(
          candidatesJson: Value(PendingTxCandidate.encodeList(candidates)),
          status: Value(
            broadcast.role == PendingTxCandidateRole.cancel
                ? PendingEvmTxStatus.cancelling.name
                : existing.status,
          ),
        ),
      );
    } else {
      await _db.upsertPendingEvmTransaction(
        PendingEvmTransactionsCompanion.insert(
          walletAddress: wallet,
          nonce: broadcast.nonce,
          chainId: broadcast.chainId,
          kind: broadcast.kind.name,
          status: broadcast.role == PendingTxCandidateRole.cancel
              ? PendingEvmTxStatus.cancelling.name
              : PendingEvmTxStatus.pending.name,
          toAddress: broadcast.toAddress,
          valueWei: broadcast.valueWei.toString(),
          data: broadcast.data,
          gasLimit: broadcast.gasLimit,
          metadataJson: (broadcast.metadata ?? _genericMetadata(broadcast.kind))
              .encode(),
          candidatesJson: PendingTxCandidate.encodeList([candidate]),
          createdAt: now,
        ),
      );
    }
    // The row this cancel just persisted is no longer a *derived* gap.
    if (broadcast.role == PendingTxCandidateRole.cancel) {
      _surfacedGaps[wallet]?.remove(broadcast.nonce);
    }
    await _emitEntries();
  }

  static PendingTxMetadata _genericMetadata(PendingEvmTxKind kind) =>
      PendingTxMetadata(
        title: kind == PendingEvmTxKind.external
            ? 'Pending transaction'
            : 'Transaction',
      );

  // ==========================================================================
  // Resolution claims
  // ==========================================================================

  /// Hand the flow that is awaiting inclusion of (`walletAddress`, [nonce]) the
  /// job of telling the user how it ended.
  ///
  /// Every normal EVM send registers here *and* waits out its own confirmation
  /// behind the send pipeline's success step. Unclaimed, the watcher's next pass
  /// announces that same confirmation on the app-wide toast, on top of the
  /// screen that just said it — the same news twice, on every send. The toast
  /// exists for the transaction that outlived its flow, so the flow that is
  /// still there claims the notice.
  ///
  /// A claimed slot still *resolves* normally (row deleted, portfolio and
  /// activity refreshed); only the announcement is withheld, and it is **kept**
  /// rather than dropped, so [releaseResolutionClaim] can still deliver it.
  ///
  /// Claimed by `signAndBroadcastEvmTransfer` in the same synchronous turn as
  /// [register], so no pass can slip in between and announce.
  void claimResolution(String walletAddress, int nonce) {
    _claims.putIfAbsent((
      apiOwnerAddress(walletAddress),
      nonce,
    ), _SlotClaim.new);
  }

  /// The claiming flow reported the outcome itself, so the toast would be the
  /// same news twice. Retires the row if the watcher has not already — the
  /// pipeline's success step is showing, and the transaction it is about must not
  /// still read as Pending behind it.
  ///
  /// No-op once [releaseResolutionClaim] has run: the user left the flow first,
  /// which makes the toast the only report they can get.
  Future<void> resolutionReported(String walletAddress, int nonce) async {
    final slot = (apiOwnerAddress(walletAddress), nonce);
    final claim = _claims[slot];
    if (claim == null) return;
    claim.reported = true;
    if (claim.held case final held?) {
      _claims.remove(slot);
      // Withheld while the flow was still running. It has now reported a
      // success, so only an outcome that contradicts it is still worth a toast.
      if (held.kind != PendingTxResolutionKind.confirmed) _announce(held);
      return;
    }
    // Nothing has resolved yet: the transaction this flow just watched mine is
    // still in the table, so retire it now instead of leaving it in Pending for
    // up to one poll interval. The pass's own announcement is withheld above.
    await refreshNow();
  }

  /// The claiming flow went away without reporting — the send pipeline's "Done"
  /// early exit, or an inclusion wait that failed. Hand the notice back: a
  /// resolution withheld while the claim was held is announced now, and a later
  /// one announces normally.
  ///
  /// A flow that already reported keeps its claim: what it told the user stands,
  /// and the row is retired either way.
  void releaseResolutionClaim(String walletAddress, int nonce) {
    final slot = (apiOwnerAddress(walletAddress), nonce);
    final claim = _claims[slot];
    if (claim == null || claim.reported) return;
    _claims.remove(slot);
    if (claim.held case final held?) _announce(held);
  }

  /// Whether a live flow owns announcing [resolution] — and, while one does,
  /// keep the resolution so [releaseResolutionClaim] can hand it back.
  bool _claimOwnsAnnouncement(PendingTxResolution resolution) {
    final slot = (resolution.tx.walletAddress, resolution.tx.nonce);
    final claim = _claims[slot];
    if (claim == null) return false;
    if (!claim.reported) {
      claim.held = resolution;
      return true;
    }
    _claims.remove(slot);
    // The flow told the user the transaction succeeded, so a confirmation is
    // that same news. A revert, a cancel, or a stranger taking the nonce is not
    // — and the flow that would have shown it is gone — so those still announce.
    return resolution.kind == PendingTxResolutionKind.confirmed;
  }

  void _announce(PendingTxResolution resolution) {
    if (!_resolutionsController.isClosed) {
      _resolutionsController.add(resolution);
    }
  }

  // ==========================================================================
  // Watcher
  // ==========================================================================

  Future<void> _runPass() async {
    // Passes are not reentrant: an 8 s tick firing while a slow pass is still
    // resolving would double-classify the same rows.
    if (_passInFlight) return;
    _passInFlight = true;
    try {
      await _pass();
    } on Object catch (e) {
      AppLogger.warn(_tag, 'watcher pass failed: $e');
    } finally {
      _passInFlight = false;
    }
  }

  Future<void> _pass() async {
    final wallets = _sessionWallets();
    if (wallets.isEmpty) {
      _gapsSeenLastPass.clear();
      _surfacedGaps.clear();
      await _emitEntries();
      return;
    }

    final resolved = <PendingTxResolution>[];
    for (final address in wallets) {
      try {
        await _passForWallet(address, resolved);
      } on Object catch (e) {
        // One wallet's RPC failure must not stop the others; the next pass
        // retries. Never resolve on an error — an unread receipt is not proof
        // the transaction did not mine.
        AppLogger.warn(_tag, 'pass failed for wallet: $e');
      }
    }

    await _emitEntries();

    if (resolved.isEmpty) return;
    notifyPortfolioRefresh();
    notifyActivityRefresh();
    _refreshTokenBalances();
    for (final resolution in resolved) {
      // A slot a live flow claimed is *resolved* here like any other (row gone,
      // portfolio and activity refreshed) — only the announcement is withheld.
      if (_claimOwnsAnnouncement(resolution)) continue;
      _announce(resolution);
    }
  }

  /// Refetch the session's EVM token balances after a slot resolved, then
  /// signal the tokens tab and the token-detail sheet to re-read.
  ///
  /// [notifyPortfolioRefresh] above reloads the *art* portfolio only, so
  /// without this an ETH/ERC-20 row kept its pre-transaction value until a
  /// pull-to-refresh. This pass is also the only point in the EVM pipeline that
  /// knows a transaction actually mined — the funnel returns its hash on an
  /// inclusion-wait timeout too, so a send flow's success step is not proof and
  /// must not refetch on its own. The flow that *did* see a receipt reaches
  /// here in the same turn, via its claim's `reported()` → [refreshNow].
  ///
  /// Every session wallet, not just the resolved slot's: an ERC-20 transfer's
  /// `to` is the token contract, so a resolved row cannot say which of the
  /// user's own wallets received it, and the tokens tab sums across all of
  /// them. Addresses come from the session rather than [_sessionWallets]
  /// (lowercased for nonce matching) because the balance cache and the blocs'
  /// scopes are keyed by the wallet's own casing.
  void _refreshTokenBalances() {
    for (final wallet in _session.sessionWalletsForChain(Chain.ethereum)) {
      unawaited(
        BalanceOptimisticUpdater.recordNonSolanaTransfer(
          chain: Chain.ethereum,
          senderAddress: wallet.address,
          recipientAddress: '',
        ),
      );
    }
  }

  Future<void> _passForWallet(
    String address,
    List<PendingTxResolution> resolved,
  ) async {
    final latest = await _rpc.getLatestNonce(address);
    final pendingCount = await _rpc.getNonce(address);

    final rows = await _db.getPendingEvmTransactions();
    final mine = rows.where((r) => r.walletAddress == address).toList();

    // 1. Rows whose slot the chain has already consumed.
    for (final row in mine.where((r) => r.nonce < latest)) {
      final entry = _toEntry(row);
      final kind = await _classify(entry);
      if (kind == null) continue; // receipt read failed — retry next pass.
      await _db.deletePendingEvmTransaction(row.walletAddress, row.nonce);
      resolved.add(PendingTxResolution(tx: entry, kind: kind));
    }

    // 2. Nonce gaps: slots between the confirmed count and the mempool count
    //    that this app has no row for — a transaction from another device.
    final localNonces = mine.map((r) => r.nonce).toSet();
    final gaps = <int>{
      for (var n = latest; n < pendingCount; n++)
        if (!localNonces.contains(n)) n,
    };

    final seenLastPass = _gapsSeenLastPass[address] ?? const <int>{};
    final surfaced = _surfacedGaps.putIfAbsent(address, () => <int>{});

    // A gap that has closed. Only `latest` moving past the nonce is proof the
    // external transaction mined; a gap can also close because the mempool
    // dropped it (eviction, or the sender's node forgetting it), and announcing
    // *that* as "Transaction confirmed" — with a portfolio and activity refresh
    // behind it — tells the user funds moved that never did. We have no hash and
    // no receipt for an external slot, so there is nothing honest to report:
    // the cell just stops being shown, and if the transaction comes back the gap
    // resurfaces.
    for (final closed in surfaced.difference(gaps).toList()) {
      surfaced.remove(closed);
      if (closed >= latest) continue;
      resolved.add(
        PendingTxResolution(
          tx: _externalEntry(address, closed),
          kind: PendingTxResolutionKind.confirmed,
        ),
      );
    }
    // A gap only surfaces after two consecutive sightings (debounce).
    surfaced.addAll(gaps.intersection(seenLastPass));
    _gapsSeenLastPass[address] = gaps;
  }

  /// Classify a consumed slot by which of its candidate hashes got a receipt.
  /// Returns null when a receipt read failed, so the caller leaves the row
  /// alone rather than guessing.
  Future<PendingTxResolutionKind?> _classify(PendingEvmTx entry) async {
    for (final candidate in entry.candidates) {
      final TransactionReceipt? mined;
      try {
        mined = await _rpc.getTransactionReceipt(candidate.hash);
      } on Object catch (e) {
        AppLogger.warn(
          _tag,
          'receipt read failed for nonce ${entry.nonce}: $e',
        );
        return null;
      }
      if (mined == null) continue;
      if (candidate.isCancel) return PendingTxResolutionKind.cancelled;
      // web3dart leaves `status` null on pre-Byzantium receipts; only an
      // explicit 0x0 is a revert.
      if (mined.status == false) {
        AppLogger.error(
          _tag,
          'transaction mined with execution reverted status; '
          'receipt does not include the revert reason',
        );
        return PendingTxResolutionKind.reverted;
      }
      return PendingTxResolutionKind.confirmed;
    }
    // Nonce consumed, none of our hashes mined — an unknown transaction took
    // the slot.
    return PendingTxResolutionKind.replaced;
  }

  // ==========================================================================
  // Replacement
  // ==========================================================================

  /// The per-field minimum a replacement for [entry] must sign:
  /// `ceil(1.1 × highest-fee candidate)`. Null for an external entry with no
  /// candidates — its stuck transaction's fees are unknown, which is why cancel
  /// falls back to the escalation ladder there.
  EvmFeeCaps? replacementFloorOf(PendingEvmTx entry) =>
      replacementFloorFor(entry.candidates);

  /// Re-broadcast [entry] at the fee in [selection], on the same nonce.
  ///
  /// The stored `to`/`value`/`data`/`gasLimit` are replayed verbatim — the
  /// original already passed the calldata and simulation gates, and re-running
  /// them (or changing the gas limit) would invalidate that. An entry that is
  /// already `cancelling` bumps its **cancel** instead, keeping it a cancel.
  ///
  /// The 110% floor is applied here as well as in the sheet, so a caller that
  /// forgets it still can't broadcast an under-priced replacement.
  ///
  /// Returns what actually happened — see [PendingTxReplacementResult]; the
  /// caller must not report a submitted replacement on
  /// [PendingTxReplacementResult.alreadyResolved].
  Future<PendingTxReplacementResult> speedUp(
    PendingEvmTx entry,
    EthGasSelection selection,
  ) async {
    if (entry.isExternal && entry.candidates.isEmpty) {
      throw const EvmTransferBlockedException(
        'This transaction was sent from another device, so it can only be '
        'cancelled, not sped up.',
      );
    }
    final asCancel = entry.isCancelling || entry.isExternal;
    final plan = buildReplacementPlan(entry, asCancel: asCancel);
    final caps = applyReplacementFloor((
      maxFeePerGas: selection.maxFeePerGas,
      maxPriorityFeePerGas: selection.maxPriorityFeePerGas,
    ), replacementFloorOf(entry));

    return _broadcastReplacement(entry: entry, plan: plan, caps: caps);
  }

  /// Replace [entry] with a 0-ETH self-send at the same nonce, so the slot is
  /// consumed by a no-op instead of the original transaction.
  ///
  /// [caps] are signed **verbatim**: they are the caps the Cancel sheet quoted
  /// and balance-gated, and re-deriving them here from a freshly fetched market
  /// would sign a fee the user never saw — one a wallet that only just covered
  /// the quote can no longer afford, which surfaces as the send funnel's
  /// insufficient-funds error. Build them with [cancelCapsFor].
  ///
  /// For an external entry there is no candidate to floor against, so the ladder
  /// in [broadcastWithEscalation] walks the bid up ×1.25 (max
  /// [kBlindCancelMaxAttempts] attempts) until the node stops answering
  /// "replacement transaction underpriced" — the one case where the signed fee
  /// exceeds the quote, which is why the sheet warns the fee may increase.
  Future<PendingTxReplacementResult> cancel(
    PendingEvmTx entry,
    EvmFeeCaps caps,
  ) async {
    final plan = buildReplacementPlan(entry, asCancel: true);
    if (entry.isExternal && entry.candidates.isEmpty) {
      var result = PendingTxReplacementResult.broadcast;
      await broadcastWithEscalation(
        caps: caps,
        isUnderpriced: (e) =>
            classifyEvmBroadcastError(e) ==
            EvmBroadcastError.replacementUnderpriced,
        broadcast: (attemptCaps) async {
          result = await _broadcastReplacement(
            entry: entry,
            plan: plan,
            caps: attemptCaps,
          );
          return '';
        },
      );
      return result;
    }
    return _broadcastReplacement(entry: entry, plan: plan, caps: caps);
  }

  /// Sign and broadcast one replacement attempt through the shared funnel,
  /// which registers the new candidate on the existing row.
  ///
  /// `nonce too low` means the slot just resolved while the user was deciding —
  /// not an error to raise, so it refreshes and reports
  /// [PendingTxReplacementResult.alreadyResolved] rather than letting the caller
  /// claim a replacement was submitted. `already known` means the identical raw
  /// transaction is already in the mempool, which is the outcome we wanted.
  Future<PendingTxReplacementResult> _broadcastReplacement({
    required PendingEvmTx entry,
    required EvmReplacementPlan plan,
    required EvmFeeCaps caps,
  }) async {
    final wallet = _session.sessionWalletForAddressCaseInsensitive(
      entry.walletAddress,
    );
    if (wallet == null || !wallet.canSign) {
      throw const EvmTransferBlockedException(
        'This transaction was sent from a wallet this session cannot sign '
        'with.',
      );
    }
    final data = evmHexToBytes(plan.data);
    try {
      await signAndBroadcastEvmTransfer(
        rpc: _rpc,
        walletManager: _walletManager,
        walletId: wallet.id,
        source: wallet.address,
        to: EthereumAddress.fromHex(plan.to),
        value: plan.value,
        data: data.isEmpty ? null : data,
        gasLimit: plan.gasLimit,
        maxFeePerGas: caps.maxFeePerGas,
        maxPriorityFeePerGas: caps.maxPriorityFeePerGas,
        refreshFees: false,
        nonceOverride: plan.nonce,
        trackKind: entry.kind,
        trackRole: plan.role,
        trackAs: entry.metadata,
        awaitInclusion: false,
      );
      return PendingTxReplacementResult.broadcast;
    } on Object catch (e) {
      switch (classifyEvmBroadcastError(e)) {
        case EvmBroadcastError.alreadyKnown:
          return PendingTxReplacementResult.broadcast;
        case EvmBroadcastError.nonceTooLow:
          await refreshNow();
          return PendingTxReplacementResult.alreadyResolved;
        case EvmBroadcastError.replacementUnderpriced:
        case EvmBroadcastError.other:
          rethrow;
      }
    }
  }

  // ==========================================================================
  // Snapshot
  // ==========================================================================

  List<String> _sessionWallets() => _session
      .sessionWalletsForChain(Chain.ethereum)
      .map((w) => apiOwnerAddress(w.address))
      .toSet()
      .toList();

  /// Rebuild and publish the current snapshot: persisted rows plus the derived
  /// external gap entries, filtered to the session's wallets.
  Future<void> _emitEntries() async {
    final order = _sessionWallets();
    if (order.isEmpty) {
      _entries = const [];
      if (!_entriesController.isClosed) _entriesController.add(_entries);
      _syncTimer();
      return;
    }
    final rows = await _db.getPendingEvmTransactions();
    final byWallet = <String, List<PendingEvmTx>>{
      for (final address in order) address: <PendingEvmTx>[],
    };
    for (final row in rows) {
      byWallet[row.walletAddress]?.add(_toEntry(row));
    }
    for (final address in order) {
      final surfaced = _surfacedGaps[address] ?? const <int>{};
      final list = byWallet[address]!;
      final known = list.map((e) => e.nonce).toSet();
      for (final nonce in surfaced) {
        if (!known.contains(nonce)) list.add(_externalEntry(address, nonce));
      }
      list.sort((a, b) => a.nonce.compareTo(b.nonce));
      // Replacements mine in nonce order, so only the lowest unresolved
      // external slot is worth cancelling; the ones above it would sit behind
      // it anyway.
      final lowestExternal = list
          .where((e) => e.isExternal)
          .map((e) => e.nonce)
          .fold<int?>(null, (min, n) => min == null || n < min ? n : min);
      for (var i = 0; i < list.length; i++) {
        final e = list[i];
        if (e.isExternal && e.nonce != lowestExternal) {
          list[i] = e.copyWith(canCancelNow: false);
        }
      }
    }
    _entries = [for (final address in order) ...byWallet[address]!];
    if (!_entriesController.isClosed) _entriesController.add(_entries);
    _syncTimer();
  }

  PendingEvmTx _toEntry(PendingEvmTransaction row) => PendingEvmTx(
    walletAddress: row.walletAddress,
    nonce: row.nonce,
    chainId: row.chainId,
    kind: PendingEvmTxKind.fromWire(row.kind),
    status: PendingEvmTxStatus.fromWire(row.status),
    toAddress: row.toAddress,
    valueWei: BigInt.tryParse(row.valueWei) ?? BigInt.zero,
    data: row.data,
    gasLimit: row.gasLimit,
    metadata: PendingTxMetadata.decode(row.metadataJson),
    candidates: PendingTxCandidate.decodeList(row.candidatesJson),
    createdAt: row.createdAt,
  );

  /// A derived nonce-gap entry: we know the wallet and the slot, nothing else.
  PendingEvmTx _externalEntry(String address, int nonce) => PendingEvmTx(
    walletAddress: address,
    nonce: nonce,
    chainId: _rpc.chainId,
    kind: PendingEvmTxKind.external,
    status: PendingEvmTxStatus.pending,
    toAddress: '',
    valueWei: BigInt.zero,
    data: '',
    gasLimit: kCancelGasLimit,
    metadata: const PendingTxMetadata(title: 'Pending transaction'),
    candidates: const [],
    createdAt: 0,
  );
}

/// The caps a cancel for [entry] must sign against [market]: the market tier,
/// floored at the live next-block base fee + tip (a stale or low tier would sign
/// a cancel the network never picks up), then floored again at 110% of the
/// highest existing candidate (the node's bump rule).
///
/// The **only** place this composition lives. The Cancel sheet quotes and
/// balance-gates the value, then hands the same value to
/// [PendingEvmTxTracker.cancel] to sign, so a base fee that moves while the user
/// reads the sheet cannot make the quote and the signature disagree.
EvmFeeCaps cancelCapsFor(PendingEvmTx entry, EthGasMarket market) {
  final tier = market.market;
  final atMarket = applyReplacementFloor(
    (
      maxFeePerGas: tier.maxFeePerGas,
      maxPriorityFeePerGas: tier.maxPriorityFeePerGas,
    ),
    (
      maxFeePerGas: market.baseFeeWei + tier.maxPriorityFeePerGas,
      maxPriorityFeePerGas: tier.maxPriorityFeePerGas,
    ),
  );
  return applyReplacementFloor(atMarket, replacementFloorFor(entry.candidates));
}

/// One tracked slot, as the claim bookkeeping keys it.
typedef _Slot = (String wallet, int nonce);

/// Mutable state behind one [PendingEvmTxTracker.claimResolution].
class _SlotClaim {
  /// A resolution the watcher reached while the flow still owned the slot, kept
  /// so [PendingEvmTxTracker.releaseResolutionClaim] can still announce it.
  PendingTxResolution? held;

  /// The flow has told the user the transaction succeeded.
  bool reported = false;
}

/// A live flow's claim on announcing how one tracked slot ended.
///
/// Consumed once, by whichever of [reported] / [release] runs first: the send
/// pipeline's early exit races the funnel's inclusion wait, and the winner
/// decides whether the user hears the outcome from the flow or from the
/// app-wide toast. Both are no-ops after the first, so callers can fire either
/// unconditionally.
///
/// Holds no tracker reference — the (wallet, nonce) pair is the whole identity of
/// a claim, and the calls go through the locator like the rest of this file's
/// fire-and-forget helpers.
@immutable
class PendingTxResolutionClaim {
  const PendingTxResolutionClaim(this.walletAddress, this.nonce);

  final String walletAddress;
  final int nonce;

  /// The flow reported the outcome itself (its own success step).
  Future<void> reported() async {
    if (!sl.isRegistered<PendingEvmTxTracker>()) return;
    await sl<PendingEvmTxTracker>().resolutionReported(walletAddress, nonce);
  }

  /// The flow went away without reporting; the toast is the user's only report.
  void release() {
    if (!sl.isRegistered<PendingEvmTxTracker>()) return;
    sl<PendingEvmTxTracker>().releaseResolutionClaim(walletAddress, nonce);
  }
}

/// Claim the resolution notice for a broadcast whose flow waits out inclusion
/// itself — see [PendingEvmTxTracker.claimResolution].
///
/// Null when DI isn't configured, like [notifyPendingEvmBroadcast]; a caller that
/// gets null simply has no claim to consume.
PendingTxResolutionClaim? claimPendingEvmResolution(
  String walletAddress,
  int nonce,
) {
  if (!sl.isRegistered<PendingEvmTxTracker>()) return null;
  sl<PendingEvmTxTracker>().claimResolution(walletAddress, nonce);
  return PendingTxResolutionClaim(walletAddress, nonce);
}

/// Fire-and-forget broadcast registration, safe to call from the funnel.
///
/// No-ops when DI isn't configured, and swallows every failure: the
/// transaction is already on the wire by the time this runs, so a database
/// error must never surface as a failed send.
void notifyPendingEvmBroadcast(PendingEvmBroadcast broadcast) {
  if (!sl.isRegistered<PendingEvmTxTracker>()) return;
  unawaited(
    sl<PendingEvmTxTracker>().register(broadcast).catchError((Object e) {
      AppLogger.warn(_tag, 'failed to record broadcast: $e');
    }),
  );
}
