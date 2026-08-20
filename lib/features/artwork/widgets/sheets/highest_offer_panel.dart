import 'package:flutter/material.dart';

import '../../../../core/services/avatar_service.dart';
import '../../../../core/services/token_metadata_service.dart';
import '../../../../core/services/token_price_service.dart';
import '../../../../di.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/address_utils.dart';
import '../../../../shared/utils/time_utils.dart';
import '../../../../shared/utils/token_image_utils.dart';
import '../../../../shared/widgets/account_avatar.dart';
import '../../../../shared/widgets/mallow_network_image.dart';
import '../../../../shared/widgets/token_amount_text.dart';
import '../../services/artwork_bloc.dart';

/// Buyer + amount rows for the highest offer, in the owner and viewer
/// variants of the Figma spec:
///
///     (avatar) kaya made the highest offer        10d ago
///     (sol) 0.034  $3.49                    Highest Offer
///
/// Shared by [ArtworkOwnerSheet] (accept-offer CTA) and
/// [ArtworkUnlistedViewerSheet] (make-offer CTA).
class HighestOfferPanel extends StatelessWidget {
  const HighestOfferPanel({required this.offer, super.key});

  final OfferRender offer;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final buyerName =
        offer.buyer?.username ??
        offer.buyer?.displayName ??
        truncateAddress(offer.buyerAddress);
    final avatarUrl = offer.buyer?.avatarUrl;
    final usd = sl<TokenPriceService>().usdValueOfRaw(
      offer.price,
      offer.currencyMint,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ClipOval(
              child: avatarUrl != null && avatarUrl.isNotEmpty
                  ? MallowNetworkImage(
                      imageUrl: avatarUrl,
                      logicalSize: 24,
                      width: 24,
                      height: 24,
                      errorBuilder: (_) => _defaultAvatar(),
                    )
                  : _defaultAvatar(),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: buyerName,
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    TextSpan(
                      text: ' made the highest offer',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (offer.date != null)
              Text(
                formatLastUpdated(offer.date),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Row(
          children: [
            tokenImageWidget(
              mint: offer.currencyMint,
              size: 18,
              enlargeChainGlyph: true,
              logoUrl: sl<TokenMetadataService>().imageUrlFor(
                offer.currencyMint,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            TokenAmountText(
              rawAmount: offer.price,
              currencyMint: offer.currencyMint,
              // See `ArtworkSheetPriceRow`: a runtime-resolved mint has no
              // curated glyph, so it carries its ticker inline.
              withSymbol: sl<TokenMetadataService>().needsLookup(
                offer.currencyMint,
              ),
              style: MallowTheme.uiTitle.copyWith(color: colors.textPrimary),
            ),
            if (usd != null) ...[
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                '\$${usd.toStringAsFixed(2)}',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
            const Spacer(),
            Text(
              'Highest Offer',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _defaultAvatar() => AccountAvatar(
    seed: avatarSeedOf(
      address: offer.buyerAddress,
      username: offer.buyer?.username,
    ),
    size: 24,
  );
}
