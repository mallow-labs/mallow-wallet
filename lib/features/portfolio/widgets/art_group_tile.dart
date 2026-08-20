import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Type of art group for display purposes.
enum ArtGroupDisplayType { artist, collection, curation }

/// A list tile for displaying an art group (artist, collection, or curation).
///
/// Shows a single featured thumbnail, name in Bodoni italic, subtitle with
/// type information, and a count badge.
class ArtGroupTile extends StatelessWidget {
  const ArtGroupTile({
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
  final ArtGroupDisplayType displayType;

  /// Creator name (used for collection/curation subtitle:
  /// "Collection • {creatorName}" / "Curation • {creatorName}").
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        child: Row(
          children: [
            // Single featured thumbnail
            _buildThumbnail(context),
            const SizedBox(width: MallowTheme.spacingMd),
            // Text content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Name in Bodoni italic
                  Text(
                    name,
                    style: MallowTheme.editorialQuote,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: MallowTheme.spacingXs),
                  // Subtitle based on type
                  _buildSubtitle(context),
                ],
              ),
            ),
            // Count badge
            _buildCountBadge(context),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    final url = imageUrls.isNotEmpty ? imageUrls.first : null;
    final radius = BorderRadius.circular(MallowTheme.radiusPrimary);

    if (url == null || url.isEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Container(
          width: 60,
          height: 60,
          color: context.mallowColors.divider,
        ),
      );
    }

    return MallowNetworkImage(
      imageUrl: url,
      logicalSize: 60,
      width: 60,
      height: 60,
      borderRadius: radius,
    );
  }

  Widget _buildSubtitle(BuildContext context) {
    switch (displayType) {
      case ArtGroupDisplayType.artist:
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
      case ArtGroupDisplayType.collection:
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
      case ArtGroupDisplayType.curation:
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
        vertical: MallowTheme.spacingXs,
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
