import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_thumbnail.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Curation card: 2x2 mosaic + name + owner username.
class CurationCard extends StatelessWidget {
  const CurationCard({
    required this.name,
    required this.curator,
    required this.curatorAddress,
    required this.imageUrls,
    super.key,
    this.onTap,
  });

  final String name;
  final String curator;
  final String curatorAddress;
  final List<String> imageUrls;
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
            ArtworkMosaic(
              imageUrls: imageUrls,
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
                onTap: curatorAddress.isNotEmpty
                    ? () => context.goToProfile(curatorAddress)
                    : null,
                child: Text(
                  curator,
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
