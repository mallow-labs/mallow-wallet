part of '../user_profile_screen.dart';

/// Shimmer skeleton shown while the profile data is loading.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // Banner skeleton
        SliverToBoxAdapter(
          child: ShimmerBox(
            width: double.infinity,
            height: 200,
            borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
          ),
        ),
        // Avatar + name row skeleton
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
              MallowTheme.spacing20,
              0,
            ),
            child: Row(
              children: [
                ShimmerBox(
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                ),
                const SizedBox(width: MallowTheme.spacing12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShimmerBox(
                        width: 140,
                        height: 18,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 6),
                      ShimmerBox(
                        width: 100,
                        height: 13,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                ),
                ShimmerBox(
                  width: 70,
                  height: 28,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Tab bar skeleton
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
              MallowTheme.spacing20,
              MallowTheme.spacingMd,
            ),
            child: Row(
              children: [
                ShimmerBox(
                  width: 60,
                  height: 28,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
                const SizedBox(width: 8),
                ShimmerBox(
                  width: 60,
                  height: 28,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
                const SizedBox(width: 8),
                ShimmerBox(
                  width: 60,
                  height: 28,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Content skeleton rows
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
                vertical: MallowTheme.spacingMd,
              ),
              child: Row(
                children: [
                  ShimmerBox(
                    width: 60,
                    height: 60,
                    borderRadius: BorderRadius.circular(
                      MallowTheme.radiusPrimary,
                    ),
                  ),
                  const SizedBox(width: MallowTheme.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ShimmerBox(
                          width: 160,
                          height: 15,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(height: 6),
                        ShimmerBox(
                          width: 100,
                          height: 13,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            childCount: 5,
          ),
        ),
      ],
    );
  }
}

/// Shimmer skeleton for content area while artworks/groups are loading.
class _ContentSkeleton extends StatelessWidget {
  const _ContentSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate(
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          (context, index) => ShimmerBox(
            width: double.infinity,
            height: double.infinity,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          childCount: 6,
        ),
      ),
    );
  }
}

/// Centered empty state widget with icon, title, and subtitle.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.iconAsset,
    required this.title,
    this.subtitle,
  });

  final String iconAsset;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacingXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowSvgIcon(
              iconAsset,
              width: 48,
              height: 48,
              color: context.mallowColors.textTertiary,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              title,
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                subtitle!,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
