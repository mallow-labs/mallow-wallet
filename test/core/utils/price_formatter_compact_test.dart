import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/price_formatter.dart';

/// Covers the four compact-display formatters that the existing
/// `price_formatter_test.dart` does not exercise:
/// `formatCompactAmount`, `formatCompactPrice`, `formatSpotPrice`, and
/// `formatCompactValue`. These render token amounts, marketplace prices,
/// spot prices, and market-cap/volume figures across the market and
/// portfolio screens, so the tier boundaries (1K / 1M) and decimal clamping
/// are correctness-critical: a misplaced threshold shows "1000.00" where the
/// UI expects "1.00K" (or vice versa).
void main() {
  group('PriceFormatter.formatCompactAmount', () {
    test('millions tier clamps decimals to 2 and suffixes M', () {
      expect(PriceFormatter.formatCompactAmount(1500000, 6), '1.50M');
    });

    test('exactly 1,000,000 enters the M tier (>= boundary, inclusive)', () {
      expect(PriceFormatter.formatCompactAmount(1000000, 2), '1.00M');
    });

    test('thousands tier clamps decimals to 2 and suffixes K', () {
      expect(PriceFormatter.formatCompactAmount(2500, 6), '2.50K');
    });

    test('exactly 1,000 enters the K tier', () {
      expect(PriceFormatter.formatCompactAmount(1000, 2), '1.00K');
    });

    test('just below 1,000 stays in the base tier (no K suffix)', () {
      expect(PriceFormatter.formatCompactAmount(999.99, 2), '999.99');
    });

    test('base tier (>= 1) clamps to maxBaseDecimals (default 4)', () {
      // decimals=9 is clamped to 4 in the [1, 1000) tier.
      expect(PriceFormatter.formatCompactAmount(12.34567, 9), '12.3457');
    });

    test('sub-1 tier clamps to maxSubDecimals (default 6)', () {
      // decimals=9 is clamped to 6 in the (0, 1) tier.
      expect(PriceFormatter.formatCompactAmount(0.123456789, 9), '0.123457');
    });

    test('tighter caps shrink decimals in the sub-1 tier', () {
      expect(
        PriceFormatter.formatCompactAmount(0.123456789, 9, maxSubDecimals: 2),
        '0.12',
      );
    });

    test('zero renders with the requested decimals (sub-1 tier)', () {
      expect(PriceFormatter.formatCompactAmount(0, 2), '0.00');
    });
  });

  group('PriceFormatter.formatCompactPrice', () {
    test('>= 1000 abbreviates with one-decimal K', () {
      expect(PriceFormatter.formatCompactPrice(1500), '1.5K');
    });

    test('exactly 1000 is the K boundary', () {
      expect(PriceFormatter.formatCompactPrice(1000), '1.0K');
    });

    test('sub-1000 keeps up to 4 decimals, stripping trailing zeros', () {
      expect(PriceFormatter.formatCompactPrice(12.5), '12.5');
    });

    test('sub-1000 with full precision keeps 4 decimals', () {
      expect(PriceFormatter.formatCompactPrice(0.1234), '0.1234');
    });

    test('zero collapses to "0" (trailing zeros and dot stripped)', () {
      expect(PriceFormatter.formatCompactPrice(0), '0');
    });
  });

  group('PriceFormatter.formatSpotPrice', () {
    test('>= 1000 uses one-decimal K', () {
      expect(PriceFormatter.formatSpotPrice(1234), '1.2K');
    });

    test('[1, 1000) uses two decimals', () {
      expect(PriceFormatter.formatSpotPrice(12.5), '12.50');
    });

    test('exactly 1 falls in the two-decimal tier', () {
      expect(PriceFormatter.formatSpotPrice(1), '1.00');
    });

    test('[0.001, 1) uses four decimals', () {
      expect(PriceFormatter.formatSpotPrice(0.1234), '0.1234');
    });

    test('exactly 0.001 stays in the four-decimal tier', () {
      expect(PriceFormatter.formatSpotPrice(0.001), '0.0010');
    });

    test('below 0.001 uses eight decimals to keep dust visible', () {
      expect(PriceFormatter.formatSpotPrice(0.0000012), '0.00000120');
    });
  });

  group('PriceFormatter.formatCompactValue', () {
    test('millions tier uses two-decimal M', () {
      expect(PriceFormatter.formatCompactValue(2500000), '2.50M');
    });

    test('exactly 1,000,000 enters the M tier', () {
      expect(PriceFormatter.formatCompactValue(1000000), '1.00M');
    });

    test('thousands tier uses two-decimal K', () {
      expect(PriceFormatter.formatCompactValue(2500), '2.50K');
    });

    test('exactly 1,000 enters the K tier', () {
      expect(PriceFormatter.formatCompactValue(1000), '1.00K');
    });

    test('sub-1000 renders two decimals with no suffix', () {
      expect(PriceFormatter.formatCompactValue(42.5), '42.50');
    });

    test('zero renders as "0.00"', () {
      expect(PriceFormatter.formatCompactValue(0), '0.00');
    });
  });
}
