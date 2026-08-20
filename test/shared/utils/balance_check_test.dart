import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/utils/balance_check.dart';

TokenBalance _sol(int lamports) => TokenBalance.nativeSol(lamports: lamports);

TokenBalance _usdc(int raw) => TokenBalance(
  mint: usdcMint,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: raw,
  uiBalance: raw / 1e6,
);

TokenBalanceState _loaded(List<TokenBalance> tokens) =>
    TokenBalanceState.loaded(tokens: tokens, totalUsdValue: 0);

void main() {
  group('checkBalance', () {
    test('returns sufficient when balances are not loaded', () {
      final result = checkBalance(
        paymentMint: solMint,
        requiredRawAmount: 10_000_000_000,
        balanceState: const TokenBalanceState.initial(),
      );
      expect(result.sufficient, isTrue);
    });

    test('SOL payment short → "Insufficient SOL"', () {
      final result = checkBalance(
        paymentMint: solMint,
        requiredRawAmount: 1_000_000_000, // 1 SOL
        balanceState: _loaded([_sol(500_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'SOL');
    });

    test('SPL short but SOL ok → "Insufficient USDC"', () {
      final result = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 10_000_000, // 10 USDC
        balanceState: _loaded([_sol(5_000_000), _usdc(1_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'USDC');
    });

    test('SPL ok but SOL gas short → "Insufficient SOL" (priority)', () {
      final result = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 1_000_000,
        balanceState: _loaded([_sol(100), _usdc(10_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'SOL');
    });

    test('both short → "Insufficient SOL" wins', () {
      final result = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 10_000_000,
        balanceState: _loaded([_sol(0), _usdc(0)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'SOL');
    });

    test('includeGasReserve: false → sufficient when balance covers payment '
        'exactly (mint case)', () {
      final result = checkBalance(
        paymentMint: solMint,
        requiredRawAmount: 50_000_000,
        balanceState: _loaded([_sol(50_000_000)]),
        includeGasReserve: false,
      );
      expect(result.sufficient, isTrue);
    });

    test('paymentMint not in tokens list → treated as 0 balance, '
        'returns "Insufficient <SYMBOL>"', () {
      final result = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 1_000_000,
        balanceState: _loaded([_sol(10_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'USDC');
    });

    test('gas-only (paymentMint null, requiredRawAmount 0): '
        'sufficient when SOL >= reserve, short when below', () {
      final ok = checkBalance(
        paymentMint: null,
        requiredRawAmount: 0,
        balanceState: _loaded([_sol(kSolGasReserveLamports)]),
      );
      expect(ok.sufficient, isTrue);

      final short = checkBalance(
        paymentMint: null,
        requiredRawAmount: 0,
        balanceState: _loaded([_sol(kSolGasReserveLamports - 1)]),
      );
      expect(short.sufficient, isFalse);
      expect(short.insufficientSymbol, 'SOL');
    });

    test('insufficient SOL payment reports deficit in lamports', () {
      final result = checkBalance(
        paymentMint: solMint,
        requiredRawAmount: 1_000_000_000, // 1 SOL
        balanceState: _loaded([_sol(500_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'SOL');
      // need (1 SOL + gas reserve) − 0.5 SOL
      expect(
        result.deficitRawAmount,
        1_000_000_000 + kSolGasReserveLamports - 500_000_000,
      );
      expect(result.deficitDecimals, 9);
      expect(result.insufficientMessage, contains('more'));
      expect(result.insufficientMessage, contains('SOL'));
    });

    test('insufficient SPL reports deficit in token decimals', () {
      final result = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 10_000_000, // 10 USDC
        balanceState: _loaded([_sol(5_000_000), _usdc(1_000_000)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'USDC');
      expect(result.deficitRawAmount, 9_000_000);
      expect(result.deficitDecimals, 6);
      expect(result.insufficientMessage, 'Insufficient USDC — need 9 more');
    });
  });

  // An edition print costs SOL beyond the listing price — the standard's
  // rent + protocol fee + the marketplace print fee — and the buyer owes it in
  // SOL even when the listing is priced in a token. These pin that the extra
  // is a *separate* term from the payment: fold it into `requiredRawAmount`
  // instead and an SPL-priced edition never checks SOL for it at all, which is
  // exactly the gap that let a wallet with 0.002 SOL start a buy that could
  // only fail on-chain.
  group('checkBalance — additionalSolLamports', () {
    test(
      'SOL payment: the extra is required on top of price + gas reserve',
      () {
        final short = checkBalance(
          paymentMint: solMint,
          requiredRawAmount: 1_000_000_000,
          balanceState: _loaded([_sol(1_000_000_000 + kSolGasReserveLamports)]),
          additionalSolLamports: 15_000_000,
        );
        expect(short.sufficient, isFalse);
        expect(short.deficitRawAmount, 15_000_000);

        final ok = checkBalance(
          paymentMint: solMint,
          requiredRawAmount: 1_000_000_000,
          balanceState: _loaded([
            _sol(1_000_000_000 + kSolGasReserveLamports + 15_000_000),
          ]),
          additionalSolLamports: 15_000_000,
        );
        expect(ok.sufficient, isTrue);
      },
    );

    test('SPL payment: SOL must cover the extra even though the price is paid '
        'in the token', () {
      final short = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 10_000_000,
        // Enough USDC and enough SOL for the reserve — but not for the fee.
        balanceState: _loaded([
          _sol(kSolGasReserveLamports),
          _usdc(10_000_000),
        ]),
        additionalSolLamports: 33_000_000,
      );
      expect(short.sufficient, isFalse);
      expect(short.insufficientSymbol, 'SOL');
      expect(short.deficitRawAmount, 33_000_000);

      final ok = checkBalance(
        paymentMint: usdcMint,
        requiredRawAmount: 10_000_000,
        balanceState: _loaded([
          _sol(kSolGasReserveLamports + 33_000_000),
          _usdc(10_000_000),
        ]),
        additionalSolLamports: 33_000_000,
      );
      expect(ok.sufficient, isTrue);
    });

    test('defaults to 0 — every existing call site keeps its old verdict', () {
      final result = checkBalance(
        paymentMint: solMint,
        requiredRawAmount: 1_000_000_000,
        balanceState: _loaded([_sol(1_000_000_000 + kSolGasReserveLamports)]),
      );
      expect(result.sufficient, isTrue);
    });
  });

  group('checkBalanceOrSkip', () {
    test('null amount → sufficient', () {
      final result = checkBalanceOrSkip(
        paymentMint: solMint,
        requiredRawAmount: null,
        balanceState: _loaded([_sol(0)]),
      );
      expect(result.sufficient, isTrue);
    });

    test('non-null amount → delegates to checkBalance', () {
      final result = checkBalanceOrSkip(
        paymentMint: solMint,
        requiredRawAmount: 10_000_000_000,
        balanceState: _loaded([_sol(0)]),
      );
      expect(result.sufficient, isFalse);
      expect(result.insufficientSymbol, 'SOL');
    });
  });
}
