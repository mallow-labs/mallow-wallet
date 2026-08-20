import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/network/logging_interceptor.dart';
import '../models/jupiter_token_info.dart';

/// Service for fetching and caching detailed token info from the Jupiter v2 API.
///
/// Uses `GET /tokens/v2/search?query={mint}` on the Jupiter API
/// and caches the payload locally with a 5-minute TTL. The info is dominated by
/// effectively-immutable fields (decimals, authorities, supply); the few
/// volatile market fields (price, market cap, holders, 24h stats) tolerate a
/// few minutes of lag on the detail screen. Caching collapses the repeated
/// single-mint requests that fired on every token-detail open.
@lazySingleton
class JupiterTokenInfoService {
  JupiterTokenInfoService(this._database) {
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
  /// (verifying the cache short-circuit) without hitting the live proxy.
  @visibleForTesting
  JupiterTokenInfoService.withAdapter(
    this._database,
    HttpClientAdapter adapter,
  ) {
    _dio = Dio(BaseOptions(baseUrl: Config.jupiterBaseUrl))
      ..httpClientAdapter = adapter;
  }

  final MallowDatabase _database;
  late final Dio _dio;

  /// Cache is considered stale after 5 minutes.
  static const _staleTtl = Duration(minutes: 5);

  /// Fetch detailed token info for a single mint address.
  ///
  /// Returns a fresh-cached row without any network call; otherwise fetches
  /// from the API, caches it, and returns it. Falls back to whatever the cache
  /// holds (even if stale) when the network fails, and returns null only when
  /// there's neither a cache entry nor a successful fetch.
  Future<JupiterTokenInfo?> getTokenInfo(String mint) async {
    final cached = await _database.getTokenInfoCache(mint);
    if (cached != null &&
        !CacheFreshness.isStale(
          CacheFreshness.fromEpochSeconds(cached.cachedAt),
          _staleTtl,
        )) {
      return _decode(cached.jsonData);
    }

    final fetched = await _fetchFromApi(mint);
    if (fetched != null) {
      await _cache(fetched);
      return fetched;
    }

    // Network failed or returned nothing — fall back to stale cache if present.
    return cached != null ? _decode(cached.jsonData) : null;
  }

  Future<JupiterTokenInfo?> _fetchFromApi(String mint) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/tokens/v2/search',
        queryParameters: {'query': mint},
      );

      final items = response.data ?? [];
      if (items.isEmpty) return null;

      // Find exact match by id/mint
      for (final item in items) {
        if (item is Map<String, dynamic>) {
          final id = item['id'] as String? ?? item['mint'] as String?;
          if (id == mint) {
            return JupiterTokenInfo.fromApiResponse(item);
          }
        }
      }

      // Fallback to first result
      final first = items.first;
      if (first is Map<String, dynamic>) {
        return JupiterTokenInfo.fromApiResponse(first);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cache(JupiterTokenInfo info) {
    return _database.upsertTokenInfoCache(
      CachedJupiterTokenInfoCompanion(
        mint: Value(info.mint),
        jsonData: Value(jsonEncode(info.toJson())),
        cachedAt: Value(CacheFreshness.nowEpochSeconds()),
      ),
    );
  }

  JupiterTokenInfo? _decode(String jsonData) {
    try {
      return JupiterTokenInfo.fromJson(
        jsonDecode(jsonData) as Map<String, dynamic>,
      );
    } catch (_) {
      // Corrupt/legacy row — treat as a miss rather than crashing the screen.
      return null;
    }
  }
}
