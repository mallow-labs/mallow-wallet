import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/network/logging_interceptor.dart';
import '../models/ohlcv_candle.dart';

/// Service for fetching pool and OHLCV data from CoinGecko onchain API.
///
/// Uses the CoinGecko API (see [Config.coinGeckoBaseUrl]).
/// Docs: https://docs.coingecko.com/reference/endpoint-overview
@lazySingleton
class GeckoTerminalService {
  GeckoTerminalService() {
    _dio = Dio(
      BaseOptions(
        baseUrl: '${Config.coinGeckoBaseUrl}/api/v3',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Accept': 'application/json'},
      ),
    );
    _dio.interceptors.add(PrettyLoggingInterceptor());
  }

  late final Dio _dio;

  /// CoinGecko onchain network ids.
  static const networkSolana = 'solana';
  static const networkEthereum = 'eth';

  /// CoinGecko coin id for native XTZ. GeckoTerminal doesn't index Tezos, so
  /// native XTZ is charted via the regular coin OHLC endpoint ([getCoinOhlc])
  /// instead of the onchain pool path.
  static const coinIdTezos = 'tezos';

  /// Fetch OHLC candles for a CoinGecko coin id via the regular markets API
  /// (`/coins/{id}/ohlc`), for native assets that have no chartable on-chain
  /// pool. Returns USD candles with volume 0 (this endpoint omits volume) and
  /// oldest-first. Returns an empty list if the request fails.
  Future<List<OhlcvCandle>> getCoinOhlc(
    String coinId,
    ChartTimeframe timeframe,
  ) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/coins/$coinId/ohlc',
        queryParameters: {
          'vs_currency': 'usd',
          'days': timeframe.coinGeckoDays,
        },
      );
      final data = response.data;
      if (data == null) return [];

      return data
          .whereType<List<dynamic>>()
          .map(OhlcvCandle.fromCoinGeckoOhlc)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Fetch OHLCV candles for a token.
  ///
  /// [tokenAddress] is the Solana mint or the EVM contract address; [network]
  /// selects the CoinGecko onchain network (`solana` default, `eth` for
  /// Ethereum mainnet).
  /// First fetches the top pool for the token, then its OHLCV data. Returns an
  /// empty list if the token has no pools or the request fails.
  Future<List<OhlcvCandle>> getOhlcv(
    String tokenAddress,
    ChartTimeframe timeframe, {
    String network = networkSolana,
  }) async {
    try {
      final poolAddress = await _getTopPool(tokenAddress, network);
      if (poolAddress == null) return [];

      return await _getOhlcvForPool(poolAddress, timeframe, network);
    } catch (_) {
      return [];
    }
  }

  Future<String?> _getTopPool(String tokenAddress, String network) async {
    try {
      // EVM ids/addresses are lowercased in the CoinGecko onchain API.
      final address = network == networkSolana
          ? tokenAddress
          : tokenAddress.toLowerCase();
      final response = await _dio.get<Map<String, dynamic>>(
        '/onchain/networks/$network/tokens/$address/pools',
        queryParameters: {'page': 1},
      );

      final data = response.data?['data'];
      if (data is! List || data.isEmpty) return null;

      // OHLCV on a pool represents the base token's price, so charting requires
      // pools where the queried token is the *base* token. Self-paired pools
      // (e.g. USDC/USDC) are skipped.
      final mintTokenId = '${network}_$address';
      final candidates = <Map<String, dynamic>>[];
      for (final entry in data) {
        if (entry is! Map<String, dynamic>) continue;
        final rels = entry['relationships'] as Map<String, dynamic>?;
        final baseId = _tokenId(rels, 'base_token');
        final quoteId = _tokenId(rels, 'quote_token');
        if (baseId != mintTokenId) continue;
        if (baseId == quoteId) continue;
        candidates.add(entry);
      }

      // Pick the highest-volume pool — the most liquid, representative market.
      // OHLCV is denominated in USD regardless of quote token, so the quote only
      // matters as a tiebreaker: among equal-volume pools prefer the network's
      // stable/native quotes (USDC, USDT, then SOL/WETH). This way a deep WETH
      // pool always beats a near-dead USDC one, while a token's stable pair still
      // wins when liquidity is otherwise tied.
      // Preferred quote ids, network-prefixed to match the pool's quote_token id
      // (e.g. "eth_0xa0b8…"). Index in this list is the preference rank.
      final prefs = _preferredQuotes(
        network,
      ).map((q) => '${network}_$q').toList();
      int quoteRank(Map<String, dynamic> pool) {
        final quoteId = _tokenId(
          pool['relationships'] as Map<String, dynamic>?,
          'quote_token',
        );
        final i = quoteId == null ? -1 : prefs.indexOf(quoteId);
        return i < 0 ? prefs.length : i; // non-preferred quotes sort last
      }

      candidates.sort((a, b) {
        final volCompare = _h24Volume(b).compareTo(_h24Volume(a)); // desc
        return volCompare != 0
            ? volCompare
            : quoteRank(a).compareTo(quoteRank(b)); // asc
      });
      final best = candidates.first;

      // Pool address is in attributes.address or id (e.g. "solana_0xabc...")
      final attrs = best['attributes'] as Map<String, dynamic>?;
      return attrs?['address'] as String? ??
          (best['id'] as String?)?.split('_').last;
    } catch (_) {
      return null;
    }
  }

  Future<List<OhlcvCandle>> _getOhlcvForPool(
    String poolAddress,
    ChartTimeframe timeframe,
    String network,
  ) async {
    try {
      // timeframe.geckoPath is e.g. "/ohlcv/day?limit=1000"
      // We strip the leading / and split into path + query
      final geckoPath = timeframe.geckoPath;
      final parts = geckoPath.split('?');
      final pathSuffix = parts[0]; // e.g. "/ohlcv/day"
      final queryString = parts.length > 1 ? parts[1] : '';

      // Build query parameters map
      final queryParams = <String, dynamic>{};
      if (queryString.isNotEmpty) {
        for (final part in queryString.split('&')) {
          final kv = part.split('=');
          if (kv.length == 2) queryParams[kv[0]] = kv[1];
        }
      }

      final response = await _dio.get<Map<String, dynamic>>(
        '/onchain/networks/$network/pools/$poolAddress$pathSuffix',
        queryParameters: queryParams,
      );

      final data = response.data?['data'] as Map<String, dynamic>?;
      final attrs = data?['attributes'] as Map<String, dynamic>?;
      final ohlcvList = attrs?['ohlcv_list'] as List<dynamic>?;

      if (ohlcvList == null) return [];

      return ohlcvList
          .whereType<List<dynamic>>()
          .map(OhlcvCandle.fromList)
          .toList()
          .reversed
          .toList(); // oldest first
    } catch (_) {
      return [];
    }
  }

  /// Preferred quote-token addresses per network, in priority order. Pools
  /// quoted in these are charted first (highest h24 volume wins within a tier).
  static List<String> _preferredQuotes(String network) => switch (network) {
    networkEthereum => const [_ethUsdc, _ethUsdt, wethAddress],
    _ => const [_usdcMint, _usdtMint, _solMint],
  };

  static const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  static const _usdtMint = 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB';
  static const _solMint = 'So11111111111111111111111111111111111111112';
  // Ethereum quote tokens (lowercased, matching CoinGecko onchain ids).
  static const _ethUsdc = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
  static const _ethUsdt = '0xdac17f958d2ee523a2206206994597c13d831ec7';

  /// Wrapped ETH (WETH) contract address. CoinGecko's onchain API charts
  /// contracts, not the native coin, so native ETH is charted via WETH — the
  /// canonical price proxy for ether.
  static const wethAddress = '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2';

  static String? _tokenId(Map<String, dynamic>? rels, String side) {
    final rel = rels?[side] as Map<String, dynamic>?;
    final data = rel?['data'] as Map<String, dynamic>?;
    return data?['id'] as String?;
  }

  static double _h24Volume(Map<String, dynamic> pool) {
    final attrs = pool['attributes'] as Map<String, dynamic>?;
    final vol = attrs?['volume_usd'] as Map<String, dynamic>?;
    return double.tryParse('${vol?['h24']}') ?? 0;
  }
}
