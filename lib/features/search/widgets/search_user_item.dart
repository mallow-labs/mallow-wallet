import 'package:flutter/material.dart';

import '../../../core/services/avatar_service.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../models/search_models.dart';

/// A single user result row: 32px avatar + label + optional verified badge.
///
/// Anonymous users (no mallow profile) have no username, so the label falls
/// back to their truncated address and the avatar to the generated identicon
/// seeded by that address.
class SearchUserItem extends StatelessWidget {
  const SearchUserItem({
    required this.user,
    this.typeLabel,
    this.thumbnailStyle = false,
    super.key,
  });

  final SearchUserResult user;

  /// Optional content-type subtitle (e.g. "User") rendered under the label.
  /// Used by the "Recently viewed" rows, where mixed content types share one
  /// list without section headers.
  final String? typeLabel;

  /// When true, the avatar renders as a 48px rounded-square to match the
  /// artwork/collection/token thumbnails. Used by the "Recently viewed" rows so
  /// every row shares one avatar footprint; the dedicated "Users" search section
  /// keeps the default 32px circle.
  final bool thumbnailStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final label = formatUsernameOrAddress(
      username: user.username,
      address: user.address,
    );
    final avatarSize = thumbnailStyle ? 48.0 : 32.0;
    final avatarRadius = thumbnailStyle
        ? BorderRadius.circular(MallowTheme.radiusPrimary)
        : BorderRadius.circular(avatarSize / 2);

    final labelRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Label (username, or truncated address for anonymous users)
        Flexible(
          child: Text(
            label,
            style: TextStyle(fontSize: 15, color: colors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Verified badge
        if (user.isVerified || user.isAdmin)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: VerifiedBadge(isAdmin: user.isAdmin),
          ),
      ],
    );

    return Row(
      children: [
        // Avatar
        SizedBox(
          width: avatarSize,
          height: avatarSize,
          child: user.avatarUrl != null
              ? MallowNetworkImage(
                  imageUrl: user.avatarUrl!,
                  logicalSize: avatarSize,
                  width: avatarSize,
                  height: avatarSize,
                  borderRadius: avatarRadius,
                  errorBuilder: (_) =>
                      _generatedAvatar(avatarSize, avatarRadius),
                )
              : _generatedAvatar(avatarSize, avatarRadius),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: typeLabel == null
              ? labelRow
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    labelRow,
                    Text(
                      typeLabel!,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _generatedAvatar(double size, BorderRadius radius) => AccountAvatar(
    seed: avatarSeedOf(address: user.address, username: user.username),
    size: size,
    // A circle is AccountAvatar's default (null radius); only the rounded-square
    // thumbnail style needs an explicit radius.
    borderRadius: thumbnailStyle ? radius : null,
  );
}
