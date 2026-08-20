part of '../notifications_screen.dart';

class NotificationContents {
  const NotificationContents({
    required this.title,
    this.message,
    this.linkPath,
    this.linkLabel,
    this.extraLinkLabel,
    this.extraLinkPath,
  });

  final String title;
  final String? message;
  final String? linkPath;
  final String? linkLabel;
  final String? extraLinkLabel;
  final String? extraLinkPath;
}

class NotificationContentHelper {
  static NotificationContents getContents(
    api.NotificationType type,
    Map<String, dynamic> data,
  ) {
    try {
      return _build(type, data);
    } catch (_) {
      return NotificationContents(title: _fallbackTitle(type));
    }
  }

  static NotificationContents _build(
    api.NotificationType type,
    Map<String, dynamic> data,
  ) {
    switch (type) {
      // ---- Auction ----
      case api.NotificationType.auctionStarted:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Auction started!',
          message: nft != null
              ? 'Auction for "${_nftName(nft)}" started with a reserve price '
                    'of ${_price(data, 'reservePrice')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.auctionCancelled:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Auction cancelled',
          message: nft != null
              ? 'Auction for "${_nftName(nft)}" has been cancelled'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.newBid:
        final nft = data['nft'] as Map<String, dynamic>?;
        final bidder = _actor(
          data['bidderUser'] as Map<String, dynamic>?,
          data['bidder'] as String?,
        );
        return NotificationContents(
          title: 'New bid',
          message: nft != null
              ? '"${_nftName(nft)}" received a bid for '
                    '${_price(data, 'bidAmount')} from $bidder'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.outbid:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'You were outbid!',
          message: nft != null
              ? 'You were outbid on "${_nftName(nft)}" for '
                    '${_price(data, 'newBidAmount')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.auctionWon:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Auction won!',
          message: nft != null
              ? 'You won the auction for "${_nftName(nft)}" for '
                    '${_price(data, 'winningBid')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.auctionEnded:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Auction ended',
          message: nft != null
              ? 'Auction for "${_nftName(nft)}" has ended'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.auctionEndingSoon:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Auction ending soon!',
          message: nft != null
              ? 'Auction for "${_nftName(nft)}" is ending soon'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.scheduledBidPlaced:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Scheduled bid placed!',
          message: nft != null
              ? 'Your scheduled bid on "${_nftName(nft)}" for '
                    '${_price(data, 'bidAmount')} was successfully placed!'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.scheduledBidReturned:
        final nft = data['nft'] as Map<String, dynamic>?;
        final reason = data['reason'] as String?;
        return NotificationContents(
          title: 'Scheduled bid returned',
          message: nft != null
              ? 'Your scheduled bid on "${_nftName(nft)}" for '
                    '${_price(data, 'bidAmount')} was returned.'
                    '${reason != null ? '\n\nReason: $reason' : ''}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );

      // ---- Market ----
      case api.NotificationType.artworkSold:
        final nft = data['nft'] as Map<String, dynamic>?;
        final buyer = _actor(
          data['buyerUser'] as Map<String, dynamic>?,
          data['buyer'] as String?,
        );
        return NotificationContents(
          title: 'Artwork sold!',
          message: nft != null
              ? '$buyer purchased "${_nftName(nft)}" for '
                    '${_price(data, 'price')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.newHighestOffer:
        final nft = data['nft'] as Map<String, dynamic>?;
        final offerer = _actor(
          data['offererUser'] as Map<String, dynamic>?,
          data['offerer'] as String?,
        );
        return NotificationContents(
          title: 'New highest offer!',
          message: nft != null
              ? '$offerer offered ${_price(data, 'offerAmount')} on '
                    '"${_nftName(nft)}"'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.offerAccepted:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Offer accepted!',
          message: nft != null
              ? 'Your offer on "${_nftName(nft)}" was accepted for '
                    '${_price(data, 'price')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.offerExpired:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Offer expired',
          message: nft != null
              ? 'Your offer on "${_nftName(nft)}" has expired'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );

      // ---- Raffle ----
      case api.NotificationType.raffleEndingSoon:
        final nft = data['nft'] as Map<String, dynamic>?;
        final supply = (data['supply'] as num?)?.toInt();
        final sold = (data['sold'] as num?)?.toInt();
        final remaining = supply != null && sold != null
            ? ' ${supply - sold}/$supply tickets remaining.'
            : '';
        return NotificationContents(
          title: 'Raffle ending soon!',
          message: nft != null
              ? 'Less than 1 hour remaining on raffle for '
                    '"${_nftName(nft)}".$remaining'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.raffleExpired:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Raffle expired',
          message: nft != null
              ? 'Raffle ended for "${_nftName(nft)}" with no ticket sales.'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.raffleEnded:
        final nft = data['nft'] as Map<String, dynamic>?;
        final sold = (data['sold'] as num?)?.toInt() ?? 0;
        return NotificationContents(
          title: 'Raffle ended',
          message: nft != null
              ? 'Raffle completed for "${_nftName(nft)}" with $sold '
                    'ticket${sold > 1 ? 's' : ''} sold for a total of '
                    '${_price(data, 'proceeds')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.raffleWon:
        final nft = data['nft'] as Map<String, dynamic>?;
        final tickets = (data['winnerTicketCount'] as num?)?.toInt() ?? 0;
        return NotificationContents(
          title: 'Raffle won!',
          message: nft != null
              ? 'You won "${_nftName(nft)}" with $tickets '
                    'ticket${tickets > 1 ? 's' : ''}!'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.raffleTicketsSold:
        final nft = data['nft'] as Map<String, dynamic>?;
        final buyer = _actor(
          data['buyerUser'] as Map<String, dynamic>?,
          data['buyer'] as String?,
        );
        final tickets = (data['ticketsSold'] as num?)?.toInt() ?? 0;
        return NotificationContents(
          title: 'Raffle tickets sold!',
          message: nft != null
              ? '$buyer bought $tickets ticket${tickets > 1 ? 's' : ''} on '
                    '"${_nftName(nft)}" for ${_price(data, 'totalPrice')}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );

      // ---- Airdrop ----
      case api.NotificationType.newAirdrop:
        final nft = data['nft'] as Map<String, dynamic>?;
        final creator = _actor(
          data['creatorUser'] as Map<String, dynamic>?,
          data['creator'] as String?,
        );
        final prints = (data['prints'] as num?)?.toInt();
        return NotificationContents(
          title: 'New airdrop!',
          message: prints != null
              ? '$creator created an airdrop with $prints prints'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.airdropReceived:
        final nft = data['nft'] as Map<String, dynamic>?;
        final creator = _actor(
          data['creatorUser'] as Map<String, dynamic>?,
          data['creator'] as String?,
        );
        return NotificationContents(
          title: 'Airdrop received!',
          message: nft != null
              ? 'You received "${_nftName(nft)}" from $creator'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.airdropCompleted:
        final nft = data['nft'] as Map<String, dynamic>?;
        return NotificationContents(
          title: 'Airdrop completed!',
          message: nft != null
              ? 'Your airdrop of "${_nftName(nft)}" has completed successfully'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );

      // ---- Gumball ----
      // Mobile has no Gumball screens (Tier D), so the Gumball-scoped rows fall
      // through to mallow.art; the ones the webapp points at an artwork stay
      // in-app.
      case api.NotificationType.gumballPurchased:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(
          data['gumball'] as Map<String, dynamic>?,
        );
        final buyer = _actor(
          data['buyerUser'] as Map<String, dynamic>?,
          data['buyer'] as String?,
        );
        return NotificationContents(
          title: 'Gumball purchase!',
          message: nft != null
              ? '$buyer purchased "${_nftName(nft)}" from your Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.gumballEnded:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        return NotificationContents(
          title: 'Gumball ended',
          message: gumballName != null
              ? 'Gumball "$gumballName" has ended. You can now claim your '
                    'proceeds and any unsold artworks.'
              : null,
          linkPath: _gumballLink(gumball),
          linkLabel: _gumballLink(gumball) != null ? 'View Gumball' : null,
        );
      case api.NotificationType.newGumballInvite:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        final inviter = _actor(
          data['inviterUser'] as Map<String, dynamic>?,
          data['inviter'] as String?,
        );
        return NotificationContents(
          title: 'Gumball invite!',
          message: gumballName != null
              ? '$inviter is inviting you to collaborate on Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _gumballLink(gumball, prefix: 'i'),
          linkLabel: _gumballLink(gumball, prefix: 'i') != null
              ? 'View invitation'
              : null,
        );
      case api.NotificationType.gumballInviteAccepted:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        final accepter = _actor(
          data['accepterUser'] as Map<String, dynamic>?,
          data['accepter'] as String?,
        );
        return NotificationContents(
          title: 'Invite accepted',
          message: gumballName != null
              ? '$accepter has accepted your invite to collaborate on Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _gumballLink(gumball, prefix: 's'),
          linkLabel: _gumballLink(gumball, prefix: 's') != null
              ? 'View Gumball'
              : null,
        );
      case api.NotificationType.gumballInviteDeclined:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        final decliner = _actor(
          data['declinerUser'] as Map<String, dynamic>?,
          data['decliner'] as String?,
        );
        return NotificationContents(
          title: 'Invite declined',
          message: gumballName != null
              ? '$decliner has declined your invite to collaborate on Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _gumballLink(gumball, prefix: 's'),
          linkLabel: _gumballLink(gumball, prefix: 's') != null
              ? 'View Gumball'
              : null,
        );
      case api.NotificationType.gumballInviteReminder:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        return NotificationContents(
          title: 'Gumball reminder',
          message: gumballName != null
              ? 'Reminder: You have a pending invite to collaborate on Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _gumballLink(gumball, prefix: 'i'),
          linkLabel: _gumballLink(gumball, prefix: 'i') != null
              ? 'View invitation'
              : null,
        );
      case api.NotificationType.artworkAddedToGumball:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(
          data['gumball'] as Map<String, dynamic>?,
        );
        final seller = _actor(
          data['sellerUser'] as Map<String, dynamic>?,
          data['seller'] as String?,
        );
        return NotificationContents(
          title: 'Artwork added to Gumball',
          message: nft != null
              ? '$seller added "${_nftName(nft)}" to your Gumball '
                    '"$gumballName"'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.artworkApprovedForGumball:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        return NotificationContents(
          title: 'Artwork approved for Gumball',
          message: nft != null
              ? '"${_nftName(nft)}" was approved for Gumball "$gumballName"'
              : null,
          linkPath: _gumballLink(gumball),
          linkLabel: _gumballLink(gumball) != null ? 'View Gumball' : null,
        );
      case api.NotificationType.artworkRemovedFromGumball:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(
          data['gumball'] as Map<String, dynamic>?,
        );
        final reason = data['reason'] as String?;
        return NotificationContents(
          title: 'Artwork removed from Gumball',
          message: nft != null
              ? '"${_nftName(nft)}" was removed from Gumball "$gumballName".'
                    '${reason != null ? '\n\nReason: $reason' : ''}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.newRequestToJoinGumball:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(
          data['gumball'] as Map<String, dynamic>?,
        );
        final requester = _actor(
          data['requesterUser'] as Map<String, dynamic>?,
          data['requester'] as String?,
        );
        return NotificationContents(
          title: 'New Gumball request',
          message: nft != null
              ? '$requester requested to add "${_nftName(nft)}" to your '
                    'Gumball "$gumballName"'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.gumballRequestRejected:
        final gumball = data['gumball'] as Map<String, dynamic>?;
        final gumballName = _getGumballName(gumball);
        return NotificationContents(
          title: 'Gumball request rejected',
          message: gumballName != null
              ? 'Your request to join Gumball "$gumballName" was rejected'
              : null,
          linkPath: _gumballLink(gumball),
          linkLabel: _gumballLink(gumball) != null ? 'View Gumball' : null,
        );

      // ---- Jellybean ----
      case api.NotificationType.jellybeanPurchased:
        final nft = data['nft'] as Map<String, dynamic>?;
        final name = _getGumballName(
          data['jellybean'] as Map<String, dynamic>?,
        );
        final buyer = _actor(
          data['buyerUser'] as Map<String, dynamic>?,
          data['buyer'] as String?,
        );
        return NotificationContents(
          title: 'Jellybean purchase!',
          message: nft != null
              ? '$buyer purchased "${_nftName(nft)}" from your Jellybean '
                    '"$name"'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.jellybeanEnded:
        final jellybean = data['jellybean'] as Map<String, dynamic>?;
        final name = _getGumballName(jellybean);
        final publicKey = jellybean?['publicKey'] as String?;
        return NotificationContents(
          title: 'Jellybean ended',
          message: name != null
              ? 'Jellybean "$name" has ended. You can now claim rent from your '
                    'Jellybean.'
              : null,
          linkPath: publicKey != null ? '/jellybean/$publicKey' : null,
          linkLabel: publicKey != null ? 'View Jellybean' : null,
        );

      // ---- Social ----
      case api.NotificationType.newFollower:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actor = _actor(actorUser, null);
        final link = _userLink(actorUser);
        return NotificationContents(
          title: '$actor followed you',
          linkPath: link,
          linkLabel: link != null ? 'View profile' : null,
          extraLinkLabel: link != null ? 'Follow back' : null,
          extraLinkPath: link,
        );
      case api.NotificationType.newFollowers:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actorCount = (data['actorCount'] as num?)?.toInt() ?? 2;
        final actor = _actor(actorUser, null);
        final others = actorCount - 1;
        final link = _userLink(actorUser);
        return NotificationContents(
          title:
              '$actor and $others other${others > 1 ? 's' : ''} followed you',
          linkPath: link,
          linkLabel: link != null ? 'View profile' : null,
        );
      case api.NotificationType.newComment:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actor = _actor(actorUser, null);
        final contentInfo = data['contentInfo'] as Map<String, dynamic>?;
        final contentType = _contentType(data);
        final contentUrl = contentInfo?['url'] as String?;
        return NotificationContents(
          title: '$actor ${_commentedOn(contentType, contentInfo)}',
          message: data['actorComment'] as String?,
          linkPath: contentUrl,
          linkLabel: contentUrl != null
              ? 'View ${_contentTypeLabel(contentType)}'
              : null,
        );
      case api.NotificationType.newComments:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actorCount = (data['actorCount'] as num?)?.toInt() ?? 2;
        final actor = _actor(actorUser, null);
        final others = actorCount - 1;
        final contentInfo = data['contentInfo'] as Map<String, dynamic>?;
        final contentType = _contentType(data);
        final contentUrl = contentInfo?['url'] as String?;
        return NotificationContents(
          title:
              '$actor and $others other${others > 1 ? 's' : ''} '
              '${_commentedOn(contentType, contentInfo)}',
          message: data['actorComment'] as String?,
          linkPath: contentUrl,
          linkLabel: contentUrl != null
              ? 'View ${_contentTypeLabel(contentType)}'
              : null,
        );
      case api.NotificationType.newLike:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actor = _actor(actorUser, null);
        final contentInfo = data['contentInfo'] as Map<String, dynamic>?;
        final contentType = _contentType(data);
        final contentUrl = contentInfo?['url'] as String?;
        return NotificationContents(
          title: '$actor liked ${_likedContent(contentType, contentInfo)}',
          linkPath: contentUrl,
          linkLabel: contentUrl != null
              ? 'View ${_contentTypeLabel(contentType)}'
              : null,
        );
      case api.NotificationType.newLikes:
        final actorUser = data['actorUser'] as Map<String, dynamic>?;
        final actorCount = (data['actorCount'] as num?)?.toInt() ?? 2;
        final actor = _actor(actorUser, null);
        final others = actorCount - 1;
        final contentInfo = data['contentInfo'] as Map<String, dynamic>?;
        final contentType = _contentType(data);
        final contentUrl = contentInfo?['url'] as String?;
        return NotificationContents(
          title:
              '$actor and $others other${others > 1 ? 's' : ''} liked '
              '${_likedContent(contentType, contentInfo)}',
          linkPath: contentUrl,
          linkLabel: contentUrl != null
              ? 'View ${_contentTypeLabel(contentType)}'
              : null,
        );

      // ---- Misc ----
      case api.NotificationType.storeProductSold:
        final product = data['storeProduct'] as Map<String, dynamic>?;
        final buyer = _actor(
          data['buyerUser'] as Map<String, dynamic>?,
          data['buyer'] as String?,
        );
        final sku = product?['sku'] as String?;
        return NotificationContents(
          title: 'Product sold!',
          message: product != null
              ? '$buyer bought "${product['name']}" for '
                    '${_price(data, 'price')}'
              : null,
          linkPath: sku != null ? '/product/${sku.replaceAll('.', '_')}' : null,
          linkLabel: sku != null ? 'View product' : null,
        );
      case api.NotificationType.tipReceived:
        final tipperUser = data['tipperUser'] as Map<String, dynamic>?;
        final tipper = _actor(tipperUser, data['tipper'] as String?);
        final link = _userLink(tipperUser);
        return NotificationContents(
          title: 'Tip received from $tipper!',
          message:
              'You received a tip of ${_price(data, 'amount')} from $tipper',
          linkPath: link,
          linkLabel: link != null ? 'View profile' : null,
        );
      case api.NotificationType.giftReceived:
        final nft = data['nft'] as Map<String, dynamic>?;
        final gifter = _actor(
          data['gifterUser'] as Map<String, dynamic>?,
          data['gifter'] as String?,
        );
        final giftMessage = data['message'] as String?;
        return NotificationContents(
          title: 'Gift received!',
          message: nft != null
              ? '$gifter sent you "${_nftName(nft)}".'
                    '${giftMessage != null && giftMessage.isNotEmpty ? '\n\nMessage from the sender: $giftMessage' : ''}'
              : null,
          linkPath: _artworkLink(nft),
          linkLabel: nft != null ? 'View artwork' : null,
        );
      case api.NotificationType.newStakingRewards:
        final smores = (data['smoresEarned'] as num?)?.round();
        final season = data['season'] as Map<String, dynamic>?;
        final seasonLabel = season?['label'] as String?;
        return NotificationContents(
          title: 'New staking rewards!',
          message: smores != null && seasonLabel != null
              ? 'You earned $smores SMORES for staking with mallow in '
                    '$seasonLabel. Claim now on the staking page.'
              : null,
          linkPath: '/stake',
          linkLabel: 'Claim SMORES',
        );
      case api.NotificationType.test:
        return NotificationContents(
          title: 'Test notification',
          message: data['message'] as String?,
        );
      case api.NotificationType.unknown:
        // A type this build doesn't know. Degrade this row only — the list
        // still renders every neighbour (see NotificationType.unknown).
        return const NotificationContents(
          title: 'Notification',
          message: 'Unable to display notification',
        );
    }
  }

  static String _fallbackTitle(api.NotificationType type) {
    final name = type.name
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .trim();
    return name[0].toUpperCase() + name.substring(1);
  }

  /// `getNameWithEditionNumber` — an edition print reads "Name #3", not "Name",
  /// which is the only thing distinguishing one print's notification from
  /// another's.
  static String _nftName(Map<String, dynamic>? nft) {
    if (nft == null) return '';
    final name = nft['name'] as String? ?? '';
    final edition = (nft['editionNumber'] as num?)?.toInt();
    return edition == null ? name : '$name #$edition';
  }

  /// The person a notification is about, as `getUsername` resolves them:
  /// `@username`, else a truncated address, else empty.
  ///
  /// Never null — an unresolvable actor must render as nothing, not as the
  /// literal string "null" in the middle of a sentence.
  static String _actor(Map<String, dynamic>? user, String? address) =>
      _getUsername(user) ??
      _shortAddr(address) ??
      _shortAddr(_getFirstAddress(user)) ??
      '';

  /// Format a raw (smallest-unit) amount in `data[amountKey]` with its token
  /// symbol, matching the webapp's `formatPriceWithSymbol`. A missing amount
  /// renders `0 SYMBOL` rather than vanishing, as it does on web.
  static String _price(Map<String, dynamic> data, String amountKey) {
    final amount = (data[amountKey] as num?)?.toDouble() ?? 0;
    return PriceFormatter.formatRawAmountWithSymbol(
      amount,
      data['currencyMint'] as String?,
    );
  }

  static String? _artworkLink(Map<String, dynamic>? nft) {
    final mint = nft?['mintAccount'] as String?;
    return mint == null ? null : '/artwork/$mint';
  }

  static String? _gumballLink(Map<String, dynamic>? gumball, {String? prefix}) {
    final publicKey = gumball?['publicKey'] as String?;
    if (publicKey == null) return null;
    return prefix == null
        ? '/gumball/$publicKey'
        : '/gumball/$prefix/$publicKey';
  }

  static String? _userLink(Map<String, dynamic>? user) {
    final username = user?['username'] as String?;
    if (username != null && username.isNotEmpty) return '/u/$username';
    final address = _getFirstAddress(user);
    return address == null ? null : '/a/$address';
  }

  /// `data.targetContent.type` — the kind of thing that was commented on or
  /// liked. Absent on older payloads, in which case the copy falls back to
  /// "artwork" the way the webapp's `getContentTypeString` default does.
  static String? _contentType(Map<String, dynamic> data) {
    final target = data['targetContent'] as Map<String, dynamic>?;
    return target?['type'] as String?;
  }

  static String _contentTypeLabel(String? contentType) {
    switch (contentType) {
      case 'gumball':
        return 'Gumball';
      case 'jellybean':
        return 'Jellybean';
      case 'nft':
      case null:
        return 'artwork';
      default:
        return contentType;
    }
  }

  static String _commentedOn(
    String? contentType,
    Map<String, dynamic>? contentInfo,
  ) {
    if (contentType == 'comment') return 'replied to your comment';
    final title = _contentTitle(contentType, contentInfo);
    return title == null
        ? 'commented on your ${_contentTypeLabel(contentType)}'
        : 'commented on "$title"';
  }

  static String _likedContent(
    String? contentType,
    Map<String, dynamic>? contentInfo,
  ) {
    final title = _contentTitle(contentType, contentInfo);
    return title ?? 'your ${_contentTypeLabel(contentType)}';
  }

  /// The webapp only quotes the content's own title for the content types it
  /// has a title for (nft / gumball / jellybean / post); everything else —
  /// notably a reply to a comment — falls back to the type word.
  static String? _contentTitle(
    String? contentType,
    Map<String, dynamic>? contentInfo,
  ) {
    switch (contentType) {
      case 'nft':
      case 'gumball':
      case 'jellybean':
      case 'post':
      case null:
        return contentInfo?['title'] as String?;
      default:
        return null;
    }
  }

  static String? _getUsername(Map<String, dynamic>? user) {
    if (user == null) return null;
    final u = user['username'] as String?;
    return (u != null && u.isNotEmpty) ? '@$u' : null;
  }

  static String? _getFirstAddress(Map<String, dynamic>? user) {
    final addresses = user?['addresses'] as List<dynamic>?;
    return addresses?.isNotEmpty == true ? addresses!.first as String? : null;
  }

  static String? _shortAddr(String? address) {
    if (address == null || address.isEmpty) return null;
    return truncateAddress(address);
  }

  static String? _getGumballName(Map<String, dynamic>? gumball) {
    if (gumball == null) return null;
    final meta = gumball['metadata'] as Map<String, dynamic>?;
    return meta?['name'] as String?;
  }
}
