part of '../notifications_screen.dart';

class _PushNotificationBanner extends StatelessWidget {
  const _PushNotificationBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  /// Ask for the OS permission (or explain how to restore it when the OS has
  /// already refused for good) instead of leaving dismiss as the only action.
  Future<void> _enable(BuildContext context) async {
    final outcome = await enablePushFromUserAction(context);
    if (outcome == PushEnableOutcome.granted) onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.mallowColors.bgTransparent,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _enable(context),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    const MallowSvgIcon(
                      'assets/icons/bell.svg',
                      width: 18,
                      height: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Turn on push notifications so you don't miss any updates!",
                        style: MallowTheme.uiCaption.copyWith(
                          color: context.mallowColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Turn on',
                      style: MallowTheme.uiCaption.copyWith(
                        color: context.mallowColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TapTargetExpander(
            child: GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: MallowSvgIcon(
                  'assets/icons/x.svg',
                  width: 12,
                  height: 12,
                  color: context.mallowColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
