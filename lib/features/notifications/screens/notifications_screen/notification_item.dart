part of '../notifications_screen.dart';

class _NotificationItem extends StatelessWidget {
  const _NotificationItem({required this.notification});

  final api.NotificationItem notification;

  bool get _isSeen => notification.acknowledgedAt != null;

  @override
  Widget build(BuildContext context) {
    final contents = NotificationContentHelper.getContents(
      notification.type,
      notification.data,
    );

    return TapTargetExpander(
      child: GestureDetector(
        onTap: () => _handleTap(context, contents),
        behavior: HitTestBehavior.opaque,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row: icon + title + timestamp
                  Row(
                    children: [
                      _NotificationIcon(type: notification.type, seen: _isSeen),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          contents.title,
                          style: MallowTheme.uiBody.copyWith(
                            color: _isSeen
                                ? context.mallowColors.textSecondary
                                : context.mallowColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatLastUpdated(notification.createdAt),
                        style: MallowTheme.uiCaption.copyWith(
                          color: context.mallowColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  if (contents.message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      contents.message!,
                      style: MallowTheme.uiCaption.copyWith(
                        color: context.mallowColors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (contents.linkLabel != null) ...[
                    const SizedBox(height: 8),
                    _buildLinkRow(context, contents),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkRow(BuildContext context, NotificationContents contents) {
    if (contents.extraLinkLabel != null) {
      return Row(
        children: [
          Text(
            contents.linkLabel!,
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.accent,
            ),
          ),
          Text(
            ' • ',
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
          Text(
            contents.extraLinkLabel!,
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.accent,
            ),
          ),
        ],
      );
    }
    return Text(
      contents.linkLabel!,
      style: MallowTheme.uiCaption.copyWith(color: context.mallowColors.accent),
    );
  }

  void _handleTap(BuildContext context, NotificationContents contents) {
    // The helper stores the link exactly as the backend/webapp builds it, so a
    // destination mobile has no screen for (Gumball, Jellybean, store, Talk
    // post, staking) resolves to a mallow.art URL instead of a route go_router
    // would fail to match.
    final link = resolveNotificationLink(contents.linkPath);
    if (link == null) return;
    if (isNotificationWebLink(link)) {
      openNotificationWebLink(link);
      return;
    }
    context.push(link);
  }
}

// =============================================================================
// Notification icon widget
// =============================================================================

class _NotificationIcon extends StatelessWidget {
  const _NotificationIcon({required this.type, this.seen = false});

  final api.NotificationType type;
  final bool seen;

  @override
  Widget build(BuildContext context) {
    return MallowSvgIcon(
      _iconFor(type),
      width: 20,
      height: 20,
      color: seen ? context.mallowColors.textSecondary : null,
    );
  }

  static const _icons = 'assets/icons';

  String _iconFor(api.NotificationType type) {
    switch (type) {
      case api.NotificationType.newFollower:
        return '$_icons/notif_user.svg';
      case api.NotificationType.newFollowers:
        return '$_icons/notif_users.svg';
      case api.NotificationType.newComment:
      case api.NotificationType.newComments:
        return '$_icons/notif_message.svg';
      case api.NotificationType.newLike:
      case api.NotificationType.newLikes:
        return '$_icons/notif_heart.svg';
      case api.NotificationType.tipReceived:
      case api.NotificationType.giftReceived:
        return '$_icons/notif_gift.svg';
      case api.NotificationType.newAirdrop:
      case api.NotificationType.airdropReceived:
      case api.NotificationType.airdropCompleted:
        return '$_icons/notif_parachute.svg';
      case api.NotificationType.artworkSold:
      case api.NotificationType.jellybeanPurchased:
      case api.NotificationType.gumballPurchased:
      case api.NotificationType.raffleTicketsSold:
      case api.NotificationType.storeProductSold:
      case api.NotificationType.newStakingRewards:
        return '$_icons/notif_coin.svg';
      case api.NotificationType.newBid:
      case api.NotificationType.auctionStarted:
      case api.NotificationType.outbid:
      case api.NotificationType.scheduledBidPlaced:
        return '$_icons/notif_gavel.svg';
      case api.NotificationType.scheduledBidReturned:
        return '$_icons/notif_arrow-back.svg';
      case api.NotificationType.auctionEndingSoon:
      case api.NotificationType.raffleEndingSoon:
        return '$_icons/notif_clock-hour-1.svg';
      case api.NotificationType.auctionCancelled:
      case api.NotificationType.raffleExpired:
      case api.NotificationType.offerExpired:
        return '$_icons/notif_circle-dashed-x.svg';
      case api.NotificationType.auctionWon:
      case api.NotificationType.raffleWon:
      case api.NotificationType.offerAccepted:
        return '$_icons/notif_confetti.svg';
      case api.NotificationType.gumballEnded:
      case api.NotificationType.newGumballInvite:
      case api.NotificationType.gumballInviteAccepted:
      case api.NotificationType.gumballInviteDeclined:
      case api.NotificationType.gumballInviteReminder:
      case api.NotificationType.artworkAddedToGumball:
      case api.NotificationType.artworkApprovedForGumball:
      case api.NotificationType.artworkRemovedFromGumball:
      case api.NotificationType.newRequestToJoinGumball:
      case api.NotificationType.gumballRequestRejected:
        return '$_icons/notif_crystal-ball.svg';
      case api.NotificationType.jellybeanEnded:
        return '$_icons/notif_jellybean.svg';
      case api.NotificationType.raffleEnded:
        return '$_icons/notif_ticket.svg';
      case api.NotificationType.newHighestOffer:
        return '$_icons/notif_hand-stop.svg';
      case api.NotificationType.auctionEnded:
        return '$_icons/notif_gavel.svg';
      case api.NotificationType.test:
      case api.NotificationType.unknown:
        return '$_icons/bell.svg';
    }
  }
}
