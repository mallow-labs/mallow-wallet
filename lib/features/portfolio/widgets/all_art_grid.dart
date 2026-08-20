import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../services/portfolio_bloc.dart';
import 'hidden_artwork_badge.dart';

/// A 2-column grid view for the "All art" tab.
///
/// Each item shows a square thumbnail with title and artist name below,
/// matching [ArtGroupGridTile] layout (same spacing, aspect ratio, typography).
class AllArtGrid extends StatelessWidget {
  const AllArtGrid({
    required this.artworks,
    this.onTap,
    this.onLongPress,
    this.heroSource,
    super.key,
  });

  final List<PortfolioArtwork> artworks;
  final ValueChanged<PortfolioArtwork>? onTap;

  /// Called with the artwork on long-press (opens the context menu).
  final ValueChanged<PortfolioArtwork>? onLongPress;

  /// When set, each tile's image opts into a shared-element flight to the
  /// artwork detail image; the string keeps the tag unique per surface. The
  /// caller must open the detail route with the matching [artworkHeroTag] as
  /// its `extra`.
  final String? heroSource;

  @override
  Widget build(BuildContext context) {
    final tileLogicalSize = (MediaQuery.sizeOf(context).width - 40 - 12) / 2;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 40,
          crossAxisSpacing: 12,
          childAspectRatio: 170.5 / 224,
        ),
        delegate: SliverChildBuilderDelegate(
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          (context, index) {
            final artwork = artworks[index];
            return _AllArtGridItem(
              artwork: artwork,
              logicalSize: tileLogicalSize,
              heroSource: heroSource,
              onTap: onTap != null ? () => onTap!(artwork) : null,
              onLongPress: onLongPress != null
                  ? () => onLongPress!(artwork)
                  : null,
            );
          },
          childCount: artworks.length,
        ),
      ),
    );
  }
}

class _AllArtGridItem extends StatelessWidget {
  const _AllArtGridItem({
    required this.artwork,
    required this.logicalSize,
    this.heroSource,
    this.onTap,
    this.onLongPress,
  });

  final PortfolioArtwork artwork;
  final double logicalSize;
  final String? heroSource;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: [
                Positioned.fill(
                  child: MallowArtworkMedia(
                    imageUrl: artwork.imageUrl,
                    playbackId: artwork.playbackId,
                    clipPlaybackId: artwork.clipPlaybackId,
                    nsfw: artwork.nsfw,
                    logicalSize: logicalSize,
                    borderRadius: BorderRadius.circular(
                      MallowTheme.radiusPrimary,
                    ),
                    heroTag: heroSource == null
                        ? null
                        : artworkHeroTag(heroSource!, artwork.mintAccount),
                  ),
                ),
                if (artwork.isHidden)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: HiddenArtworkBadge(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            formatArtworkName(
              name: artwork.title,
              editionNumber: artwork.editionNumber,
            ),
            style: MallowTheme.editorialQuote,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            formatUsernameOrAddress(
              username: artwork.artistUsername,
              address: artwork.updateAuth,
            ),
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
