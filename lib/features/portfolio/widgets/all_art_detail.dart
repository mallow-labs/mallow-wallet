import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/tappable.dart';
import '../services/portfolio_bloc.dart';
import 'hidden_artwork_badge.dart';

/// Detail view — one card per artwork with the image, edition/supply line,
/// listing status, title, creator, price and sold count.
///
/// The richest of the three artwork layouts ([AllArtMasonry] and [AllArtGrid]
/// being the other two) and the only one that surfaces price and listing
/// timing. Shared by every artwork surface: the portfolio, the profile artwork
/// tabs, the collection and curation screens, the group drilldown, and the
/// search drilldown.
class AllArtDetail extends StatelessWidget {
  const AllArtDetail({
    required this.artworks,
    this.onTap,
    this.onLongPress,
    this.heroSource,
    super.key,
  });

  final List<PortfolioArtwork> artworks;
  final ValueChanged<PortfolioArtwork>? onTap;

  /// Press-and-hold opens the per-artwork options sheet. This layout has no
  /// kebab, matching the masonry and grid layouts.
  final ValueChanged<PortfolioArtwork>? onLongPress;

  /// When set, each card's image opts into a shared-element flight to the
  /// artwork detail image; the string keeps the tag unique per surface. The
  /// caller must open the detail route with the matching [artworkHeroTag] as
  /// its `extra`.
  final String? heroSource;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverList.separated(
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        itemCount: artworks.length,
        separatorBuilder: (_, _) =>
            const SizedBox(height: MallowTheme.spacingLg),
        itemBuilder: (context, index) {
          final artwork = artworks[index];
          return ArtworkDetailCard(
            artwork: artwork,
            heroSource: heroSource,
            onTap: onTap != null ? () => onTap!(artwork) : null,
            onLongPress: onLongPress != null
                ? () => onLongPress!(artwork)
                : null,
          );
        },
      ),
    );
  }
}

/// A single artwork card for [AllArtDetail].
class ArtworkDetailCard extends StatelessWidget {
  const ArtworkDetailCard({
    required this.artwork,
    this.heroSource,
    this.onTap,
    this.onLongPress,
    super.key,
  });

  final PortfolioArtwork artwork;
  final String? heroSource;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final listingStatus = _buildListingStatus(artwork);
    final price = artwork.displayPrice;
    final soldCount = artwork.soldCountLabel;
    final isOneOfOne =
        artwork.parentEdition == null &&
        artwork.maxSupply != null &&
        artwork.maxSupply! <= 1;

    return Tappable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image container with padding
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(MallowTheme.spacing20),
              decoration: BoxDecoration(
                color: colors.bgSurface,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) => MallowArtworkMedia(
                        imageUrl: artwork.imageUrl,
                        playbackId: artwork.playbackId,
                        clipPlaybackId: artwork.clipPlaybackId,
                        nsfw: artwork.nsfw,
                        logicalSize: constraints.maxWidth,
                        fit: BoxFit.contain,
                        cdnFit: 'inside',
                        heroTag: heroSource == null
                            ? null
                            : artworkHeroTag(heroSource!, artwork.mintAccount),
                      ),
                    ),
                  ),
                  if (artwork.isHidden)
                    const Positioned(
                      top: 0,
                      right: 0,
                      child: HiddenArtworkBadge(),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: MallowTheme.spacing12),

          // Edition info row
          Row(
            children: [
              SvgPicture.asset(
                isOneOfOne
                    ? 'assets/icons/one_of_one.svg'
                    : 'assets/icons/edition.svg',
                width: 14,
                height: 14,
                colorFilter: ColorFilter.mode(
                  colors.textSecondary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                artwork.supplyLabel,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (listingStatus != null) ...[
                const Spacer(),
                if (listingStatus.iconPath != null) ...[
                  SvgPicture.asset(
                    listingStatus.iconPath!,
                    height: 11,
                    colorFilter: ColorFilter.mode(
                      listingStatus.isPink
                          ? colors.accent
                          : colors.textSecondary,
                      BlendMode.srcIn,
                    ),
                  ),
                  if (listingStatus.text.isNotEmpty) const SizedBox(width: 4),
                ],
                if (listingStatus.text.isNotEmpty)
                  Text(
                    listingStatus.text,
                    style: MallowTheme.uiCaption.copyWith(
                      color: listingStatus.isPink
                          ? colors.accent
                          : colors.textSecondary,
                    ),
                  ),
              ],
            ],
          ),

          const SizedBox(height: 6),

          // Title
          Text(
            formatArtworkName(
              name: artwork.title,
              editionNumber: artwork.editionNumber,
            ),
            style: MallowTheme.editorialQuote.copyWith(
              color: colors.textPrimary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 6),

          // Creator username, matching the portfolio grid/masonry cards. The
          // artwork model's artistName prefers displayName, which is not the
          // identity this card should expose.
          Text(
            formatUsernameOrAddress(
              username: artwork.artistUsername,
              address: artwork.updateAuth,
            ),
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          // Price + sold count row
          if (price.isNotEmpty || soldCount != null) ...[
            const SizedBox(height: MallowTheme.spacing12),
            Row(
              children: [
                if (price.isNotEmpty)
                  Text(
                    price,
                    style: MallowTheme.uiMeta.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                if (price.isNotEmpty && soldCount != null) const Spacer(),
                if (soldCount != null)
                  Text(
                    soldCount,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Listing status result for display in the edition row.
class _ListingStatus {
  const _ListingStatus({
    required this.text,
    required this.isPink,
    this.iconPath,
  });

  final String text;
  final bool isPink;
  final String? iconPath;
}

/// Compute listing status text from artwork metadata.
_ListingStatus? _buildListingStatus(PortfolioArtwork artwork) {
  final now = DateTime.now().toUtc();

  // Unlisted printable with prints: "{supply} printed"
  if ((artwork.listingType == null ||
          artwork.listingType == api.ListingType.unlisted) &&
      artwork.isPrintable &&
      (artwork.supply ?? 0) > 0) {
    return _ListingStatus(
      text: '${formatCount(artwork.supply ?? 0)} printed',
      isPink: false,
    );
  }

  if (artwork.listingType == api.ListingType.auction) {
    final auction = artwork.auctionMetadata;
    if (auction == null) return null;

    // Starts on first bid (no end date set)
    if (auction.endsAt == null) {
      return const _ListingStatus(text: 'Starts on bid', isPink: false);
    }

    // Pending start (startsAt in future)
    if (auction.startsAt != null && auction.startsAt!.isAfter(now)) {
      final label =
          'Auction · ${_formatDuration(auction.startsAt!.difference(now))}';
      return _ListingStatus(text: label, isPink: false);
    }

    // Active auction
    if (auction.endsAt!.isAfter(now)) {
      final label =
          'Live auction · Ends ${_formatDuration(auction.endsAt!.difference(now))}';
      return _ListingStatus(text: label, isPink: true);
    }
  }

  if (artwork.listingType == api.ListingType.buyNow) {
    final buyNow = artwork.buyNowMetadata;
    // Pending start (startsAt in future)
    if (buyNow?.startsAt != null && buyNow!.startsAt!.isAfter(now)) {
      return _ListingStatus(
        text: _formatDuration(buyNow.startsAt!.difference(now)),
        isPink: false,
      );
    }
    if (buyNow?.endsAt != null && buyNow!.endsAt!.isAfter(now)) {
      // Only show if within 30 days
      if (buyNow.endsAt!.difference(now).inDays < 30) {
        final label =
            'Live · Ends ${_formatDuration(buyNow.endsAt!.difference(now))}';
        return _ListingStatus(text: label, isPink: true);
      }
    }
  }

  if (artwork.listingType == api.ListingType.raffle) {
    // Webapp `CardStatusContent`, whose `isActive` for a card (no
    // on-chain read) is `raffleMetadata != null && now < endsAt`
    // (`raffleStateDerivation`). Once the window closes the badge is
    // no longer a call to action: tickets sold means the draw is still to come,
    // none sold means the raffle simply expired. Badging both "Live raffle"
    // sent testers to a purchase they could no longer make.
    final raffle = artwork.raffleMetadata;
    final endsAt = raffle?.endsAt;
    if (raffle == null || endsAt == null) {
      // No lifecycle to read (endpoint didn't hydrate it). Keep the neutral
      // raffle marker rather than asserting a state we can't verify — the
      // webapp's `isActive` would say "expired" here, but it never sees a
      // preview without the field.
      return const _ListingStatus(
        text: '',
        isPink: false,
        iconPath: 'assets/icons/jellybean.svg',
      );
    }
    if (endsAt.isAfter(now)) {
      return _ListingStatus(
        text: 'Live raffle · Ends ${_formatDuration(endsAt.difference(now))}',
        isPink: true,
        iconPath: 'assets/icons/jellybean.svg',
      );
    }
    return _ListingStatus(
      text: (raffle.sold ?? 0) > 0 ? 'Draw pending' : 'Raffle expired',
      isPink: false,
      iconPath: 'assets/icons/jellybean.svg',
    );
  }

  if (artwork.listingType == api.ListingType.gumball) {
    return const _ListingStatus(
      text: '',
      isPink: false,
      iconPath: 'assets/icons/gumball.svg',
    );
  }

  return null;
}

/// Format a Duration as "Xd Yh", "Xh Ym", or "Xm".
String _formatDuration(Duration duration) {
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;

  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${math.max(1, minutes)}m';
}
