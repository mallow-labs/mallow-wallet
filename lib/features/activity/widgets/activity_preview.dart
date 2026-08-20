import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/mallow_tokens.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/nsfw_obscured.dart';
import '../utils/activity_helpers.dart';

/// Preview area at the top of activity detail views.
///
/// Three layout modes:
/// 1. Single image — for NFT receive/transfer/mint
/// 2. Split view — for swaps and buys (two sides)
/// 3. Token only — for token send/receive without NFT
class ActivityPreview extends StatelessWidget {
  const ActivityPreview({required this.activity, super.key});

  final api.Activity activity;

  @override
  Widget build(BuildContext context) {
    if (activity.type == api.ActivityType.swap) {
      return _buildSwapPreview(context);
    }

    if (activity.type == api.ActivityType.buy) {
      return _buildBuyPreview(context);
    }

    // NFT activities with artwork
    final marketData = activity.marketData;
    if (marketData != null) {
      final displayName = formatArtworkName(
        name: marketData.artwork.name,
        editionNumber: marketData.artwork.editionNumber,
      );
      return _buildSingleImage(
        context,
        imageUrl: marketData.artwork.imageUrl,
        fallbackLabel: displayName.isNotEmpty
            ? displayName
            : truncateAddress(marketData.artwork.mintAccount),
        nsfw: marketData.artwork.nsfw,
        contentId: marketData.artwork.mintAccount,
      );
    }

    // Transfer with NFT
    final transferData = activity.transferData;
    if (transferData != null && transferData.isNft) {
      final logoUrl = transferData.token.logoUrl;
      // Prefer the resolved artwork name (with edition); fall back to
      // symbol/mint.
      final label = transferData.nftName?.isNotEmpty == true
          ? formatArtworkName(
              name: transferData.nftName!,
              editionNumber: transferData.nftEditionNumber,
            )
          : tokenDisplaySymbol(transferData.token);
      if (logoUrl != null && logoUrl.isNotEmpty) {
        return _buildSingleImage(
          context,
          imageUrl: logoUrl,
          fallbackLabel: label,
          nsfw: transferData.nftNsfw,
          contentId: transferData.token.mint,
        );
      }
      // No image — show name/address as large editorial text
      return _buildSingleImage(
        context,
        imageUrl: '',
        fallbackLabel: label,
        borderColor: previewBorderColor(activity.type, context.mallowColors),
      );
    }

    // Token transfer — show token image with amount
    if (transferData != null) {
      // Activity-aware direction: a refunded bid keeps the type of the bid it
      // reverses, so the type alone would render returned escrow as another
      // debit. Same fix as the list row.
      final prefix = isActivityIncoming(activity) ? '+' : '-';
      final sym = tokenDisplaySymbol(transferData.token);
      final amount =
          '$prefix${PriceFormatter.formatCompactAmount(transferData.token.amount, transferData.token.decimals)} $sym';
      final colors = context.mallowColors;
      return _buildTokenPreview(
        context,
        token: transferData.token,
        amount: amount,
        amountColor: activityDirectionColor(activity, colors),
        borderColor: previewBorderColor(activity.type, colors),
      );
    }

    // Native staking — SOL and the amount, on the same terms as a token
    // transfer. An unstake moves nothing yet, so it renders unsigned and
    // uncoloured (see `isOutgoing` / `isIncoming`).
    final stakeData = activity.stakeData;
    if (stakeData != null) {
      final colors = context.mallowColors;
      final prefix = isActivityOutgoing(activity)
          ? '-'
          : isActivityIncoming(activity)
          ? '+'
          : '';
      final amount =
          '$prefix${PriceFormatter.formatCompactAmount(stakeData.token.amount, stakeData.token.decimals)} '
          '${tokenDisplaySymbol(stakeData.token)}';
      return _buildTokenPreview(
        context,
        token: stakeData.token,
        amount: amount,
        amountColor: activityDirectionColor(activity, colors),
        borderColor: previewBorderColor(activity.type, colors),
      );
    }

    // Fallback
    return const SizedBox(height: 20);
  }

  Widget _buildSingleImage(
    BuildContext context, {
    required String imageUrl,
    required String fallbackLabel,
    bool nsfw = false,
    String? contentId,
    Color? borderColor,
  }) {
    final colors = context.mallowColors;

    Widget fallback() => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          fallbackLabel,
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            // Frost a flagged artwork behind the viewer's show-NSFW setting,
            // the same treatment [ActivityListItem] gives the row this sheet
            // opens from. Without it, tapping a blurred activity row revealed
            // the artwork at full size — the blur would have been one tap of
            // theatre.
            child: NsfwObscured(
              // Only the rendered artwork needs the frost; the text fallback
              // (unindexed mint) carries no imagery to obscure.
              nsfw: nsfw && imageUrl.isNotEmpty,
              contentId: contentId,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(MallowTheme.popupRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: imageUrl.isEmpty
                    ? fallback()
                    : MallowNetworkImage(
                        imageUrl: imageUrl,
                        logicalSize: 300,
                        fit: BoxFit.contain,
                        placeholderBuilder: (_) => const SizedBox.shrink(),
                        errorBuilder: (_) => fallback(),
                      ),
              ),
            ),
          ),
          if (borderColor != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(height: 2, color: borderColor),
            ),
        ],
      ),
    );
  }

  Widget _buildTokenPreview(
    BuildContext context, {
    required api.TokenInfo token,
    String? amount,
    Color? amountColor,
    Color? borderColor,
  }) {
    final colors = context.mallowColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                tokenImageWidget(
                  mint: token.mint,
                  // Same reason as [_buildSwapSide]: the feed leaves the symbol
                  // empty and the logo unset for anything outside the registry.
                  symbol: tokenDisplaySymbol(token),
                  logoUrl: tokenDisplayLogoUrl(token),
                  size: 100,
                ),
                if (amount != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    amount,
                    style: MallowTheme.uiBody.copyWith(
                      color: amountColor ?? colors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
          if (borderColor != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(height: 2, color: borderColor),
            ),
        ],
      ),
    );
  }

  Widget _buildSwapPreview(BuildContext context) {
    final swapData = activity.swapData;
    if (swapData == null) return const SizedBox(height: 20);

    final colors = context.mallowColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            // Input token (outgoing, red)
            Expanded(
              child: _buildSwapSide(
                context,
                token: swapData.inputToken,
                amount:
                    '-${PriceFormatter.formatCompactAmount(swapData.inputToken.amount, swapData.inputToken.decimals)} ${tokenDisplaySymbol(swapData.inputToken)}',
                borderColor: colors.negative,
                amountColor: colors.negative,
              ),
            ),
            // Vertical divider
            VerticalDivider(width: 1, color: colors.dividerLight),
            // Output token (incoming, green)
            Expanded(
              child: _buildSwapSide(
                context,
                token: swapData.outputToken,
                amount:
                    '+${PriceFormatter.formatCompactAmount(swapData.outputToken.amount, swapData.outputToken.decimals)} ${tokenDisplaySymbol(swapData.outputToken)}',
                borderColor: colors.positive,
                amountColor: colors.positive,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBuyPreview(BuildContext context) {
    final marketData = activity.marketData;
    if (marketData == null) return const SizedBox(height: 20);

    final colors = context.mallowColors;
    // The listing currency, not SOL: mallow listings price in USDC and the
    // other registry mints too, and the hardcoded pair rendered a USDC purchase
    // as "-25 SOL" beside the wrapped-SOL logo.
    final currencyMint = marketData.currencyMint;
    final currencySymbol =
        marketData.currencySymbol ?? tokenByMint(currencyMint)?.symbol ?? 'SOL';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            // Currency spent (outgoing, red)
            Expanded(
              child: _buildSwapSideWithImage(
                context,
                imageWidget: tokenImageWidget(
                  mint: currencyMint,
                  symbol: currencySymbol,
                  size: 100,
                ),
                amount: '-${marketData.price} $currencySymbol',
                borderColor: colors.negative,
                amountColor: colors.negative,
              ),
            ),
            VerticalDivider(width: 1, color: colors.dividerLight),
            // NFT received (incoming, green)
            Expanded(
              child: _buildSwapSideWithImage(
                context,
                imageWidget: NsfwObscured(
                  nsfw: marketData.artwork.nsfw,
                  contentId: marketData.artwork.mintAccount,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: MallowNetworkImage(
                    imageUrl: marketData.artwork.imageUrl,
                    logicalSize: 100,
                    width: 100,
                    height: 100,
                    borderRadius: BorderRadius.circular(
                      MallowTheme.radiusPrimary,
                    ),
                    errorBuilder: (ctx) => Container(
                      width: 100,
                      height: 100,
                      color: ctx.mallowColors.divider,
                      child: MallowSvgIcon(
                        'assets/icons/stamp.svg',
                        color: ctx.mallowColors.textTertiary,
                      ),
                    ),
                  ),
                ),
                amount: formatArtworkName(
                  name: marketData.artwork.name,
                  editionNumber: marketData.artwork.editionNumber,
                ),
                borderColor: colors.positive,
                amountColor: colors.positive,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwapSide(
    BuildContext context, {
    required api.TokenInfo token,
    required String amount,
    required Color borderColor,
    required Color amountColor,
  }) {
    return _buildSwapSideWithImage(
      context,
      imageWidget: tokenImageWidget(
        mint: token.mint,
        // Not the raw `symbol`: the feed leaves it empty for anything outside
        // the registry, which rendered the fallback tile as a blank square.
        symbol: tokenDisplaySymbol(token),
        logoUrl: tokenDisplayLogoUrl(token),
        size: 100,
      ),
      amount: amount,
      borderColor: borderColor,
      amountColor: amountColor,
    );
  }

  Widget _buildSwapSideWithImage(
    BuildContext context, {
    required Widget imageWidget,
    required String amount,
    required Color borderColor,
    required Color amountColor,
  }) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                imageWidget,
                const SizedBox(height: 20),
                Text(
                  amount,
                  style: MallowTheme.uiBody.copyWith(color: amountColor),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(height: 2, color: borderColor),
        ),
      ],
    );
  }
}
