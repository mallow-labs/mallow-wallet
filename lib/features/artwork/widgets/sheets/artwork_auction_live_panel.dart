import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/services/avatar_service.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/user_display.dart';
import '../../../../shared/widgets/account_avatar.dart';
import '../../../../shared/widgets/mallow_network_image.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';
import 'listing_disclosures.dart';

/// Timing snapshot handed to [ArtworkAuctionLivePanel.actionBuilder] so each
/// sheet can pick its CTA without re-deriving the clock.
class AuctionPanelTiming {
  const AuctionPanelTiming({
    required this.preStart,
    required this.ended,
    required this.hasBids,
  });

  /// Scheduled auction whose start instant is still in the future.
  final bool preStart;

  /// Countdown has reached `endsAt`.
  final bool ended;

  /// At least one bid has landed.
  final bool hasBids;
}

/// Shared timed auction body used by the bidder sheet
/// ([ArtworkAuctionBidSheet]), the seller sheet ([ArtworkAuctionOwnerSheet]),
/// and the post-auction settle sheet ([ArtworkAuctionClaimSheet] via
/// [forceEnded]). Renders the header price + countdown row, the
/// salmon final-window progress bar, the highest-bid strip, and the listing
/// disclosures — everything above the CTA. Each sheet supplies its own CTA via
/// [actionBuilder]; the panel owns the design and the clock so the two stay in
/// lockstep.
///
/// A ticker (1s normally, 100ms while the progress bar is visible) re-evaluates
/// the countdown, the final-window progress bar, and the pre-start gate. Bid/bidder changes (someone outbids, the first bid
/// on an on-bid auction sets the clock, a late bid extends `endsAt`) arrive via
/// the screen's realtime `watchMint` subscription, which re-pulls
/// `auctionMetadata` and rebuilds this panel. When the countdown crosses
/// `endsAt`, [onAuctionEnded] fires once so the screen can rebuild and flip to
/// the claim/settle sheet (the ended check is time-based, not on-chain).
class ArtworkAuctionLivePanel extends StatefulWidget {
  const ArtworkAuctionLivePanel({
    required this.artwork,
    required this.actionBuilder,
    this.currentBidderUsername,
    this.onAuctionEnded,
    this.forceEnded = false,
    super.key,
  });

  final ArtworkDetails artwork;

  /// Pins the panel to its ended shape — "Auction ended" status, no progress
  /// bar — regardless of the auction clock. Set by the post-auction
  /// claim/settle sheet, which already knows the auction is over (the indexed
  /// `endsAt` may briefly read in the future relative to the device clock).
  final bool forceEnded;

  /// Resolved mallow username for `auctionMetadata.currentBidder`.
  final String? currentBidderUsername;

  /// Builds the CTA rendered below the disclosures, given the live timing.
  final Widget Function(BuildContext, AuctionPanelTiming) actionBuilder;

  /// Fired once, the moment the countdown reaches `endsAt`, so the screen can
  /// rebuild and let `resolveArtworkActionState` swap this panel for the
  /// claim/settle sheet. The ended decision is purely time-based (the indexed
  /// `listingState` never flips on its own at the end instant), so no refetch
  /// is needed to transition.
  final VoidCallback? onAuctionEnded;

  @override
  State<ArtworkAuctionLivePanel> createState() =>
      _ArtworkAuctionLivePanelState();
}

class _ArtworkAuctionLivePanelState extends State<ArtworkAuctionLivePanel> {
  /// Fallback salmon-bar window when the auction carries no `timeExtPeriod`.
  /// The bar appears only inside the final window before `endsAt` and counts
  /// down from a full bar.
  static const _defaultProgressWindow = Duration(minutes: 15);

  /// Coarse cadence while only the "Xh Ym Zs" text is counting.
  static const _coarseTick = Duration(seconds: 1);

  /// Fine cadence while the final-window progress bar is visible, so it
  /// drains smoothly instead of jumping once per second.
  static const _fineTick = Duration(milliseconds: 100);

  Timer? _ticker;
  Duration? _tickerInterval;
  DateTime _now = DateTime.now();
  bool _endedFired = false;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ArtworkAuctionLivePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.artwork.auctionMetadata;
    final next = widget.artwork.auctionMetadata;
    // A bid inside the `timeExtPeriod` end phase pushes `endsAt` out to
    // `now + timeExtDelta` (and the first bid on an
    // on-bid auction sets `startsAt`/`endsAt` for the first time). When the
    // target instant moves, rebase the countdown immediately and tear down
    // the old ticker so it doesn't keep ticking toward a stale deadline —
    // `_syncTicker` recreates it against the new clock. A pushed-out `endsAt`
    // also re-arms the end callback.
    if (old?.endsAt != next?.endsAt || old?.startsAt != next?.startsAt) {
      _now = DateTime.now();
      _endedFired = next?.endsAt != null && next!.endsAt!.isAfter(_now)
          ? false
          : _endedFired;
      _ticker?.cancel();
      _ticker = null;
    }
    // A realtime refresh can also swap an on-bid auction (no clock) for a
    // started one (live countdown) — re-evaluate whether a ticker is needed.
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Run the ticker only while there's a future instant to count toward —
  /// a scheduled start or a live end. On-bid auctions with no clock yet don't
  /// need it (nothing changes until the realtime subscription pushes a bid).
  /// Ticks are coarse (1s) for the text countdown and switch to fine (100ms)
  /// once the countdown enters the final progress-bar window; each tick
  /// re-syncs so the upgrade happens the moment the window opens.
  void _syncTicker() {
    final auction = widget.artwork.auctionMetadata;
    final now = DateTime.now();
    final startsAt = auction?.startsAt;
    final endsAt = auction?.endsAt;
    final needsTicker =
        !widget.forceEnded &&
        ((startsAt != null && startsAt.isAfter(now)) ||
            (endsAt != null && endsAt.isAfter(now)));

    if (!needsTicker) {
      _ticker?.cancel();
      _ticker = null;
      _tickerInterval = null;
      return;
    }

    final inProgressWindow =
        (startsAt == null || !startsAt.isAfter(now)) &&
        endsAt != null &&
        endsAt.isAfter(now) &&
        endsAt.difference(now) <= _progressWindow(auction);
    final interval = inProgressWindow ? _fineTick : _coarseTick;

    if (_ticker == null || _tickerInterval != interval) {
      _ticker?.cancel();
      _tickerInterval = interval;
      _ticker = Timer.periodic(interval, (_) {
        if (!mounted) return;
        setState(() => _now = DateTime.now());
        _maybeFireEnded();
        _syncTicker();
      });
    }
  }

  /// Span of the final-window progress bar: the auction's **end phase** — the
  /// window before `endsAt` in which a landing bid extends the auction —
  /// falling back to 15 minutes.
  ///
  /// This is `timeExtPeriod`, not `timeExtDelta`. The two are independent
  /// fields on the wire and only coincide because both clients default them to
  /// the same value at creation. `mallow-auction`'s bid processor reads them
  /// as different things:
  /// `timestamp >= end_time - time_ext_period` decides *whether* to extend,
  /// and `new_end_time = timestamp + time_ext_delta` decides *by how much*.
  /// The webapp draws its end-phase window off `timeExtPeriod` too
  /// (`AuctionInfoBox`).
  Duration _progressWindow(AuctionMetadata? auction) {
    final extPeriod = auction?.timeExtPeriod;
    return (extPeriod != null && extPeriod > 0)
        ? Duration(seconds: extPeriod)
        : _defaultProgressWindow;
  }

  /// Notify the screen the first time the countdown reaches `endsAt` so it can
  /// re-resolve into the claim/settle sheet.
  void _maybeFireEnded() {
    if (_endedFired) return;
    final endsAt = widget.artwork.auctionMetadata?.endsAt;
    if (endsAt != null && !endsAt.isAfter(_now)) {
      _endedFired = true;
      widget.onAuctionEnded?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final auction = widget.artwork.auctionMetadata;
    final now = _now;

    final hasBids = (auction?.bidCount ?? 0) > 0;
    final startsAt = auction?.startsAt;
    final endsAt = auction?.endsAt;
    final ended = widget.forceEnded || (endsAt != null && !endsAt.isAfter(now));
    // An ended auction is never pre-start, even if the device clock disagrees
    // with a stale `startsAt`.
    final preStart = !ended && startsAt != null && startsAt.isAfter(now);

    final amount = hasBids ? auction?.currentBidAmount : auction?.reservePrice;

    final remaining = endsAt != null && endsAt.isAfter(now)
        ? endsAt.difference(now)
        : Duration.zero;
    final progressWindow = _progressWindow(auction);
    // Only inside the final window of a live countdown — `remaining` is zero
    // when there's no future `endsAt` (e.g. an on-bid auction with no clock),
    // which must not render an empty bar.
    final showProgress =
        !preStart &&
        !ended &&
        remaining > Duration.zero &&
        remaining <= progressWindow;

    final timing = AuctionPanelTiming(
      preStart: preStart,
      ended: ended,
      hasBids: hasBids,
    );

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                _statusText(auction, now, preStart: preStart, ended: ended),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: MallowTheme.spacing12),
            // Salmon fills the share of the final window still left, so it
            // shrinks toward zero as the auction closes. Millisecond
            // precision so the 100ms fine ticks each move the bar.
            ArtworkSheetSupplyProgress(
              sold: remaining.inMilliseconds.toDouble(),
              total: progressWindow.inMilliseconds.toDouble(),
              spark: true,
            ),
          ],
          if (hasBids && auction?.currentBidder != null) ...[
            const SizedBox(height: MallowTheme.spacing12),
            _BidderStrip(
              name: formatUsernameOrAddress(
                username: widget.currentBidderUsername,
                address: auction!.currentBidder,
              ),
              avatarUrl: _bidderAvatarUrl(auction),
              avatarSeed: avatarSeedOf(
                address: auction.currentBidder,
                username: widget.currentBidderUsername,
              ),
              bidCount: auction.bidCount,
            ),
          ],
          ListingDisclosures(artwork: widget.artwork),
          // The CTA owns its own leading gap so the seller sheet can drop both
          // the button and the spacing once bids land (no dangling gap).
          widget.actionBuilder(context, timing),
        ],
      ),
    );
  }

  /// Avatar for the highest bidder. `bidders`/`bidderPfps` are paired by index
  /// (index 0 = most recent), so look the bidder up rather than assuming a
  /// slot; fall back to the most-recent pfp.
  String? _bidderAvatarUrl(AuctionMetadata auction) {
    final bidder = auction.currentBidder;
    if (bidder != null) {
      final idx = auction.bidders.indexOf(bidder);
      if (idx >= 0 && idx < auction.bidderPfps.length) {
        return auction.bidderPfps[idx];
      }
    }
    return auction.bidderPfps.isNotEmpty ? auction.bidderPfps.first : null;
  }

  /// Right-aligned status line in the header row. Drives the three pre-start /
  /// active shapes off the auction clock.
  String _statusText(
    AuctionMetadata? auction,
    DateTime now, {
    required bool preStart,
    required bool ended,
  }) {
    final durationLabel = auction?.duration != null
        ? _durationLabel(auction!.duration!)
        : '';
    final prefix = durationLabel.isEmpty ? 'Auction' : '$durationLabel auction';

    if (preStart) {
      return '$prefix starts in ${_hms(auction!.startsAt!.difference(now))}';
    }
    if (ended) return 'Auction ended';
    // On-bid auctions have no clock until the first bid lands.
    if (auction?.startsAt == null && auction?.endsAt == null) {
      return '$prefix starts on bid';
    }
    final endsAt = auction?.endsAt;
    if (endsAt != null && endsAt.isAfter(now)) {
      return '${_hms(endsAt.difference(now))} remaining';
    }
    return '$prefix starts on bid';
  }
}

/// Avatar + "{name} placed the highest bid" + "{n} bids total" — the
/// highest-bid strip from the Figma spec.
class _BidderStrip extends StatelessWidget {
  const _BidderStrip({
    required this.name,
    required this.avatarUrl,
    required this.avatarSeed,
    required this.bidCount,
  });

  final String name;
  final String? avatarUrl;
  final String avatarSeed;
  final int bidCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    const caption = MallowTheme.uiCaption;

    return Row(
      children: [
        _BidderAvatar(imageUrl: avatarUrl, seed: avatarSeed),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: name,
                  style: caption.copyWith(color: colors.textPrimary),
                ),
                TextSpan(
                  text: ' placed the highest bid',
                  style: caption.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Text(
          '$bidCount ${bidCount == 1 ? 'bid' : 'bids'} total',
          style: caption.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }
}

/// 24×24 rounded-square bidder avatar. Falls back to the generated identicon
/// seeded by the bidder's address when they have no pfp.
class _BidderAvatar extends StatelessWidget {
  const _BidderAvatar({this.imageUrl, this.seed = ''});

  final String? imageUrl;
  final String seed;

  static const double _size = 24;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(MallowTheme.radiusPrimary);
    final url = imageUrl;
    if (url != null && url.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: url,
        logicalSize: _size,
        width: _size,
        height: _size,
        borderRadius: radius,
        errorBuilder: (_) =>
            AccountAvatar(seed: seed, size: _size, borderRadius: radius),
      );
    }
    return AccountAvatar(seed: seed, size: _size, borderRadius: radius);
  }
}

/// Compact auction-length label: "24h", "36h", "3d", "7d 12h". Hours up to
/// 48h (so a 24h auction reads "24h", matching the design), days beyond.
String _durationLabel(int seconds) {
  if (seconds <= 0) return '';
  final totalHours = seconds ~/ 3600;
  if (totalHours < 48) {
    if (totalHours >= 1) return '${totalHours}h';
    return '${seconds ~/ 60}m';
  }
  final days = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  return h > 0 ? '${days}d ${h}h' : '${days}d';
}

/// Countdown as "12h 14m 25s" (or "1d 2h 3m" past a day). Drops a leading
/// zero hours ("14m 25s"). Clamped at zero.
String _hms(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final days = d.inDays;
  final h = d.inHours.remainder(24);
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (days > 0) return '${days}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m ${s}s';
  return '${m}m ${s}s';
}
