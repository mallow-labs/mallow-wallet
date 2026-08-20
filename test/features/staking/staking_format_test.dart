import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/staking/staking_format.dart';

void main() {
  group('sol', () {
    test('uses 2 dp at or above 0.1, trimming trailing zeros', () {
      expect(StakingFormat.sol(124.39), '124.39');
      expect(StakingFormat.sol(10), '10');
    });

    test('uses 4 dp below 0.1', () {
      expect(StakingFormat.sol(0.05), '0.05');
    });

    test('lamports convert at 1e9', () {
      expect(StakingFormat.lamportsToSol(1000000000), 1.0);
      expect(StakingFormat.lamportsSol(510000000), '0.51');
    });
  });

  group('abbreviate / withCommas', () {
    test('abbreviates thousands and millions', () {
      expect(StakingFormat.abbreviate(125000), '125k');
      expect(StakingFormat.abbreviate(273400), '273.4k');
      expect(StakingFormat.abbreviate(1500000), '1.5M');
    });

    test('keeps sub-thousand values plain', () {
      expect(StakingFormat.abbreviate(281), '281');
    });

    test('groups thousands with commas', () {
      expect(StakingFormat.withCommas(55458), '55,458');
    });

    test('usd prefixes ~\$ with 2 dp and commas', () {
      expect(StakingFormat.usd(881.13), r'~$881.13');
      expect(StakingFormat.usd(1234.5), r'~$1,234.5');
    });
  });

  group('apy', () {
    test('renders a fraction as a percentage', () {
      expect(StakingFormat.apy(0.0574), '5.74%');
      expect(StakingFormat.apy(0.0559), '5.59%');
    });
  });

  group('seasonEnd', () {
    test('shows the inclusive last day as an ordinal date', () {
      // Webapp subtracts a day from the exclusive end.
      expect(StakingFormat.seasonEnd(DateTime(2026, 7)), '30th June');
      expect(StakingFormat.seasonEnd(DateTime(2026, 6, 2)), '1st June');
    });

    test('handles a null end date', () {
      expect(StakingFormat.seasonEnd(null), '—');
    });
  });
}
