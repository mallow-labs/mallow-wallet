import 'package:freezed_annotation/freezed_annotation.dart';

part 'notification.freezed.dart';
part 'notification.g.dart';

/// Notification type values — mirrors the TypeScript NotificationType enum
/// (integer-based, 0-indexed).
enum NotificationType {
  @JsonValue(0)
  test,
  @JsonValue(1)
  auctionStarted,
  @JsonValue(2)
  auctionCancelled,
  @JsonValue(3)
  newBid,
  @JsonValue(4)
  outbid,
  @JsonValue(5)
  auctionWon,
  @JsonValue(6)
  auctionEnded,
  @JsonValue(7)
  auctionEndingSoon,
  @JsonValue(8)
  scheduledBidPlaced,
  @JsonValue(9)
  scheduledBidReturned,
  @JsonValue(10)
  gumballPurchased,
  @JsonValue(11)
  gumballEnded,
  @JsonValue(12)
  newGumballInvite,
  @JsonValue(13)
  gumballInviteAccepted,
  @JsonValue(14)
  gumballInviteDeclined,
  @JsonValue(15)
  gumballInviteReminder,
  @JsonValue(16)
  artworkAddedToGumball,
  @JsonValue(17)
  artworkApprovedForGumball,
  @JsonValue(18)
  artworkRemovedFromGumball,
  @JsonValue(19)
  newRequestToJoinGumball,
  @JsonValue(20)
  gumballRequestRejected,
  @JsonValue(21)
  newAirdrop,
  @JsonValue(22)
  airdropReceived,
  @JsonValue(23)
  airdropCompleted,
  @JsonValue(24)
  jellybeanPurchased,
  @JsonValue(25)
  jellybeanEnded,
  @JsonValue(26)
  artworkSold,
  @JsonValue(27)
  newHighestOffer,
  @JsonValue(28)
  offerAccepted,
  @JsonValue(29)
  offerExpired,
  @JsonValue(30)
  raffleEndingSoon,
  @JsonValue(31)
  raffleExpired,
  @JsonValue(32)
  raffleEnded,
  @JsonValue(33)
  raffleWon,
  @JsonValue(34)
  raffleTicketsSold,
  @JsonValue(35)
  storeProductSold,
  @JsonValue(36)
  tipReceived,
  @JsonValue(37)
  giftReceived,
  @JsonValue(38)
  newFollowers,
  @JsonValue(39)
  newFollower,
  @JsonValue(40)
  newComments,
  @JsonValue(41)
  newComment,
  @JsonValue(42)
  newLikes,
  @JsonValue(43)
  newLike,
  @JsonValue(44)
  newStakingRewards,

  /// Any type the backend ships that this client doesn't know yet.
  ///
  /// Deliberately has no `@JsonValue`: it is only ever produced by
  /// [NotificationItem]'s `unknownEnumValue` fallback. Without it a single new
  /// server-side enum makes the whole `/v1/notifications` decode throw and the
  /// list renders empty — the webapp degrades one cell instead (its handler
  /// lookup misses and `NotificationCell`'s try/catch shows a placeholder).
  unknown,
}

/// A single notification returned by GET /v1/notifications.
@freezed
sealed class NotificationItem with _$NotificationItem {
  const factory NotificationItem({
    required int id,
    @JsonKey(unknownEnumValue: NotificationType.unknown) required NotificationType type,
    required Map<String, dynamic> data,
    required DateTime createdAt,
    DateTime? acknowledgedAt,
  }) = _NotificationItem;

  factory NotificationItem.fromJson(Map<String, dynamic> json) => _$NotificationItemFromJson(json);
}

/// Response wrapper for GET /v1/notifications.
@freezed
sealed class NotificationsListResponse with _$NotificationsListResponse {
  const factory NotificationsListResponse({required List<NotificationItem> result}) =
      _NotificationsListResponse;

  factory NotificationsListResponse.fromJson(Map<String, dynamic> json) =>
      _$NotificationsListResponseFromJson(json);
}

/// Unread count data returned by GET /v1/notifications/unread-count.
@freezed
sealed class NotificationUnreadCount with _$NotificationUnreadCount {
  const factory NotificationUnreadCount({
    required int unreadCount,
    required bool hasUnreadMessages,
  }) = _NotificationUnreadCount;

  factory NotificationUnreadCount.fromJson(Map<String, dynamic> json) =>
      _$NotificationUnreadCountFromJson(json);
}

/// Response wrapper for GET /v1/notifications/unread-count.
@freezed
sealed class NotificationUnreadCountResponse with _$NotificationUnreadCountResponse {
  const factory NotificationUnreadCountResponse({required NotificationUnreadCount result}) =
      _NotificationUnreadCountResponse;

  factory NotificationUnreadCountResponse.fromJson(Map<String, dynamic> json) =>
      _$NotificationUnreadCountResponseFromJson(json);
}
