import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// Skeleton placeholders for the "All art" tab, mirroring [AllArtGrid],
/// [AllArtDetail] and [AllArtMasonry] so a filter refetch shows shimmer tiles
/// in the artwork layout (not the group-tile layout of
/// [PortfolioSkeletonGrid]).

/// 2-column grid skeleton — square thumbnail + title + artist, matching
/// [AllArtGrid].
class AllArtSkeletonGrid extends StatelessWidget {
  const AllArtSkeletonGrid({super.key, this.itemCount = 6});

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
          childAspectRatio: 170.5 / 224,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => const _AllArtGridTileSkeleton(),
          childCount: itemCount,
        ),
      ),
    );
  }
}

class _AllArtGridTileSkeleton extends StatelessWidget {
  const _AllArtGridTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ShimmerBox(
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        ShimmerBox(
          width: 120,
          height: 18,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        ShimmerBox(
          width: 80,
          height: 14,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    );
  }
}

/// Detail skeleton — square card + edition, title, creator and price bars,
/// matching [AllArtDetail]. Only two cards fit a phone screen, so the default
/// count is lower than the grid's.
class AllArtSkeletonDetail extends StatelessWidget {
  const AllArtSkeletonDetail({super.key, this.itemCount = 3});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverList.separated(
        itemCount: itemCount,
        separatorBuilder: (_, _) =>
            const SizedBox(height: MallowTheme.spacingLg),
        itemBuilder: (context, index) => const _AllArtDetailCardSkeleton(),
      ),
    );
  }
}

class _AllArtDetailCardSkeleton extends StatelessWidget {
  const _AllArtDetailCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ShimmerBox(
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        // Edition / listing status line
        ShimmerBox(
          width: 100,
          height: 14,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 6),
        // Title
        ShimmerBox(
          width: 180,
          height: 20,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 6),
        // Creator
        ShimmerBox(
          width: 110,
          height: 14,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        // Price
        ShimmerBox(
          width: 70,
          height: 16,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    );
  }
}

/// 3-column masonry skeleton with varied tile heights, matching
/// [AllArtMasonry].
class AllArtSkeletonMasonry extends StatelessWidget {
  const AllArtSkeletonMasonry({super.key, this.itemCount = 9});

  final int itemCount;

  /// Cycled aspect ratios so the masonry columns stagger like real artwork.
  static const _aspectRatios = [1.0, 0.75, 1.3, 0.9, 1.15, 0.8];

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverMasonryGrid(
        gridDelegate: const SliverSimpleGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
        ),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        delegate: SliverChildBuilderDelegate(
          (context, index) => AspectRatio(
            aspectRatio: _aspectRatios[index % _aspectRatios.length],
            child: ShimmerBox(
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
            ),
          ),
          childCount: itemCount,
        ),
      ),
    );
  }
}
