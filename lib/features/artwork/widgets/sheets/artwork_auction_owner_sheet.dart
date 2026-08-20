import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_auction_live_panel.dart';

/// Bottom sheet shown to the seller while their auction is active. Shares the
/// timed [ArtworkAuctionLivePanel] body with the bidder sheet — same price +
/// countdown header, final-window progress bar, highest-bid strip, and the
/// 1-second ticker that auto-updates on new bids and auction end.
///
/// The only seller-specific bit is the CTA: a "Cancel auction" button while no
/// bid has landed (cancellation is blocked once bidding starts, parity with
/// the webapp). Once a bid lands the button is removed entirely — the seller is
/// committed and just watches the live auction until it settles.
///
/// Triggered by `owner` × `auction` × not-ended — see
/// `docs/artwork_state.md`.
class ArtworkAuctionOwnerSheet extends StatelessWidget {
  const ArtworkAuctionOwnerSheet({
    required this.artwork,
    required this.onCancelAuction,
    this.currentBidderUsername,
    this.isLoading = false,
    this.onAuctionEnded,
    super.key,
  });

  final ArtworkDetails artwork;
  final VoidCallback onCancelAuction;
  final bool isLoading;

  /// Resolved mallow username for `auctionMetadata.currentBidder`.
  final String? currentBidderUsername;

  /// Forwarded to [ArtworkAuctionLivePanel.onAuctionEnded].
  final VoidCallback? onAuctionEnded;

  @override
  Widget build(BuildContext context) {
    return ArtworkAuctionLivePanel(
      artwork: artwork,
      currentBidderUsername: currentBidderUsername,
      onAuctionEnded: onAuctionEnded,
      actionBuilder: (context, timing) {
        // Once a bid lands the auction can't be cancelled — drop the CTA.
        if (timing.hasBids) return const SizedBox.shrink();

        final canCancel = !timing.ended && !isLoading;
        return Padding(
          padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
          child: MallowButton(
            label: 'Cancel auction',
            variant: MallowButtonVariant.secondary,
            enabled: canCancel,
            isLoading: isLoading,
            onPressed: canCancel ? onCancelAuction : null,
            isFullWidth: true,
          ),
        );
      },
    );
  }
}
