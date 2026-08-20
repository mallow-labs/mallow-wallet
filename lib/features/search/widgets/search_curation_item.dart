import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../models/search_models.dart';

/// A single collection result row: 48px thumbnail + title + @curator.
class SearchCollectionItem extends StatelessWidget {
  const SearchCollectionItem({
    required this.collection,
    this.typeLabel,
    super.key,
  });

  final SearchCollectionResult collection;

  /// Optional content-type prefix for the subtitle (e.g. "Collection" renders
  /// "Collection • @curator"). Used by the "Recently viewed" rows, where mixed
  /// content types share one list without section headers.
  final String? typeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Row(
      children: [
        // Thumbnail
        SizedBox(
          width: 48,
          height: 48,
          child: collection.thumbnailUrl != null
              ? MallowNetworkImage(
                  imageUrl: collection.thumbnailUrl!,
                  logicalSize: 48,
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  errorBuilder: (_) => _placeholder(context),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: _placeholder(context),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                collection.name,
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (collection.curatorUsername != null ||
                  (collection.curatorAddress?.isNotEmpty ?? false))
                UserHandleText(
                  username: collection.curatorUsername,
                  address: collection.curatorAddress,
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

/// A single curation result row: 48px thumbnail + title + @owner + artwork count.
class SearchCurationItem extends StatelessWidget {
  const SearchCurationItem({required this.curation, this.typeLabel, super.key});

  final SearchCurationResult curation;

  /// Optional content-type prefix for the subtitle (e.g. "Curation" renders
  /// "Curation • @owner"). Used by the "Recently viewed" rows, where mixed
  /// content types share one list without section headers.
  final String? typeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final imageUrl = curation.thumbnailUrls.isNotEmpty
        ? curation.thumbnailUrls.first
        : null;

    return Row(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: imageUrl != null
              ? MallowNetworkImage(
                  imageUrl: imageUrl,
                  logicalSize: 48,
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  errorBuilder: (_) => _placeholder(context),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: _placeholder(context),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                curation.name,
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (curation.ownerUsername != null ||
                  (curation.ownerAddress?.isNotEmpty ?? false))
                UserHandleText(
                  username: curation.ownerUsername,
                  address: curation.ownerAddress,
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
