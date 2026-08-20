import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/nsfw_obscured.dart';

/// The per-artwork header on the Offers screen: a 52px
/// thumbnail + editorial title + creator username, with its offer/bid [rows]
/// underneath. Tapping the header opens the artwork detail screen.
class OffersArtworkGroup extends StatelessWidget {
  const OffersArtworkGroup({required this.item, required this.rows, super.key});

  /// Any item in the group — supplies the shared artwork (asset/title/creator)
  /// metadata for the header.
  final api.OffersInboxItem item;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final imageUrl = item.artworkImageUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push(AppRoutes.artworkDetailPath(item.asset)),
          child: Row(
            children: [
              _thumbnail(colors, imageUrl),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatArtworkName(
                        name: item.artworkTitle,
                        editionNumber: item.editionNumber,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.editorialQuote.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (item.creatorUsername != null &&
                        item.creatorUsername!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.creatorUsername!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        ...rows,
      ],
    );
  }

  /// Artwork thumb, blurred behind the viewer's show-NSFW setting when the
  /// piece is flagged — the same treatment the artwork grids give their tiles.
  Widget _thumbnail(MallowColors colors, String? imageUrl) {
    return NsfwObscured(
      nsfw: item.nsfw,
      contentId: item.asset,
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        child: imageUrl != null && imageUrl.isNotEmpty
            ? MallowNetworkImage(
                imageUrl: imageUrl,
                logicalSize: 52,
                width: 52,
                height: 52,
                errorBuilder: (_) => _placeholder(colors),
              )
            : _placeholder(colors),
      ),
    );
  }

  Widget _placeholder(MallowColors colors) =>
      Container(width: 52, height: 52, color: colors.surfaceMuted);
}
