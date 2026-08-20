import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../models/jupiter_token_info.dart';

/// Detailed Ethereum token info for the token-detail screen — the EVM analog of
/// [JupiterTokenInfoService]. Fetches `GET {apiV2BaseUrl}/evm/token/{contract}`
/// on the mallow **v2** backend (CoinGecko-sourced) and maps its `EvmTokenInfo`
/// payload into the shared [JupiterTokenInfo] via
/// [JupiterTokenInfo.fromEvmTokenInfo] — the EVM field names differ from
/// Jupiter's, and the response is wrapped in the `{ "result": … }` envelope.
///
/// Caches the raw JSON blob in [CachedEvmTokenInfo] keyed by `(chain, contract)`
/// with a 5-minute TTL, mirroring [JupiterTokenInfoService]: stale-cache
/// fallback on network failure; null only when there is neither cache nor a
/// successful fetch.
@lazySingleton
class EthereumTokenInfoService {
  EthereumTokenInfoService(this._database, this._dio);

  final MallowDatabase _database;
  final Dio _dio;

  static const _chain = 'ethereum';
  static const _staleTtl = Duration(minutes: 5);

  /// Detailed info for an ERC-20 [contractAddress] (lowercased internally).
  Future<JupiterTokenInfo?> getTokenInfo(String contractAddress) async {
    final contract = contractAddress.toLowerCase();
    final cached = await _database.getEvmTokenInfoCache(_chain, contract);
    if (cached != null &&
        !CacheFreshness.isStale(
          CacheFreshness.fromEpochSeconds(cached.cachedAt),
          _staleTtl,
        )) {
      return _decode(cached.jsonData);
    }

    final fetched = await _fetchFromApi(contract);
    if (fetched != null) {
      await _cache(contract, fetched);
      return fetched;
    }

    // Network failed or returned nothing — fall back to stale cache if present.
    return cached != null ? _decode(cached.jsonData) : null;
  }

  Future<JupiterTokenInfo?> _fetchFromApi(String contract) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${Config.apiV2BaseUrl}/evm/token/$contract',
        queryParameters: {'chain': _chain},
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      // The v2 route wraps the token info in the standard `{ "result": {…} }`
      // envelope (`ApiResponse<EvmTokenInfo>`); unwrap it (tolerating an
      // already-unwrapped body) before mapping the EVM field names.
      final item = (data['result'] as Map<String, dynamic>?) ?? data;
      return JupiterTokenInfo.fromEvmTokenInfo(item);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cache(String contract, JupiterTokenInfo info) {
    return _database.upsertEvmTokenInfoCache(
      CachedEvmTokenInfoCompanion(
        contractAddress: Value(contract),
        chain: const Value(_chain),
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
      return null;
    }
  }
}
