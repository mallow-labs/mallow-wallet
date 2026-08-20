part of '../collection_screen.dart';

/// 2-column grid similar to [AllArtGrid] but showing collection name instead
/// of artist name.
class _CollectionArtGrid extends StatelessWidget {
  const _CollectionArtGrid({
    required this.artworks,
    required this.onTap,
    required this.onLongPress,
  });

  final List<PortfolioArtwork> artworks;
  final ValueChanged<PortfolioArtwork> onTap;
  final ValueChanged<PortfolioArtwork> onLongPress;

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
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(artwork),
              onLongPress: () => onLongPress(artwork),
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
                            logicalSize: tileLogicalSize,
                            borderRadius: BorderRadius.circular(
                              MallowTheme.radiusPrimary,
                            ),
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
                ],
              ),
            );
          },
          childCount: artworks.length,
        ),
      ),
    );
  }
}
