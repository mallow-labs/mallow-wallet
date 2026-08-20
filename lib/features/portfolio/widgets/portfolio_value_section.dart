import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/price_format.dart';

/// Portfolio total value (USD) with 24h change row.
class PortfolioValueSection extends StatelessWidget {
  const PortfolioValueSection({
    required this.totalUsd,
    super.key,
    this.isRefreshing = false,
    this.totalChange24h,
    this.totalChangePercent24h,
    this.padding = const EdgeInsets.symmetric(
      horizontal: MallowTheme.spacing20,
    ),
  });

  final double totalUsd;
  final bool isRefreshing;
  final double? totalChange24h;
  final double? totalChangePercent24h;

  /// Outer padding around the value. Defaults to the standard 20px horizontal
  /// gutter; the empty-state card passes [EdgeInsets.zero] since it supplies
  /// its own padding.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final formatted = _formatCurrency(totalUsd);

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedOpacity(
            opacity: isRefreshing ? 0.6 : 1.0,
            duration: const Duration(milliseconds: 200),
            // Text.rich (not RichText) so the balance honours the platform
            // text scaler / Dynamic Type instead of defaulting to no scaling.
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatted.main,
                    style: MallowTheme.uiHeadline.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                  TextSpan(
                    text: formatted.cents,
                    style: MallowTheme.uiMetaTabular.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (totalChange24h != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            _PortfolioChangeRow(
              dollarChange: totalChange24h!,
              percentChange: totalChangePercent24h,
            ),
          ],
        ],
      ),
    );
  }

  /// Splits the shared [formatUsd] rendering so the cents can be typeset
  /// smaller than the dollars. Formatting once and splitting keeps the two
  /// halves consistent — deriving them separately let the cents reach 100 and
  /// the headline read "$9.100".
  _FormattedCurrency _formatCurrency(double value) {
    final formatted = formatUsd(value);
    final dot = formatted.lastIndexOf('.');
    return _FormattedCurrency(
      main: formatted.substring(0, dot),
      cents: formatted.substring(dot),
    );
  }
}

class _FormattedCurrency {
  const _FormattedCurrency({required this.main, required this.cents});
  final String main;
  final String cents;
}

class _PortfolioChangeRow extends StatelessWidget {
  const _PortfolioChangeRow({required this.dollarChange, this.percentChange});

  final double dollarChange;
  final double? percentChange;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isPositive = dollarChange >= 0;
    final color = isPositive ? colors.positive : colors.negative;
    final arrow = isPositive ? '↑' : '↓';
    final dollarPrefix = isPositive ? '+' : '';
    final dollarText =
        '$dollarPrefix\$${dollarChange.abs().toStringAsFixed(2)}';

    final pctText = percentChange != null
        ? '${isPositive ? '+' : ''}${percentChange!.toStringAsFixed(2)}%'
        : null;

    return Row(
      children: [
        Text(arrow, style: MallowTheme.uiCaption.copyWith(color: color)),
        const SizedBox(width: 4),
        Text(
          pctText != null ? '$dollarText  •  $pctText' : dollarText,
          style: MallowTheme.uiCaption.copyWith(color: color),
        ),
      ],
    );
  }
}
