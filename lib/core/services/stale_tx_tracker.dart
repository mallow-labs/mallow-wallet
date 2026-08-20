/// Stale-blockhash recovery for server-co-signed transactions.
///
/// Some backend endpoints return pre-signed transactions whose signature
/// covers the original blockhash. A client-side blockhash refresh would
/// invalidate that signature, so when the user lingers on the confirmation
/// sheet long enough to risk a "Blockhash not found" rejection, blocs must
/// re-ask the backend for a freshly-co-signed tx instead.
///
/// Non-co-signed flows fall through to [TransactionPipeline.signAndBroadcast]'s
/// automatic client-side blockhash refresh and don't strictly need this
/// helper, but every prepare path uses it anyway for uniformity (and so the
/// recovery still works if a backend endpoint flips to co-signing later).
///
/// Tuned below the ~60s blockhash lifetime to leave margin for the
/// simulate → sign → broadcast tail.
class StaleTxTracker<T> {
  StaleTxTracker({Duration staleAfter = const Duration(seconds: 30)})
    : _staleAfter = staleAfter;

  final Duration _staleAfter;

  DateTime? _readyAt;
  Future<T> Function()? _rebuild;

  /// Runs [build] once and stores both the wall-clock timestamp and the
  /// closure for later replay. Caller emits the prepared tx state.
  Future<T> buildAndTrack(Future<T> Function() build) async {
    final result = await build();
    _readyAt = DateTime.now();
    _rebuild = build;
    return result;
  }

  /// Drops the tracked tx. Call from terminal states (success/error/reset).
  void clear() {
    _readyAt = null;
    _rebuild = null;
  }

  /// Returns a freshly-rebuilt tx if the tracked one has aged past the
  /// staleness window, otherwise null. Refreshes [_readyAt] on success.
  /// Rethrows the rebuild closure's exception so callers can surface it.
  Future<T?> refreshIfStale() async {
    final readyAt = _readyAt;
    final rebuild = _rebuild;
    if (readyAt == null || rebuild == null) return null;
    if (DateTime.now().difference(readyAt) <= _staleAfter) return null;
    final fresh = await rebuild();
    _readyAt = DateTime.now();
    return fresh;
  }
}
