import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/price_format.dart';

void main() {
  group('stripTrailingZeros', () {
    test('returns input unchanged when no decimal point', () {
      expect(stripTrailingZeros('0'), '0');
      expect(stripTrailingZeros('1234'), '1234');
      expect(stripTrailingZeros('-7'), '-7');
    });

    test('strips trailing zeros after the decimal point', () {
      expect(stripTrailingZeros('1.200'), '1.2');
      expect(stripTrailingZeros('1.20300'), '1.203');
      expect(stripTrailingZeros('0.50'), '0.5');
    });

    test('removes dangling decimal point when all fractionals stripped', () {
      expect(stripTrailingZeros('1.000'), '1');
      expect(stripTrailingZeros('1.'), '1');
      expect(stripTrailingZeros('-12.00'), '-12');
    });

    test('does not touch leading zeros', () {
      expect(stripTrailingZeros('0.5'), '0.5');
      expect(stripTrailingZeros('0.0010'), '0.001');
    });
  });

  group('displayDecimal', () {
    test('whole numbers render with no decimal point', () {
      expect(displayDecimal(0), '0');
      expect(displayDecimal(1), '1');
      expect(displayDecimal(1234), '1234');
      expect(displayDecimal(-5), '-5');
    });

    test('fractional numbers strip trailing zeros', () {
      expect(displayDecimal(0.5), '0.5');
      expect(displayDecimal(1.25), '1.25');
    });

    test('caps fractional output at 6 decimal places', () {
      // 1.234567891 — should truncate the toStringAsFixed at 6.
      final out = displayDecimal(1.234567891);
      // After the decimal point, no more than 6 chars.
      final dotIdx = out.indexOf('.');
      expect(dotIdx, isNonNegative);
      expect(out.length - dotIdx - 1, lessThanOrEqualTo(6));
    });

    test('negative fractional', () {
      expect(displayDecimal(-0.5), '-0.5');
    });

    test('values that look whole after truncation still drop the decimal', () {
      // 1.000000001 rounds via toStringAsFixed(6) to '1.000000' → stripped to '1'.
      // Note: function uses value == value.truncateToDouble() first; that's
      // false for 1.000000001, so it routes through stringAsFixed → strip.
      // Either '1' or '1.0' would be acceptable display; this guards the
      // documented behaviour.
      expect(displayDecimal(1.000000001), '1');
    });
  });

  group('groupThousands / formatCount', () {
    // A returning webapp user reads every number the webapp grouped for them
    // (JS `toLocaleString`). Ungrouped, "1234 sold" and "$1234567" of volume
    // are read wrong at a glance — an order of magnitude is one missing comma.
    test('groups the integer part from the right', () {
      expect(groupThousands('1234'), '1,234');
      expect(groupThousands('1234567'), '1,234,567');
    });

    test('leaves three digits or fewer alone', () {
      expect(groupThousands('0'), '0');
      expect(groupThousands('999'), '999');
    });

    test('never touches the fractional part', () {
      // Grouping the decimals would invent precision that isn't there.
      expect(groupThousands('1234.5678'), '1,234.5678');
      expect(groupThousands('0.123456'), '0.123456');
    });

    test('preserves a leading sign and a trailing suffix', () {
      // Abbreviated tiers arrive as "1500B"; the suffix must survive.
      expect(groupThousands('-1234.5'), '-1,234.5');
      expect(groupThousands('1500B'), '1,500B');
    });

    test('returns non-numeric input untouched', () {
      // Callers pass already-formatted strings, some of which are words
      // ("Free", "Not listed") — those must pass through unharmed.
      expect(groupThousands('Free'), 'Free');
      expect(groupThousands(''), '');
    });

    test('formatCount groups a plain integer', () {
      expect(formatCount(1234), '1,234');
      expect(formatCount(0), '0');
      expect(formatCount(-12345), '-12,345');
    });
  });

  group('formatUsd', () {
    // One shared helper replaced four pasted copies (drawer wallets tab, edit
    // accounts, edit profiles, portfolio headline) that had already diverged
    // on grouping. Every USD figure the app renders now goes through here, so
    // the table below is the contract for all four surfaces at once.
    const cases = <(double, String)>[
      // Zero and sub-dollar amounts still show both cents digits — a bare
      // "$0" reads as "no data" rather than "nothing yet".
      (0, r'$0.00'),
      (0.5, r'$0.50'),
      (9.99, r'$9.99'),
      // Grouping is unconditional: three of the four surfaces gained it in
      // this consolidation, because a returning webapp user reads every USD
      // figure grouped and "$1234567" is misread by an order of magnitude.
      (999, r'$999.00'),
      (1000, r'$1,000.00'),
      (1234.56, r'$1,234.56'),
      (1234567.891, r'$1,234,567.89'),
      // A whole portfolio-sized figure must not lose a separator.
      (987654321.05, r'$987,654,321.05'),
    ];

    for (final (input, expected) in cases) {
      test('formats $input as $expected', () {
        expect(formatUsd(input), expected);
      });
    }

    test('carries a full 100 cents into the dollars', () {
      // The bug this helper exists to prevent: deriving the dollars by
      // truncation and the cents by rounding the remainder independently let
      // the cents reach 100, which padLeft(2) left as "100" — 9.999 rendered
      // as "$9.100", a 10x misread of the user's balance. Rounding to a
      // single total-cents integer first is what keeps the halves consistent.
      expect(formatUsd(9.999), r'$10.00');
      expect(formatUsd(0.999), r'$1.00');
      expect(formatUsd(999.999), r'$1,000.00');
    });

    test('rounds on the actual double, matching the webapp', () {
      // 9.995 is not representable: the nearest double is 9.99499999...,
      // so JS `toLocaleString`/`toFixed` on the webapp render "9.99" too.
      // Pinned so a future "round half up" rewrite has to justify diverging.
      expect(formatUsd(9.995), r'$9.99');
      expect(formatUsd(0.005), r'$0.01');
    });

    test('puts the sign outside the currency symbol', () {
      // Only the 24h-change row can go negative; "-$5.00" is the webapp form.
      expect(formatUsd(-5), r'-$5.00');
      expect(formatUsd(-1234.56), r'-$1,234.56');
    });

    test('a negative that rounds to zero loses its sign', () {
      // "-$0.00" reads as a bug, not as a rounding artefact.
      expect(formatUsd(-0.004), r'$0.00');
      expect(formatUsd(-0.0), r'$0.00');
    });
  });
}
