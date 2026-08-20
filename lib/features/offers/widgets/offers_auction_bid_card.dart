import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/avatar_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_pill_chip.dart';
import '../../../shared/widgets/nsfw_obscured.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../artwork/widgets/activity_list_row.dart';

/// Auction-bid card on the Offers screen: a self-contained
/// surface card with the artwork header (thumb + title + creator) and a
/// "Live auction"/"Auction complete" chip inside it, the grouped per-auction
/// bid breakdown from [api.AuctionInfo] beneath, and a footer with the
/// outcome chip (placed only) and a "View" pill.
///
/// Which bids show, per tab:
/// - **Received:** up to the last 3 bids (newest first). The seller's own
///   listing event — indexed as a bid whose bidder is
///   [api.AuctionInfo.sellerAddress] — renders as "You listed".
/// - **Placed:** always the viewer's own bid. When outbid, the current highest
///   bid is shown above it and the viewer's amount renders struck-through;
///   when the viewer leads, the bid they outbid (if any) is shown struck-
///   through below theirs.
///
/// The footer pill appears on every placed card and on completed received
/// cards — accent-colored "Claim NFT" (winner) / "Settle" (seller) when the
/// ended auction owes the viewer an action, plain "View auction" otherwise.
/// It and the header both fire [onView], which deep-links to the artwork.
class OffersAuctionBidCard extends StatelessWidget {
  const OffersAuctionBidCard({
    required this.item,
    required this.onView,
    super.key,
  });

  final api.OffersInboxItem item;
  final VoidCallback onView;

  api.AuctionInfo get _auction => item.auction!;

  bool get _isPlaced => item.direction == api.OffersInboxDirection.placed;

  bool get _isComplete => _auction.status == api.AuctionStatus.complete;

  /// The footer pill shows whenever the card is worth revisiting on the
  /// artwork screen: any placed bid (outbid or leading), or an ended auction.
  bool get _showView => _isPlaced || _isComplete;

  /// A recent-bids entry by the seller is the auction's listing event, not a
  /// real bid — rendered with the "listed" verb and never struck through.
  bool _isListing(api.AuctionBidRef b) =>
      _auction.sellerAddress != null &&
      b.bidderAddress == _auction.sellerAddress;

  /// The bids to list, in render order. Received shows up to the last 3
  /// recent bids; placed shows highest-then-yours when outbid (yours struck),
  /// or yours-then-the-bid-you-outbid (theirs struck) when leading.
  List<_CardBid> _bids() {
    if (!_isPlaced) {
      return [
        for (final b in _auction.recentBids.take(3))
          _CardBid(
            bid: b,
            isYou: b.bidderAddress == item.viewerAddress,
            isListing: _isListing(b),
          ),
      ];
    }
    final bids = <_CardBid>[];
    if (!_auction.isHighestBidder && _auction.highestBid != null) {
      bids.add(_CardBid(bid: _auction.highestBid!, isYou: false));
    }
    if (_auction.yourBid != null) {
      bids.add(
        _CardBid(
          bid: _auction.yourBid!,
          isYou: true,
          struck: !_auction.isHighestBidder,
        ),
      );
    }
    if (_auction.isHighestBidder) {
      // The bid the viewer outbid on their way to the top — the newest recent
      // bid that isn't theirs and isn't the seller's listing event.
      for (final b in _auction.recentBids) {
        if (b.bidderAddress != item.viewerAddress && !_isListing(b)) {
          bids.add(_CardBid(bid: b, isYou: false, struck: true));
          break;
        }
      }
    }
    return bids;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bids = _bids();

    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacingMd),
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(colors),
          if (bids.isNotEmpty) ...[
            const SizedBox(height: MallowTheme.spacingLg),
            for (var i = 0; i < bids.length; i++) ...[
              if (i > 0) const SizedBox(height: MallowTheme.spacingMd),
              _bidRow(bids[i]),
            ],
          ],
          if (_isPlaced || _showView) ...[
            const SizedBox(height: MallowTheme.spacingLg),
            _footer(colors),
          ],
        ],
      ),
    );
  }

  /// Artwork thumb + title + creator with the auction-status chip top-right.
  /// Tapping anywhere on it opens the artwork.
  Widget _header(MallowColors colors) {
    final imageUrl = item.artworkImageUrl;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onView,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _thumbnail(colors, imageUrl),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatArtworkName(
                      name: item.artworkTitle,
                      editionNumber: item.editionNumber,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.editorialQuote.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  if (item.creatorUsername != null &&
                      item.creatorUsername!.isNotEmpty) ...[
                    const SizedBox(height: MallowTheme.spacingXs),
                    Text(
                      item.creatorUsername!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _statusChip(colors),
        ],
      ),
    );
  }

  /// "Live auction" (accent text + pinging accent dot) or "Auction complete"
  /// (plain primary text), both on the muted gray chip.
  Widget _statusChip(MallowColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacingSm,
        vertical: MallowTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: colors.divider,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isComplete) ...[
            _PingingDot(color: colors.accent, size: 6),
            const SizedBox(width: MallowTheme.spacingXs),
          ],
          Text(
            _isComplete ? 'Auction complete' : 'Live auction',
            style: MallowTheme.uiCaption.copyWith(
              color: _isComplete ? colors.textPrimary : colors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bidRow(_CardBid entry) {
    final bid = entry.bid;
    final name = entry.isYou
        ? 'You'
        : (bid.bidder?.username ??
              bid.bidder?.displayName ??
              truncateAddress(bid.bidderAddress));
    return ActivityListRow(
      name: name,
      action: entry.isListing ? 'listed' : 'made a bid',
      circularAvatar: true,
      avatarUrl: bid.bidder?.avatarUrl,
      // "You" rows stay inert; counterparty rows linkify to the profile.
      username: entry.isYou ? null : bid.bidder?.username,
      address: entry.isYou ? null : bid.bidderAddress,
      // The identicon seed keeps the bidder's identity even on inert rows.
      avatarSeed: avatarSeedOf(
        address: bid.bidderAddress,
        username: bid.bidder?.username,
      ),
      amount: PriceFormatter.formatRawAmountWithSymbol(
        bid.rawAmount,
        bid.currencyMint,
      ),
      age: bid.date == null ? null : formatLastUpdated(bid.date),
      avatarSize: 24,
      textStyle: MallowTheme.uiCaption,
      amountStruckThrough: entry.struck,
      // Wide enough for the longest relative stamp ("Just now") on one line.
      ageWidth: 48,
      verticalPadding: 0,
    );
  }

  /// Outcome chip (placed only) + optional trailing pill.
  /// Leading while live reads "You are the highest bidder" on the muted gray
  /// chip; once the auction completes it flips to the green "You won the
  /// auction!". Outbid always gets the salmon "You were outbid!". The pill
  /// reads "Claim" in the accent color when the complete auction awaits the
  /// viewer's claim (seller's proceeds, or winner's prize); otherwise it's
  /// the plain "View".
  Widget _footer(MallowColors colors) {
    final highest = _auction.isHighestBidder;
    final won = highest && _isComplete;
    // The seller (received) and the winner both have a claim waiting on the
    // artwork screen once the auction ends (proceeds / prize).
    final claimAwaits = _isComplete && (!_isPlaced || highest);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_isPlaced)
          _chip(
            won
                ? 'You won the auction!'
                : highest
                ? 'You are the highest bidder'
                : 'You were outbid!',
            won
                ? colors.positive.withValues(alpha: 0.5)
                : highest
                ? colors.divider
                : colors.accent.withValues(alpha: 0.5),
            colors,
          )
        else
          const SizedBox.shrink(),
        if (_showView)
          TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onView,
              // Same pill either way — accent-colored when actionable: the
              // winner claims the NFT, the seller settles the auction.
              child: MallowPillChip(
                claimAwaits
                    ? (_isPlaced ? 'Claim NFT' : 'Settle')
                    : 'View auction',
                color: claimAwaits ? colors.accent : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _chip(String label, Color background, MallowColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacingSm,
        vertical: MallowTheme.spacingXs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Text(
        label,
        style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
      ),
    );
  }

  /// Artwork thumb, blurred behind the viewer's show-NSFW setting when the
  /// piece is flagged — the same treatment the artwork grids give their tiles.
  Widget _thumbnail(MallowColors colors, String? imageUrl) {
    return NsfwObscured(
      nsfw: item.nsfw,
      contentId: item.asset,
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        child: imageUrl != null && imageUrl.isNotEmpty
            ? MallowNetworkImage(
                imageUrl: imageUrl,
                logicalSize: 52,
                width: 52,
                height: 52,
                errorBuilder: (_) => _placeholder(colors),
              )
            : _placeholder(colors),
      ),
    );
  }

  Widget _placeholder(MallowColors colors) =>
      Container(width: 52, height: 52, color: colors.surfaceMuted);
}

/// A small dot with a repeating radar-ping: an expanding, fading ring pulses
/// out from the solid center — the "live" indicator on the auction chip.
class _PingingDot extends StatefulWidget {
  const _PingingDot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_PingingDot> createState() => _PingingDotState();
}

class _PingingDotState extends State<_PingingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion: hold the solid dot with no radar ping.
    if (context.reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduce Motion: render just the solid centre dot, no expanding ring.
    if (context.reduceMotion) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      );
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_controller.value);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 1 + 1.5 * t,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.5 * (1 - t)),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A bid paired with how it renders: [isYou] drives the "You" label and the
/// inert (non-linkified) row; [isListing] swaps the verb to "listed";
/// [struck] strikes the amount (a superseded bid).
class _CardBid {
  const _CardBid({
    required this.bid,
    required this.isYou,
    this.isListing = false,
    this.struck = false,
  });

  final api.AuctionBidRef bid;
  final bool isYou;
  final bool isListing;
  final bool struck;
}
