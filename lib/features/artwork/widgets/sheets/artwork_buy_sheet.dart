import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/price_format.dart';
import '../../../../shared/utils/balance_check.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../../portfolio/services/token_balance_bloc.dart';
import '../../services/artwork_action_state.dart' show ArtworkBuyBlock;
import '../../services/artwork_bloc.dart';
import 'artwork_funding_source.dart';
import 'artwork_sheet_frame.dart';
import 'listing_disclosures.dart';
import 'offer_action_buttons.dart';

/// Persistent bottom sheet for listed 1/1s and edition prints. Shows the
/// listing price, a supply-progress bar (when applicable), and a Buy CTA.
///
/// Triggered by `viewer` × `buyNow` × (`oneOfOne` ∨ `editionPrint`) — see
/// `docs/artwork_state.md`.
class ArtworkBuySheet extends StatelessWidget {
  const ArtworkBuySheet({
    required this.artwork,
    required this.onBuy,
    required this.onMakeOffer,
    required this.onCancelOffer,
    this.isLoading = false,
    this.userOwnOffer = false,
    this.block,
    super.key,
  });

  final ArtworkDetails artwork;
  final VoidCallback onBuy;
  final bool isLoading;

  /// Non-null when the listing must not be bought — the CTA renders disabled
  /// with the reason instead of an enabled "Buy" that fails downstream. See
  /// [ArtworkBuyBlock].
  final ArtworkBuyBlock? block;

  /// True when the connected wallet has a live offer on this artwork —
  /// flips the secondary CTA from "Make offer" to "Cancel offer".
  final bool userOwnOffer;

  final VoidCallback onMakeOffer;
  final VoidCallback onCancelOffer;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final block = this.block;
    final buyLabel = _buyLabel(block);
    final blockedReason = _blockedReason(block);
    final showProgress =
        artwork.quantitySold != null &&
        artwork.quantityTotal != null &&
        artwork.quantityTotal! > 1;

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
              if (artwork.quantitySold != null &&
                  artwork.quantityTotal != null &&
                  artwork.quantityTotal! > 1)
                Text(
                  '${formatCount(artwork.quantitySold!.toInt())} / '
                  '${formatCount(artwork.quantityTotal!.toInt())} sold',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: MallowTheme.spacingMd),
            ArtworkSheetSupplyProgress(
              sold: artwork.quantitySold!,
              total: artwork.quantityTotal!,
            ),
          ],
          ListingDisclosures(artwork: artwork),
          if (blockedReason != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              blockedReason,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingMd),
          // Both CTAs are funded in the listing currency, so one source line
          // covers the pair. The affordability check below re-derives off
          // TokenBalanceBloc, which the switch reloads for the new wallet.
          ArtworkFundingSource(
            currencyMint: artwork.currency,
            builder: (context, switching) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
                  builder: (context, balanceState) {
                    final result = checkBalanceOrSkip(
                      paymentMint: artwork.currency,
                      requiredRawAmount: artwork.price?.round(),
                      balanceState: balanceState,
                    );
                    return MallowButton(
                      label: buyLabel,
                      enabled: block == null && !switching,
                      onPressed: isLoading || block != null
                          ? null
                          : () {
                              if (!ensureSufficientBalance(context, result)) {
                                return;
                              }
                              onBuy();
                            },
                      isLoading: isLoading && block == null,
                      isFullWidth: true,
                    );
                  },
                ),
                const SizedBox(height: MallowTheme.spacingSm),
                OfferActionButtons(
                  userOwnOffer: userOwnOffer,
                  isLoading: isLoading || switching,
                  onMakeOffer: onMakeOffer,
                  onCancelOffer: onCancelOffer,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _buyLabel(ArtworkBuyBlock? block) => switch (block) {
    null => 'Buy',
    ArtworkBuyBlock.notStarted => 'Sale not started',
    ArtworkBuyBlock.ended => 'Sale ended',
    ArtworkBuyBlock.unknownCurrency => 'Buy',
  };

  /// One line of copy under the price explaining a disabled CTA. Without it the
  /// pre-start / ended states read as the app being broken.
  String? _blockedReason(ArtworkBuyBlock? block) {
    final startsAt = artwork.buyNowMetadata?.startsAt;
    return switch (block) {
      null => null,
      ArtworkBuyBlock.notStarted =>
        startsAt == null
            ? 'This sale has not started yet.'
            : 'This sale starts ${_formatSaleStart(startsAt)}.',
      ArtworkBuyBlock.ended => 'This sale has ended.',
      // No explanatory line: the price row directly above is already showing
      // the shimmer / "Unknown token" that this block exists to follow, and
      // the state usually lasts one network round-trip. Copy here would flash.
      ArtworkBuyBlock.unknownCurrency => null,
    };
  }

  String _formatSaleStart(DateTime startsAt) {
    final d = startsAt.difference(DateTime.now());
    if (d.inDays > 0) return 'in ${d.inDays}d ${d.inHours.remainder(24)}h';
    if (d.inHours > 0) return 'in ${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return 'in ${d.inMinutes}m';
    return 'shortly';
  }
}
