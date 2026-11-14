import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/network/auth_service.dart';

/// Repository for fetching notifications and managing read state.
@lazySingleton
class NotificationsRepository {
  NotificationsRepository(this._api, this._auth)
    : _sessionAddress = _auth.currentAddress {
    _auth.addListener(_onSessionChanged);
    _auth.walletSigChanges.addListener(_onSessionChanged);
  }

  final api.MallowApiClient _api;
  final AuthService _auth;

  /// Set when [refreshUnreadCount] could not refresh (no proof yet, or the
  /// server refused the one sent), so the next session change tries again.
  bool _awaitingProof = false;

  /// The logged-in address [hasUnread] describes.
  String? _sessionAddress;

  /// Whether anything has asked for the badge yet. After a switch the badge
  /// is re-read for the new address only if it had been.
  bool _requested = false;

  /// The refresh in flight, shared by concurrent callers (a drawer open and a
  /// session change can land together).
  Future<void>? _refreshing;

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
  ///
  /// Sent with `requireProof=true` (the client's default), so a login without a valid `wallet-sig` is
  /// a 401 rather than a zero count. [background] marks a read the user did
  /// not ask for: its 401 fails instead of re-signing, which on a hardware
  /// wallet would open the verify sheet.
  Future<api.NotificationUnreadCount> getUnreadCount({
    bool background = false,
  }) async {
    final response = await _api.getNotificationUnreadCount(
      extras: background ? const {kSkipSignatureRetryExtra: true} : const {},
    );
    return response.result;
  }

  /// Refresh [hasUnread] from the server.
  ///
  /// Swallows failures: an unauthenticated or offline session must leave the
  /// badge as it was, never blow up the drawer that asked for it.
  ///
  /// 🛑 Never prompts: the drawer calls this when it opens. It fetches only
  /// when [AuthService.canSendBackgroundSignedRead] says the logged-in wallet
  /// already holds a valid `wallet-sig`, as a [background] read that opts out
  /// of the 401 re-sign. Without a proof, or on a refusal, the badge keeps its
  /// value and the refresh runs again when [AuthService.walletSigChanges] says
  /// a proof may have arrived — the same gate as the block list
  /// (`BlockStore.ensureLoaded`). A wallet switch or logout clears the badge:
  /// it described the previous address. A badge that had been asked for is
  /// then re-read for the new address once its proof allows.
  Future<void> refreshUnreadCount() {
    final pending = _refreshing;
    if (pending != null) return pending;
    late final Future<void> refresh;
    refresh = _refreshUnreadCount().whenComplete(() {
      if (identical(_refreshing, refresh)) _refreshing = null;
    });
    return _refreshing = refresh;
  }

  Future<void> _refreshUnreadCount() async {
    _requested = true;
    _awaitingProof = true;
    if (!await _auth.canSendBackgroundSignedRead()) return;
    final address = _sessionAddress;
    try {
      final unread = await getUnreadCount(background: true);
      // A switch while the read was out: the answer is the old wallet's.
      if (address != _sessionAddress) return;
      hasUnread.value = unread.hasUnreadMessages;
      _awaitingProof = false;
    } catch (e) {
      debugPrint('[NotificationsRepository] Unread count failed: $e');
    }
  }

  void _onSessionChanged() {
    final address = _auth.currentAddress;
    if (address != _sessionAddress) {
      _sessionAddress = address;
      // A refresh still out belongs to the previous address (its answer is
      // dropped); one for this address must not join it.
      _refreshing = null;
      hasUnread.value = false;
      _awaitingProof = _requested;
    }
    if (_awaitingProof) unawaited(refreshUnreadCount());
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
