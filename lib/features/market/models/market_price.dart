import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/data/mallow_tokens.dart';

part 'market_price.freezed.dart';

/// A token-denominated amount used by every market flow (buy, offer,
/// bid, listing-update). Mirrors the webapp's `Price` type from
/// `tokens` — `{ amount, currencyMint }` — and is
/// the single shape passed through the bloc's events + states so the
/// confirmation sheet can render the right symbol and decimals
/// regardless of listing currency.
///
/// [rawAmount] is the on-chain (atomic) amount in [currencyMint]'s
/// smallest unit. A null [currencyMint] means SOL — matches how the
/// API + listing models leave currency unset for SOL listings.
@freezed
sealed class MarketPrice with _$MarketPrice {
  const factory MarketPrice({required double rawAmount, String? currencyMint}) =
      _MarketPrice;
  const MarketPrice._();

  /// Convenience constructor for "no amount" (cancel flows).
  factory MarketPrice.zero({String? currencyMint}) =>
      MarketPrice(rawAmount: 0, currencyMint: currencyMint);

  /// Display amount = `rawAmount / 10^decimals`. Falls back to 9
  /// decimals (SOL) for unknown mints — matches the webapp.
  double get displayAmount => rawAmount / pow(10, _decimals);

  /// Effective currency mint, defaulting to SOL when unset.
  String get effectiveCurrencyMint => currencyMint ?? solMint;

  int get _decimals => tokenByMint(currencyMint)?.decimals ?? 9;
}
