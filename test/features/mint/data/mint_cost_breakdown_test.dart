import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/mint/data/mint_repository.dart';

/// Tests for [MintCostBreakdown], the pre-mint fee summary shown on the
/// confirmation sheet. The total must include every line item (a dropped
/// component silently under-quotes the user) and the lamports→SOL conversion
/// must preserve sub-lamport precision for display. Both are fund-facing.
void main() {
  group('MintCostBreakdown', () {
    test('totalLamports sums every fee line item', () {
      const breakdown = MintCostBreakdown(
        mallowFeeLamports: 1000000,
        protocolFeeLamports: kCoreProtocolFeeLamports,
        rentLamports: kCoreRentLamports,
        txFeeLamports: 5000,
      );

      expect(
        breakdown.totalLamports,
        1000000 + kCoreProtocolFeeLamports + kCoreRentLamports + 5000,
      );
    });

    test('totalSol converts lamports using the canonical divisor', () {
      const breakdown = MintCostBreakdown(
        mallowFeeLamports: kLamportsPerSol ~/ 2, // 0.5 SOL
        protocolFeeLamports: 0,
        rentLamports: 0,
        txFeeLamports: 0,
      );

      expect(breakdown.totalSol, 0.5);
    });

    test('preserves precision for a realistic Core-asset mint', () {
      const breakdown = MintCostBreakdown(
        mallowFeeLamports: 0,
        protocolFeeLamports: kCoreProtocolFeeLamports, // 0.0015 SOL
        rentLamports: kCoreRentLamports, // 0.0025 SOL
        txFeeLamports: 5000, // 0.000005 SOL
      );

      expect(breakdown.totalLamports, 4005000);
      expect(breakdown.totalSol, closeTo(0.004005, 1e-9));
    });

    test('a fully zeroed breakdown totals zero', () {
      const breakdown = MintCostBreakdown(
        mallowFeeLamports: 0,
        protocolFeeLamports: 0,
        rentLamports: 0,
        txFeeLamports: 0,
      );

      expect(breakdown.totalLamports, 0);
      expect(breakdown.totalSol, 0);
    });
  });
}
