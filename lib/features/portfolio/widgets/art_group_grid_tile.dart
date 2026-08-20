import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Type of art group for display purposes.
enum ArtGroupGridDisplayType { artist, collection, curation }

/// A grid tile for displaying an art group (artist, collection, or curation).
///
/// Shows a single featured square thumbnail, name in Bodoni italic,
/// subtitle with type information, and a count badge. Designed for
/// 2-column grid layout per Figma.
class ArtGroupGridTile extends StatelessWidget {
  const ArtGroupGridTile({
    required this.name,
    required this.imageUrls,
    required this.count,
    required this.displayType,
    this.collectionName,
    this.isPinned = false,
    this.onTap,
    super.key,
  });

  /// Name of the artist, collection, or curation.
  final String name;

  /// URLs for thumbnails. First URL is used as the featured image.
  final List<String> imageUrls;

  /// Number of items in this group.
  final int count;

  /// Type of group to display.
  final ArtGroupGridDisplayType displayType;

  /// Creator name (used for collection/curation subtitle).
  final String? collectionName;

  /// Whether this group is pinned (shows pin icon for artists).
  final bool isPinned;

  /// Callback when the tile is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Square thumbnail - single featured image
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              child: _buildThumbnail(context),
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          // Name + subtitle with count badge centered vertically
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: MallowTheme.editorialQuote,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: MallowTheme.spacingXs),
                    _buildSubtitle(context),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _buildCountBadge(context),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    final url = imageUrls.isNotEmpty ? imageUrls.first : null;

    if (url == null || url.isEmpty) {
      return Container(color: context.mallowColors.divider);
    }

    // 2-column grid with 20 px outer padding and 12 px gutter — matches
    // the SliverGrid configurations in `user_profile_screen.dart` and
    // `all_art_grid.dart`. Caps the image decode to the actual rendered
    // tile width.
    final tileLogicalSize = (MediaQuery.sizeOf(context).width - 40 - 12) / 2;

    return MallowNetworkImage(imageUrl: url, logicalSize: tileLogicalSize);
  }

  Widget _buildSubtitle(BuildContext context) {
    switch (displayType) {
      case ArtGroupGridDisplayType.artist:
        if (isPinned) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MallowSvgIcon(
                'assets/icons/pin.svg',
                width: 12,
                height: 12,
                color: context.mallowColors.textSecondary,
              ),
              const SizedBox(width: MallowTheme.spacingXs),
              Text(
                'Artist',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          );
        }
        return Text(
          'Artist',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        );
      case ArtGroupGridDisplayType.collection:
        return Text(
          collectionName != null
              ? 'Collection • $collectionName'
              : 'Collection',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      case ArtGroupGridDisplayType.curation:
        return Text(
          collectionName != null ? 'Curation • $collectionName' : 'Curation',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }

  Widget _buildCountBadge(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacingSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Text(
        count.toString(),
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textPrimary,
        ),
      ),
    );
  }
}
