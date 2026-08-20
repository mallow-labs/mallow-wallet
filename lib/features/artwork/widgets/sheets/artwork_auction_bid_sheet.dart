import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_auction_live_panel.dart';
import 'artwork_funding_source.dart';

/// Bottom sheet shown to non-owners while an auction is active. Mirrors the
/// webapp's `AuctionBidBox`.
///
/// Triggered by (`viewer` ∨ `creator`) × `auction` × not-ended — see
/// `docs/artwork_state.md`. The timed body (price + countdown header, the
/// final-window salmon progress bar, the highest-bid strip, and the
/// ticker that auto-updates on new bids and auction end) lives in the shared
/// [ArtworkAuctionLivePanel]; this sheet only supplies the CTA, which renders
/// three time-driven shapes:
///   - pre-start scheduled — button disabled "Auction pending start";
///   - active — button "Place bid" (or "You are the highest bidder" when the
///     connected wallet already holds the top bid).
class ArtworkAuctionBidSheet extends StatelessWidget {
  const ArtworkAuctionBidSheet({
    required this.artwork,
    required this.onPlaceBid,
    this.currentBidderUsername,
    this.isCurrentUserHighestBidder = false,
    this.isLoading = false,
    this.onAuctionEnded,
    this.unknownCurrency = false,
    super.key,
  });

  final ArtworkDetails artwork;

  /// Resolved mallow username for `auctionMetadata.currentBidder`.
  final String? currentBidderUsername;

  /// True when the connected wallet is the current high bidder. Disables
  /// "Place bid" and swaps the label to "You are the highest bidder".
  final bool isCurrentUserHighestBidder;

  /// Opens the bid-amount input flow on the screen side. The screen
  /// handles the price-input sheet and dispatches
  /// `MarketEvent.placeBid` with the resulting SOL string.
  final VoidCallback onPlaceBid;

  final bool isLoading;

  /// Forwarded to [ArtworkAuctionLivePanel.onAuctionEnded].
  final VoidCallback? onAuctionEnded;

  /// True while the auction's `bidMint` has no resolved symbol/decimals, so
  /// the panel above is showing a shimmer or "Unknown token" instead of the
  /// current bid. Bidding against an amount that was never displayed is the
  /// exact failure this blocks — see [ArtworkBuyBlock.unknownCurrency].
  final bool unknownCurrency;

  @override
  Widget build(BuildContext context) {
    return ArtworkAuctionLivePanel(
      artwork: artwork,
      currentBidderUsername: currentBidderUsername,
      onAuctionEnded: onAuctionEnded,
      actionBuilder: (context, timing) {
        final canBid =
            !timing.preStart &&
            !timing.ended &&
            !isCurrentUserHighestBidder &&
            !unknownCurrency &&
            !isLoading;
        final String label;
        if (timing.preStart) {
          label = 'Auction pending start';
        } else if (isCurrentUserHighestBidder) {
          label = 'You are the highest bidder';
        } else {
          label = 'Place bid';
        }

        return Padding(
          padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
          // Bids are funded in the auction's `bidMint`, not the listing
          // currency (which is null for auctions).
          child: ArtworkFundingSource(
            currencyMint: artwork.auctionMetadata?.bidMint ?? artwork.currency,
            builder: (context, switching) => MallowButton(
              label: label,
              enabled: canBid && !switching,
              isLoading: isLoading,
              onPressed: canBid ? onPlaceBid : null,
              isFullWidth: true,
            ),
          ),
        );
      },
    );
  }
}
