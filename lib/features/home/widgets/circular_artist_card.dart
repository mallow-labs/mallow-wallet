import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';

/// Circular artist avatar card (used for Discover + Trending artists).
class CircularArtistCard extends StatelessWidget {
  const CircularArtistCard({
    required this.label,
    required this.avatarUrl,
    super.key,
    this.avatarSeed = '',
    this.onTap,
  });

  final String label;
  final String avatarUrl;

  /// Generated-identicon seed (see `avatarSeedOf`) rendered when [avatarUrl]
  /// is empty or fails to load.
  final String avatarSeed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const diameter = 93.06;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: diameter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            avatarUrl.isNotEmpty
                ? MallowNetworkImage(
                    imageUrl: avatarUrl,
                    logicalSize: diameter,
                    width: diameter,
                    height: diameter,
                    borderRadius: BorderRadius.circular(diameter / 2),
                    errorBuilder: (context) =>
                        AccountAvatar(seed: avatarSeed, size: diameter),
                  )
                : AccountAvatar(seed: avatarSeed, size: diameter),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              label,
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
            ),
          ],
        ),
      ),
    );
  }
}
