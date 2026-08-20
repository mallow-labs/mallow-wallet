/// Centralised arithmetic for the cache-first repositories.
///
/// All `cachedAt` columns in this app are persisted as Unix seconds (int).
/// Each repo used to reimplement the same `now ~/ 1000`, "is older than TTL",
/// and prune-cutoff math inline, with subtle drift (one repo used
/// `.difference()` instead of `.subtract().isBefore()`, another used 30 seconds
/// vs the others' 5 minutes, etc.). This class is the single source of truth.
abstract final class CacheFreshness {
  /// `DateTime.now()` expressed as Unix seconds — the format every
  /// `cachedAt` Drift column stores.
  static int nowEpochSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Inverse of [nowEpochSeconds]: lift a stored `cachedAt` back into a
  /// `DateTime` for staleness comparisons.
  static DateTime fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  /// Returns true when [cachedAt] is null (cache miss) or older than [ttl].
  ///
  /// Uses `.isBefore(now - ttl)` rather than `now.difference(cachedAt) > ttl`
  /// — they're equivalent for forward-clock cases, but `isBefore` is the
  /// pattern already used in four of the five repos and avoids surprises if
  /// `cachedAt` is somehow in the future (clock skew, restored backup).
  static bool isStale(DateTime? cachedAt, Duration ttl) {
    if (cachedAt == null) return true;
    final cutoff = DateTime.now().subtract(ttl);
    return cachedAt.isBefore(cutoff);
  }

  /// Epoch-second cutoff for `pruneOldCache` queries: rows with
  /// `cachedAt < cutoff` should be deleted.
  static int pruneCutoffEpoch(Duration retention) =>
      DateTime.now().subtract(retention).millisecondsSinceEpoch ~/ 1000;
}
