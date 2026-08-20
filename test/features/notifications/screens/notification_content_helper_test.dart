import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/notifications/screens/notifications_screen.dart';

const _solMint = 'So11111111111111111111111111111111111111112';

Map<String, dynamic> _nft({int? editionNumber}) => {
  'name': 'Sunset',
  'mintAccount': 'MINT1',
  'imageUrl': 'https://img/1.png',
  'editionNumber': ?editionNumber,
};

Map<String, dynamic> _user(String username) => {
  'username': username,
  'addresses': ['ADDR1234567890'],
};

void main() {
  group('money in the body (webapp parity)', () {
    // Every one of these types exists to tell the user how much money moved.
    // A body that names the artwork but drops the amount is the wrong
    // information — the user has to open the artwork to learn what they were
    // outbid by, or what their piece sold for.
    test('outbid states the amount that beat you', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.outbid,
        {'nft': _nft(), 'newBidAmount': 1500000000, 'currencyMint': _solMint},
      );
      expect(contents.message, 'You were outbid on "Sunset" for 1.5 SOL');
    });

    test('artwork sold states buyer and price', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.artworkSold,
        {
          'nft': _nft(),
          'price': 2000000000,
          'currencyMint': _solMint,
          'buyer': 'ADDR1234567890',
          'buyerUser': _user('collector'),
        },
      );
      expect(contents.message, '@collector purchased "Sunset" for 2 SOL');
    });

    test('auction won, new bid and offers all carry their amount', () {
      String? messageFor(
        api.NotificationType type,
        Map<String, dynamic> data,
      ) => NotificationContentHelper.getContents(type, data).message;

      expect(
        messageFor(api.NotificationType.auctionWon, {
          'nft': _nft(),
          'winningBid': 3000000000,
          'currencyMint': _solMint,
        }),
        contains('3 SOL'),
      );
      expect(
        messageFor(api.NotificationType.newBid, {
          'nft': _nft(),
          'bidAmount': 500000000,
          'currencyMint': _solMint,
          'bidderUser': _user('bidder'),
        }),
        '"Sunset" received a bid for 0.5 SOL from @bidder',
      );
      expect(
        messageFor(api.NotificationType.newHighestOffer, {
          'nft': _nft(),
          'offerAmount': 250000000,
          'currencyMint': _solMint,
          'offererUser': _user('offerer'),
        }),
        '@offerer offered 0.25 SOL on "Sunset"',
      );
      expect(
        messageFor(api.NotificationType.offerAccepted, {
          'nft': _nft(),
          'price': 1000000000,
          'currencyMint': _solMint,
        }),
        'Your offer on "Sunset" was accepted for 1 SOL',
      );
    });

    test('an edition print is named with its edition number', () {
      // Two prints of the same edition produce identical copy without this —
      // the user can't tell which one sold.
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.airdropReceived,
        {'nft': _nft(editionNumber: 7), 'creatorUser': _user('artist')},
      );
      expect(contents.message, 'You received "Sunset #7" from @artist');
    });

    test('an unresolvable actor renders as nothing, never "null"', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.artworkSold,
        {'nft': _nft(), 'price': 1000000000, 'currencyMint': _solMint},
      );
      expect(contents.message, isNot(contains('null')));
    });
  });

  group('tap targets (webapp parity)', () {
    test('artwork-scoped rows link to the artwork', () {
      for (final type in [
        api.NotificationType.gumballPurchased,
        api.NotificationType.jellybeanPurchased,
        api.NotificationType.artworkAddedToGumball,
      ]) {
        final contents = NotificationContentHelper.getContents(type, {
          'nft': _nft(),
          'gumball': {
            'publicKey': 'GUMBALL1',
            'metadata': {'name': 'Bag'},
          },
          'jellybean': {
            'publicKey': 'JELLY1',
            'metadata': {'name': 'Bag'},
          },
          'buyerUser': _user('buyer'),
          'sellerUser': _user('seller'),
        });
        expect(contents.linkPath, '/artwork/MINT1', reason: '$type');
        expect(contents.linkLabel, 'View artwork', reason: '$type');
      }
    });

    test('web-only rows still get a link instead of a dead cell', () {
      // Mobile has no Gumball/Jellybean/store/staking screens; the row must
      // still be tappable (the tap handler routes these to mallow.art).
      final gumball = NotificationContentHelper.getContents(
        api.NotificationType.gumballEnded,
        {
          'gumball': {
            'publicKey': 'GUMBALL1',
            'metadata': {'name': 'Bag'},
          },
        },
      );
      expect(gumball.linkPath, '/gumball/GUMBALL1');

      final staking = NotificationContentHelper.getContents(
        api.NotificationType.newStakingRewards,
        {
          'smoresEarned': 12.4,
          'season': {'label': 'Season 2'},
        },
      );
      expect(staking.linkPath, '/stake');
      expect(staking.message, contains('12 SMORES'));

      final product = NotificationContentHelper.getContents(
        api.NotificationType.storeProductSold,
        {
          'storeProduct': {'sku': 'shirt.blue', 'name': 'Shirt'},
          'price': 1000000000,
          'currencyMint': _solMint,
          'buyerUser': _user('buyer'),
        },
      );
      expect(product.linkPath, '/product/shirt_blue');
      expect(product.message, '@buyer bought "Shirt" for 1 SOL');
    });

    test('social rows link to the actor by username when there is one', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.newFollower,
        {'actorUser': _user('artist')},
      );
      expect(contents.linkPath, '/u/artist');

      final noUsername = NotificationContentHelper.getContents(
        api.NotificationType.newFollower,
        {
          'actorUser': {
            'addresses': ['ADDR1234567890'],
          },
        },
      );
      expect(noUsername.linkPath, '/a/ADDR1234567890');
    });

    test('a comment on a non-artwork is labelled by its own content type', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.newComment,
        {
          'actorUser': _user('artist'),
          'targetContent': {'id': 'GUMBALL1', 'type': 'gumball'},
          'contentInfo': {
            'title': 'Bag',
            'url': 'https://mallow.art/gumball/GUMBALL1',
          },
          'actorComment': 'nice',
        },
      );
      expect(contents.title, '@artist commented on "Bag"');
      expect(contents.linkLabel, 'View Gumball');
      expect(contents.linkPath, 'https://mallow.art/gumball/GUMBALL1');
    });

    test('a reply to a comment says so', () {
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.newComment,
        {
          'actorUser': _user('artist'),
          'targetContent': {'id': 'C1', 'type': 'comment'},
          'contentInfo': {'title': 'Sunset'},
          'actorComment': 'agreed',
        },
      );
      expect(contents.title, '@artist replied to your comment');
    });
  });

  group('unknown notification type', () {
    test('degrades one cell instead of blanking the list', () {
      // A new backend enum decodes to NotificationType.unknown; this row must
      // still render so its neighbours survive.
      final contents = NotificationContentHelper.getContents(
        api.NotificationType.unknown,
        const {},
      );
      expect(contents.title, 'Notification');
      expect(contents.message, 'Unable to display notification');
      expect(contents.linkPath, isNull);
    });

    test('an unknown wire value decodes to unknown rather than throwing', () {
      final item = api.NotificationItem.fromJson({
        'id': 1,
        'type': 9999,
        'data': <String, dynamic>{},
        'createdAt': DateTime.utc(2026).toIso8601String(),
      });
      expect(item.type, api.NotificationType.unknown);
    });
  });
}
