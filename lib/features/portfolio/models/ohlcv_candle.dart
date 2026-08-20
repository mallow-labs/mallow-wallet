/// A single OHLCV candlestick data point from GeckoTerminal.
class OhlcvCandle {
  const OhlcvCandle({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final int timestamp; // Unix seconds
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  DateTime get dateTime =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

  /// Parse from GeckoTerminal OHLCV item: [timestamp, open, high, low, close, volume]
  static OhlcvCandle fromList(List<dynamic> row) {
    return OhlcvCandle(
      timestamp: (row[0] as num).toInt(),
      open: (row[1] as num).toDouble(),
      high: (row[2] as num).toDouble(),
      low: (row[3] as num).toDouble(),
      close: (row[4] as num).toDouble(),
      volume: (row[5] as num).toDouble(),
    );
  }

  /// Parse from the CoinGecko coin OHLC item: [timestamp_ms, open, high, low,
  /// close]. Differs from [fromList]: the timestamp is milliseconds (converted
  /// to seconds here) and there is no volume field (defaults to 0).
  static OhlcvCandle fromCoinGeckoOhlc(List<dynamic> row) {
    return OhlcvCandle(
      timestamp: (row[0] as num).toInt() ~/ 1000,
      open: (row[1] as num).toDouble(),
      high: (row[2] as num).toDouble(),
      low: (row[3] as num).toDouble(),
      close: (row[4] as num).toDouble(),
      volume: 0,
    );
  }
}

/// Chart timeframe selector options.
enum ChartTimeframe { all, oneHour, oneDay, oneWeek, oneMonth, oneYear }

extension ChartTimeframeX on ChartTimeframe {
  String get label {
    return switch (this) {
      ChartTimeframe.all => 'All',
      ChartTimeframe.oneHour => '1h',
      ChartTimeframe.oneDay => '1d',
      ChartTimeframe.oneWeek => '1w',
      ChartTimeframe.oneMonth => '1m',
      ChartTimeframe.oneYear => '1y',
    };
  }

  /// GeckoTerminal path segment for this timeframe: /{resolution}?aggregate={agg}&limit={n}
  String get geckoPath {
    return switch (this) {
      ChartTimeframe.all => '/ohlcv/day?limit=1000',
      ChartTimeframe.oneHour => '/ohlcv/minute?aggregate=1&limit=60',
      ChartTimeframe.oneDay => '/ohlcv/minute?aggregate=15&limit=96',
      ChartTimeframe.oneWeek => '/ohlcv/hour?aggregate=1&limit=168',
      ChartTimeframe.oneMonth => '/ohlcv/hour?aggregate=4&limit=180',
      ChartTimeframe.oneYear => '/ohlcv/day?limit=365',
    };
  }

  /// `days` window for the CoinGecko coin OHLC endpoint (used for native assets
  /// with no on-chain pool, e.g. XTZ). Only the API's discrete buckets are
  /// valid (1, 7, 30, 365, max); candle granularity is auto-selected by the API
  /// (30m ≤2d, 4h for 3–30d, 4d for 31d+), so sub-day timeframes can't be finer
  /// than a day and both 1h/1d map to `1`.
  String get coinGeckoDays {
    return switch (this) {
      ChartTimeframe.oneHour => '1',
      ChartTimeframe.oneDay => '1',
      ChartTimeframe.oneWeek => '7',
      ChartTimeframe.oneMonth => '30',
      ChartTimeframe.oneYear => '365',
      ChartTimeframe.all => 'max',
    };
  }
}
