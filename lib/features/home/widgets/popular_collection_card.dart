import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_thumbnail.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Popular collection card: cover image + name + artist.
class PopularCollectionCard extends StatelessWidget {
  const PopularCollectionCard({
    required this.name,
    required this.artistName,
    required this.artistAddress,
    required this.imageUrl,
    super.key,
    this.onTap,
  });

  final String name;
  final String artistName;
  final String artistAddress;
  final String imageUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 139.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArtworkThumbnail(
              imageUrl: imageUrl,
              size: 139.6,
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              name,
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            TapTargetExpander(
              child: GestureDetector(
                onTap: artistAddress.isNotEmpty
                    ? () => context.goToProfile(artistAddress)
                    : null,
                child: Text(
                  artistName,
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
