import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'artwork_sheet_image.dart';

/// Sheet header showing the artwork the action targets: the image centered
/// above a "Title / @artist" line. Used by
/// the make-offer sheet and the market pipeline sheet so the action keeps
/// its visual subject from input through signing → success.
class ArtworkSubjectHeader extends StatelessWidget {
  const ArtworkSubjectHeader({
    required this.title,
    super.key,
    this.imageUrl,
    this.username,
    this.nsfw = false,
  });

  final String title;
  final String? imageUrl;
  final String? username;

  /// Moderation flag: blurs the preview (with an eye-icon reveal) unless the
  /// viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final image = imageUrl;
    final artist = username;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (image != null && image.isNotEmpty) ...[
          ArtworkSheetImage(
            imageUrl: image,
            nsfw: nsfw,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
        ],
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: title,
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (artist != null && artist.isNotEmpty) ...[
                TextSpan(
                  text: ' / ',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
                TextSpan(
                  text: '@$artist',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
