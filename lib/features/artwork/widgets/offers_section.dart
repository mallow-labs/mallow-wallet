import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/token_metadata_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/token_amount_text.dart';
import '../data/offer_repository.dart';
import 'activity_list_row.dart';
import 'paged_section.dart';

/// Offers tab on the artwork page. Shows the same
/// active-offer rows the webapp lists (`/v1/offers` with
/// `filter: {nftMint, activeOnly}`), latest first, with a load-more
/// affordance when the response pages.
class OffersSection extends StatelessWidget {
  const OffersSection({
    required this.mintAccount,
    this.refreshToken = 0,
    super.key,
  });

  final String mintAccount;

  /// Bumped on each indexer-driven refresh to re-pull page 0 in place.
  final int refreshToken;

  @override
  Widget build(BuildContext context) {
    return PagedSection<api.OfferRender>(
      refreshToken: refreshToken,
      identity: (offer) =>
          offer.txId ??
          '${offer.buyerAddress}-${offer.currencyMint}-${offer.price}',
      fetchPage: (page) async {
        final result = await sl<OfferRepository>().getOffers(
          mintAccount: mintAccount,
          page: page,
        );
        return (items: result.result, nextPage: result.nextPage);
      },
      emptyLabel: 'No offers yet.',
      errorLabel: 'Could not load offers.',
      rowBuilder: (offer) => ActivityListRow(
        name:
            offer.buyer?.username ??
            offer.buyer?.displayName ??
            truncateAddress(offer.buyerAddress),
        action: 'made an offer',
        avatarUrl: offer.buyer?.avatarUrl,
        username: offer.buyer?.username,
        address: offer.buyerAddress,
        // An offer's currency is whatever the buyer chose, so it can be a mint
        // the static registry doesn't key — those resolve through DAS rather
        // than rendering as an empty amount cell.
        amount: sl<TokenMetadataService>().needsLookup(offer.currencyMint)
            ? null
            : PriceFormatter.formatRawAmountWithSymbol(
                offer.price,
                offer.currencyMint,
              ),
        amountWidget: sl<TokenMetadataService>().needsLookup(offer.currencyMint)
            ? TokenAmountText(
                rawAmount: offer.price,
                currencyMint: offer.currencyMint,
                shimmerWidth: 56,
              )
            : null,
        age: offer.date == null ? null : formatLastUpdated(offer.date),
      ),
    );
  }
}
