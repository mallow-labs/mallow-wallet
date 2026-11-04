import 'package:flutter/material.dart';

import '../../core/services/token_price_service.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import '../utils/price_format.dart';

/// Live "~$1,234.56" estimate of [rawAmount] (atomic units of [mint]),
/// sized for the trailing `suffix` slot of a price `MallowPillField`.
///
/// Rebuilds when [TokenPriceService] refreshes its prices, so the figure
/// appears once the first fetch lands. Renders nothing for an empty or zero
/// amount, or while the mint has no known price — an estimate we cannot
/// make is left out rather than shown as `$0.00`.
class UsdEstimate extends StatelessWidget {
  const UsdEstimate({required this.rawAmount, required this.mint, super.key});

  final num? rawAmount;
  final String mint;

  @override
  Widget build(BuildContext context) {
    final raw = rawAmount;
    if (raw == null || raw <= 0) return const SizedBox.shrink();
    final priceService = sl<TokenPriceService>();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: priceService.prices,
      builder: (context, _, _) {
        final usd = priceService.usdValueOfRaw(raw, mint);
        if (usd == null) return const SizedBox.shrink();
        return Text(
          '~${formatUsd(usd)}',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        );
      },
    );
  }
}
