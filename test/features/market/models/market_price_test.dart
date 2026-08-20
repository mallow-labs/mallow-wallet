import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/features/market/models/market_price.dart';

void main() {
  group('MarketPrice.displayAmount', () {
    test('SOL: divides by 10^9 (canonical decimals)', () {
      const p = MarketPrice(rawAmount: 1_500_000_000); // 1.5 SOL
      expect(p.displayAmount, closeTo(1.5, 1e-9));
    });

    test('USDC: divides by 10^6 (canonical decimals)', () {
      const p = MarketPrice(rawAmount: 1_500_000, currencyMint: usdcMint);
      expect(p.displayAmount, closeTo(1.5, 1e-9));
    });

    test('unknown currencyMint falls back to 9 decimals', () {
      // Matches webapp behavior; an unknown listing currency shouldn't
      // render at the wrong scale just because we lost the metadata.
      const p = MarketPrice(rawAmount: 1_000_000_000, currencyMint: 'unknown');
      expect(p.displayAmount, closeTo(1.0, 1e-9));
    });

    test('null currencyMint is treated as SOL', () {
      const p = MarketPrice(rawAmount: 1_000_000_000);
      expect(p.displayAmount, closeTo(1.0, 1e-9));
    });
  });

  group('MarketPrice.effectiveCurrencyMint', () {
    test('returns the explicit mint when set', () {
      const p = MarketPrice(rawAmount: 0, currencyMint: usdcMint);
      expect(p.effectiveCurrencyMint, usdcMint);
    });

    test('defaults to SOL when unset', () {
      const p = MarketPrice(rawAmount: 0);
      expect(p.effectiveCurrencyMint, solMint);
    });
  });

  group('MarketPrice.zero', () {
    test('builds zero amount with optional currency', () {
      final z = MarketPrice.zero(currencyMint: usdcMint);
      expect(z.rawAmount, 0);
      expect(z.currencyMint, usdcMint);
      expect(z.displayAmount, 0);
    });

    test('zero without currency mints to SOL', () {
      final z = MarketPrice.zero();
      expect(z.rawAmount, 0);
      expect(z.effectiveCurrencyMint, solMint);
    });
  });
}
