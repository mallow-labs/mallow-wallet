import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/preferences_service.dart';
import '../../../core/services/push_notification_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/notification_link.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/state_viewer.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/notifications_bloc.dart';

part 'notifications_screen/push_notification_banner.dart';
part 'notifications_screen/notification_item.dart';
part 'notifications_screen/notification_content_helper.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          sl<NotificationsBloc>()..add(const NotificationsEvent.load()),
      child: const _NotificationsView(),
    );
  }
}

class _NotificationsView extends StatefulWidget {
  const _NotificationsView();

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView> {
  bool _checkInProgress = false;

  @override
  void initState() {
    super.initState();
    _checkPushPermission();
  }

  Future<void> _checkPushPermission() async {
    if (_checkInProgress) return;
    _checkInProgress = true;
    try {
      final prefs = sl<PreferencesService>();
      final pushService = sl<PushNotificationService>();

      AuthorizationStatus status;
      if (!prefs.hasPromptedForPushPermission) {
        // First visit: trigger the OS permission dialog.
        status = await pushService.requestPermission();
        await prefs.setHasPromptedForPushPermission(true);
      } else {
        final settings = await FirebaseMessaging.instance
            .getNotificationSettings();
        status = settings.authorizationStatus;
      }

      if (!mounted) return;
      final isAuthorized =
          status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
      if (!isAuthorized) {
        context.read<NotificationsBloc>().add(
          const NotificationsEvent.showPushBanner(),
        );
      }
    } finally {
      _checkInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: BlocBuilder<NotificationsBloc, NotificationsState>(
          builder: (context, state) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, state),
                Expanded(child: _buildBody(context, state)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, NotificationsState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          TapTargetExpander(
            child: GestureDetector(
              onTap: () => context.pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 24,
                height: 40,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MallowSvgIcon(
                    'assets/icons/arrow_left.svg',
                    width: 16,
                    height: 16,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Notifications',
              style: MallowTheme.editorialSection.copyWith(
                color: context.mallowColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, NotificationsState state) {
    final isLoading =
        state is NotificationsInitial || state is NotificationsLoading;
    final error = state is NotificationsError ? state.message : null;
    final loaded = state is NotificationsLoaded ? state : null;
    final notifications = loaded?.notifications ?? const [];
    final showPushBanner = loaded?.showPushBanner ?? false;

    return StateViewer(
      isLoading: isLoading,
      error: error,
      onRetry: () => context.read<NotificationsBloc>().add(
        const NotificationsEvent.load(),
      ),
      child: MallowRefreshIndicator(
        onRefresh: () async {
          context.read<NotificationsBloc>().add(
            const NotificationsEvent.refresh(),
          );
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showPushBanner) ...[
                      _PushNotificationBanner(
                        onDismiss: () => context.read<NotificationsBloc>().add(
                          const NotificationsEvent.dismissPushBanner(),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    if (notifications.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: TapTargetExpander(
                          child: GestureDetector(
                            onTap: () => context.read<NotificationsBloc>().add(
                              const NotificationsEvent.markAllRead(),
                            ),
                            child: Text(
                              'Mark all as read',
                              style: MallowTheme.uiCaption.copyWith(
                                color: context.mallowColors.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
            if (notifications.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Text(
                    'No notifications yet',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.separated(
                  itemCount: notifications.length,
                  separatorBuilder: (context, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Divider(
                      height: 1,
                      thickness: 1,
                      color: context.mallowColors.dividerLight,
                    ),
                  ),
                  itemBuilder: (context, index) {
                    return _NotificationItem(
                      notification: notifications[index],
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}
