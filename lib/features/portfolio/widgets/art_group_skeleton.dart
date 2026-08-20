import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// Skeleton placeholder for list view art group tiles.
class ArtGroupTileSkeleton extends StatelessWidget {
  const ArtGroupTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Row(
        children: [
          // Mosaic thumbnail skeleton
          ShimmerBox(
            width: 60,
            height: 60,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          // Text content skeleton
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name placeholder
                ShimmerBox(
                  width: 120,
                  height: 18,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                // Subtitle placeholder
                ShimmerBox(
                  width: 80,
                  height: 14,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
          ),
          // Count badge skeleton
          ShimmerBox(
            width: 32,
            height: 24,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
        ],
      ),
    );
  }
}

/// Skeleton placeholder for grid view art group tiles.
class ArtGroupGridTileSkeleton extends StatelessWidget {
  const ArtGroupGridTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Square thumbnail skeleton
        AspectRatio(
          aspectRatio: 1,
          child: ShimmerBox(
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        // Name placeholder
        ShimmerBox(
          width: 100,
          height: 18,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        // Subtitle placeholder
        ShimmerBox(
          width: 60,
          height: 14,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    );
  }
}

/// A sliver that shows skeleton loading placeholders for the portfolio.
class PortfolioSkeletonList extends StatelessWidget {
  const PortfolioSkeletonList({super.key, this.itemCount = 6});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        // Alternating items and dividers
        final itemIndex = index ~/ 2;
        final isDivider = index.isOdd;

        if (isDivider) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
              vertical: MallowTheme.spacingMd,
            ),
            child: Divider(height: 1, color: context.mallowColors.dividerLight),
          );
        }

        if (itemIndex >= itemCount) return null;
        return const ArtGroupTileSkeleton();
      }, childCount: itemCount * 2 - 1),
    );
  }
}

/// A sliver grid that shows skeleton loading placeholders for the portfolio.
class PortfolioSkeletonGrid extends StatelessWidget {
  const PortfolioSkeletonGrid({super.key, this.itemCount = 6});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 40,
          crossAxisSpacing: 12,
          childAspectRatio: 170.5 / 223.5,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => const ArtGroupGridTileSkeleton(),
          childCount: itemCount,
        ),
      ),
    );
  }
}
