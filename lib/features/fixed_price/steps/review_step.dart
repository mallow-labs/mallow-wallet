import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/listing_review_artwork_header.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_kv_row.dart';
import '../../sale/widgets/proceeds_breakdown.dart';
import '../services/fixed_price_bloc.dart';

/// Step 4: review summary + per-recipient proceeds breakdown.
///
/// Layout per the Figma spec. Shows the artwork preview + `TITLE /
/// @artist` headline, listing-details rows, and the proceeds breakdown. The
/// pricing-error red panel renders only if validation fails.
class ReviewStep extends StatelessWidget {
  const ReviewStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      builder: (context, state) {
        final colors = context.mallowColors;
        final token = tokenByMint(state.currencyMint) ?? defaultBidToken;
        final artwork = state.selectedArtwork;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: MallowTheme.spacingXl,
            children: [
              if (artwork != null)
                ListingReviewArtworkHeader(
                  imageUrl: artwork.imageUrl,
                  title: formatArtworkName(
                    name: artwork.title,
                    editionNumber: artwork.editionNumber,
                  ),
                  artistDisplay: formatHandleOrAddress(
                    username: artwork.artistUsername,
                    address: state.updateAuthority,
                  ),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Listing Details',
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  MallowKvList(
                    rows: [
                      const MallowKvRow(
                        label: 'Sale type',
                        value: 'Fixed Price',
                      ),
                      MallowKvRow(
                        label: 'Price',
                        value: state.price == 0
                            ? '—'
                            : '${displayDecimal(token.rawToDisplay(state.price))} ${token.symbol}',
                      ),
                      if (state.isMasterEdition)
                        MallowKvRow(
                          label: 'Max per wallet',
                          value: state.editionsLimit == 0
                              ? 'No cap'
                              : state.editionsLimit.toString(),
                        ),
                      if (state.includePhysical &&
                          (state.physical?.description.trim().isNotEmpty ??
                              false))
                        const MallowKvRow(label: 'Physical', value: 'Included'),
                      if (state.includeRewards &&
                          state.rewardsDescription.trim().isNotEmpty)
                        const MallowKvRow(label: 'Rewards', value: 'Included'),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: MallowTheme.spacingMd,
                children: [
                  if (state.showDirectProceedsOption)
                    MallowCheckbox(
                      value: !state.disablePrimarySplit,
                      label: 'Direct all proceeds to creators',
                      onChanged: (directToCreators) =>
                          context.read<FixedPriceBloc>().add(
                            FixedPriceEvent.setDisablePrimarySplit(
                              !directToCreators,
                            ),
                          ),
                    ),
                  ProceedsBreakdown(
                    splits: state.proceedsSplits,
                    token: token,
                    priceRaw: state.price,
                  ),
                ],
              ),
              if (state.pricingError != null)
                Container(
                  padding: const EdgeInsets.all(MallowTheme.spacingMd),
                  decoration: BoxDecoration(
                    color: colors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(
                      MallowTheme.radiusPrimary,
                    ),
                  ),
                  child: Text(
                    state.pricingError!,
                    style: MallowTheme.uiCaption.copyWith(color: colors.error),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
