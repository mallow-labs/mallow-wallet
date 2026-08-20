import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/price_format.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../../../shared/widgets/token_amount_text.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';

/// Bottom sheet shown when the connected wallet owns an artwork that's
/// currently listed buy-now. Mirrors the webapp's `SellerBuyNowBox`.
///
/// Tapping "Update listing" opens a secondary sheet that owns the price
/// input *and* the cancel-listing affordance — see `UpdateListingSheet`.
///
/// Triggered by `owner` × `buyNow` — see `docs/artwork_state.md`.
class ArtworkOwnerListedSheet extends StatelessWidget {
  const ArtworkOwnerListedSheet({
    required this.artwork,
    required this.onUpdateListing,
    required this.onAcceptOffer,
    this.highestOffer,
    this.editionState,
    this.isLoading = false,
    super.key,
  });

  final ArtworkDetails artwork;
  final VoidCallback onUpdateListing;

  /// DAS-derived edition state. When present, its `supplyInfo` drives the
  /// "sold" caption in preference to the indexed `quantitySold` /
  /// `quantityTotal` from `/byMint` — matching the buyer's edition sheet.
  final EditionLiveState? editionState;

  /// Dispatches the accept-offer transaction for the given offer. The backend
  /// resolves the seller and handles the delist-and-accept for a listed
  /// artwork, so the call is identical to the unlisted owner sheet's.
  final ValueChanged<OfferRender> onAcceptOffer;

  /// Highest active offer on the artwork, loaded via `OfferRepository`.
  /// Carries the offer's raw `price` + `currencyMint` so the amount renders
  /// with the right token decimals — the indexer scalar `artwork.highestOffer`
  /// has neither, so it can't be formatted correctly. Null while loading or
  /// when none exist.
  final OfferRender? highestOffer;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final offer = highestOffer;
    final soldCaption = _soldCaption();

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ArtworkSheetPriceRow(
                rawAmount: artwork.price,
                currencyMint: artwork.currency,
                buyerSetsPrice: artwork.buyNowMetadata?.buyerSetsPrice ?? false,
              ),
              const Spacer(),
              if (soldCaption != null)
                Text(
                  soldCaption,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                )
              else if (offer != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Offer: ',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    TokenAmountText(
                      rawAmount: offer.price,
                      currencyMint: offer.currencyMint,
                      shimmerWidth: 48,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            label: 'Update listing',
            variant: MallowButtonVariant.secondary,
            onPressed: isLoading ? null : onUpdateListing,
            isLoading: isLoading,
            isFullWidth: true,
          ),
          if (offer != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            MallowButton(
              label: 'Accept highest offer',
              variant: MallowButtonVariant.secondary,
              onPressed: isLoading ? null : () => onAcceptOffer(offer),
              isFullWidth: true,
            ),
          ],
        ],
      ),
    );
  }

  /// The "X sold" / "X / Y sold" caption shown opposite the price for
  /// Open/Limited Edition listings — mirroring `ArtworkBuyEditionSheet` so
  /// the seller sees the same supply progress as buyers. Returns null for
  /// non-edition artwork (1/1s), which keep the highest-offer caption.
  String? _soldCaption() {
    final supplyType = artwork.supplyType;
    final isOpenEdition = supplyType == SupplyType.openEdition;
    final isLimitedEdition = supplyType == SupplyType.limitedEdition;
    if (!isOpenEdition && !isLimitedEdition) return null;

    // Prefer live DAS supply over the indexed snapshot when available —
    // the indexer can lag a few seconds during active mints.
    final liveSupply = editionState?.supplyInfo;
    final sold = liveSupply != null
        ? liveSupply.supply.toDouble()
        : artwork.quantitySold;
    if (sold == null) return null;
    final total = liveSupply?.maxSupply != null
        ? liveSupply!.maxSupply!.toDouble()
        : artwork.quantityTotal;

    if (isOpenEdition || total == null) {
      return '${formatCount(sold.toInt())} sold';
    }
    return '${formatCount(sold.toInt())} / ${formatCount(total.toInt())} sold';
  }
}
