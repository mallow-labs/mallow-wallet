import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_kv_row.dart';
import '../models/jupiter_token_info.dart';
import '../models/token_balance.dart';

/// Overview tab content for the token detail screen.
///
/// Shows 24h performance stats and detailed token info.
class TokenOverviewTab extends StatelessWidget {
  const TokenOverviewTab({
    required this.token,
    super.key,
    this.tokenInfo,
    this.isLoading = false,
  });

  final TokenBalance token;
  final JupiterTokenInfo? tokenInfo;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PerformanceSection(
          token: token,
          tokenInfo: tokenInfo,
          isLoading: isLoading,
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _TokenInfoSection(token: token, tokenInfo: tokenInfo),
        const SizedBox(height: MallowTheme.spacingXl),
      ],
    );
  }
}

class _PerformanceSection extends StatelessWidget {
  const _PerformanceSection({
    required this.token,
    required this.isLoading,
    this.tokenInfo,
  });

  final TokenBalance token;
  final JupiterTokenInfo? tokenInfo;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final volume = tokenInfo?.volume24h;
    final traders = tokenInfo?.uniqueTraders24h;
    final localeName = Localizations.localeOf(context).toString();
    final volumeFmt = NumberFormat.compactCurrency(
      locale: localeName,
      symbol: '\$',
      decimalDigits: 2,
    );
    final tradersFmt = NumberFormat.decimalPattern(localeName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '24h Performance',
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Volume',
                value: volume != null ? volumeFmt.format(volume) : '—',
                loading: isLoading,
                skeletonWidth: 72,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Expanded(
              child: _StatCard(
                label: 'Traders',
                value: traders != null ? tradersFmt.format(traders) : '—',
                change: token.priceChange24h,
                loading: isLoading,
                skeletonWidth: 56,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.change,
    this.loading = false,
    this.skeletonWidth = 64,
  });

  final String label;
  final String value;
  final double? change;
  final bool loading;
  final double skeletonWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacingMd),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (change != null) ...[
                const SizedBox(width: 4),
                _ChangeChip(change: change!),
              ],
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 19,
            child: loading
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: ShimmerBox(width: skeletonWidth, height: 12),
                  )
                : Text(
                    value,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChangeChip extends StatelessWidget {
  const _ChangeChip({required this.change});

  final double change;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final isPositive = change >= 0;
    final color = isPositive ? colors.positive : colors.negative;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isPositive ? '↑' : '↓',
          style: MallowTheme.uiCaption.copyWith(color: color, fontSize: 10),
        ),
        Text(
          '${change.abs().toStringAsFixed(1)}%',
          style: MallowTheme.uiCaption.copyWith(color: color, fontSize: 10),
        ),
      ],
    );
  }
}

class _TokenInfoSection extends StatelessWidget {
  const _TokenInfoSection({required this.token, this.tokenInfo});

  final TokenBalance token;
  final JupiterTokenInfo? tokenInfo;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final info = tokenInfo;
    final isNative = token.isNative;
    final localeName = Localizations.localeOf(context).toString();
    final currencyFmt = NumberFormat.compactCurrency(
      locale: localeName,
      symbol: '\$',
      decimalDigits: 2,
    );
    final compactFmt = NumberFormat.compact(locale: localeName);
    final intFmt = NumberFormat.decimalPattern(localeName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Token Info',
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        MallowKvList(
          rows: [
            MallowKvRow(label: 'Name', value: token.name),
            MallowKvRow(label: 'Symbol', value: token.symbol),
            if (!isNative)
              MallowKvAddressRow(
                label: token.isEvm ? 'Contract' : 'Mint',
                address: token.mint,
                chain: token.chain,
              ),
            MallowKvRow(label: 'Network', value: token.chain.label),
            if (info?.liquidity != null)
              MallowKvRow(
                label: 'Liquidity',
                value: currencyFmt.format(info!.liquidity),
              ),
            if (info?.marketCap != null)
              MallowKvRow(
                label: 'Market Cap',
                value: currencyFmt.format(info!.marketCap),
              ),
            if (info?.holders != null)
              MallowKvRow(
                label: 'Holders',
                value: intFmt.format(info!.holders),
              ),
            if (info?.totalSupply != null)
              MallowKvRow(
                label: 'Total Supply',
                value: compactFmt.format(info!.totalSupply),
              ),
            if (info?.circSupply != null)
              MallowKvRow(
                label: 'Circulating Supply',
                value: compactFmt.format(info!.circSupply),
              ),
            if (info?.createdAt != null)
              MallowKvRow(
                label: 'Created',
                value: _formatDate(info!.createdAt!),
              ),
          ],
        ),
      ],
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year.toString().substring(2)}';
    } catch (_) {
      return iso;
    }
  }
}
