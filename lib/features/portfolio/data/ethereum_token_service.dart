import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' show EvmHolding;

import '../../../core/config/environment.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../models/token_balance.dart';
import 'uniswap_token_list_service.dart';

import '../../../shared/utils/chain.dart';

/// Fetches an Ethereum address's native + ERC-20 balances via the mallow **v2**
/// backend proxy (`GET {apiV2BaseUrl}/evm/balances`), classifies each token
/// verified/unverified against the Uniswap list ([UniswapTokenListService]),
/// suppresses spam/dust, and write-through caches into [CachedBalances]
/// (chain = `ethereum`).
///
/// Mirrors `TokenRepository` (Solana) in shape — per-address in-flight
/// coalescing and stale-cache fallback — but is a separate provider because
/// the data source and chain semantics differ. Ethereum is mainnet-only in
/// every environment.
@lazySingleton
class EthereumTokenService {
  EthereumTokenService(this._database, this._uniswapList, this._dio);

  final MallowDatabase _database;
  final UniswapTokenListService _uniswapList;
  final Dio _dio;

  static const _chain = Chain.ethereum;
  static const _chainParam = 'ethereum';

  /// Contracts always treated as verified even if the Uniswap fetch is cold —
  /// the bluest-chip ERC-20s. The Uniswap list already includes these; this is
  /// a first-launch safety net so they don't flash as "unverified". Lowercased.
  static const _alwaysVerified = <String>{
    '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2', // WETH
    '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // USDC
    '0xdac17f958d2ee523a2206206994597c13d831ec7', // USDT
    '0x6b175474e89094c44da98b954eedeac495271d0f', // DAI
  };

  /// Unverified ERC-20s with no USD price and a UI balance below this are
  /// dropped as spam/scam airdrops. Verified tokens and any priced token are
  /// always kept regardless of size.
  static const _dustThreshold = 0.000001;

  /// Per-address in-flight fetches, keyed by lowercased address. Many consumers
  /// (tokens tab, drawer, header aggregate) hit the same address at once; they
  /// share one network round instead of stampeding the proxy.
  final Map<String, Future<List<TokenBalance>>> _inFlight = {};

  /// Native + ERC-20 balances for [address]. Network-first with a cache
  /// fallback: on any failure the last cached rows are returned so the
  /// portfolio degrades gracefully instead of dropping the chain.
  Future<List<TokenBalance>> getTokenBalances(String address) {
    final key = address.toLowerCase();
    final existing = _inFlight[key];
    if (existing != null) return existing;

    // NB: a block body, not `() => _inFlight.remove(key)`. `remove` returns the
    // very future this callback is attached to, and whenComplete awaits a
    // returned future — an arrow body would make it wait on itself and
    // deadlock, so getTokenBalances would never complete. (Mirrors the same
    // guard in TokenRepository.getTokenBalances.)
    final future = _fetch(address).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<List<TokenBalance>> _fetch(String address) async {
    final verified = await _uniswapList.verifiedContracts();
    try {
      final holdings = await _fetchFromApi(address);
      final tokens = holdings
          .map((h) => TokenBalance.fromEvmHolding(h))
          .where((t) => t.rawBalance > 0)
          .map((t) => t.copyWith(isVerified: _resolveVerified(t, verified)))
          .where(_keepToken)
          .toList();
      final sorted = _sorted(tokens);
      await _cache(address, sorted);
      return sorted;
    } catch (_) {
      return _readCache(address, verified);
    }
  }

  Future<List<EvmHolding>> _fetchFromApi(String address) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '${Config.apiV2BaseUrl}/evm/balances',
      queryParameters: {'address': address, 'chain': _chainParam},
    );
    // Spec (`getV2EvmBalances`): `{ "result": [EvmHolding, ...] }`. Parse via
    // the generated model so the shape stays tied to the OpenAPI contract.
    final list = (response.data?['result'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(EvmHolding.fromJson)
        .toList();
  }

  /// A token is verified if it's native ETH, on the Uniswap list, or in the
  /// always-verified safety net.
  static bool _resolveVerified(TokenBalance token, Set<String> verified) {
    if (token.isNative) return true;
    final mint = token.mint.toLowerCase();
    return verified.contains(mint) || _alwaysVerified.contains(mint);
  }

  /// Spam/dust gate: keep native ETH, every verified token, and any token with
  /// a USD price; drop only unverified, unpriced, near-zero airdrops.
  static bool _keepToken(TokenBalance token) {
    if (token.isNative || token.isVerified) return true;
    if (token.pricePerToken != null) return true;
    return token.uiBalance >= _dustThreshold;
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

  /// Cached ETH balances for [address] without a network call — used for the
  /// instant cache-first portfolio paint while the live fetch is in flight.
  Future<List<TokenBalance>> getCachedBalances(String address) async {
    final verified = await _uniswapList.verifiedContracts();
    return _readCache(address, verified);
  }

  Future<List<TokenBalance>> _readCache(
    String address,
    Set<String> verified,
  ) async {
    final rows = await _database.getBalances(address);
    final tokens = rows.map((db) {
      final base = TokenBalance(
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
        chain: Chain.fromDbString(db.chain),
      );
      return base.copyWith(isVerified: _resolveVerified(base, verified));
    }).toList();
    return _sorted(tokens);
  }
}
