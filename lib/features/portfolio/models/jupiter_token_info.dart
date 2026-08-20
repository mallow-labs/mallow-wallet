import 'package:freezed_annotation/freezed_annotation.dart';

part 'jupiter_token_info.freezed.dart';
part 'jupiter_token_info.g.dart';

@freezed
sealed class JupiterTokenInfo with _$JupiterTokenInfo {
  const factory JupiterTokenInfo({
    required String mint,
    String? name,
    String? symbol,
    String? logoUri,
    int? decimals,

    // Market data
    double? price,
    double? liquidity,
    double? marketCap,
    double? fdv,
    double? circSupply,
    double? totalSupply,
    int? holders,
    String? createdAt,

    // Authority info (null = frozen/burned)
    String? mintAuthority,
    String? freezeAuthority,
    bool? isMutable,

    // 24h stats
    double? priceChange24h,
    double? volume24h,
    int? uniqueTraders24h,

    // Security / audit
    String? devAddress,
    double? devHoldingPercent,
    double? topHoldersPercent,
  }) = _JupiterTokenInfo;

  factory JupiterTokenInfo.fromJson(Map<String, dynamic> json) =>
      _$JupiterTokenInfoFromJson(json);

  /// Parse a Jupiter v2 search API response item.
  factory JupiterTokenInfo.fromApiResponse(Map<String, dynamic> item) {
    final stats = item['stats24h'] as Map<String, dynamic>?;
    final audit = item['audit'] as Map<String, dynamic>?;

    final buyVolume = (stats?['buyVolume'] as num?)?.toDouble();
    final sellVolume = (stats?['sellVolume'] as num?)?.toDouble();
    final double? volume24h = (buyVolume == null && sellVolume == null)
        ? null
        : (buyVolume ?? 0) + (sellVolume ?? 0);

    return JupiterTokenInfo(
      mint: item['id'] as String? ?? item['mint'] as String? ?? '',
      name: item['name'] as String?,
      symbol: item['symbol'] as String?,
      logoUri: item['icon'] as String?,
      decimals: (item['decimals'] as num?)?.toInt(),
      price: (item['usdPrice'] as num?)?.toDouble(),
      liquidity: (item['liquidity'] as num?)?.toDouble(),
      marketCap: (item['mcap'] as num?)?.toDouble(),
      fdv: (item['fdv'] as num?)?.toDouble(),
      circSupply: (item['circSupply'] as num?)?.toDouble(),
      totalSupply: (item['totalSupply'] as num?)?.toDouble(),
      holders: (item['holderCount'] as num?)?.toInt(),
      createdAt: item['createdAt'] as String?,
      mintAuthority: item['mintAuthority'] as String?,
      freezeAuthority: item['freezeAuthority'] as String?,
      isMutable: item['isMutable'] as bool?,
      priceChange24h: (stats?['priceChange'] as num?)?.toDouble(),
      volume24h: volume24h,
      uniqueTraders24h: (stats?['numTraders'] as num?)?.toInt(),
      devAddress: item['dev'] as String?,
      devHoldingPercent: (audit?['devBalancePercentage'] as num?)?.toDouble(),
      topHoldersPercent: (audit?['topHoldersPercentage'] as num?)?.toDouble(),
    );
  }

  /// Parse a v2 backend EVM token-info payload (`EvmTokenInfo`). Despite sharing
  /// this model, the EVM shape is NOT Jupiter-shaped: it uses its own camelCase
  /// field names (`address`, `priceUsd`, `marketCapUsd`, `logoUrl`,
  /// `priceChange24h`, `totalVolume24hUsd`, `circulatingSupply`), sourced from
  /// CoinGecko. Authority/holder/dev audit fields have no EVM equivalent and
  /// stay null. Caller must unwrap the `{ "result": … }` envelope first.
  factory JupiterTokenInfo.fromEvmTokenInfo(Map<String, dynamic> item) {
    return JupiterTokenInfo(
      mint: item['address'] as String? ?? '',
      name: item['name'] as String?,
      symbol: item['symbol'] as String?,
      logoUri: item['logoUrl'] as String?,
      decimals: (item['decimals'] as num?)?.toInt(),
      price: (item['priceUsd'] as num?)?.toDouble(),
      marketCap: (item['marketCapUsd'] as num?)?.toDouble(),
      circSupply: (item['circulatingSupply'] as num?)?.toDouble(),
      totalSupply: (item['totalSupply'] as num?)?.toDouble(),
      priceChange24h: (item['priceChange24h'] as num?)?.toDouble(),
      volume24h: (item['totalVolume24hUsd'] as num?)?.toDouble(),
    );
  }
}
