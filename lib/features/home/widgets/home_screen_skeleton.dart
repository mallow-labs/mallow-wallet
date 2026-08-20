import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../cast/widgets/now_casting_bar.dart';

/// Skeleton placeholder for the home screen.
///
/// Renders the section titles + shimmer rows that the home screen shows
/// while [HomeBloc] is in its loading state. Also used during session
/// initialization so the user lands on a structured layout instead of
/// a centered spinner.
class HomeScreenSkeleton extends StatelessWidget {
  const HomeScreenSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _SpotlightSkeleton()),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Popular curations',
            child: _HorizontalRowSkeleton(
              rowHeight: 180,
              itemWidth: 139.6,
              imageHeight: 139.6,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Recommended for you',
            child: _HorizontalRowSkeleton(
              rowHeight: 180,
              itemWidth: 139.6,
              imageHeight: 139.6,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Discover',
            child: _HorizontalRowSkeleton(
              rowHeight: 122,
              itemWidth: 93.06,
              imageHeight: 93.06,
              isCircular: true,
              textLineCount: 1,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Featured listings',
            child: _HorizontalRowSkeleton(
              rowHeight: 210,
              itemWidth: 139.6,
              imageHeight: 139.6,
              textLineCount: 3,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Trending artists',
            child: _HorizontalRowSkeleton(
              rowHeight: 122,
              itemWidth: 93.06,
              imageHeight: 93.06,
              isCircular: true,
              textLineCount: 1,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SkeletonSection(
            title: 'Popular collections',
            child: _HorizontalRowSkeleton(
              rowHeight: 180,
              itemWidth: 139.6,
              imageHeight: 139.6,
            ),
          ),
        ),
        SliverToBoxAdapter(child: NavBarBottomReserve()),
      ],
    );
  }
}

/// Section title above a skeleton row. Mirrors the live home screen layout.
class _SkeletonSection extends StatelessWidget {
  const _SkeletonSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: MallowTheme.spacing26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Text(title, style: MallowTheme.editorialQuote),
          ),
          const SizedBox(height: MallowTheme.spacing12),
          child,
        ],
      ),
    );
  }
}

class _SpotlightSkeleton extends StatelessWidget {
  const _SpotlightSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: MallowTheme.spacing26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Text(
              'Your daily spotlight',
              style: MallowTheme.editorialQuote,
            ),
          ),
          const SizedBox(height: MallowTheme.spacing12),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: AspectRatio(
              aspectRatio: 357 / 171,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                child: const ImageShimmerGrid(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HorizontalRowSkeleton extends StatelessWidget {
  const _HorizontalRowSkeleton({
    required this.rowHeight,
    required this.itemWidth,
    required this.imageHeight,
    this.isCircular = false,
    this.textLineCount = 2,
  });

  final double rowHeight;
  final double itemWidth;
  final double imageHeight;
  final bool isCircular;
  final int textLineCount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: 3,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (_, _) => SizedBox(
          width: itemWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(
                  isCircular ? itemWidth / 2 : MallowTheme.radiusPrimary,
                ),
                child: ImageShimmerGrid(width: itemWidth, height: imageHeight),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              ShimmerBox(width: itemWidth * 0.7, height: 12),
              if (textLineCount >= 2) ...[
                const SizedBox(height: 4),
                ShimmerBox(width: itemWidth * 0.5, height: 12),
              ],
              if (textLineCount >= 3) ...[
                const SizedBox(height: 4),
                ShimmerBox(width: itemWidth * 0.4, height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
