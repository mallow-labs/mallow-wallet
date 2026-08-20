import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/balance_check.dart';

/// The existing `balance_check_test.dart` exercises the `checkBalance`
/// decision logic, but the user-facing `insufficientMessage` getter has two
/// branches it never reaches: the null-symbol fallback and the
/// zero/negative-deficit case. Those branches are exactly what render when
/// the deficit is unknown — a garbled message here ("need 0 more",
/// "need -5 more") is what users see when a transaction is blocked, so the
/// copy must stay clean.
void main() {
  group('BalanceCheckResult.insufficientMessage', () {
    test('sufficient result (null symbol) falls back to generic copy', () {
      const result = BalanceCheckResult.sufficient();
      expect(result.insufficientMessage, 'Insufficient balance');
    });

    test('zero deficit omits the amount clause', () {
      const result = BalanceCheckResult.insufficient(
        symbol: 'SOL',
        deficitRawAmount: 0,
        deficitDecimals: 9,
      );
      expect(result.insufficientMessage, 'Insufficient SOL');
    });

    test('negative deficit (defensive) omits the amount clause', () {
      // deficitRawAmount should never be negative in practice, but the getter
      // must not emit "need -1 more" if it ever is.
      const result = BalanceCheckResult.insufficient(
        symbol: 'SOL',
        deficitRawAmount: -1,
        deficitDecimals: 9,
      );
      expect(result.insufficientMessage, 'Insufficient SOL');
    });

    test('positive SOL deficit formats lamports as a SOL amount', () {
      // 1,000,000 lamports = 0.001 SOL.
      const result = BalanceCheckResult.insufficient(
        symbol: 'SOL',
        deficitRawAmount: 1000000,
        deficitDecimals: 9,
      );
      expect(result.insufficientMessage, 'Insufficient SOL — need 0.001 more');
    });

    test('small USDC deficit formats at 6 decimals', () {
      // 9 raw units of a 6-decimal token = 0.000009, not "0".
      const result = BalanceCheckResult.insufficient(
        symbol: 'USDC',
        deficitRawAmount: 9,
        deficitDecimals: 6,
      );
      expect(
        result.insufficientMessage,
        'Insufficient USDC — need 0.000009 more',
      );
    });

    test('whole-number deficit renders without a trailing decimal', () {
      // 5 whole USDC (6 decimals) → "5", not "5.000000".
      const result = BalanceCheckResult.insufficient(
        symbol: 'USDC',
        deficitRawAmount: 5000000,
        deficitDecimals: 6,
      );
      expect(result.insufficientMessage, 'Insufficient USDC — need 5 more');
    });
  });
}
