import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/database/database.dart';

/// One row of the cached Jupiter verified-token catalog.
typedef JupiterListToken = ({
  String mint,
  String symbol,
  String name,
  String? iconUrl,
  int decimals,

  /// 24h traded volume in USD, or null when upstream reports no 24h stats.
  double? dailyVolume,
});

/// Browsable catalog of every Jupiter-**verified** Solana mint, backing the
/// swap buy-side search. The Solana analog of `UniswapTokenListService`.
///
/// Why a full local catalog rather than a live query per keystroke: the buy
/// picker otherwise only offers the ~20 hand-maintained registry tokens plus
/// whatever the user already holds, and `JupiterTokenService`'s cache is
/// populated by mint (held tokens only), so it can't answer "what verified
/// tokens exist". The upstream list is ~3.9k tokens / ~5 MB, so it is fetched
/// once per 24h into Drift ([CachedJupiterTokenList]) and searched offline.
///
/// Never throws on a failed refresh: [ensureCached] swallows network *and*
/// database errors (the sheet fires it unawaited, so anything escaping becomes
/// an unhandled zone error), and [search] serves whatever is cached — empty on
/// a first cold run — so search degrades to registry + held tokens rather than
/// erroring the picker.
///
/// A refresh never blocks a search that has rows to show: [search] only awaits
/// the fetch while the cache is completely empty, and a failed refresh backs
/// off for a few minutes so an offline user isn't parked behind a fresh 5 MB
/// attempt on every keystroke.
@lazySingleton
class JupiterVerifiedTokenListService {
  JupiterVerifiedTokenListService(this._database) {
    _dio = Dio(
      BaseOptions(
        baseUrl: Config.jupiterBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    // The payload is ~5 MB; decoding it on the platform isolate janks the sheet
    // for a visible beat. Dio's default threshold is -1 (never offload).
    _dio.transformer = FusedTransformer(
      contentLengthIsolateThreshold: 512 * 1024,
    );
  }

  /// Builds the service against a caller-supplied [HttpClientAdapter] so tests
  /// can serve a canned catalog without hitting the live proxy.
  @visibleForTesting
  JupiterVerifiedTokenListService.withAdapter(
    this._database,
    HttpClientAdapter adapter,
  ) {
    _dio = Dio(BaseOptions(baseUrl: Config.jupiterBaseUrl))
      ..httpClientAdapter = adapter;
  }

  final MallowDatabase _database;
  late final Dio _dio;

  /// The verified set moves rarely; refresh at most once a day.
  static const _staleTtl = Duration(hours: 24);

  /// How long a failed refresh is remembered. Without it every keystroke
  /// re-attempts the ~5 MB fetch, which offline costs a 15s connect timeout
  /// (60s receive) each time while the cached rows were queryable all along.
  static const _failureBackoff = Duration(minutes: 5);

  /// Max ranked hits handed back to the picker.
  static const _maxResults = 30;

  /// Max rows on the picker's "Popular" tab.
  static const _maxPopular = 50;

  /// Coalesces concurrent callers onto a single refresh — the buy sheet warms
  /// the cache on open while the user's first keystroke also asks for it.
  Future<void>? _inFlight;

  /// True once a refresh has succeeded (or been skipped as fresh) this session,
  /// so repeated sheet opens don't re-hit the DB for the freshness check.
  bool _fresh = false;

  /// When the last refresh failed, gating retries for [_failureBackoff].
  DateTime? _failedAt;

  /// Populates the catalog if it has never been cached or is older than 24h.
  /// Safe to call repeatedly and to fire-and-forget; failures are swallowed.
  Future<void> ensureCached() async {
    if (_fresh) return;
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureBackoff) {
      return;
    }
    await (_inFlight ??= _refresh().whenComplete(() => _inFlight = null));
  }

  /// Verified tokens matching [query], best match first. Waits on [ensureCached]
  /// only while nothing is cached, so the very first search populates the
  /// catalog rather than returning empty; once there are rows they are served
  /// immediately and the refresh runs behind the search.
  Future<List<JupiterListToken>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    // `getJupiterTokenListCacheTime` is non-null iff at least one row exists,
    // so it doubles as the "is the cache empty" probe. Only a completely cold
    // cache is worth blocking the picker on the ~5 MB fetch for.
    if (!_fresh && (await _database.getJupiterTokenListCacheTime()) == null) {
      await ensureCached();
    } else {
      unawaited(ensureCached());
    }
    final rows = await _database.searchJupiterTokenList(trimmed);
    final tokens = [for (final row in rows) ?_toToken(row)];
    tokens.sort((a, b) => _rank(a, trimmed).compareTo(_rank(b, trimmed)));
    return tokens.take(_maxResults).toList();
  }

  /// The highest-24h-volume verified tokens, highest first — the swap picker's
  /// "Popular" tab.
  ///
  /// Unlike [search] this always awaits [ensureCached]: the tab has no local
  /// rows to fall back on, so serving an empty list while the catalog is cold
  /// would read as "there are no popular tokens". `ensureCached` returns
  /// immediately once the catalog is fresh, so only the first run pays for it,
  /// and a failed refresh still resolves — to whatever is cached, or empty.
  Future<List<JupiterListToken>> popular({int limit = _maxPopular}) async {
    await ensureCached();
    final rows = await _database.topJupiterTokensByVolume(limit: limit);
    return [for (final row in rows) ?_toToken(row)];
  }

  /// A cached row as a catalog token, or null when it can't be offered.
  ///
  /// A null `decimals` (rows cached by an earlier build) is skipped, not
  /// defaulted: the value feeds the buy-side amount math, so a plausible wrong
  /// number is worse than the token missing from the picker.
  JupiterListToken? _toToken(CachedJupiterTokenListData row) {
    final symbol = row.symbol ?? '';
    final decimals = row.decimals;
    if (symbol.isEmpty || decimals == null) return null;
    return (
      mint: row.mint,
      symbol: symbol,
      name: (row.name ?? '').isEmpty ? symbol : row.name!,
      iconUrl: row.iconUrl,
      decimals: decimals,
      dailyVolume: row.dailyVolume,
    );
  }

  /// Lower is better: exact symbol, symbol prefix, name prefix, then the rest.
  /// Without this a search for `SOL` buries `SOL` under every `…SOL…` name.
  int _rank(JupiterListToken token, String query) {
    final q = query.toLowerCase();
    final symbol = token.symbol.toLowerCase();
    final name = token.name.toLowerCase();
    if (symbol == q || token.mint == query) return 0;
    if (symbol.startsWith(q)) return 1;
    if (name == q) return 2;
    if (name.startsWith(q)) return 3;
    if (symbol.contains(q)) return 4;
    return 5;
  }

  Future<void> _refresh() async {
    try {
      // Inside the try: the sheet can be torn down (and the database closed)
      // mid-refresh, and callers fire this unawaited.
      final cachedAt = await _database.getJupiterTokenListCacheTime();
      if (cachedAt != null &&
          DateTime.now().difference(cachedAt) <= _staleTtl) {
        _fresh = true;
        return;
      }

      final tokens = await _fetchFromApi();
      if (tokens.isEmpty) {
        _failedAt = DateTime.now();
        return;
      }
      await _database.replaceJupiterTokenList(
        tokens.map(_toCompanion).toList(),
      );
      _fresh = true;
    } catch (e) {
      // Network or database unavailable — leave the previous catalog in place
      // (possibly empty on a first cold run) and back off before retrying.
      _failedAt = DateTime.now();
      debugPrint('[JupiterVerifiedTokenListService] refresh failed: $e');
    }
  }

  Future<List<JupiterListToken>> _fetchFromApi() async {
    final response = await _dio.get<List<dynamic>>(
      '/tokens/v2/tag',
      queryParameters: {'query': 'verified'},
    );

    final tokens = <JupiterListToken>[];
    for (final item in response.data ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      final mint = (item['id'] as String?)?.trim();
      final symbol = (item['symbol'] as String?)?.trim();
      final Object? decimals = item['decimals'];
      // Missing or non-numeric decimals drop the token instead of caching it
      // as 0: the value drives the buy-side amount math, so a token that is
      // off by 10^d is worse than one the picker never offers.
      if (mint == null ||
          mint.isEmpty ||
          symbol == null ||
          symbol.isEmpty ||
          decimals is! num) {
        continue;
      }
      final name = (item['name'] as String?)?.trim();
      final icon = (item['icon'] as String?)?.trim();
      tokens.add((
        mint: mint,
        symbol: symbol,
        name: (name == null || name.isEmpty) ? symbol : name,
        iconUrl: (icon == null || icon.isEmpty) ? null : icon,
        decimals: decimals.toInt(),
        dailyVolume: _dailyVolume(item['stats24h']),
      ));
    }
    return tokens;
  }

  /// Total 24h traded volume from a `stats24h` block: buys plus sells.
  ///
  /// Null when the block is absent or carries neither side — upstream omits it
  /// for roughly half the catalog, and those tokens are left out of the
  /// "Popular" ranking rather than entered at zero.
  double? _dailyVolume(Object? stats24h) {
    if (stats24h is! Map<String, dynamic>) return null;
    final buy = stats24h['buyVolume'];
    final sell = stats24h['sellVolume'];
    if (buy is! num && sell is! num) return null;
    return (buy is num ? buy.toDouble() : 0) +
        (sell is num ? sell.toDouble() : 0);
  }

  CachedJupiterTokenListCompanion _toCompanion(JupiterListToken token) {
    return CachedJupiterTokenListCompanion(
      mint: Value(token.mint),
      symbol: Value(token.symbol),
      name: Value(token.name),
      decimals: Value(token.decimals),
      iconUrl: Value(token.iconUrl),
      dailyVolume: Value(token.dailyVolume),
      cachedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
  }
}
