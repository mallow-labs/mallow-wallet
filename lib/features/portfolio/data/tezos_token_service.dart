import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' show EvmHolding;

import '../../../core/config/environment.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../models/token_balance.dart';

import '../../../shared/utils/chain.dart';

/// Fetches a Tezos address's native XTZ + FA1.2/FA2 balances via the mallow
/// **v2** backend proxy (`GET {apiV2BaseUrl}/tezos/balances`) and write-through
/// caches them into [CachedBalances] (chain = `tezos`).
///
/// The Tezos balances route mirrors `/evm/balances` down to the wire shape —
/// it returns the same holding objects with a `"native"` sentinel for the chain
/// coin, so [TokenBalance.fromEvmHolding] parses both chains identically. The
/// backend (TzKT-sourced) already drops spam/dust and NFT rows, so unlike
/// [EthereumTokenService] there is no Uniswap-style verified-list classification
/// here: every returned fungible is trusted.
///
/// Mirrors `EthereumTokenService` in shape — per-address in-flight coalescing
/// and stale-cache fallback — but is a separate provider because the data
/// source and chain semantics differ. Tezos is mainnet-only on the backend; the
/// `chain` query param is accepted but ignored there.
@lazySingleton
class TezosTokenService {
  TezosTokenService(this._database, this._dio);

  final MallowDatabase _database;
  final Dio _dio;

  static const _chain = Chain.tezos;

  /// Per-address in-flight fetches, keyed by address. Many consumers (tokens
  /// tab, drawer, header aggregate) hit the same address at once; they share one
  /// network round instead of stampeding the proxy. Tezos addresses are
  /// case-sensitive base58, so the key is the address verbatim.
  final Map<String, Future<List<TokenBalance>>> _inFlight = {};

  /// Native XTZ + FA balances for [address]. Network-first with a cache
  /// fallback: on any failure the last cached rows are returned so the portfolio
  /// degrades gracefully instead of dropping the chain.
  Future<List<TokenBalance>> getTokenBalances(String address) {
    final existing = _inFlight[address];
    if (existing != null) return existing;

    // NB: a block body, not an arrow. `remove` returns the very future this
    // callback is attached to, and whenComplete awaits a returned future — an
    // arrow body would make it wait on itself and deadlock. (Mirrors the guard
    // in EthereumTokenService.getTokenBalances.)
    final future = _fetch(address).whenComplete(() {
      _inFlight.remove(address);
    });
    _inFlight[address] = future;
    return future;
  }

  Future<List<TokenBalance>> _fetch(String address) async {
    try {
      final holdings = await _fetchFromApi(address);
      final tokens = holdings
          .map((h) => TokenBalance.fromEvmHolding(h, chain: _chain))
          .where((t) => t.rawBalance > 0)
          // The backend already filtered spam/NFTs; every returned fungible is
          // trusted, so native XTZ and FA tokens alike are marked verified.
          .map((t) => t.copyWith(isVerified: true))
          .toList();
      final sorted = _sorted(tokens);
      await _cache(address, sorted);
      return sorted;
    } catch (_) {
      return _readCache(address);
    }
  }

  Future<List<EvmHolding>> _fetchFromApi(String address) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '${Config.apiV2BaseUrl}/tezos/balances',
      queryParameters: {'address': address},
    );
    // The Rust route reuses the EVM holdings shape, wrapped in the standard
    // `{ "result": [...] }` envelope (`ApiResponse<Vec<EvmHolding>>`). Parse via
    // the generated [EvmHolding] model — same contract as `/evm/balances`.
    final list = (response.data?['result'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(EvmHolding.fromJson)
        .toList();
  }

  List<TokenBalance> _sorted(List<TokenBalance> tokens) {
    return [...tokens]..sort((a, b) {
      if (a.isNative != b.isNative) return a.isNative ? -1 : 1;
      return (b.totalUsdValue ?? 0).compareTo(a.totalUsdValue ?? 0);
    });
  }

  Future<void> _cache(String address, List<TokenBalance> tokens) async {
    final now = CacheFreshness.nowEpochSeconds();
    final companions = tokens
        .map(
          (t) => CachedBalancesCompanion(
            walletAddress: Value(address),
            mint: Value(t.mint),
            symbol: Value(t.symbol),
            name: Value(t.name),
            decimals: Value(t.decimals),
            rawBalance: Value(t.rawBalance),
            uiBalance: Value(t.uiBalance),
            pricePerToken: Value(t.pricePerToken),
            totalUsdValue: Value(t.totalUsdValue),
            logoUrl: Value(t.logoUrl),
            isNative: Value(t.isNative),
            chain: Value(_chain.toDbString()),
            cachedAt: Value(now),
          ),
        )
        .toList();
    await _database.deleteBalances(address);
    await _database.upsertBalances(companions);
  }

  /// Cached Tezos balances for [address] without a network call — used for the
  /// instant cache-first portfolio paint while the live fetch is in flight.
  Future<List<TokenBalance>> getCachedBalances(String address) =>
      _readCache(address);

  Future<List<TokenBalance>> _readCache(String address) async {
    final rows = await _database.getBalances(address);
    final tokens = rows
        .where((db) => Chain.fromDbString(db.chain) == _chain)
        .map(
          (db) => TokenBalance(
            mint: db.mint,
            symbol: db.symbol,
            name: db.name,
            decimals: db.decimals,
            rawBalance: db.rawBalance,
            uiBalance: db.uiBalance,
            logoUrl: db.logoUrl,
            pricePerToken: db.pricePerToken,
            totalUsdValue: db.totalUsdValue,
            isNative: db.isNative,
            isVerified: true,
            chain: _chain,
          ),
        )
        .toList();
    return _sorted(tokens);
  }
}
