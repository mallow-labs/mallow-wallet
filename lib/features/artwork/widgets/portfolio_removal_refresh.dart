import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mallow_api/mallow_api.dart'
    show MallowApiClient, UpdateOwnerRequest;

import '../../../core/network/auth_service.dart';
import '../../../core/services/transaction_check.dart';
import '../../../di.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../data/artwork_repository.dart';
import '../services/artwork_removal_signal.dart';

/// Refresh the My Art tab once the indexer reflects [mint] having left the
/// active wallet — a send (transfer) or a burn.
///
/// `checkTx` returning 200 only means the indexer *fetched* the tx; it flushes
/// the new on-chain ownership a few hundred milliseconds later (backend:
/// `processTransaction` → ownership flush → cache invalidation). Gating the
/// `byOwner` refetch on the `checkTx` ack alone therefore re-reads the stale
/// pre-send set and the sent artwork lingers on the tab (observed: the
/// refetch fired ~250 ms before the ownership flush landed).
///
/// So: nudge + confirm the tx via `checkTx` (the indexer can miss the gRPC
/// stream, and this re-pulls it), then poll the mint's ownership until it no
/// longer resolves to the active wallet — or the asset 404s, i.e. it was
/// burnt — and only then signal the refetch. Unlike `checkEntry`, this works
/// for plain transfers/burns, which write no marketplace entry (so `checkEntry`
/// would never land and would just time out).
///
/// [optimisticRemove] fires the app-wide [ArtworkRemovalSignal] immediately so
/// every mounted owned-art view drops [mint] on the spot, instead of lingering
/// until the reindex refetch below lands. Burns always pass true; a transfer
/// passes false when the recipient is one of the viewer's own session wallets,
/// since the portfolio aggregates across them and the asset is still owned (see
/// [ArtworkRemovalSignal]). The delayed refetch still runs and reconciles.
///
/// [updateOwner] forces the backend to re-read and persist the new on-chain
/// owner synchronously (`POST /v1/artwork/updateOwner`), mirroring
/// `the reference web client`'s `TransferNftModal`. Without it we'd wait for the async
/// ownership flush that `checkTx` only queues, so the poll below usually costs
/// several extra cycles. Solana transfers pass true; burns and EVM transfers
/// leave it false (the route is Solana-only and a burnt mint has no owner).
///
/// Fire-and-forget: it outlives the closing transfer/burn sheet and bloc.
/// Falls back to signalling after the poll budget so a missed flip (or an
/// unreadable owner) still refreshes, just later.
///
/// [checkSolanaIndexer] controls the Solana-only `checkTx`/`checkEntry` nudge.
/// EVM transfers leave it false because their pending tracker and EVM activity
/// path own transaction resolution.
Future<void> refreshMyArtAfterRemoval({
  required String mint,
  required String signature,
  bool optimisticRemove = true,
  bool updateOwner = false,
  bool checkSolanaIndexer = true,
  int maxAttempts = 12,
  Duration delay = const Duration(seconds: 1),
}) async {
  if (optimisticRemove) notifyArtworkRemoved(mint);

  // /v0/checkTx and /v0/checkEntry are Solana indexer nudges. EVM artwork
  // transfers are tracked by the EVM pending-transaction service and must not
  // send their Ethereum hash to these Solana-only endpoints.
  if (checkSolanaIndexer) {
    await checkTransaction(signature, api: sl<MallowApiClient>());
  }

  if (updateOwner) {
    // Best-effort: a failure here just means the poll below falls back to
    // waiting for the async flush, so swallow and continue.
    try {
      await sl<MallowApiClient>().updateOwner(
        UpdateOwnerRequest(mintAccount: mint),
      );
    } catch (_) {}
  }

  final me = sl<AuthService>().currentAddress;
  // Without a known owner to diff against we can't detect the flip — fall
  // straight through to the refresh (it re-reads whatever the server has).
  if (me != null && me.isNotEmpty) {
    final repo = sl<ArtworkRepository>();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final details = await repo.getArtworkDetail(mint);
        if (details.ownerAddress != me) break; // re-indexed to the new owner
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) break; // burnt / no longer indexed
        // transient — keep polling
      } catch (_) {
        // transient — keep polling
      }
      await Future<void>.delayed(delay);
    }
  }

  notifyPortfolioRefresh();
}
