import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/token_amount.dart';

void main() {
  group('TokenAmount.parseTokenAmount', () {
    final cases = <({String input, int decimals, BigInt expected})>[
      // Whole numbers
      (input: '0', decimals: 9, expected: BigInt.zero),
      (input: '1', decimals: 9, expected: BigInt.parse('1000000000')),
      (input: '1234', decimals: 6, expected: BigInt.parse('1234000000')),

      // Common fractional amounts
      (input: '0.1', decimals: 9, expected: BigInt.parse('100000000')),
      (input: '0.000000001', decimals: 9, expected: BigInt.one),
      (input: '1.23', decimals: 9, expected: BigInt.parse('1230000000')),

      // Truncation (NOT rounding) of excess precision — protects users from
      // silent fee inflation when they paste long copy-pasted strings.
      (
        input: '0.123456789012345',
        decimals: 9,
        expected: BigInt.parse('123456789'),
      ),

      // Edge inputs
      (input: '', decimals: 9, expected: BigInt.zero),
      (input: '   ', decimals: 9, expected: BigInt.zero),
      (input: '.5', decimals: 9, expected: BigInt.parse('500000000')),
      (input: '5.', decimals: 9, expected: BigInt.parse('5000000000')),

      // 0-decimal token (NFT-like)
      (input: '42', decimals: 0, expected: BigInt.from(42)),

      // Multiple dots → 0 (defensive: rejects malformed user input)
      (input: '1.2.3', decimals: 9, expected: BigInt.zero),

      // Whitespace stripping
      (input: '  1.5  ', decimals: 9, expected: BigInt.parse('1500000000')),
    ];

    for (final c in cases) {
      test('"${c.input}" with ${c.decimals} decimals → ${c.expected}', () {
        expect(TokenAmount.parseTokenAmount(c.input, c.decimals), c.expected);
      });
    }
  });

  group('TokenAmount.formatTokenAmount', () {
    final cases = <({BigInt raw, int decimals, String expected})>[
      (raw: BigInt.zero, decimals: 9, expected: '0'),
      (raw: BigInt.one, decimals: 9, expected: '0.000000001'),
      (raw: BigInt.from(100000000), decimals: 9, expected: '0.1'),
      (raw: BigInt.parse('1230000000'), decimals: 9, expected: '1.23'),
      (raw: BigInt.parse('1000000000'), decimals: 9, expected: '1'),
      // No decimals: pass-through
      (raw: BigInt.from(42), decimals: 0, expected: '42'),
      // Trailing zero trimming
      (raw: BigInt.parse('123450000'), decimals: 9, expected: '0.12345'),
    ];

    for (final c in cases) {
      test('${c.raw} with ${c.decimals} decimals → "${c.expected}"', () {
        expect(TokenAmount.formatTokenAmount(c.raw, c.decimals), c.expected);
      });
    }
  });

  group('TokenAmount.parseTokenAmount → formatTokenAmount round-trip', () {
    final inputs = ['0', '1', '0.1', '1.23', '0.000000001', '999.5'];

    for (final s in inputs) {
      test('"$s" round-trips through 9 decimals', () {
        final raw = TokenAmount.parseTokenAmount(s, 9);
        // Reformat may strip leading zeroes / trailing zeroes — compare
        // against parse(format(raw)).
        final formatted = TokenAmount.formatTokenAmount(raw, 9);
        expect(TokenAmount.parseTokenAmount(formatted, 9), raw);
      });
    }
  });

  group('TokenAmount sol/lamport helpers', () {
    test('solToLamports("1") == 1_000_000_000 lamports', () {
      expect(TokenAmount.solToLamports('1'), BigInt.from(1000000000));
    });

    test('lamportsToSol(1) == "0.000000001"', () {
      expect(TokenAmount.lamportsToSol(BigInt.one), '0.000000001');
    });

    test('round-trips realistic SOL values losslessly', () {
      for (final s in ['0.5', '12.345678901', '0.000123456']) {
        final lamports = TokenAmount.solToLamports(s);
        // 0.000123456 has only 6 decimals so format trims; compare against
        // the truncated-to-9-decimals canonical form.
        expect(
          TokenAmount.solToLamports(TokenAmount.lamportsToSol(lamports)),
          lamports,
          reason: 'sol→lamports→sol→lamports must be lossless for "$s"',
        );
      }
    });
  });

  group('TokenAmount.toInt', () {
    test('passes small values through', () {
      expect(TokenAmount.toInt(BigInt.from(42)), 42);
      expect(TokenAmount.toInt(BigInt.zero), 0);
    });

    test('throws StateError when value overflows int64', () {
      // 2^63 — one above the int64 max.
      final big = BigInt.parse('9223372036854775808');
      expect(() => TokenAmount.toInt(big), throwsA(isA<StateError>()));
    });

    test('throws StateError when value underflows int64', () {
      final tiny = BigInt.parse('-9223372036854775809');
      expect(() => TokenAmount.toInt(tiny), throwsA(isA<StateError>()));
    });
  });
}
