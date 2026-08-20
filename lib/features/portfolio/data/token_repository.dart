import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';

import '../../../core/config/environment.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/network/logging_interceptor.dart';
import '../../../core/utils/address_format.dart';
import '../models/token_balance.dart';
import 'confirmed_tx_balances.dart';
import 'jupiter_token_service.dart';

/// A confirmed transaction's before/after balance for one holding, held until
/// [_ConfirmedGuard.expiresAt].
typedef _ConfirmedGuard = ({
  int previousRawBalance,
  int rawBalance,
  DateTime expiresAt,
});

@lazySingleton
class TokenRepository {
  TokenRepository(
    this._priceClient,
    this._database,
    this._jupiterTokenService,
  ) {
    final rpcUrl = Config.solanaRpcUrl;
    _dio = Dio(
      BaseOptions(
        baseUrl: rpcUrl,
        headers: {
          'Content-Type': 'application/json',
          // Host-gated: this Dio has no interceptor chain, and the configured
          // RPC may be a public node rather than a first-party proxy.
          ...Config.clientIdHeadersFor(Uri.parse(rpcUrl)),
        },
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    // Add logging interceptor for network visibility
    _dio.interceptors.add(PrettyLoggingInterceptor());
  }

  /// Builds the repository against a caller-supplied [HttpClientAdapter] so
  /// tests can serve canned Helius responses and count the underlying
  /// searchAssets calls (verifying per-wallet request coalescing) without
  /// hitting the live RPC.
  @visibleForTesting
  TokenRepository.withAdapter(
    this._priceClient,
    this._database,
    this._jupiterTokenService,
    HttpClientAdapter adapter,
  ) {
    _dio = Dio(BaseOptions(baseUrl: 'https://helius.test/'))
      ..httpClientAdapter = adapter;
  }

  final JupiterPriceClient _priceClient;
  final MallowDatabase _database;
  final JupiterTokenService _jupiterTokenService;
  late final Dio _dio;

  /// Cache staleness threshold - refresh if older than this. Intentionally
  /// short: balances must reflect transfers promptly. Token *metadata* (names,
  /// logos, market info) lives in the long-lived Jupiter caches instead — don't
  /// lengthen this to cut requests; cache the metadata, not the balances.
  static const _staleTtl = Duration(seconds: 30);

  /// Retention for pruning old entries.
  static const _pruneRetention = Duration(hours: 24);

  /// Helius `searchAssets` page size. 1000 is the documented maximum.
  static const _searchAssetsPageSize = 1000;

  /// Safety cap on `searchAssets` pagination. 10 pages ≈ 10k fungible
  /// accounts, well past any realistic wallet; the cap exists only to
  /// guarantee termination if the API ever returns full pages indefinitely.
  static const _maxSearchAssetsPages = 10;

  /// Per-wallet in-flight balance fetches, keyed by address. Many independent
  /// consumers hit the same wallet at once: [TokenBalanceBloc] is a DI factory
  /// re-created (and re-`load()`ed) per screen/sheet — tokens tab, swap, send,
  /// mint, auction, artwork — plus the wallet drawer fetching every wallet, and
  /// all of them re-fire on every wallet change. Without coalescing each runs
  /// its own searchAssets + Jupiter-enrich round; that burst of redundant
  /// rounds is what produced the duplicate `/tokens/v2/search` traffic and the
  /// 429s. Concurrent callers for the same address share one fetch; the entry
  /// clears once it settles, so the short balance cache handles staleness after.
  final Map<String, Future<List<TokenBalance>>> _inFlightBalances = {};

  /// Broadcasts a wallet address whenever its cached balances were mutated
  /// out-of-band (e.g. by an optimistic post-tx delta). [TokenBalanceBloc]
  /// subscribes so the visible balances reload from the freshly updated cache
  /// before the authoritative Helius refetch lands.
  ///
  /// Chain-agnostic despite living on the Solana repository: the payload is an
  /// address, and a wallet's Solana/Ethereum/Tezos addresses are disjoint
  /// strings, so a subscriber tells the chains apart by the address alone.
  /// `EthereumTokenService` and `TezosTokenService` own their own caches and
  /// write no delta of their own, so they announce a refreshed cache through
  /// [notifyBalancesChanged] rather than a second stream the same two blocs
  /// would have to subscribe to twice.
  final StreamController<String> _invalidationController =
      StreamController<String>.broadcast();
  Stream<String> get balancesInvalidated => _invalidationController.stream;

  /// Announce that [walletAddress]'s cached balances changed on a chain this
  /// repository does not own, without touching the Solana cache.
  ///
  /// The Ethereum/Tezos services write their rows through their own caches, so
  /// there is no delta to apply here — only the signal that makes the tokens
  /// tab and the token-detail sheet re-read. Callers must refresh that chain's
  /// cache **before** signalling: [TokenDetailBloc] answers this by reading the
  /// cache and never the network, so signalling first just re-reads the
  /// pre-transaction row.
  void notifyBalancesChanged(String walletAddress) {
    if (walletAddress.isEmpty || _invalidationController.isClosed) return;
    _invalidationController.add(walletAddress);
  }

  Future<List<TokenBalance>> getTokenBalances(String walletAddress) {
    final existing = _inFlightBalances[walletAddress];
    if (existing != null) return existing;

    // NB: a block body, not `() => _inFlightBalances.remove(...)`. `remove`
    // returns the very future this callback is attached to, and whenComplete
    // awaits a returned future — an arrow body would make it wait on itself
    // and deadlock, so getTokenBalances would never complete.
    final future = _fetchTokenBalances(walletAddress).whenComplete(() {
      _inFlightBalances.remove(walletAddress);
    });
    _inFlightBalances[walletAddress] = future;
    return future;
  }

  Future<List<TokenBalance>> _fetchTokenBalances(String walletAddress) async {
    final allItems = <Map<String, dynamic>>[];
    int? nativeLamports;
    double? nativePricePerSol;

    for (var page = 1; page <= _maxSearchAssetsPages; page++) {
      // Native balance is only meaningful on page 1 — skip the extra work on
      // subsequent pages.
      final isFirstPage = page == 1;

      final response = await _dio.post<Map<String, dynamic>>(
        '',
        data: jsonEncode({
          'jsonrpc': '2.0',
          'id': 'mallow-wallet',
          'method': 'searchAssets',
          'params': {
            'ownerAddress': walletAddress,
            'tokenType': 'fungible',
            'page': page,
            'limit': _searchAssetsPageSize,
            if (isFirstPage) 'displayOptions': {'showNativeBalance': true},
          },
        }),
      );

      final result = response.data?['result'] as Map<String, dynamic>?;
      final items =
          (result?['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      allItems.addAll(items);

      if (isFirstPage) {
        final nativeBalanceData =
            result?['nativeBalance'] as Map<String, dynamic>?;
        nativeLamports = (nativeBalanceData?['lamports'] as num?)?.toInt() ?? 0;
        nativePricePerSol = (nativeBalanceData?['price_per_sol'] as num?)
            ?.toDouble();
      }

      // Last page detected when fewer items returned than the page size.
      if (items.length < _searchAssetsPageSize) break;

      if (page == _maxSearchAssetsPages) {
        debugPrint(
          '[TokenRepository] searchAssets hit pagination cap '
          '($_maxSearchAssetsPages pages × $_searchAssetsPageSize) for $walletAddress; '
          'tail items may be truncated.',
        );
      }
    }

    var tokens = allItems
        .map(TokenBalance.fromHeliusAsset)
        .where((token) => token.rawBalance > 0)
        .toList();

    // Prepend native SOL if balance > 0
    final lamports = nativeLamports ?? 0;
    if (lamports > 0) {
      // Use price from Helius response, fall back to Jupiter if not available
      final solPrice = nativePricePerSol ?? await _fetchSolPrice();
      final solToken = TokenBalance.nativeSol(
        lamports: lamports,
        pricePerToken: solPrice,
      );
      tokens = [solToken, ...tokens];
    }

    // Before pricing: a read taken before one of our own confirmed
    // transactions landed must not roll those balances back.
    tokens = _applyConfirmedGuard(walletAddress, tokens);

    final enriched = await _enrichWithPriceChanges(tokens);

    // Sort by USD value after enrichment — Jupiter may have added prices for
    // tokens Helius didn't cover, so a pre-enrichment sort would misplace them.
    // Native SOL is pinned to first regardless of value.
    return [...enriched]..sort((a, b) {
      if (a.isNative != b.isNative) return a.isNative ? -1 : 1;
      return (b.totalUsdValue ?? 0).compareTo(a.totalUsdValue ?? 0);
    });
  }

  /// Enriches tokens with Jupiter price, 24h change, and verified tag.
  ///
  /// Jupiter's `usdPrice` is preferred over Helius's `price_info.price_per_token`
  /// because Jupiter covers far more tokens; Helius only reports prices for the
  /// well-known set. Helius is used only when Jupiter has no price.
  Future<List<TokenBalance>> _enrichWithPriceChanges(
    List<TokenBalance> tokens,
  ) async {
    try {
      final mints = tokens.map((t) => t.mint).toList();
      final marketInfo = await _jupiterTokenService.getMarketInfo(mints);

      return tokens.map((token) {
        final info = marketInfo[token.mint];
        final effectivePrice = info?.usdPrice ?? token.pricePerToken;
        final effectiveTotal = effectivePrice != null
            ? token.uiBalance * effectivePrice
            : null;
        final withMarket = token.copyWith(
          pricePerToken: effectivePrice,
          totalUsdValue: effectiveTotal,
          priceChange24h: info?.priceChange24h,
          isVerified: _resolveVerified(token, info?.isVerified ?? false),
        );
        return _applyJupiterMetadataFallback(withMarket, info);
      }).toList();
    } catch (_) {
      // Gracefully degrade on Jupiter failure — keep balances, but still apply
      // the always-verified override so SOL/SMORES/USDC_DEV don't get
      // misclassified as unverified.
      return tokens
          .map((t) => t.copyWith(isVerified: _resolveVerified(t, t.isVerified)))
          .toList();
    }
  }

  /// Combines Jupiter's verified tag with mallow's always-verified set
  /// ([TokenBalance.alwaysVerifiedMints]) and the native-asset rule. The
  /// explicit SOL-mint check covers cache reads where `isNative` isn't
  /// persisted.
  static bool _resolveVerified(TokenBalance token, bool jupiterVerified) {
    if (jupiterVerified) return true;
    if (token.isNative || token.mint == TokenBalance.solMint) return true;
    return TokenBalance.alwaysVerifiedMints.contains(token.mint);
  }

  /// Fills in display fields from Jupiter only when Helius (plus any
  /// `_metadataOverrides`/registry overrides) didn't supply them: empty symbol,
  /// the truncated-address name fallback, or a missing logo URL.
  static TokenBalance _applyJupiterMetadataFallback(
    TokenBalance token,
    JupiterMarketInfo? info,
  ) {
    if (info == null) return token;
    final needsSymbol = token.symbol.isEmpty && info.symbol != null;
    final needsName =
        info.name != null && token.name == truncateAddress(token.mint);
    final needsLogo =
        info.iconUrl != null &&
        (token.logoUrl == null || token.logoUrl!.isEmpty);
    if (!needsSymbol && !needsName && !needsLogo) return token;
    return token.copyWith(
      symbol: needsSymbol ? info.symbol! : token.symbol,
      name: needsName ? info.name! : token.name,
      logoUrl: needsLogo ? info.iconUrl : token.logoUrl,
    );
  }

  /// Fetches the current SOL price in USD from Jupiter.
  ///
  /// Returns null if the price fetch fails (graceful degradation).
  Future<double?> _fetchSolPrice() async {
    try {
      final prices = await _priceClient.getPrice(
        const PriceRequestDto(ids: [TokenBalance.solMint]),
      );
      // Price v3 is a flat mint → entry map; an unpriced mint is simply absent.
      return prices[TokenBalance.solMint]?.usdPrice;
    } catch (_) {
      // Gracefully handle price fetch failures - SOL will show without USD value
      return null;
    }
  }

  double calculateTotalValue(List<TokenBalance> tokens) {
    return tokens.fold(0.0, (sum, token) => sum + (token.totalUsdValue ?? 0));
  }

  /// Calculates the USD change for a single token based on its 24h price change.
  ///
  /// Returns null if price change data is unavailable.
  static double? tokenUsdChange(TokenBalance token) {
    final total = token.totalUsdValue;
    final pct = token.priceChange24h;
    if (total == null || pct == null) return null;
    // Exact: current - previous, where previous = current / (1 + pct/100)
    return total - total / (1 + pct / 100);
  }

  /// Calculates portfolio-level 24h change (dollar amount and percentage).
  ///
  /// Returns (dollarChange, percentChange) or null values if unavailable.
  ({double? dollarChange, double? percentChange}) calculatePortfolioChange(
    List<TokenBalance> tokens,
  ) {
    var totalChange = 0.0;
    var hasAnyChange = false;

    for (final token in tokens) {
      final change = tokenUsdChange(token);
      if (change != null) {
        totalChange += change;
        hasAnyChange = true;
      }
    }

    if (!hasAnyChange) {
      return (dollarChange: null, percentChange: null);
    }

    final totalValue = calculateTotalValue(tokens);
    final previousValue = totalValue - totalChange;
    final percentChange = previousValue > 0
        ? (totalChange / previousValue) * 100
        : null;

    return (dollarChange: totalChange, percentChange: percentChange);
  }

  // ============================================================================
  // Caching Methods
  // ============================================================================

  /// Get cached token balances for a wallet.
  /// Returns empty list if no cache exists.
  Future<List<TokenBalance>> getCachedBalances(String walletAddress) async {
    final dbBalances = await _database.getBalances(walletAddress);
    if (dbBalances.isEmpty) return [];

    // Also load cached market data for price changes + verified flag
    final mints = dbBalances.map((b) => b.mint).toList();
    final marketData = await _database.getMarketData(mints);
    final marketMap = {for (final md in marketData) md.mint: md};

    return dbBalances.map((db) {
      final md = marketMap[db.mint];
      // Prefer a fresh Jupiter price from the market cache; fall back to
      // whatever was last persisted on the balance row (which itself preferred
      // Jupiter at write time and fell back to Helius).
      final effectivePrice = md?.usdPrice ?? db.pricePerToken;
      final effectiveTotal = effectivePrice != null
          ? db.uiBalance * effectivePrice
          : null;
      final base = TokenBalance.applyMetadataOverrides(
        TokenBalance(
          mint: db.mint,
          symbol: db.symbol,
          name: db.name,
          decimals: db.decimals,
          rawBalance: db.rawBalance,
          uiBalance: db.uiBalance,
          logoUrl: db.logoUrl,
          pricePerToken: effectivePrice,
          totalUsdValue: effectiveTotal,
          priceChange24h: md?.priceChangePercent24h,
          isNative: db.isNative,
        ),
      );
      final withVerified = base.copyWith(
        isVerified: _resolveVerified(base, md?.isVerified ?? false),
      );
      final info = md == null
          ? null
          : (
              usdPrice: md.usdPrice,
              priceChange24h: md.priceChangePercent24h,
              isVerified: md.isVerified,
              name: md.name,
              symbol: md.symbol,
              iconUrl: md.iconUrl,
            );
      return _applyJupiterMetadataFallback(withVerified, info);
    }).toList();
  }

  /// Cache token balances to the local database.
  Future<void> cacheBalances(
    String walletAddress,
    List<TokenBalance> tokens,
  ) async {
    final now = CacheFreshness.nowEpochSeconds();

    final companions = tokens
        .map(
          (token) => CachedBalancesCompanion(
            walletAddress: Value(walletAddress),
            mint: Value(token.mint),
            symbol: Value(token.symbol),
            name: Value(token.name),
            decimals: Value(token.decimals),
            rawBalance: Value(token.rawBalance),
            uiBalance: Value(token.uiBalance),
            pricePerToken: Value(token.pricePerToken),
            totalUsdValue: Value(token.totalUsdValue),
            logoUrl: Value(token.logoUrl),
            isNative: Value(token.isNative),
            cachedAt: Value(now),
          ),
        )
        .toList();

    // Clear old balances for this wallet and insert new ones
    await _database.deleteBalances(walletAddress);
    await _database.upsertBalances(companions);
  }

  /// Get the timestamp of the last cache update for a wallet.
  Future<DateTime?> getCacheTimestamp(String walletAddress) {
    return _database.getBalancesCacheTime(walletAddress);
  }

  /// Check if the cache is stale (older than staleness threshold).
  Future<bool> isCacheStale(String walletAddress) async {
    return CacheFreshness.isStale(
      await getCacheTimestamp(walletAddress),
      _staleTtl,
    );
  }

  /// Apply a known balance delta to a single cached row, then signal
  /// listeners so the visible portfolio rehydrates from the updated cache.
  ///
  /// No-op when no cached row exists for `(walletAddress, mint, isNative)` —
  /// we don't have the metadata (decimals, symbol, etc.) to synthesize one,
  /// and the post-tx refresh will pick the row up shortly anyway. Still
  /// signals listeners so the refresh kicks off and surfaces the new mint.
  ///
  /// `rawDelta` may be negative (debit) or positive (credit). The row's
  /// `rawBalance`, `uiBalance`, and `totalUsdValue` are recomputed; price and
  /// metadata fields are preserved verbatim.
  Future<void> applyOptimisticDelta({
    required String walletAddress,
    required String mint,
    required int rawDelta,
    required bool isNative,
  }) async {
    if (rawDelta == 0) return;
    final rows = await _database.getBalances(walletAddress);
    final row = rows
        .where((r) => r.mint == mint && r.isNative == isNative)
        .firstOrNull;
    if (row == null) {
      _invalidationController.add(walletAddress);
      return;
    }

    final newRaw = (row.rawBalance + rawDelta).clamp(0, 1 << 62);
    final newUi = row.decimals > 0
        ? newRaw / _pow10(row.decimals)
        : newRaw.toDouble();
    final newTotal = row.pricePerToken == null
        ? null
        : newUi * row.pricePerToken!;
    final now = CacheFreshness.nowEpochSeconds();

    await _database.upsertBalances([
      CachedBalancesCompanion(
        walletAddress: Value(walletAddress),
        mint: Value(mint),
        symbol: Value(row.symbol),
        name: Value(row.name),
        decimals: Value(row.decimals),
        rawBalance: Value(newRaw),
        uiBalance: Value(newUi),
        pricePerToken: Value(row.pricePerToken),
        totalUsdValue: Value(newTotal),
        logoUrl: Value(row.logoUrl),
        isNative: Value(isNative),
        cachedAt: Value(now),
      ),
    ]);

    _invalidationController.add(walletAddress);
  }

  /// Overwrite cached rows with the absolute balances a *confirmed*
  /// transaction reported for this wallet, then signal listeners so the
  /// visible portfolio rehydrates from the updated cache.
  ///
  /// Absolute writes, not deltas, on purpose: the transaction's own metadata
  /// is the post-tx truth, so applying it twice — or after a refetch already
  /// landed the same change — corrects rather than double-counts.
  ///
  /// Mints with no cached row are skipped: there's no metadata (decimals,
  /// symbol, logo) to synthesize one from, and the signalled refetch surfaces
  /// them. Listeners are signalled even for an empty [balances] so a caller
  /// that couldn't read the transaction still gets that refetch.
  Future<void> applyConfirmedBalances({
    required String walletAddress,
    required List<ConfirmedBalance> balances,
    @visibleForTesting Duration? guardTtl,
  }) async {
    _armConfirmedGuards(
      walletAddress,
      balances,
      guardTtl ?? _confirmedGuardTtl,
    );

    if (balances.isNotEmpty) {
      final rows = await _database.getBalances(walletAddress);
      final now = CacheFreshness.nowEpochSeconds();
      final companions = <CachedBalancesCompanion>[];

      for (final balance in balances) {
        final row = rows
            .where(
              (r) => r.mint == balance.mint && r.isNative == balance.isNative,
            )
            .firstOrNull;
        if (row == null) continue;
        if (row.rawBalance == balance.rawBalance) continue;

        final newUi = row.decimals > 0
            ? balance.rawBalance / _pow10(row.decimals)
            : balance.rawBalance.toDouble();
        companions.add(
          CachedBalancesCompanion(
            walletAddress: Value(walletAddress),
            mint: Value(balance.mint),
            symbol: Value(row.symbol),
            name: Value(row.name),
            decimals: Value(row.decimals),
            rawBalance: Value(balance.rawBalance),
            uiBalance: Value(newUi),
            pricePerToken: Value(row.pricePerToken),
            totalUsdValue: Value(
              row.pricePerToken == null ? null : newUi * row.pricePerToken!,
            ),
            logoUrl: Value(row.logoUrl),
            isNative: Value(balance.isNative),
            cachedAt: Value(now),
          ),
        );
      }

      if (companions.isNotEmpty) await _database.upsertBalances(companions);
    }

    _invalidationController.add(walletAddress);
  }

  // ---------------------------------------------------------------------------
  // Confirmed-transaction guard
  // ---------------------------------------------------------------------------

  /// How long a confirmed transaction's balances outrank a Helius read that
  /// still reports the pre-transaction value. Helius indexes within a second
  /// or two — the window only has to outlast that lag, and every guard drops
  /// as soon as one read disagrees with the pre-value anyway.
  static const _confirmedGuardTtl = Duration(seconds: 60);

  /// What a confirmed transaction moved a holding from → to, per wallet and
  /// `mint|isNative`. Helius `searchAssets` carries no slot to compare
  /// against, so `previousRawBalance` stands in for one: a fetch reporting
  /// exactly that value is demonstrably a view from before our own
  /// transaction, and must not overwrite the balance it already moved.
  final Map<String, Map<String, _ConfirmedGuard>> _confirmedGuards = {};

  static String _guardKey(String mint, bool isNative) => '$mint|$isNative';

  void _armConfirmedGuards(
    String walletAddress,
    List<ConfirmedBalance> balances,
    Duration ttl,
  ) {
    final expiresAt = DateTime.now().add(ttl);
    for (final balance in balances) {
      // A holding the transaction didn't move can't identify a stale read.
      if (balance.previousRawBalance == balance.rawBalance) continue;
      _confirmedGuards.putIfAbsent(walletAddress, () => {})[_guardKey(
        balance.mint,
        balance.isNative,
      )] = (
        previousRawBalance: balance.previousRawBalance,
        rawBalance: balance.rawBalance,
        expiresAt: expiresAt,
      );
    }
  }

  /// Corrects a freshly fetched balance list against recently confirmed
  /// transactions, so an indexer read taken before ours landed can't roll the
  /// portfolio back to pre-transaction numbers.
  ///
  /// Only a fetched value *equal to the pre-transaction balance* is treated as
  /// stale. Any other value is a state we haven't seen — our own transaction,
  /// or something newer still (a second swap, an incoming transfer) — so the
  /// fetch wins and the guard is retired. That keeps the window from pinning a
  /// balance that has legitimately moved on.
  List<TokenBalance> _applyConfirmedGuard(
    String walletAddress,
    List<TokenBalance> tokens,
  ) {
    final guards = _confirmedGuards[walletAddress];
    if (guards == null) return tokens;
    final now = DateTime.now();
    guards.removeWhere((_, guard) => !now.isBefore(guard.expiresAt));
    if (guards.isEmpty) {
      _confirmedGuards.remove(walletAddress);
      return tokens;
    }

    final corrected = <TokenBalance>[];
    for (final token in tokens) {
      final key = _guardKey(token.mint, token.isNative);
      final guard = guards[key];
      if (guard == null) {
        corrected.add(token);
        continue;
      }
      if (token.rawBalance != guard.previousRawBalance) {
        guards.remove(key);
        corrected.add(token);
        continue;
      }
      // Stale read — restore the confirmed balance and stay armed until a
      // fetch reports something else (or the window closes).
      if (guard.rawBalance <= 0) continue;
      final uiBalance = token.decimals > 0
          ? guard.rawBalance / _pow10(token.decimals)
          : guard.rawBalance.toDouble();
      corrected.add(
        token.copyWith(
          rawBalance: guard.rawBalance,
          uiBalance: uiBalance,
          totalUsdValue: token.pricePerToken == null
              ? null
              : uiBalance * token.pricePerToken!,
        ),
      );
    }
    return corrected;
  }

  static int _pow10(int exp) {
    var result = 1;
    for (var i = 0; i < exp; i++) {
      result *= 10;
    }
    return result;
  }

  /// Clear cached balances for a wallet.
  Future<void> clearCache(String walletAddress) {
    // A surviving guard would re-apply a confirmed balance onto the fetch that
    // repopulates the cleared cache.
    _confirmedGuards.remove(walletAddress);
    return _database.deleteBalances(walletAddress);
  }

  /// Prune old cached balances (older than the prune retention).
  Future<void> pruneOldCache() {
    return _database.deleteOldBalances(
      CacheFreshness.pruneCutoffEpoch(_pruneRetention),
    );
  }
}
