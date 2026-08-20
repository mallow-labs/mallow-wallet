import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../services/portfolio_bloc.dart';
import 'hidden_artwork_badge.dart';

/// A 3-column masonry grid for the "All art" tab.
///
/// Each item displays the artwork image at its native aspect ratio.
/// [onTap] is called with the artwork when tapped.
/// [onLongPress] is called with the artwork on long-press (for context menu).
class AllArtMasonry extends StatelessWidget {
  const AllArtMasonry({
    required this.artworks,
    this.onTap,
    this.onLongPress,
    this.heroSource,
    super.key,
  });

  final List<PortfolioArtwork> artworks;
  final ValueChanged<PortfolioArtwork>? onTap;
  final ValueChanged<PortfolioArtwork>? onLongPress;

  /// When set, each tile's image opts into a shared-element flight to the
  /// artwork detail image; the string keeps the tag unique per surface. The
  /// caller must open the detail route with the matching [artworkHeroTag] as
  /// its `extra`.
  final String? heroSource;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      // Use the base [SliverMasonryGrid] constructor (not `.count`) so we can
      // pass an explicit [SliverChildBuilderDelegate] with keep-alives off.
      // Off-screen tiles must dispose to keep the image cache from holding
      // onto every NFT the user has scrolled past.
      sliver: SliverMasonryGrid(
        gridDelegate: const SliverSimpleGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
        ),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        delegate: SliverChildBuilderDelegate(
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          (context, index) {
            final artwork = artworks[index];
            return _MasonryItem(
              artwork: artwork,
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

class _MasonryItem extends StatelessWidget {
  const _MasonryItem({
    required this.artwork,
    this.heroSource,
    this.onTap,
    this.onLongPress,
  });

  final PortfolioArtwork artwork;
  final String? heroSource;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AspectRatio(
        aspectRatio: artwork.aspectRatio,
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
                  cdnFit: 'inside',
                  errorIconSize: 20,
                  heroTag: heroSource == null
                      ? null
                      : artworkHeroTag(heroSource!, artwork.mintAccount),
                ),
              ),
            ),
            if (artwork.isHidden)
              const Positioned(top: 8, right: 8, child: HiddenArtworkBadge()),
          ],
        ),
      ),
    );
  }
}
