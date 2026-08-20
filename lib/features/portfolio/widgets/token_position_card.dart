import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../models/token_balance.dart';

/// "Your Position" card showing the user's token holding with P&L.
class TokenPositionCard extends StatelessWidget {
  const TokenPositionCard({required this.token, super.key});

  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your Position',
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(MallowTheme.spacingMd),
          decoration: BoxDecoration(
            color: colors.bgPrimary,
            borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
          ),
          child: Row(
            children: [
              Expanded(child: _buildLeft(context)),
              _buildRight(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLeft(BuildContext context) {
    final colors = context.mallowColors;
    final usdValue = token.totalUsdValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          usdValue != null ? '\$${_compactUsd(usdValue)}' : '—',
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          token.symbol.isEmpty
              ? _formatBalance(token.uiBalance)
              : '${_formatBalance(token.uiBalance)} ${token.symbol}',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildRight(BuildContext context) {
    final colors = context.mallowColors;
    final change = token.priceChange24h;
    if (change == null) return const SizedBox.shrink();

    final isPositive = change >= 0;
    final changeColor = isPositive ? colors.positive : colors.negative;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${isPositive ? '+' : ''}${change.toStringAsFixed(2)}%',
          style: MallowTheme.uiBody.copyWith(color: changeColor),
        ),
        const SizedBox(height: 2),
        Text(
          '24h',
          style: MallowTheme.uiCaption.copyWith(color: colors.textTertiary),
        ),
      ],
    );
  }

  /// Abbreviated, symbol-less USD for the position card's tight column — not
  /// a copy of the canonical [formatUsd], which never abbreviates. The card
  /// pairs this with the compact [_formatBalance] below and supplies its own
  /// `$`, so grouping never applies.
  String _compactUsd(double value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(2)}K';
    return value.toStringAsFixed(2);
  }

  String _formatBalance(double balance) {
    if (balance >= 1000000) return '${(balance / 1000000).toStringAsFixed(2)}M';
    if (balance >= 1000) return '${(balance / 1000).toStringAsFixed(2)}K';
    if (balance >= 1) return balance.toStringAsFixed(4);
    if (balance > 0) return balance.toStringAsFixed(8);
    return '0';
  }
}
