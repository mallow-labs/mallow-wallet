part of '../collection_screen.dart';

/// Avatar / collection name / verified badge / subtitle / 3-dot menu —
/// the collection-screen analog of [ProfileHeader] but locked to
/// "Collection • creator" subtitle and without a follow button.
class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({
    required this.title,
    required this.subtitle,
    required this.avatarUrl,
    required this.isVerified,
    required this.onMenuTap,
    this.isAdmin = false,
  });

  final String title;
  final Widget subtitle;
  final String? avatarUrl;
  final bool isVerified;
  final bool isAdmin;
  final VoidCallback onMenuTap;

  static const double _avatarSize = 48;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MallowTheme.spacing20,
          MallowTheme.spacing20,
          MallowTheme.spacing20,
          0,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (avatarUrl != null && avatarUrl!.isNotEmpty)
              MallowNetworkImage(
                imageUrl: avatarUrl!,
                logicalSize: _avatarSize,
                width: _avatarSize,
                height: _avatarSize,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                errorBuilder: (ctx) => Container(
                  width: _avatarSize,
                  height: _avatarSize,
                  color: ctx.mallowColors.divider,
                ),
              )
            else
              Container(
                width: _avatarSize,
                height: _avatarSize,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                ),
              ),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: MallowTheme.editorialSection.copyWith(
                            color: colors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isVerified || isAdmin) ...[
                        const SizedBox(width: MallowTheme.spacingXs),
                        VerifiedBadge(isAdmin: isAdmin),
                      ],
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacingXs),
                  subtitle,
                ],
              ),
            ),
            const SizedBox(width: MallowTheme.spacingXs),
            TapTargetExpander(
              child: GestureDetector(
                onTap: onMenuTap,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 24,
                  height: 26,
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/icons/dots_vertical.svg',
                      width: 16,
                      height: 16,
                      colorFilter: ColorFilter.mode(
                        colors.textPrimary,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
