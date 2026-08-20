import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Repository for fetching notifications and managing read state.
@lazySingleton
class NotificationsRepository {
  NotificationsRepository(this._api);

  final api.MallowApiClient _api;

  /// Whether the signed-in profile has unacknowledged notifications — the
  /// account-drawer badge reads this.
  ///
  /// Lives on the repository (rather than a bloc) because read state is
  /// server-owned and all-or-nothing: the drawer, the notifications screen and
  /// a push arrival all mutate the same single flag, and the drawer outlives
  /// any notifications bloc.
  final ValueNotifier<bool> hasUnread = ValueNotifier(false);

  /// Fetch all notifications for the current user.
  Future<List<api.NotificationItem>> getNotifications() async {
    final response = await _api.getNotifications();
    return response.result;
  }

  /// Get the unread notification count.
  Future<api.NotificationUnreadCount> getUnreadCount() async {
    final response = await _api.getNotificationUnreadCount();
    return response.result;
  }

  /// Refresh [hasUnread] from the server.
  ///
  /// Swallows failures: an unauthenticated or offline session must leave the
  /// badge as it was, never blow up the drawer that asked for it.
  Future<void> refreshUnreadCount() async {
    try {
      hasUnread.value = (await getUnreadCount()).hasUnreadMessages;
    } catch (e) {
      debugPrint('[NotificationsRepository] Unread count failed: $e');
    }
  }

  /// Mark all notifications as read.
  ///
  /// Clears [hasUnread] on success — the server expires its unread-count cache
  /// in the same request, so no refetch is needed to drop the badge.
  Future<void> acknowledgeAll() async {
    await _api.acknowledgeNotifications();
    hasUnread.value = false;
  }
}
