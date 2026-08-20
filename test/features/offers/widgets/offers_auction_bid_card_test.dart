import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/widgets/activity_list_row.dart';
import 'package:mallow_wallet/features/offers/widgets/offers_auction_bid_card.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  const solMint = 'So11111111111111111111111111111111111111112';

  // ActivityListRow's missing-image avatar is a generated identicon
  // (AccountAvatar), which resolves AvatarService via GetIt. An unstubbed
  // mock Dio makes every fetch fail, so rows render the anon fallback.
  setUpAll(() {
    sl.registerLazySingleton<AvatarService>(
      () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
    );
  });
  tearDownAll(() => sl.unregister<AvatarService>());

  api.AuctionBidRef bid(String address, double amount, {String? username}) =>
      api.AuctionBidRef(
        bidderAddress: address,
        bidder: username == null ? null : api.ApiUserRef(username: username),
        rawAmount: amount,
        currencyMint: solMint,
      );

  api.OffersInboxItem placedBid({
    required bool isHighestBidder,
    required api.AuctionStatus status,
    List<api.AuctionBidRef> recentBids = const [],
  }) => api.OffersInboxItem(
    kind: api.OffersInboxKind.bid,
    direction: api.OffersInboxDirection.placed,
    asset: 'ASSET',
    artworkTitle: 'Art',
    creatorUsername: 'maker',
    actorAddress: 'W1',
    viewerAddress: 'W1',
    rawAmount: 2000000000,
    currencyMint: solMint,
    auction: api.AuctionInfo(
      status: status,
      sellerAddress: 'SELLER',
      isHighestBidder: isHighestBidder,
      highestBid: isHighestBidder
          ? bid('W1', 2000000000)
          : bid('OTHER', 3000000000, username: 'rival'),
      yourBid: bid('W1', 2000000000),
      recentBids: recentBids,
    ),
  );

  api.OffersInboxItem receivedBids(
    List<api.AuctionBidRef> recent, {
    api.AuctionStatus status = api.AuctionStatus.live,
  }) => api.OffersInboxItem(
    kind: api.OffersInboxKind.bid,
    direction: api.OffersInboxDirection.received,
    asset: 'ASSET',
    artworkTitle: 'Art',
    creatorUsername: 'maker',
    actorAddress: 'OTHER',
    // The viewer is the seller on received cards.
    viewerAddress: 'SELLER',
    rawAmount: 3000000000,
    currencyMint: solMint,
    auction: api.AuctionInfo(
      status: status,
      sellerAddress: 'SELLER',
      recentBids: recent,
    ),
  );

  Future<void> pumpCard(
    WidgetTester tester,
    api.OffersInboxItem item, {
    VoidCallback? onView,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OffersAuctionBidCard(item: item, onView: onView ?? () {}),
        ),
      ),
    );
    // Not pumpAndSettle: the live-auction chip hosts a repeating ping
    // animation, so the tree never settles.
    await tester.pump();
  }

  /// Amount texts rendered struck-through — the card's "this bid was
  /// superseded" treatment.
  Finder struckTexts() => find.byWidgetPredicate(
    (w) => w is Text && w.style?.decoration == TextDecoration.lineThrough,
  );

  testWidgets(
    'header shows the artwork title, creator and status chip inside the card — '
    'the card is self-contained and no longer relies on a group header',
    (tester) async {
      await pumpCard(
        tester,
        placedBid(isHighestBidder: false, status: api.AuctionStatus.live),
      );

      expect(find.text('Art'), findsOneWidget);
      expect(find.text('maker'), findsOneWidget);
      expect(find.text('Live auction'), findsOneWidget);
    },
  );

  testWidgets(
    'placed + highest bidder: your bid plus the struck-through bid you outbid '
    '— leading still shows what you beat, but the listing event is not a bid '
    'so it never appears as the outbid row',
    (tester) async {
      await pumpCard(
        tester,
        placedBid(
          isHighestBidder: true,
          status: api.AuctionStatus.live,
          recentBids: [
            bid('W1', 2000000000),
            bid('LOSER', 1500000000, username: 'runnerup'),
            bid('SELLER', 1000000000, username: 'sellerguy'),
          ],
        ),
      );

      expect(find.text('You are the highest bidder'), findsOneWidget);
      expect(find.text('You were outbid!'), findsNothing);
      // Leading + live still links back to the auction with the plain pill.
      expect(find.text('View auction'), findsOneWidget);
      expect(find.text('Claim'), findsNothing);
      expect(find.byType(ActivityListRow), findsNWidgets(2));
      expect(find.textContaining('runnerup'), findsOneWidget);
      // The seller's listing event is skipped, not shown as an outbid bid.
      expect(find.textContaining('sellerguy'), findsNothing);
      // Exactly the outbid rival's amount strikes through, not yours.
      expect(struckTexts(), findsOneWidget);
      expect(tester.widget<Text>(struckTexts()).data, '1.5 SOL');
    },
  );

  testWidgets(
    'placed + outbid: highest bid above your struck-through bid, outbid chip '
    'and a View pill — the outbid viewer needs both numbers and a way back to '
    'the auction to re-bid',
    (tester) async {
      await pumpCard(
        tester,
        placedBid(isHighestBidder: false, status: api.AuctionStatus.live),
      );

      expect(find.text('You were outbid!'), findsOneWidget);
      expect(find.text('You are the highest bidder'), findsNothing);
      expect(find.text('View auction'), findsOneWidget);
      expect(find.text('Bid again'), findsNothing);
      expect(find.byType(ActivityListRow), findsNWidgets(2));
      expect(find.textContaining('rival'), findsOneWidget);
      // Only the viewer's own (superseded) amount strikes through.
      expect(struckTexts(), findsOneWidget);
      expect(tester.widget<Text>(struckTexts()).data, '2 SOL');
    },
  );

  testWidgets(
    'complete auction shows "Auction complete" with a View pill — a finished '
    'auction can no longer be bid on, but its outcome is worth revisiting',
    (tester) async {
      await pumpCard(
        tester,
        placedBid(isHighestBidder: false, status: api.AuctionStatus.complete),
      );

      expect(find.text('Auction complete'), findsOneWidget);
      expect(find.text('Live auction'), findsNothing);
      expect(find.text('View auction'), findsOneWidget);
      expect(find.text('You were outbid!'), findsOneWidget);
      // The loser has nothing to claim — the pill stays the plain pill.
      expect(find.text('Claim NFT'), findsNothing);
      expect(find.text('Settle'), findsNothing);
      expect(
        tester.widget<Text>(find.text('View auction')).style?.color,
        isNot(MallowTheme.accent),
      );
    },
  );

  testWidgets(
    'placed + highest + complete: the chip flips to "You won the auction!" '
    'with a View pill — the ended auction is won, not merely led',
    (tester) async {
      await pumpCard(
        tester,
        placedBid(isHighestBidder: true, status: api.AuctionStatus.complete),
      );

      expect(find.text('You won the auction!'), findsOneWidget);
      expect(find.text('You are the highest bidder'), findsNothing);
      expect(find.text('Auction complete'), findsOneWidget);
      // Won chip sits on the half-alpha success green (#3FAE5D80).
      final wonChip = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('You won the auction!'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (wonChip.decoration as BoxDecoration?)?.color,
        MallowColors.light.positive.withValues(alpha: 0.5),
      );
      // The winner has a prize waiting — the pill reads "Claim NFT" in accent.
      expect(find.text('View auction'), findsNothing);
      expect(
        tester.widget<Text>(find.text('Claim NFT')).style?.color,
        MallowColors.light.accent,
      );
    },
  );

  testWidgets(
    'received card caps at the 3 most recent bids and labels the seller\'s '
    'listing event "You listed" — the listing is indexed as a bid by the '
    'seller but must not read as one',
    (tester) async {
      await pumpCard(
        tester,
        receivedBids([
          bid('A', 3000000000, username: 'alice'),
          bid('B', 2500000000, username: 'bob'),
          bid('SELLER', 1000000000),
          bid('C', 2000000000, username: 'carol'),
        ]),
      );

      expect(find.text('Live auction'), findsOneWidget);
      expect(find.byType(ActivityListRow), findsNWidgets(3));
      expect(find.textContaining('alice'), findsOneWidget);
      expect(find.textContaining('bob'), findsOneWidget);
      // The seller (= viewer) listing row reads "You listed", inert.
      expect(find.text('You listed', findRichText: true), findsOneWidget);
      // The 4th recent bid falls off the 3-row cap.
      expect(find.textContaining('carol'), findsNothing);
      // No footer while live, no strikethrough ever on received rows.
      expect(find.text('View auction'), findsNothing);
      expect(find.text('You were outbid!'), findsNothing);
      expect(find.text('You are the highest bidder'), findsNothing);
      expect(struckTexts(), findsNothing);
    },
  );

  testWidgets(
    'received + complete: the View pill appears without an outcome chip — the '
    'seller needs a way back to the ended auction to settle it',
    (tester) async {
      await pumpCard(
        tester,
        receivedBids([
          bid('A', 3000000000, username: 'alice'),
        ], status: api.AuctionStatus.complete),
      );

      expect(find.text('Auction complete'), findsOneWidget);
      expect(find.text('You were outbid!'), findsNothing);
      expect(find.text('You are the highest bidder'), findsNothing);
      // The seller has proceeds waiting — the pill reads "Settle" in accent.
      expect(find.text('View auction'), findsNothing);
      expect(
        tester.widget<Text>(find.text('Settle')).style?.color,
        MallowColors.light.accent,
      );
    },
  );

  testWidgets(
    'the age stamp renders on a single line — "Just now" is the widest '
    'relative stamp and must not wrap inside the fixed age column',
    (tester) async {
      await pumpCard(
        tester,
        receivedBids([
          api.AuctionBidRef(
            bidderAddress: 'A',
            bidder: const api.ApiUserRef(username: 'alice'),
            rawAmount: 3000000000,
            currencyMint: solMint,
            date: DateTime.now(),
          ),
        ]),
      );

      final age = find.text('Just now');
      expect(age, findsOneWidget);
      expect(tester.widget<Text>(age).maxLines, 1);
      // Single uiCaption line is 14px tall; a wrapped stamp would be ~28.
      expect(tester.getSize(age).height, lessThan(20));
    },
  );

  testWidgets(
    'header and the footer View pill both fire onView — both deep-link to the '
    'artwork, wired by the screen',
    (tester) async {
      var views = 0;
      await pumpCard(
        tester,
        placedBid(isHighestBidder: false, status: api.AuctionStatus.live),
        onView: () => views++,
      );

      await tester.tap(find.text('Art'));
      await tester.tap(find.text('View auction'));
      expect(views, 2);
    },
  );
}
