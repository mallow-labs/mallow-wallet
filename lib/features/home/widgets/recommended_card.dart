import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_thumbnail.dart';

/// Recommended-for-you card: 2x2 mosaic with category badge overlay.
class RecommendedCard extends StatelessWidget {
  const RecommendedCard({
    required this.label,
    required this.imageUrls,
    required this.artistUsernames,
    super.key,
    this.onTap,
  });

  final String label;
  final List<String> imageUrls;
  final List<String> artistUsernames;
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
            Stack(
              children: [
                ArtworkMosaic(
                  imageUrls: imageUrls,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                ),
                // Category label badge — bottom-left of mosaic.
                // Sits on top of artwork imagery, so black/white literals are
                // intentional for consistent contrast across photo backgrounds.
                Positioned(
                  left: 0,
                  bottom: 14,
                  child: Container(
                    color: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      label,
                      style: MallowTheme.editorialQuote.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              _formatArtistList(artistUsernames),
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  String _formatArtistList(List<String> names) {
    final usernames = names
        .where(
          (n) =>
              n.isNotEmpty &&
              !n.startsWith('0x') &&
              !n.startsWith('tz1') &&
              n.length < 44,
        )
        .toList();
    if (usernames.isEmpty) return '';
    return '${usernames.take(3).join(', ')} + more';
  }
}
