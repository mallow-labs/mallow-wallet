import 'package:flutter/foundation.dart';
import 'package:mallow_api/mallow_api.dart';

import '../config/environment.dart';

/// Poll the indexer to confirm a freshly-broadcast transaction has been
/// ingested server-side. Mirrors the webapp's `checkTx` in
/// `solana`.
///
/// gRPC stream listeners occasionally miss transactions. Calling this after
/// `signSendConfirm` returns nudges the indexer to re-pull the tx and queue
/// any marketplace-entry processing it would otherwise drop. Callers should
/// fire-and-forget (via `unawaited`) — the success sheet shows immediately
/// on chain confirmation; the indexed result drives a quiet refetch.
///
/// Returns `true` once the indexer acknowledges the tx (response body is
/// `{}` / contains no string `result`). Returns `false` after [maxAttempts]
/// poll cycles where the indexer keeps reporting "not yet processed" — the
/// caller should still trigger refresh, since the indexer may catch up later.
Future<bool> checkTransaction(
  String signature, {
  required MallowApiClient api,
  int maxAttempts = 10,
  Duration? delay,
}) async {
  final pollDelay = delay ?? _defaultDelay();
  await Future<void>.delayed(pollDelay);

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final response = await api.checkTx({
        'txId': signature,
        'attempt': attempt,
      });
      final result = response is Map ? response['result'] : null;
      if (result is String) {
        // Indexer says "not yet processed" — keep polling.
        await Future<void>.delayed(pollDelay);
        continue;
      }
      debugPrint(
        '[LIST-DEBUG] checkTx OK sig=$signature attempt=$attempt '
        '@${DateTime.now().toIso8601String()}',
      );
      return true;
    } catch (e) {
      // 404s and transient network errors are expected while the tx
      // propagates. Match the webapp's uniform swallow + retry.
      debugPrint('[checkTx] attempt $attempt for $signature failed: $e');
      await Future<void>.delayed(pollDelay);
    }
  }

  debugPrint('[checkTx] gave up after $maxAttempts attempts for $signature');
  return false;
}

/// Poll until the marketplace *entry* produced by [signature] is indexed.
/// Mirrors the webapp's `checkEntry` in `solana`.
///
/// [checkTransaction] only acks that the transaction was processed — which
/// happens within tens of milliseconds — whereas the listing doesn't appear
/// in `/byMint` until its derived marketplace entry lands in the index, a
/// strictly later event. Listing flows gate their refresh on this so the
/// refetch reads the post-listing state instead of the stale pre-listing one.
///
/// The backend returns `{}` (200) once the entry is found and a 404 while it
/// is still pending; the 404 surfaces as an exception that the catch swallows
/// and retries, matching [checkTransaction]'s shape. Returns `false` after
/// [maxAttempts] cycles — callers should still refresh, since the entry may
/// land later.
Future<bool> checkMarketplaceEntry(
  String signature, {
  required MallowApiClient api,
  int maxAttempts = 10,
  Duration? delay,
}) async {
  final pollDelay = delay ?? _defaultDelay();
  await Future<void>.delayed(pollDelay);

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final response = await api.checkEntry({'txId': signature});
      final result = response is Map ? response['result'] : null;
      if (result is String) {
        // Still pending — keep polling.
        await Future<void>.delayed(pollDelay);
        continue;
      }
      debugPrint(
        '[LIST-DEBUG] checkEntry OK sig=$signature attempt=$attempt '
        '@${DateTime.now().toIso8601String()}',
      );
      return true;
    } catch (e) {
      // 404 ("Entry not found") is the expected pending signal; transient
      // network errors retry the same way.
      debugPrint('[checkEntry] attempt $attempt for $signature failed: $e');
      await Future<void>.delayed(pollDelay);
    }
  }

  debugPrint('[checkEntry] gave up after $maxAttempts attempts for $signature');
  return false;
}

Duration _defaultDelay() {
  // `Config.apiBaseUrl` resolves from compiled-in defines and no longer throws,
  // but keep the guard: this helper must never fail a transaction check over a
  // config read. Falls back to the prod-default 1s delay.
  try {
    return Config.apiBaseUrl.contains('localhost')
        ? const Duration(milliseconds: 100)
        : const Duration(seconds: 1);
  } catch (_) {
    return const Duration(seconds: 1);
  }
}
