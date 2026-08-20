part of '../account_menu_drawer.dart';

/// Notification menu row with an unread-dot indicator overlay.
///
/// The dot tracks [NotificationsRepository.hasUnread] — the app's only unread
/// surface, refreshed whenever the drawer opens and cleared once the
/// notifications screen acknowledges the feed.
class _NotificationMenuRow extends StatelessWidget {
  const _NotificationMenuRow({required this.onTap, this.disabled = false});

  final VoidCallback onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: TapTargetExpander(
        child: GestureDetector(
          onTap: disabled ? null : onTap,
          behavior: HitTestBehavior.opaque,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Stack(
                    children: [
                      const Center(
                        child: MallowSvgIcon(
                          'assets/icons/bell.svg',
                          width: 16,
                          height: 16,
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable:
                            sl<NotificationsRepository>().hasUnread,
                        builder: (context, hasUnread, _) {
                          if (!hasUnread) return const SizedBox.shrink();
                          return Positioned(
                            left: 13.32,
                            top: 5.75,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: context.mallowColors.accent,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: context.mallowColors.bgPrimary,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Notifications',
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Social icon button: 26x26 container with SVG.
class _SocialIcon extends StatelessWidget {
  const _SocialIcon({
    required this.icon,
    required this.onTap,
    this.padding = 0,
  });

  final String icon;
  final VoidCallback onTap;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final iconSize = 26 - padding * 2;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 26,
          height: 26,
          child: Center(
            child: MallowSvgIcon(icon, width: iconSize, height: iconSize),
          ),
        ),
      ),
    );
  }
}
