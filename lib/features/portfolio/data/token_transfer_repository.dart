import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/config/environment.dart';
import '../../../core/data/address_scope_key.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';

/// A page of activities + the cursor for the next page.
class TokenTransfersResult {
  const TokenTransfersResult({required this.activities, this.paginationToken});

  final List<api.Activity> activities;
  final String? paginationToken;

  bool get hasMore => paginationToken != null;
}

/// Repository for per-token transfer history.
///
/// Three-tier load (memory → Drift → API): callers display cached results
/// instantly while a fresh request to `/v2/transfers` runs in the
/// background. The backend proxies Helius `getTransfersByAddress`, classifies
/// swap-tagged transactions, and enriches counterparties + USD prices, so
/// the response shape matches `ActivityListResponse` and renders through the
/// existing `ActivityListItem` without changes.
@lazySingleton
class TokenTransferRepository {
  TokenTransferRepository(this._database, this._dio);

  final MallowDatabase _database;
  final Dio _dio;

  static const _pruneRetention = Duration(hours: 24);
  static const _staleTtl = Duration(minutes: 5);

  /// Fetch a page from the backend and cache the rows under
  /// [addressScopeKey].
  ///
  /// Hits the public v2 `GET /v2/transfers`, which aggregates per-token
  /// transfer history across [addresses] — passed as a comma-joined
  /// `addresses` query — merge-sorts by block time, and returns an
  /// `ActivityListResponse`.
  ///
  /// The route is chain-aware: it classifies each address and routes it to the
  /// upstream that can answer for it (Solana → Helius, Ethereum → Alchemy,
  /// Tezos → TzKT), reading [mint] in that chain's terms. So [addresses] is
  /// simply the caller's portfolio scope on the token's chain (see
  /// `TokenDetailBloc._historyAddresses`) — wallets on another chain would only
  /// cost a round-trip to return nothing.
  ///
  /// On API failure the call rethrows — callers (the bloc) decide whether to
  /// fall back to the cache.
  Future<TokenTransfersResult> fetchTransfers({
    required List<String> addresses,
    required String mint,
    String? paginationToken,
    int limit = 50,
  }) async {
    if (addresses.isEmpty) return const TokenTransfersResult(activities: []);

    final response = await _dio.get<Map<String, dynamic>>(
      '${Config.apiV2BaseUrl}/transfers',
      queryParameters: {
        'mint': mint,
        // Comma-joined so the Rust handler's single `addresses` param can
        // split it; a repeated-key list would not deserialize server-side.
        'addresses': addresses.join(','),
        'limit': limit,
        'paginationToken': ?paginationToken,
      },
    );

    // 🛑 Double envelope: the route returns the `ActivityListResponse` wrapped
    // in the shared v2 `ApiResponse` — `{"result": {"result": [...],
    // "pagination": {...}}}` — unlike `/v2/activity`, which returns it bare.
    // Reading `result` as the row list casts a Map to a List and throws, which
    // the bloc's catch turns into a permanently empty History tab.
    final payload = response.data?['result'] as Map<String, dynamic>?;
    final list = (payload?['result'] as List?) ?? const [];
    final activities = list
        .whereType<Map<String, dynamic>>()
        .map(api.Activity.fromJson)
        .toList();

    await _cacheActivities(addressScopeKey(addresses), mint, activities);

    final pagination = payload?['pagination'] as Map<String, dynamic>?;

    return TokenTransfersResult(
      activities: activities,
      paginationToken: pagination?['lastSignature'] as String?,
    );
  }

  /// Read cached activities for this (scope, mint), newest first. [cacheKey] is
  /// the [addressScopeKey] of the addresses the page was fetched for — a bare
  /// wallet address for the single-wallet and EVM paths.
  Future<List<api.Activity>> getCachedActivities({
    required String cacheKey,
    required String mint,
    int? limit,
  }) async {
    final rows = await _database.getTokenTransfers(
      cacheKey,
      mint,
      limit: limit,
    );
    return rows.map(_decodeActivity).toList();
  }

  Future<DateTime?> getCacheTimestamp(String walletAddress, String mint) {
    return _database.getTokenTransfersCacheTime(walletAddress, mint);
  }

  Future<bool> isCacheStale(String walletAddress, String mint) async {
    return CacheFreshness.isStale(
      await getCacheTimestamp(walletAddress, mint),
      _staleTtl,
    );
  }

  Future<void> pruneOldCache() {
    return _database.deleteOldTokenTransfers(
      CacheFreshness.pruneCutoffEpoch(_pruneRetention),
    );
  }

  // ---------------------------------------------------------------------------
  // Internal: cache encode/decode
  // ---------------------------------------------------------------------------

  Future<void> _cacheActivities(
    String walletAddress,
    String mint,
    List<api.Activity> activities,
  ) async {
    if (activities.isEmpty) return;
    final now = CacheFreshness.nowEpochSeconds();

    final companions = activities
        .map(
          (activity) => TokenTransfersCompanion(
            walletAddress: Value(walletAddress),
            mint: Value(mint),
            activityId: Value(activity.id),
            signature: Value(activity.signature),
            jsonData: Value(jsonEncode(activity.toJson())),
            timestamp: Value(activity.timestamp),
            cachedAt: Value(now),
          ),
        )
        .toList();

    await _database.upsertTokenTransfers(companions);
  }

  api.Activity _decodeActivity(TokenTransfer dbRow) {
    final json = jsonDecode(dbRow.jsonData) as Map<String, dynamic>;
    return api.Activity.fromJson(json);
  }
}
