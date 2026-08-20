import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../../../shared/widgets/user_handle_text.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_auction_live_panel.dart';
import 'artwork_sheet_frame.dart';

/// Role of the connected wallet relative to an ended auction. Drives the CTA
/// label and visibility — see the auction-ended table in
/// `docs/artwork_state.md`.
enum AuctionEndedRole {
  /// Auction creator / NFT owner — settles or reclaims.
  seller,

  /// Highest bidder — claims the NFT.
  winner,

  /// Anyone else (or disconnected once the connect-wallet variant routes
  /// here for unauthenticated viewers).
  observer,
}

/// Bottom sheet shown after an auction has ended.
///
/// Triggered by `auction` × ended — see `docs/artwork_state.md`.
class ArtworkAuctionClaimSheet extends StatelessWidget {
  const ArtworkAuctionClaimSheet({
    required this.artwork,
    required this.role,
    required this.onSettle,
    required this.onMakeOffer,
    this.winnerUsername,
    this.isLoading = false,
    super.key,
  });

  final ArtworkDetails artwork;
  final AuctionEndedRole role;

  /// Single callback covers settle (seller, has-bids), reclaim (seller,
  /// no-bids), and claim (winner) — they all dispatch the same
  /// `MarketEvent.settleAuction` event since `settleAuction` is a single
  /// program ix that does the right thing based on the caller's role.
  final VoidCallback onSettle;

  /// Opens the make-offer flow for the [AuctionEndedRole.observer] CTA.
  final VoidCallback onMakeOffer;

  /// Resolved mallow username for `auctionMetadata.currentBidder`. Renders
  /// as `@handle` when present, falls back to the truncated address.
  final String? winnerUsername;

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final auction = artwork.auctionMetadata;
    final hasBids = (auction?.bidCount ?? 0) > 0;

    // Seller settling a won auction reuses the live auction panel design —
    // winning-bid price + "Auction ended" status (no progress bar) and the
    // highest-bid strip — capped with a "Settle auction" CTA.
    if (role == AuctionEndedRole.seller && hasBids) {
      return ArtworkAuctionLivePanel(
        artwork: artwork,
        currentBidderUsername: winnerUsername,
        forceEnded: true,
        actionBuilder: (context, _) => Padding(
          padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
          child: MallowButton(
            label: 'Settle auction',
            onPressed: isLoading ? null : onSettle,
            isLoading: isLoading,
            isFullWidth: true,
          ),
        ),
      );
    }

    // Observers (neither seller nor winner) get the same ended-auction panel
    // as the seller's settle sheet — final price + "Auction ended" status and
    // the highest-bid strip — capped with a "Make offer" CTA instead.
    if (role == AuctionEndedRole.observer) {
      return ArtworkAuctionLivePanel(
        artwork: artwork,
        currentBidderUsername: winnerUsername,
        forceEnded: true,
        actionBuilder: (context, _) => Padding(
          padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
          child: MallowButton(
            label: 'Make offer',
            onPressed: isLoading ? null : onMakeOffer,
            isLoading: isLoading,
            isFullWidth: true,
          ),
        ),
      );
    }

    final colors = context.mallowColors;
    final headlineLabel = hasBids
        ? 'Winning bid'
        : 'Auction ended with no bids';
    final amount = hasBids ? auction?.currentBidAmount : null;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            headlineLabel,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          if (role == AuctionEndedRole.winner) ...[
            if (amount != null) ...[
              const SizedBox(height: 4),
              // Price + "You won the auction!" on a single line, mirroring the
              // bid sheet's price/status header row.
              Row(
                children: [
                  Expanded(
                    child: ArtworkSheetPriceRow(
                      rawAmount: amount,
                      currencyMint: auction?.bidMint,
                    ),
                  ),
                  const SizedBox(width: MallowTheme.spacingSm),
                  Text(
                    'You won the auction!',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ] else ...[
            if (amount != null) ...[
              const SizedBox(height: 4),
              ArtworkSheetPriceRow(
                rawAmount: amount,
                currencyMint: auction?.bidMint,
              ),
            ],
            if (hasBids && auction?.currentBidder != null) ...[
              const SizedBox(height: 4),
              UserHandleText(
                prefix: 'Winner: ',
                username: winnerUsername,
                address: auction!.currentBidder,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ],
          const SizedBox(height: MallowTheme.spacingMd),
          // Seller-with-bids (settle) and observers (make-offer) are handled by
          // the live-panel early returns above; only seller-no-bids (reclaim)
          // and winner (claim) render here.
          if (role == AuctionEndedRole.seller && !hasBids)
            MallowButton(
              label: 'Reclaim NFT',
              // Seller reclaim after no-bid expiry uses cancel-auction in
              // the program (handled in MarketBloc dispatch).
              onPressed: isLoading ? null : onSettle,
              isLoading: isLoading,
              isFullWidth: true,
            )
          else if (role == AuctionEndedRole.winner)
            MallowButton(
              label: 'Claim NFT',
              onPressed: isLoading ? null : onSettle,
              isLoading: isLoading,
              isFullWidth: true,
            ),
        ],
      ),
    );
  }
}
