import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

import '../../features/activity/services/activity_refresh_signal.dart';
import '../config/remote_config.dart';
import '../crypto/wallet_manager.dart';
import '../network/solana_rpc_service.dart';
import '../result/app_failure.dart';
import '../result/result.dart';
import '../security/transaction_auth_gate.dart';
import 'ledger_service.dart';
import 'transaction_check.dart';
import 'transaction_signing.dart';

/// Unified transaction signing pipeline shared across feature BLoCs.
///
/// Every flow that signs a server-built compiled transaction (mint, swap,
/// fixed-price/auction listing, market actions, raffle) used to inline the
/// same skeleton:
///
/// ```
/// emit(signing) → signSendConfirm(...) → emit(broadcasting) →
///   emit(success) → unawaited(_runCheckTx(sig))
/// ```
///
/// …plus a bespoke `try / on TransactionAuthCancelledException / catch`
/// block per BLoC. This helper centralises the parts that are genuinely
/// shared so the per-feature blocs only own the parts that legitimately
/// vary (state shape, error copy, USD-outflow computation):
///
///   * [signAndBroadcast] wraps [signSendConfirm] in [Result.guard] so
///     cancellations classify as [AppFailureKind.cancelled] consistently
///     across every flow. Callers branch on `failure.isCancelled` to
///     render the cancel message verbatim instead of as a generic error.
///   * [runIndexerCheck] is the fire-and-forget indexer prod that every
///     BLoC reimplemented as a private `_runCheckTx` plus an
///     `_onIndexedAck` reducer. Callers pass `isClosed` so a torn-down
///     BLoC can't acknowledge into a dead state.
///
/// The pipeline does NOT emit BLoC states itself — state shapes differ
/// across features (sealed-class vs. enum-field) and centralising that
/// would force every flow onto a common state machine. Instead callers
/// keep their per-feature states and use [onSigned] / [onLedgerSigning]
/// to flip them at the right pipeline edges.
@lazySingleton
class TransactionPipeline {
  TransactionPipeline(
    this._walletManager,
    this._rpcService,
    this._authGate,
    this._api,
    this._ledgerService,
  );

  final WalletManager _walletManager;
  final SolanaRpcService _rpcService;
  final TransactionAuthGate _authGate;
  final MallowApiClient _api;
  final LedgerService _ledgerService;

  /// Sign → broadcast → confirm a single base64-encoded compiled tx.
  ///
  /// Returns a [Result] carrying the on-chain signature on success.
  /// [TransactionAuthCancelledException] (from the auth gate) and the
  /// wallet-side cancellation type are both classified as
  /// [AppFailureKind.cancelled] via [AppFailure.from], so callers can
  /// branch on `failure.isCancelled` rather than pattern-matching the
  /// underlying throwable type.
  ///
  /// A remote kill is **not** in that bucket: it arrives as
  /// [AppFailureKind.flowDisabled], so a caller whose cancel branch is
  /// silent still surfaces it. Call `handleFlowDisabled(context, failure)` from
  /// the failure branch before any generic handling.
  ///
  /// [onSigned] fires synchronously between sign and broadcast — flows
  /// that surface distinct "Approve in your wallet" → "Confirming on
  /// Solana" copy flip their state here.
  ///
  /// [onLedgerSigning] streams [LedgerService.signingState] for the
  /// duration of the signing call so hosts can swap the pipeline label
  /// to "Approve on your Ledger device" without branching on wallet
  /// type. Set [useLedger] = false to opt out entirely (e.g. flows that
  /// don't surface Ledger-specific copy and want to avoid the extra
  /// stream subscription).
  Future<Result<String, AppFailure>> signAndBroadcast({
    required String unsignedTxBase64,
    required double? usdValue,
    required FlowKey flow,
    List<Ed25519HDKeyPair> additionalSigners = const [],
    VoidCallback? onSigned,
    void Function(LedgerSigningState)? onLedgerSigning,
    bool useLedger = true,
    SolanaRpcService? rpcOverride,
  }) => Result.guard(
    () => signSendConfirm(
      unsignedTxBase64,
      walletManager: _walletManager,
      rpcService: rpcOverride ?? _rpcService,
      authGate: _authGate,
      usdValue: usdValue,
      flow: flow,
      additionalSigners: additionalSigners,
      onSigned: onSigned,
      ledgerService: useLedger ? _ledgerService : null,
      onLedgerSigning: useLedger ? onLedgerSigning : null,
    ),
  );

  /// Fire-and-forget indexer poll. Replaces the `_runCheckTx` helper
  /// every transaction-submitting BLoC reimplemented inline.
  ///
  /// [isClosed] guards both before and after the poll — a BLoC that has
  /// been torn down between broadcast and ack must not dispatch
  /// `indexedAck` into a dead `add()` queue.
  ///
  /// [delay] is exposed for tests; production callers should leave it
  /// null and let [checkTransaction] pick the env-appropriate cadence.
  ///
  /// Set [requireEntry] for flows whose post-tx UI reads server-derived
  /// state off the *marketplace entry* (e.g. listing flows that refetch
  /// `/byMint`). When set, the ack also waits for [checkMarketplaceEntry]
  /// so the refresh doesn't race the entry-indexing lag — [checkTransaction]
  /// alone acks the tx within tens of milliseconds, well before the listing
  /// is queryable. Mirrors the webapp's `checkTx(...).then(() => checkEntry(...))`.
  void runIndexerCheck({
    required String signature,
    required void Function(String signature, bool ok) onAck,
    required bool Function() isClosed,
    bool requireEntry = false,
    @visibleForTesting Duration? delay,
  }) {
    unawaited(() async {
      if (isClosed()) return;
      var ok = await checkTransaction(signature, api: _api, delay: delay);
      // Every Solana flow that reaches this point (mint, swap, stake,
      // list/buy/offer/bid/settle/burn) writes an activity row the server
      // only surfaces once the tx is indexed. Before this, the only producer
      // of [ActivityRefreshSignal] was the EVM pending-tx tracker, so the
      // "Recent activity" sheet was stale after every Solana action until the
      // user reopened it cold. Fire on the tx ack (not the entry ack) —
      // `/v2/activity` reads the tx, not the marketplace entry — and fire
      // regardless of [isClosed]: the signal is app-wide, so a torn-down
      // originating BLoC must not suppress it.
      if (ok) notifyActivityRefresh();
      if (ok && requireEntry) {
        if (isClosed()) return;
        ok = await checkMarketplaceEntry(signature, api: _api, delay: delay);
      }
      if (isClosed()) return;
      onAck(signature, ok);
    }());
  }
}
