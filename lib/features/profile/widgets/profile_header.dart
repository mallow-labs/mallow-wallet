import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/verified_badge.dart';

/// Profile info row: avatar, name + verified badge, handle + role, follow
/// button, and 3-dot menu. Matches the Figma layout.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    required this.avatarUrl,
    required this.username,
    required this.role,
    required this.isVerified,
    required this.isFollowing,
    required this.onFollowTap,
    this.avatarSeed = '',
    this.handle,
    this.roles = const [],
    this.onMenuTap,
    this.showFollowButton = true,
    super.key,
  });

  final String avatarUrl;

  /// Generated-identicon seed (see `avatarSeedOf`) rendered when [avatarUrl]
  /// is empty or fails to load.
  final String avatarSeed;
  final String username;
  final String? handle;
  final String role;
  final List<String> roles;
  final bool isVerified;
  final bool isFollowing;
  final VoidCallback onFollowTap;
  final VoidCallback? onMenuTap;

  /// Hidden when the session user is viewing their own profile — you can't
  /// follow yourself.
  final bool showFollowButton;

  static const double _avatarSize = 48;

  Widget _generatedAvatar() => AccountAvatar(
    seed: avatarSeed,
    size: _avatarSize,
    borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
  );

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MallowTheme.spacing20,
          MallowTheme.spacing20,
          MallowTheme.spacing20,
          16,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar — 48×48 rounded rect (primary_radius = 4px)
            if (avatarUrl.isEmpty)
              _generatedAvatar()
            else
              MallowNetworkImage(
                imageUrl: avatarUrl,
                logicalSize: _avatarSize,
                width: _avatarSize,
                height: _avatarSize,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                errorBuilder: (_) => _generatedAvatar(),
              ),
            const SizedBox(width: MallowTheme.spacing12),
            // Name + handle column
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + verified badge
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          username,
                          style: MallowTheme.editorialSection.copyWith(
                            color: context.mallowColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isVerified || roles.contains('admin')) ...[
                        const SizedBox(width: MallowTheme.spacingXs),
                        VerifiedBadge(isAdmin: roles.contains('admin')),
                      ],
                    ],
                  ),
                  if (handle != null && handle!.isNotEmpty) ...[
                    const SizedBox(height: MallowTheme.spacingXs),
                    // @handle + role
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '@$handle'),
                          if (role.isNotEmpty) TextSpan(text: ' \u2022 $role'),
                        ],
                      ),
                      style: MallowTheme.uiCaption.copyWith(
                        color: context.mallowColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MallowTheme.spacingXs),
            // Follow button + 3-dot menu
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showFollowButton) ...[
                  _FollowButton(isFollowing: isFollowing, onTap: onFollowTap),
                  const SizedBox(width: MallowTheme.spacingXs),
                ],
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
                            context.mallowColors.textPrimary,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill-shaped Follow / Following button matching the Figma design token.
class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.isFollowing, required this.onTap});

  final bool isFollowing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: context.mallowColors.bgPrimary,
            border: Border.all(color: context.mallowColors.dividerLight),
            borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          ),
          child: Text(
            isFollowing ? 'Following' : 'Follow',
            style: MallowTheme.uiCaption.copyWith(
              color: isFollowing
                  ? context.mallowColors.textSecondary
                  : context.mallowColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
