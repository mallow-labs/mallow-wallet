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
import '../services/auction_bloc.dart';

/// Step 5: review summary before listing. Shares the artwork preview +
/// `TITLE / @artist` headline with the fixed-price review; the
/// reserve-price line keeps a `(Reserve)` qualifier in
/// `textSecondary`.
class AuctionReviewStep extends StatelessWidget {
  const AuctionReviewStep({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      builder: (context, state) {
        final colors = context.mallowColors;
        final token = tokenByMint(state.bidMint) ?? defaultBidToken;
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
                      const MallowKvRow(label: 'Sale type', value: 'Auction'),
                      MallowKvRow(
                        label: 'Price',
                        valueWidget: _reservePriceText(
                          context,
                          reservePrice: state.reservePrice,
                          token: token,
                        ),
                      ),
                      MallowKvRow(
                        label: 'Duration',
                        value: _formatDuration(state.duration),
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
                          context.read<AuctionBloc>().add(
                            AuctionEvent.setDisablePrimarySplit(
                              !directToCreators,
                            ),
                          ),
                    ),
                  // Auctions show percentages, not amounts: the hammer price
                  // is unknown at listing time, so amounts derived from the
                  // reserve are wrong for any auction settling above it
                  // (webapp parity — `ProceedsInfo` `showPercentages`).
                  ProceedsBreakdown(
                    splits: state.proceedsSplits,
                    token: token,
                    priceRaw: null,
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

/// Reserve-price value: amount + a `(Reserve)` qualifier that uses the
/// same `textSecondary` tone as the label so it reads as supplementary text.
Widget _reservePriceText(
  BuildContext context, {
  required int reservePrice,
  required MallowToken token,
}) {
  final colors = context.mallowColors;
  final amount = reservePrice == 0
      ? '—'
      : '${displayDecimal(token.rawToDisplay(reservePrice))} ${token.symbol}';
  final amountStyle = MallowTheme.uiCaption.copyWith(
    color: colors.textSecondary,
    fontWeight: FontWeight.w500,
  );
  final qualifierStyle = MallowTheme.uiCaption.copyWith(
    color: colors.textSecondary,
  );
  return RichText(
    textAlign: TextAlign.right,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      children: [
        TextSpan(text: amount, style: amountStyle),
        if (reservePrice > 0)
          TextSpan(text: ' (Reserve)', style: qualifierStyle),
      ],
    ),
  );
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return '—';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours == 0) return '$minutes minutes';
  if (minutes == 0) return '$hours hours';
  return '${hours}h ${minutes}m';
}
