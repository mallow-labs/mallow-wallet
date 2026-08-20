import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_sheet.dart';
import '../../../../shared/widgets/sheet_drag_handle.dart';
import '../../../../shared/widgets/tap_target_expander.dart';
import '../../../../shared/widgets/token_amount_text.dart';
import '../../services/artwork_bloc.dart';
import '../offers_section.dart';
import 'artwork_funding_source.dart';
import 'artwork_sheet_frame.dart';
import 'highest_offer_panel.dart';
import 'offer_action_buttons.dart';

/// Bottom sheet for non-owners viewing an unlisted artwork. Shows the
/// highest active offer (if any) — buyer, amount,
/// age, same panel as the owner sheet — and a make-offer CTA.
///
/// Triggered by (`viewer` ∨ `creator`) × `unlisted` — see
/// `docs/artwork_state.md`.
class ArtworkUnlistedViewerSheet extends StatelessWidget {
  const ArtworkUnlistedViewerSheet({
    required this.artwork,
    required this.onMakeOffer,
    required this.onCancelOffer,
    this.highestOffer,
    this.userOwnOffer = false,
    this.isLoading = false,
    super.key,
  });

  final ArtworkDetails artwork;

  /// Highest active offer on the artwork, loaded via `OfferRepository`.
  /// While null (loading / none exist) the sheet falls back to the
  /// indexer's scalar `artwork.highestOffer`.
  final OfferRender? highestOffer;

  /// True when the connected wallet has a live offer on this artwork —
  /// flips "Make offer" to "Cancel offer".
  final bool userOwnOffer;

  /// Opens the offer-amount input flow on the screen side and dispatches
  /// `MarketEvent.makeOfferV2`.
  final VoidCallback onMakeOffer;

  /// Dispatches `MarketEvent.cancelOffer` for the connected wallet's
  /// active offer on this mint.
  final VoidCallback onCancelOffer;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final offer = highestOffer;
    final indexerHighestOffer = artwork.highestOffer;
    final offersCount = artwork.offersCount ?? 0;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offer != null)
            HighestOfferPanel(offer: offer)
          else if (indexerHighestOffer != null)
            // `artwork.highestOffer` is the indexer's raw base-unit scalar
            // (the wire object's `price`), not a display amount, and it drops
            // the offer's `currencyMint` on the way through the model.
            // Rendering it as-is printed a 1.5 SOL offer as
            // "1500000000.00 SOL". Divide by the artwork's own currency — the
            // currency an offer must be funded in on this screen — resolving
            // an unregistered mint through DAS and, past that, falling back to
            // the chain's native token.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Highest offer: ',
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TokenAmountText(
                  rawAmount: indexerHighestOffer,
                  currencyMint: artwork.currency,
                  chain: artwork.chain,
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else
            Text(
              'No active offers yet.',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          if (offersCount > 1) ...[
            const SizedBox(height: 4),
            TapTargetExpander(
              child: GestureDetector(
                onTap: () => _showOffers(context),
                child: Text(
                  'View $offersCount offers',
                  style: MallowTheme.uiCaption.copyWith(color: colors.accent),
                ),
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingMd),
          // The offer is funded in the artwork's currency (SOL when unlisted
          // artworks carry none).
          ArtworkFundingSource(
            currencyMint: artwork.currency,
            builder: (context, switching) => OfferActionButtons(
              userOwnOffer: userOwnOffer,
              isLoading: isLoading || switching,
              isPrimary: true,
              onMakeOffer: onMakeOffer,
              onCancelOffer: onCancelOffer,
            ),
          ),
        ],
      ),
    );
  }

  /// Opens every offer on the artwork in a modal sheet.
  ///
  /// Renders the same mint-scoped [OffersSection] the artwork page's "Offers"
  /// tab uses (`OfferRepository.getOffers`, paged) — surfaced here because
  /// this pinned sheet sits on top of that tab.
  void _showOffers(BuildContext context) {
    showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ArtworkOffersSheet(mintAccount: artwork.mintAccount),
    );
  }
}

/// Modal list of every offer on a single artwork. Shrink-wraps its content
/// and only scrolls once [showMallowSheet]'s height cap is reached.
class _ArtworkOffersSheet extends StatelessWidget {
  const _ArtworkOffersSheet({required this.mintAccount});

  final String mintAccount;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Text(
              'Offers',
              style: MallowTheme.uiBody.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: MallowTheme.spacing20,
                right: MallowTheme.spacing20,
                bottom: sheetBottomInset(context),
              ),
              child: OffersSection(mintAccount: mintAccount),
            ),
          ),
        ],
      ),
    );
  }
}
