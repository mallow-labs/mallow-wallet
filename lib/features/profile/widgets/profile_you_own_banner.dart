import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';

/// Tappable "You own N artworks" row with a 2×2 thumbnail grid on the left.
class ProfileYouOwnBanner extends StatelessWidget {
  const ProfileYouOwnBanner({
    required this.count,
    this.thumbnailUrls = const [],
    this.onTap,
    super.key,
  });

  final int count;
  final List<String> thumbnailUrls;
  final VoidCallback? onTap;

  static const double _gridSize = 48;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              _ThumbnailGrid(urls: thumbnailUrls, size: _gridSize),
              const SizedBox(width: MallowTheme.spacingMd),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'You own',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    '$count artwork${count == 1 ? '' : 's'}',
                    style: MallowTheme.uiMeta.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2×2 grid of artwork thumbnails, clipped to [size]×[size].
class _ThumbnailGrid extends StatelessWidget {
  const _ThumbnailGrid({required this.urls, required this.size});

  final List<String> urls;
  final double size;

  @override
  Widget build(BuildContext context) {
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      child: SizedBox(
        width: size,
        height: size,
        child: Wrap(
          children: List.generate(4, (i) {
            final url = i < urls.length ? urls[i] : null;
            if (url == null) {
              return SizedBox(
                width: half,
                height: half,
                child: ColoredBox(color: context.mallowColors.divider),
              );
            }
            return MallowNetworkImage(
              imageUrl: url,
              logicalSize: half,
              width: half,
              height: half,
              placeholderBuilder: (ctx) =>
                  ColoredBox(color: ctx.mallowColors.divider),
              errorBuilder: (ctx) =>
                  ColoredBox(color: ctx.mallowColors.divider),
            );
          }),
        ),
      ),
    );
  }
}
