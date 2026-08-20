import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/database/database.dart';
import '../../../core/network/logging_interceptor.dart';

/// Per-mint market data returned by [JupiterTokenService].
typedef JupiterMarketInfo = ({
  double? usdPrice,
  double? priceChange24h,
  bool isVerified,
  String? name,
  String? symbol,
  String? iconUrl,
});

/// Service for fetching and caching Jupiter token market data.
///
/// Fetches 24h price change data and the `verified` tag from the Jupiter API
/// from the Jupiter API and caches it locally with a 15-minute TTL.
@lazySingleton
class JupiterTokenService {
  JupiterTokenService(this._database) {
    _dio = Dio(
      BaseOptions(
        baseUrl: Config.jupiterBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    _dio.interceptors.add(PrettyLoggingInterceptor());
  }

  /// Builds the service against a caller-supplied [HttpClientAdapter] so tests
  /// can serve canned responses and count the underlying network calls
  /// (verifying request coalescing) without hitting the live proxy.
  @visibleForTesting
  JupiterTokenService.withAdapter(this._database, HttpClientAdapter adapter) {
    _dio = Dio(BaseOptions(baseUrl: Config.jupiterBaseUrl))
      ..httpClientAdapter = adapter;
  }

  final MallowDatabase _database;
  late final Dio _dio;

  /// Per-mint in-flight network fetches, keyed by mint. Coalesces concurrent
  /// requests for the same mint so the burst of overlapping [getMarketInfo]
  /// calls that fire together (app open, wallet switch — one per wallet across
  /// several blocs) collapses into a single batched API call instead of a
  /// cache-cold stampede that the proxy rejects with 429. Entries are removed
  /// once the fetch resolves and its result is written to the cache.
  final Map<String, Future<JupiterMarketInfo?>> _inFlight = {};

  /// Cache is considered stale after 15 minutes.
  static const _staleTtlMinutes = 15;

  /// Maximum mints per Jupiter `/tokens/v2/search` call. Jupiter's `query`
  /// param is a comma-separated list with a practical cap; chunking keeps
  /// requests within both the API limit and reasonable URL lengths.
  static const _maxMintsPerRequest = 100;

  /// Returns a map of mint address -> market info (24h price change + verified
  /// tag). Mints absent from the response/cache are omitted; callers should
  /// treat missing entries as unverified with no price change data.
  ///
  /// Cache freshness is evaluated per-mint: rows < 15 min old are returned
  /// from cache; missing or stale mints are fetched from the API in chunks.
  Future<Map<String, JupiterMarketInfo>> getMarketInfo(
    List<String> mints,
  ) async {
    if (mints.isEmpty) return {};

    final staleCutoffSeconds =
        DateTime.now()
            .subtract(const Duration(minutes: _staleTtlMinutes))
            .millisecondsSinceEpoch ~/
        1000;

    final cachedRows = await _database.getMarketData(mints);
    final freshFromCache = <String, JupiterMarketInfo>{};
    final staleFromCache = <String, JupiterMarketInfo>{};
    for (final row in cachedRows) {
      final info = (
        usdPrice: row.usdPrice,
        priceChange24h: row.priceChangePercent24h,
        isVerified: row.isVerified,
        name: row.name,
        symbol: row.symbol,
        iconUrl: row.iconUrl,
      );
      if (row.cachedAt >= staleCutoffSeconds) {
        freshFromCache[row.mint] = info;
      } else {
        staleFromCache[row.mint] = info;
      }
    }

    final toFetch = mints
        .where((mint) => !freshFromCache.containsKey(mint))
        .toList();
    if (toFetch.isEmpty) return freshFromCache;

    // Start a batched fetch for any mints not already in flight; concurrent
    // callers reuse the existing future instead of issuing duplicate requests.
    final newMints = toFetch
        .where((mint) => !_inFlight.containsKey(mint))
        .toList();
    if (newMints.isNotEmpty) _startFetch(newMints);

    // Await the per-mint future for everything we need (ours and any already
    // in flight from a sibling call). Failures resolve to null and fall back to
    // stale cache below so the UI keeps prior verified/price-change context.
    final fetched = <String, JupiterMarketInfo>{};
    await Future.wait(
      toFetch.map((mint) async {
        final info = await _inFlight[mint];
        if (info != null) fetched[mint] = info;
      }),
    );

    // Merge fresh cache + fetched. Stale cache fills mints Jupiter didn't
    // return at all (e.g. delisted) or that failed to fetch.
    return {...staleFromCache, ...freshFromCache, ...fetched};
  }

  /// Issues a batched API fetch for [mints], registering a per-mint future in
  /// [_inFlight] so overlapping callers share this one request. The futures
  /// resolve (and the cache is written) before the entries are cleared.
  void _startFetch(List<String> mints) {
    final completers = {
      for (final mint in mints) mint: Completer<JupiterMarketInfo?>(),
    };
    completers.forEach((mint, completer) {
      _inFlight[mint] = completer.future;
    });

    unawaited(() async {
      Map<String, JupiterMarketInfo> fetched = const {};
      try {
        fetched = await _fetchFromApi(mints);
        await _cacheData(fetched);
      } catch (_) {
        // Leave [fetched] empty; completers resolve null and callers fall back
        // to stale cache.
      } finally {
        completers.forEach((mint, completer) {
          completer.complete(fetched[mint]);
        });
        _inFlight.removeWhere((mint, _) => completers.containsKey(mint));
      }
    }());
  }

  Future<Map<String, JupiterMarketInfo>> _fetchFromApi(
    List<String> mints,
  ) async {
    final chunks = <List<String>>[
      for (var i = 0; i < mints.length; i += _maxMintsPerRequest)
        mints.sublist(
          i,
          i + _maxMintsPerRequest > mints.length
              ? mints.length
              : i + _maxMintsPerRequest,
        ),
    ];

    final responses = await Future.wait(chunks.map(_fetchChunk));

    final result = <String, JupiterMarketInfo>{};
    for (final chunk in responses) {
      result.addAll(chunk);
    }
    return result;
  }

  Future<Map<String, JupiterMarketInfo>> _fetchChunk(List<String> mints) async {
    final response = await _dio.get<List<dynamic>>(
      '/tokens/v2/search',
      queryParameters: {'query': mints.join(',')},
    );

    final items = response.data ?? [];
    final result = <String, JupiterMarketInfo>{};

    for (final item in items) {
      if (item is Map<String, dynamic>) {
        final mint = item['id'] as String?;
        if (mint == null) continue;

        final stats = item['stats24h'] as Map<String, dynamic>?;
        final priceChange = (stats?['priceChange'] as num?)?.toDouble();
        final usdPrice = (item['usdPrice'] as num?)?.toDouble();
        final tags = (item['tags'] as List?)?.cast<String>() ?? const [];
        final name = (item['name'] as String?)?.trim();
        final symbol = (item['symbol'] as String?)?.trim();
        final iconUrl = (item['icon'] as String?)?.trim();
        result[mint] = (
          usdPrice: usdPrice,
          priceChange24h: priceChange,
          isVerified: tags.contains('verified'),
          name: (name?.isEmpty ?? true) ? null : name,
          symbol: (symbol?.isEmpty ?? true) ? null : symbol,
          iconUrl: (iconUrl?.isEmpty ?? true) ? null : iconUrl,
        );
      }
    }

    return result;
  }

  Future<void> _cacheData(Map<String, JupiterMarketInfo> data) async {
    if (data.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entries = data.entries
        .map(
          (e) => CachedTokenMarketDataCompanion(
            mint: Value(e.key),
            usdPrice: Value(e.value.usdPrice),
            priceChangePercent24h: Value(e.value.priceChange24h),
            isVerified: Value(e.value.isVerified),
            name: Value(e.value.name),
            symbol: Value(e.value.symbol),
            iconUrl: Value(e.value.iconUrl),
            cachedAt: Value(now),
          ),
        )
        .toList();

    await _database.upsertMarketData(entries);
  }
}
