import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Featured listing card: light gray bg + object-fit contain image.
class FeaturedListingCard extends StatelessWidget {
  const FeaturedListingCard({
    required this.title,
    required this.artistName,
    required this.artistAddress,
    required this.imageUrl,
    super.key,
    this.playbackId,
    this.clipPlaybackId,
    this.nsfw = false,
    this.priceRawAmount,
    this.currencyMint,
    this.buyerSetsPrice = false,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final String artistName;
  final String artistAddress;
  final String imageUrl;
  final String? playbackId;
  final String? clipPlaybackId;

  /// Moderation flag: blurs the media until revealed or the show-NSFW
  /// setting is on.
  final bool nsfw;
  final double? priceRawAmount;
  final String? currencyMint;

  /// True for a SYOP ("set your own price") listing — its on-chain price is 0,
  /// so the card must show the label rather than "0 SOL".
  final bool buyerSetsPrice;
  final VoidCallback? onTap;

  /// Long-press opens the artwork context menu.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    const cardSize = 139.6;
    // Matches the webapp card (`ArtworkCardMetadata`): the row is
    // omitted entirely when there's no price, and a SYOP / zero price renders
    // as a word rather than a misleading figure.
    final priceLabel = priceRawAmount != null || buyerSetsPrice
        ? PriceFormatter.formatListingPrice(
            priceRawAmount ?? 0,
            currencyMint,
            buyerSetsPrice: buyerSetsPrice,
          )
        : null;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: cardSize,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: cardSize,
              height: cardSize,
              decoration: BoxDecoration(
                color: context.mallowColors.surfaceMuted,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
              padding: const EdgeInsets.all(12),
              child: imageUrl.isNotEmpty
                  ? MallowArtworkMedia(
                      imageUrl: imageUrl,
                      playbackId: playbackId,
                      clipPlaybackId: clipPlaybackId,
                      nsfw: nsfw,
                      logicalSize: cardSize,
                      fit: BoxFit.contain,
                      cdnFit: 'inside',
                      placeholderBuilder: (_) => const SizedBox.shrink(),
                      errorBuilder: (_) => const SizedBox.shrink(),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              title,
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            TapTargetExpander(
              child: GestureDetector(
                onTap: artistAddress.isNotEmpty
                    ? () => context.goToProfile(artistAddress)
                    : null,
                child: Text(
                  artistName,
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (priceLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                priceLabel,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
