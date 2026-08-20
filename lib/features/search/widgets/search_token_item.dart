import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/data/mallow_tokens.dart' show solMint;
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../portfolio/models/token_balance.dart';
import '../models/search_models.dart';

/// A single token result row:
/// 48px icon + name + truncated mint + price + % change.
class SearchTokenItem extends StatelessWidget {
  const SearchTokenItem({required this.token, this.typeLabel, super.key});

  final SearchTokenResult token;

  /// Optional content-type prefix for the subtitle (e.g. "Token" renders
  /// "Token • EPjF…Dt1v"). Used by the "Recently viewed" rows, where mixed
  /// content types share one list without section headers.
  final String? typeLabel;

  /// The mint fragment shown in the subtitle. Native chain currencies show
  /// their symbol (SOL/ETH/XTZ) instead of a mint address: ETH/XTZ carry a
  /// `native`/`tez-native` sentinel mint rather than a real address, and SOL's
  /// real mint is noise beside its universally-known ticker.
  String get _subtitleDetail {
    final isNative =
        token.mintAddress == solMint ||
        token.mintAddress == TokenBalance.evmNativeSentinel ||
        token.mintAddress == TokenBalance.tezosNativeSentinel;
    return isNative ? token.symbol : truncateAddress(token.mintAddress);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final change = token.priceChange24h;
    final isPositive = change != null && change >= 0;
    final changeColor = change == null
        ? colors.textSecondary
        : isPositive
        ? colors.positive
        : colors.negative;

    // Native ETH/XTZ share the `native`/`tez-native` sentinel mint, so resolve
    // their bundled square tiles by symbol; SOL and SPL/ERC-20s resolve by
    // mint. Matches the portfolio token list.
    final localAsset =
        localTokenImagePath(token.mintAddress) ??
        nativeCoinImagePath(token.symbol);

    return Row(
      children: [
        // Token icon — local asset overrides (e.g. USDC DEV) win over the
        // fetched icon URL, matching the portfolio token list.
        SizedBox(
          width: 48,
          height: 48,
          child: localAsset != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: Image.asset(
                    localAsset,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _placeholder(context),
                  ),
                )
              : token.iconUrl != null
              ? MallowNetworkImage(
                  imageUrl: token.iconUrl!,
                  logicalSize: 48,
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  errorBuilder: (_) => _placeholder(context),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: _placeholder(context),
                ),
        ),
        const SizedBox(width: 12),
        // Name + mint address
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                token.name,
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                typeLabel != null
                    ? '$typeLabel • $_subtitleDetail'
                    : _subtitleDetail,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Price + change
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (token.usdPrice != null)
              Text(
                '\$${token.usdPrice!.toStringAsFixed(token.usdPrice! < 1 ? 7 : 2)}',
                style: TextStyle(
                  fontSize: 14,
                  color: context.mallowColors.textPrimary,
                ),
              ),
            if (change != null)
              Text(
                '${isPositive ? '+' : ''}${change.toStringAsFixed(2)}%',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w300,
                  color: changeColor,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) {
    Widget icon = MallowSvgIcon(
      'assets/icons/coin.svg',
      width: 24,
      height: 24,
      color: context.mallowColors.textTertiary,
    );
    // In the "Recently viewed" rows (the only place `typeLabel` is set), inset
    // the coin glyph so it doesn't crowd the tile edges.
    if (typeLabel != null) {
      icon = Padding(padding: const EdgeInsets.all(10), child: icon);
    }
    return Container(
      width: 48,
      height: 48,
      color: context.mallowColors.surfaceMuted,
      child: icon,
    );
  }
}
