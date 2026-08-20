import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../models/search_models.dart';

/// A single artwork result row: 48px thumbnail + title (italic) + @artist.
class SearchArtworkItem extends StatelessWidget {
  const SearchArtworkItem({required this.artwork, this.typeLabel, super.key});

  final SearchArtworkResult artwork;

  /// Optional content-type prefix for the subtitle (e.g. "Artwork" renders
  /// "Artwork • @artist"). Used by the "Recently viewed" rows, where mixed
  /// content types share one list without section headers.
  final String? typeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Row(
      children: [
        // Thumbnail
        artwork.thumbnailUrl != null
            ? MallowArtworkMedia(
                imageUrl: artwork.thumbnailUrl!,
                playbackId: artwork.playbackId,
                clipPlaybackId: artwork.clipPlaybackId,
                nsfw: artwork.nsfw,
                logicalSize: 48,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                errorBuilder: (_) => ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: _placeholder(context),
                ),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                child: _placeholder(context),
              ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatArtworkName(
                  name: artwork.title,
                  editionNumber: artwork.editionNumber,
                ),
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (artwork.artistUsername != null)
                UserHandleText(
                  username: artwork.artistUsername,
                  address: null,
                  prefix: typeLabel != null ? '$typeLabel • ' : null,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                )
              else if (typeLabel != null)
                Text(
                  typeLabel!,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: context.mallowColors.surfaceMuted,
    );
  }
}
