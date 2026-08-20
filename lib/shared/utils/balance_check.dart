import 'package:flutter/material.dart';

import '../../core/data/mallow_tokens.dart';
import '../../core/utils/token_amount.dart';
import '../../features/portfolio/models/token_balance.dart';
import '../../features/portfolio/services/token_balance_bloc.dart';
import '../widgets/app_snack_bar.dart';
import 'chain.dart';

/// SOL kept in reserve to cover base + priority fee and any ATA rent for a
/// transaction. UI-only safety margin; the actual on-chain fee may differ.
const int kSolGasReserveLamports = 1_000_000;

class BalanceCheckResult {
  const BalanceCheckResult.sufficient()
    : sufficient = true,
      insufficientSymbol = null,
      deficitRawAmount = 0,
      deficitDecimals = 0;
  const BalanceCheckResult.insufficient({
    required String symbol,
    required this.deficitRawAmount,
    required this.deficitDecimals,
  }) : sufficient = false,
       insufficientSymbol = symbol;

  final bool sufficient;
  final String? insufficientSymbol;

  /// Additional amount needed to make the balance sufficient, in the smallest
  /// unit of the insufficient token. Zero when [sufficient] is true.
  final int deficitRawAmount;

  /// Decimals for [deficitRawAmount]. Used to format the snackbar message.
  final int deficitDecimals;

  /// Snackbar copy describing how much more the user needs.
  String get insufficientMessage {
    if (insufficientSymbol == null) return 'Insufficient balance';
    if (deficitRawAmount <= 0) {
      return 'Insufficient $insufficientSymbol';
    }
    final formatted = TokenAmount.formatTokenAmount(
      BigInt.from(deficitRawAmount),
      deficitDecimals,
    );
    return 'Insufficient $insufficientSymbol — need $formatted more';
  }
}

/// Returns whether the wallet has enough balance for a **Solana** transaction.
///
/// This is a SOL-gas-reserve model end to end: the reserve, the deficit symbol
/// and the decimals are all SOL, and [paymentMint] is a Solana mint. Calling it
/// for an Ethereum or Tezos payment reports "Insufficient SOL" for a chain that
/// does not use SOL — `send_sheet.dart` shows the right shape, branching on the
/// chain first and reaching here only on its Solana arm. Entry points for the
/// Solana-only flows are gated in `chain_support_guard.dart`, so the other call
/// sites can only be reached on Solana.
///
/// * `paymentMint` — mint of the token being paid. Pass `null` for gas-only
///   transactions (listings, cancels) where the user only needs SOL for fees.
/// * `requiredRawAmount` — required payment in the smallest unit of
///   `paymentMint`. Pass `0` for gas-only transactions.
/// * `includeGasReserve` — when `true`, also requires SOL ≥ gas reserve. Set
///   `false` when the required amount already includes the network fee
///   (e.g. mint's `totalLamports` bundles fee + rent).
/// * `additionalSolLamports` — SOL the transaction spends *beyond* the payment
///   and the gas reserve, owed regardless of what `paymentMint` is. Today this
///   is the edition-print mint fee (asset rent + Metaplex protocol fee + the
///   marketplace print fee), which the buyer pays in SOL even when the listing
///   itself is priced in USDC — webapp `useBuyNow`'s `requiredSolLamports`.
///   Without it an SPL-priced edition passes a gate that only ever saw the
///   0.001 SOL reserve and then fails on-chain for the whole fee.
///
/// Rules:
///   1. Balances not loaded yet → sufficient (don't false-disable on entry).
///   2. SOL payment (or null): SOL ≥ requiredRawAmount + extra + (gas if
///      requested).
///   3. SPL payment: SOL gas takes priority — if SOL < reserve + extra, returns
///      "Insufficient SOL". Otherwise checks SPL balance.
BalanceCheckResult checkBalance({
  required String? paymentMint,
  required int requiredRawAmount,
  required TokenBalanceState balanceState,
  bool includeGasReserve = true,
  int additionalSolLamports = 0,
}) {
  if (balanceState is! TokenBalanceLoaded) {
    return const BalanceCheckResult.sufficient();
  }
  final tokens = balanceState.tokens;

  final solBalance = _rawBalanceFor(tokens, solMint);
  final isSolPayment = paymentMint == null || paymentMint == solMint;

  if (isSolPayment) {
    final reserve = includeGasReserve ? kSolGasReserveLamports : 0;
    final needed = requiredRawAmount + reserve + additionalSolLamports;
    if (solBalance < needed) {
      return BalanceCheckResult.insufficient(
        symbol: 'SOL',
        deficitRawAmount: needed - solBalance,
        deficitDecimals: 9,
      );
    }
    return const BalanceCheckResult.sufficient();
  }

  final solNeeded =
      (includeGasReserve ? kSolGasReserveLamports : 0) + additionalSolLamports;
  if (solNeeded > 0 && solBalance < solNeeded) {
    return BalanceCheckResult.insufficient(
      symbol: 'SOL',
      deficitRawAmount: solNeeded - solBalance,
      deficitDecimals: 9,
    );
  }

  if (requiredRawAmount > 0) {
    final splBalance = _rawBalanceFor(tokens, paymentMint);
    if (splBalance < requiredRawAmount) {
      final token = tokenByMint(paymentMint);
      return BalanceCheckResult.insufficient(
        symbol: token?.symbol ?? 'tokens',
        deficitRawAmount: requiredRawAmount - splBalance,
        deficitDecimals: token?.decimals ?? 0,
      );
    }
  }

  return const BalanceCheckResult.sufficient();
}

/// Same as [checkBalance] but returns sufficient when [requiredRawAmount] is
/// null — for call sites where the amount isn't known yet (e.g. swap before
/// quote, send before user types an amount).
BalanceCheckResult checkBalanceOrSkip({
  required String? paymentMint,
  required int? requiredRawAmount,
  required TokenBalanceState balanceState,
  bool includeGasReserve = true,
  int additionalSolLamports = 0,
}) {
  if (requiredRawAmount == null) {
    return const BalanceCheckResult.sufficient();
  }
  return checkBalance(
    paymentMint: paymentMint,
    requiredRawAmount: requiredRawAmount,
    balanceState: balanceState,
    includeGasReserve: includeGasReserve,
    additionalSolLamports: additionalSolLamports,
  );
}

/// Returns `true` if [result] is sufficient. Otherwise shows a snackbar with
/// the deficit and returns `false`. Use to guard button presses:
///
/// ```dart
/// onPressed: () {
///   if (!ensureSufficientBalance(context, result)) return;
///   ...continue with action...
/// }
/// ```
bool ensureSufficientBalance(BuildContext context, BalanceCheckResult result) {
  if (result.sufficient) return true;
  AppSnackBar.show(context, result.insufficientMessage);
  return false;
}

/// The Solana-side balance for [mint].
///
/// Matched on `(chain, mint)`, not on mint alone: that pair is what
/// `session_portfolio_aggregator.mergeTokenBalances` dedupes on, so a bare
/// mint match can return another chain's row for a colliding sentinel mint
/// (`'native'`, `'tez-native'`) and report an ETH or XTZ balance as though it
/// were SOL. Every mint this function is asked about is a Solana mint —
/// [checkBalance] models SOL gas reserve and SPL payment only.
int _rawBalanceFor(List<TokenBalance> tokens, String mint) {
  for (final t in tokens) {
    if (t.chain == Chain.solana && t.mint == mint) return t.rawBalance;
  }
  return 0;
}
