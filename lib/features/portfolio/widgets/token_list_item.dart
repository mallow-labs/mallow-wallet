import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../data/token_repository.dart';
import '../models/token_balance.dart';

/// A list item displaying a token's balance and USD value.
///
/// Matches Figma design: 48px square logo, editorial name,
/// balance subtitle, USD value + change on the right.
class TokenListItem extends StatelessWidget {
  const TokenListItem({
    required this.token,
    super.key,
    this.onTap,
    this.onLongPress,
  });

  final TokenBalance token;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: MallowTheme.spacing12,
        ),
        child: Row(
          children: [
            // Token logo — 48px square with 4px radius, plus a chain badge in
            // the bottom-right corner for non-Solana tokens.
            _LogoWithChainBadge(token: token),
            const SizedBox(width: MallowTheme.spacing12),
            // Token name (editorial) and balance
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    token.name,
                    style: MallowTheme.editorialQuote.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatBalanceWithSymbol(token.uiBalance, token.symbol),
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // USD value and 24h change
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _usdOrDash(token.totalUsdValue),
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                _PriceChangeLabel(token: token),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static final _thousandsTwoDp = NumberFormat('#,##0.00');

  String _formatBalanceWithSymbol(double balance, String symbol) {
    final String balanceStr;
    if (balance >= 1000000) {
      balanceStr = '${(balance / 1000000).toStringAsFixed(2)}M';
    } else if (balance >= 1000) {
      balanceStr = _thousandsTwoDp.format(balance);
    } else if (balance > 0) {
      balanceStr = balance.toStringAsFixed(5);
    } else {
      balanceStr = '0';
    }
    return symbol.isEmpty ? balanceStr : '$balanceStr $symbol';
  }

  String _usdOrDash(double? value) => value == null ? '--' : formatUsd(value);
}

class _PriceChangeLabel extends StatelessWidget {
  const _PriceChangeLabel({required this.token});

  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final usdChange = TokenRepository.tokenUsdChange(token);
    if (usdChange == null) {
      return Text(
        '--',
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      );
    }

    final colors = context.mallowColors;
    final isPositive = usdChange >= 0;
    final prefix = isPositive ? '+' : '-';
    final text = '$prefix\$${usdChange.abs().toStringAsFixed(2)}';

    return Text(
      text,
      style: MallowTheme.uiCaption.copyWith(
        color: isPositive ? colors.positive : colors.negative,
      ),
    );
  }
}

/// The token logo with a chain badge overlaid bottom-right for non-Solana
/// tokens. Solana is the implicit default and stays bare to keep the common
/// case clean (matches the agreed "badge non-Solana only" design).
class _LogoWithChainBadge extends StatelessWidget {
  const _LogoWithChainBadge({required this.token});

  final TokenBalance token;

  @override
  Widget build(BuildContext context) {
    final logo = _TokenLogo(
      mint: token.mint,
      logoUrl: token.logoUrl,
      symbol: token.symbol,
    );
    if (token.chain == Chain.solana) return logo;
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          logo,
          Positioned(right: -2, bottom: -2, child: _ChainBadge(token.chain)),
        ],
      ),
    );
  }
}

/// Small circular chain-icon badge (e.g. Ethereum) overlaid on a token logo.
/// The chain glyph is themed to [context.mallowColors.textPrimary] so it stays
/// legible against the badge background in both light and dark mode.
class _ChainBadge extends StatelessWidget {
  const _ChainBadge(this.chain);

  final Chain chain;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: 18,
      height: 18,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        shape: BoxShape.circle,
        border: Border.all(color: colors.dividerLight),
      ),
      child: MallowSvgIcon(chain.iconAsset),
    );
  }
}

class _TokenLogo extends StatelessWidget {
  const _TokenLogo({required this.mint, required this.symbol, this.logoUrl});

  final String mint;
  final String? logoUrl;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    // Native ETH/XTZ share the `native` mint, so resolve their square tiles by
    // symbol; SOL and SPL/ERC-20s resolve by mint.
    final assetPath = localTokenImagePath(mint) ?? nativeCoinImagePath(symbol);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: context.mallowColors.divider,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      clipBehavior: Clip.antiAlias,
      child: assetPath != null
          ? Image.asset(
              assetPath,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            )
          : logoUrl != null
          ? MallowNetworkImage(
              imageUrl: logoUrl!,
              logicalSize: 48,
              width: 48,
              height: 48,
              placeholderBuilder: (_) => _fallback(),
              errorBuilder: (_) => _fallback(),
            )
          : _fallback(),
    );
  }

  /// Native chain coins (ETH/XTZ) arrive with the `native` sentinel mint, no
  /// local asset, and — for XTZ — no logoUrl from the backend, so they'd
  /// otherwise show a bare letter. Fall back to the brand mark in its original
  /// colors (mirroring the activity rows); other tokens keep the letter chip.
  Widget _fallback() {
    final brandAsset = symbol.toUpperCase() == 'ETH'
        ? 'assets/icons/ethereum_color.svg'
        : chainSymbolSvgAsset(mint: mint, symbol: symbol);
    if (brandAsset != null) {
      return MallowSvgIcon(
        brandAsset,
        width: 48,
        height: 48,
        useOriginalColors: true,
      );
    }
    return _Placeholder(symbol: symbol);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.symbol});

  final String symbol;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        symbol.isNotEmpty ? symbol[0].toUpperCase() : '?',
        style: MallowTheme.uiBody.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    );
  }
}
