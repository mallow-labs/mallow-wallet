import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/address_scope_key.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/utils/token_amount.dart';

/// Repository for fetching and caching activity data.
///
/// Implements three-tier caching:
/// 1. Memory (in-bloc state) - instant access
/// 2. Drift DB (Activities table) - persistent, 24h TTL
/// 3. Backend API + Redis (60s TTL) - fresh data
@lazySingleton
class ActivityRepository {
  ActivityRepository(this._apiV2, this._database);

  final api.MallowApiV2Client _apiV2;
  final MallowDatabase _database;

  /// Activities written locally after a successful transaction but before the
  /// indexer exposes them through `/v2/activity`. They are overlaid on the
  /// next page-0 response and removed as soon as the server returns the same
  /// transaction.
  final Map<String, Map<String, api.Activity>> _optimisticActivities = {};

  static const _pruneRetention = Duration(hours: 24);
  static const _staleTtl = Duration(minutes: 5);

  /// Fetch the aggregated activity feed from the public v2 read
  /// `GET /v2/activity`.
  ///
  /// [addresses] is the REQUIRED plural set of session wallet addresses the
  /// feed aggregates over (sourced from `SessionManager.sessionWallets`). The
  /// backend routes each address by chain (Solana/EVM/Tezos), merges, and
  /// paginates the combined result.
  ///
  /// Returns [api.ActivityListResponse] with activities and pagination info.
  /// The endpoint returns [ActivityListResponse] directly (no [ApiResponse]
  /// wrapper).
  Future<api.ActivityListResponse> getActivities({
    required List<String> addresses,
    int? page,
    int? limit,
    List<api.ActivityType>? types,
    String? before,
  }) async {
    final typesString = types?.map((t) => t.name).join(',');

    final response = await _apiV2.getActivities(
      addresses: addresses.join(','),
      page: page,
      limit: limit,
      types: typesString,
      before: before,
    );

    // Only page 0 is the fresh head of the feed. Appending a locally-created
    // row to an older cursor page could disturb pagination ordering.
    if (page != null && page != 0) return response;

    final cacheKey = addressScopeKey(addresses);
    final cachedOptimistic = (await getCachedActivities(
      cacheKey,
    )).where(_isOptimistic).toList();
    final local = {
      for (final activity in [
        ...?_optimisticActivities[cacheKey]?.values,
        ...cachedOptimistic,
      ])
        activity.id: activity,
    };

    final serverKeys = {
      for (final activity in response.result) ...[
        activity.id,
        activity.signature,
      ],
    };
    final resolvedIds = local.values
        .where(
          (activity) =>
              serverKeys.contains(activity.id) ||
              serverKeys.contains(activity.signature),
        )
        .map((activity) => activity.id)
        .toList();
    for (final id in resolvedIds) {
      _optimisticActivities[cacheKey]?.remove(id);
      local.remove(id);
    }
    if (local.isEmpty) return response;

    final merged = [...response.result, ...local.values]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return response.copyWith(result: merged);
  }

  /// Get cached activities from the local database.
  ///
  /// Returns activities for the given wallet address, ordered by timestamp.
  Future<List<api.Activity>> getCachedActivities(
    String walletAddress, {
    int? limit,
  }) async {
    final dbActivities = await _database.getActivities(
      walletAddress,
      limit: limit,
    );

    return dbActivities.map(_mapDbActivityToModel).toList();
  }

  /// Cache activities to the local database.
  Future<void> cacheActivities(
    String walletAddress,
    List<api.Activity> activities,
  ) async {
    final companions = activities
        .map((a) => _mapActivityToCompanion(walletAddress, a))
        .toList();

    await _database.upsertActivities(companions);
  }

  /// Persist an activity created locally after a successful send and retain it
  /// as an overlay until the activity endpoint returns the indexed row.
  ///
  /// This is deliberately best-effort: a cache failure must never turn a
  /// confirmed transaction into a failed send. The in-memory overlay is set
  /// before the database write so an already-open activity sheet can render it
  /// during the same event loop turn.
  Future<void> cacheOptimisticActivity({
    required List<String> addresses,
    required api.Activity activity,
  }) async {
    if (addresses.isEmpty) return;
    final cacheKey = addressScopeKey(addresses);
    final stored = activity.copyWith(
      data: {...activity.data, '_optimistic': true},
    );
    (_optimisticActivities[cacheKey] ??= {})[stored.id] = stored;

    try {
      await _database.upsertActivity(_mapActivityToCompanion(cacheKey, stored));
    } catch (_) {
      // The network response or the in-memory overlay will still reconcile it.
    }
  }

  /// Check if the cache is stale (older than the stale TTL).
  Future<bool> isCacheStale(String walletAddress) async {
    return CacheFreshness.isStale(
      await getCacheTimestamp(walletAddress),
      _staleTtl,
    );
  }

  /// Get the timestamp of the last cache update for a wallet.
  Future<DateTime?> getCacheTimestamp(String walletAddress) async {
    final activities = await _database.getActivities(walletAddress, limit: 1);
    if (activities.isEmpty) return null;
    return CacheFreshness.fromEpochSeconds(activities.first.cachedAt);
  }

  /// Clear cached activities for a wallet.
  Future<void> clearCache(String walletAddress) async {
    // Delete all activities for this wallet by setting a future cutoff
    final cutoff = CacheFreshness.nowEpochSeconds() + 1;
    await _database.deleteOldActivities(cutoff);
  }

  /// Delete old cached activities (older than the prune retention).
  Future<void> pruneOldCache() async {
    await _database.deleteOldActivities(
      CacheFreshness.pruneCutoffEpoch(_pruneRetention),
    );
  }

  // Convert database Activity to API Activity model
  api.Activity _mapDbActivityToModel(Activity dbActivity) {
    final jsonData = jsonDecode(dbActivity.jsonData) as Map<String, dynamic>;

    return api.Activity(
      id: dbActivity.txId,
      type: _parseActivityType(dbActivity.type),
      timestamp: dbActivity.timestamp,
      signature: dbActivity.txId,
      status: api.ActivityStatus.finalized,
      data: (jsonData['data'] as Map<String, dynamic>?) ?? {},
    );
  }

  api.ActivityType _parseActivityType(String type) {
    return api.ActivityType.values.firstWhere(
      (t) => t.name == type,
      orElse: () => api.ActivityType.unknown,
    );
  }

  bool _isOptimistic(api.Activity activity) =>
      activity.data['_optimistic'] == true;

  // Convert API Activity to database companion
  ActivitiesCompanion _mapActivityToCompanion(
    String walletAddress,
    api.Activity activity,
  ) {
    final now = CacheFreshness.nowEpochSeconds();

    // Extract mint account from data if it's a market activity
    String? mintAccount;
    final marketData = activity.marketData;
    if (marketData != null) {
      mintAccount = marketData.artwork.mintAccount;
    }

    // Extract amount and token mint from data
    int? amount;
    String? tokenMint;

    final transferData = activity.transferData;
    final swapData = activity.swapData;

    if (transferData != null) {
      amount = _rawSmallestUnitOrNull(
        transferData.token.amount,
        transferData.token.decimals,
      );
      tokenMint = transferData.token.mint;
    } else if (swapData != null) {
      amount = _rawSmallestUnitOrNull(
        swapData.inputToken.amount,
        swapData.inputToken.decimals,
      );
      tokenMint = swapData.inputToken.mint;
    }

    return ActivitiesCompanion(
      txId: Value(activity.id),
      walletAddress: Value(walletAddress),
      type: Value(activity.type.name),
      title: Value(_getActivityTitle(activity)),
      mintAccount: Value(mintAccount),
      amount: Value(amount),
      tokenMint: Value(tokenMint),
      jsonData: Value(jsonEncode({'data': activity.data})),
      timestamp: Value(activity.timestamp),
      cachedAt: Value(now),
    );
  }

  /// Raw smallest-unit value for the denormalized [Activities.amount] cache
  /// column, or null when it overflows int64. High-value 18-decimal EVM
  /// transfers (≥ ~9.22 ETH, or any ERC-20 moving thousands of tokens) exceed
  /// int64 once scaled by `10^decimals`, and [TokenAmount.toInt] throws on
  /// those. The column is a write-only convenience — reconstruction reads the
  /// full amount from [jsonData] and never touches it — so dropping it on
  /// overflow keeps one large transfer from failing the entire cache write
  /// (which previously surfaced as a "Failed to load activities" toast).
  int? _rawSmallestUnitOrNull(double amount, int decimals) {
    try {
      return TokenAmount.toInt(
        TokenAmount.parseTokenAmount(
          amount.toStringAsFixed(decimals),
          decimals,
        ),
      );
    } on StateError {
      return null;
    }
  }

  String _getActivityTitle(api.Activity activity) {
    switch (activity.type) {
      case api.ActivityType.sale:
        return 'Sold';
      case api.ActivityType.buy:
        return 'Purchased';
      case api.ActivityType.list:
        return 'Listed';
      case api.ActivityType.delist:
        return 'Delisted';
      case api.ActivityType.offer:
        return 'Made offer';
      case api.ActivityType.offerReceived:
        return 'Received offer';
      case api.ActivityType.mint:
        return 'Minted';
      case api.ActivityType.swap:
        return 'Swapped';
      case api.ActivityType.send:
        return 'Sent';
      case api.ActivityType.receive:
        return 'Received';
      case api.ActivityType.gumballCreate:
        return 'Create Gumball';
      case api.ActivityType.gumballUpdate:
        return 'Update Gumball';
      case api.ActivityType.altCreate:
        return 'Create Lookup Table';
      case api.ActivityType.stake:
        return 'Staked';
      case api.ActivityType.unstake:
        return 'Unstaked';
      case api.ActivityType.stakeWithdraw:
        return 'Claimed stake';
      case api.ActivityType.unknown:
        return 'Transaction';
    }
  }
}

/// Exception thrown when activity operations fail.
class ActivityException implements Exception {
  ActivityException(this.message);

  final String message;

  @override
  String toString() => 'ActivityException: $message';
}
