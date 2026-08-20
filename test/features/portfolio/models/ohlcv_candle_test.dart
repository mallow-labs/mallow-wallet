import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/portfolio/models/ohlcv_candle.dart';

void main() {
  group('OhlcvCandle.fromList', () {
    test('decodes the GeckoTerminal positional payload', () {
      // GeckoTerminal returns [timestamp, open, high, low, close, volume]
      // as positional arrays. Misaligning the order would silently swap
      // OHLC across the entire chart.
      final c = OhlcvCandle.fromList([
        1_700_000_000,
        1.0,
        2.0,
        0.5,
        1.5,
        1234.5,
      ]);
      expect(c.timestamp, 1_700_000_000);
      expect(c.open, 1.0);
      expect(c.high, 2.0);
      expect(c.low, 0.5);
      expect(c.close, 1.5);
      expect(c.volume, 1234.5);
    });

    test('coerces int values to double for price/volume fields', () {
      // Gecko returns ints when the value has no fractional part. We must
      // promote them to double or the model will throw at runtime.
      final c = OhlcvCandle.fromList([1_700_000_000, 1, 2, 0, 1, 100]);
      expect(c.open, 1.0);
      expect(c.volume, 100.0);
    });

    test('dateTime converts unix seconds to milliseconds', () {
      final c = OhlcvCandle.fromList([1_700_000_000, 1, 2, 0, 1, 0]);
      expect(
        c.dateTime,
        DateTime.fromMillisecondsSinceEpoch(1_700_000_000 * 1000),
      );
    });
  });

  group('ChartTimeframe.label', () {
    test('each value has the documented short label', () {
      expect(ChartTimeframe.all.label, 'All');
      expect(ChartTimeframe.oneHour.label, '1h');
      expect(ChartTimeframe.oneDay.label, '1d');
      expect(ChartTimeframe.oneWeek.label, '1w');
      expect(ChartTimeframe.oneMonth.label, '1m');
      expect(ChartTimeframe.oneYear.label, '1y');
    });
  });

  group('ChartTimeframe.geckoPath', () {
    test('uses minute aggregation for short ranges, hour/day for longer', () {
      expect(
        ChartTimeframe.oneHour.geckoPath,
        '/ohlcv/minute?aggregate=1&limit=60',
      );
      expect(
        ChartTimeframe.oneDay.geckoPath,
        '/ohlcv/minute?aggregate=15&limit=96',
      );
      expect(
        ChartTimeframe.oneWeek.geckoPath,
        '/ohlcv/hour?aggregate=1&limit=168',
      );
      expect(
        ChartTimeframe.oneMonth.geckoPath,
        '/ohlcv/hour?aggregate=4&limit=180',
      );
      expect(ChartTimeframe.oneYear.geckoPath, '/ohlcv/day?limit=365');
      expect(ChartTimeframe.all.geckoPath, '/ohlcv/day?limit=1000');
    });
  });
}
