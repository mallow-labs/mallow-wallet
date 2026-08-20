import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' show EvmTokenListResponse;

import '../../../core/config/environment.dart';
import '../../../core/database/database.dart';

/// Verified-token source of truth for Ethereum — the analog of Jupiter's
/// `verified` tag for Solana. A token is "verified" iff its (lowercased)
/// contract address appears on the Uniswap token list, which the mallow **v2**
/// backend proxies/caches upstream (`GET {apiV2BaseUrl}/evm/token-list`).
///
/// Heavily cached, as the list changes rarely:
///   - in-memory for the whole session (no repeat work per portfolio load),
///   - Drift ([CachedEvmTokenList]) for 24h,
///   - network only when both are cold or stale.
///
/// Never throws: on a network failure it falls back to whatever is cached
/// (possibly empty on a first cold run), so a token degrades to *unverified*
/// rather than erroring the portfolio.
@lazySingleton
class UniswapTokenListService {
  UniswapTokenListService(this._database, this._dio);

  final MallowDatabase _database;
  final Dio _dio;

  /// Logical chain. Ethereum is mainnet-only in every environment.
  static const _chain = 'ethereum';

  /// The Uniswap list moves rarely; refresh at most once a day.
  static const _staleTtl = Duration(hours: 24);

  /// Session-lifetime lowercased contract set. Once populated, lookups never
  /// touch the DB or network again until the app restarts.
  Set<String>? _memo;

  /// Coalesces concurrent first-load callers onto a single refresh.
  Future<void>? _inFlight;

  /// Lowercased set of verified contract addresses for Ethereum.
  Future<Set<String>> verifiedContracts() async {
    final memo = _memo;
    if (memo != null) return memo;
    await (_inFlight ??= _ensureFresh().whenComplete(() => _inFlight = null));
    return _memo ?? const {};
  }

  /// True when [contractAddress] is on the Uniswap list (case-insensitive).
  Future<bool> isVerified(String contractAddress) async {
    final set = await verifiedContracts();
    return set.contains(contractAddress.toLowerCase());
  }

  Future<void> _ensureFresh() async {
    final cacheTime = await _database.getEvmTokenListCacheTime(_chain);
    final isStale =
        cacheTime == null || DateTime.now().difference(cacheTime) > _staleTtl;

    if (!isStale) {
      _memo = await _loadContractsFromCache();
      return;
    }

    try {
      final tokens = await _fetchFromApi();
      await _database.replaceEvmTokenList(
        _chain,
        tokens.map(_toCompanion).toList(),
      );
      _memo = tokens.map((t) => t.contractAddress).toSet();
    } catch (_) {
      // Network unavailable — serve stale cache (empty on first cold run).
      _memo = await _loadContractsFromCache();
    }
  }

  Future<Set<String>> _loadContractsFromCache() async {
    final rows = await _database.getEvmTokenList(_chain);
    return rows.map((r) => r.contractAddress).toSet();
  }

  Future<List<_EvmListToken>> _fetchFromApi() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '${Config.apiV2BaseUrl}/evm/token-list',
      queryParameters: {'chain': _chain},
    );
    // Spec (`getV2EvmTokenList`): the Uniswap list is nested under a `result`
    // envelope — `{ "result": { version, updatedAt, tokens: [...] } }`. Parse
    // via the generated model so the shape stays tied to the OpenAPI contract.
    // (Reading `data['tokens']` directly here is the bug that silently emptied
    // the verified set and flagged every ERC-20 as unverified.)
    final result = response.data?['result'];
    if (result is! Map<String, dynamic>) return const [];
    final parsed = EvmTokenListResponse.fromJson(result);
    final tokens = <_EvmListToken>[];
    for (final entry in parsed.tokens) {
      final address = entry.address.toLowerCase();
      if (address.isEmpty) continue;
      tokens.add(
        _EvmListToken(
          contractAddress: address,
          symbol: entry.symbol.trim(),
          name: entry.name.trim(),
          decimals: entry.decimals.toInt(),
          logoUrl: entry.logoURI?.trim(),
        ),
      );
    }
    return tokens;
  }

  CachedEvmTokenListCompanion _toCompanion(_EvmListToken t) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return CachedEvmTokenListCompanion(
      contractAddress: Value(t.contractAddress),
      chain: const Value(_chain),
      symbol: Value(t.symbol),
      name: Value(t.name),
      decimals: Value(t.decimals),
      logoUrl: Value(t.logoUrl),
      cachedAt: Value(now),
    );
  }
}

/// One parsed entry of the Uniswap token list.
class _EvmListToken {
  const _EvmListToken({
    required this.contractAddress,
    this.symbol,
    this.name,
    this.decimals,
    this.logoUrl,
  });

  final String contractAddress;
  final String? symbol;
  final String? name;
  final int? decimals;
  final String? logoUrl;
}
