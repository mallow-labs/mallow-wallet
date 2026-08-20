import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/all_art_detail.dart';

// Every raffle tile badged "Live raffle" regardless of state, because the
// preview payload carried no raffle metadata at all — so a raffle whose window
// closed weeks ago still read as a purchase a tester could make. The badge is
// the only lifecycle signal on a browse surface; getting it wrong sends people
// to a sheet that can do nothing. These pin the three states the webapp
// distinguishes (`CardStatusContent`) plus the no-metadata case,
// which must NOT be reported as expired — an absent field is not a fact.
void main() {
  api.RaffleMetadata raffle({DateTime? endsAt, int? sold}) =>
      api.RaffleMetadata(
        mintAccount: 'ArtMint11111111111111111111111111111111111',
        creator: 'Creator111111111111111111111111111111111111',
        raffleAccount: 'Raffle1111111111111111111111111111111111111',
        entrantsAccount: 'Entrant111111111111111111111111111111111111',
        endsAt: endsAt,
        sold: sold,
      );

  PortfolioArtwork tile(
    api.RaffleMetadata? metadata, {
    String artistName = 'artist',
    String? artistUsername,
  }) => PortfolioArtwork(
    mintAccount: 'ArtMint11111111111111111111111111111111111',
    title: 'Sunset',
    imageUrl: '',
    artistName: artistName,
    artistUsername: artistUsername,
    listingType: api.ListingType.raffle,
    raffleMetadata: metadata,
  );

  Future<void> pump(
    WidgetTester tester,
    PortfolioArtwork artwork, {
    ValueChanged<PortfolioArtwork>? onLongPress,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            AllArtDetail(
              artworks: [artwork],
              onLongPress: onLongPress ?? (_) {},
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('an open window badges "Live raffle" with a countdown', (
    tester,
  ) async {
    await pump(
      tester,
      tile(
        raffle(
          endsAt: DateTime.now().toUtc().add(const Duration(hours: 5)),
          sold: 3,
        ),
      ),
    );

    expect(
      find.textContaining('Live raffle · Ends'),
      findsOneWidget,
      reason: 'the countdown is what makes "live" actionable',
    );
  });

  testWidgets('a closed window with tickets sold badges "Draw pending"', (
    tester,
  ) async {
    // The prize hasn't moved yet, but nothing can be bought — the entrant is
    // waiting on the draw, not on a decision of their own.
    await pump(
      tester,
      tile(
        raffle(
          endsAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          sold: 7,
        ),
      ),
    );

    expect(find.text('Draw pending'), findsOneWidget);
    expect(find.textContaining('Live raffle'), findsNothing);
  });

  testWidgets('a closed window with no tickets sold badges "Raffle expired"', (
    tester,
  ) async {
    // `sold` is what separates the two closed states; zero means the raffle
    // simply lapsed and there is no draw coming.
    await pump(
      tester,
      tile(
        raffle(
          endsAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          sold: 0,
        ),
      ),
    );

    expect(find.text('Raffle expired'), findsOneWidget);
  });

  testWidgets('missing raffle metadata claims no lifecycle at all', (
    tester,
  ) async {
    // An endpoint that didn't hydrate the join must not be read as "expired" —
    // that would relabel every live raffle on any surface still behind the
    // backend deploy. Silence is the honest answer.
    await pump(tester, tile(null));

    expect(find.textContaining('Live raffle'), findsNothing);
    expect(find.text('Raffle expired'), findsNothing);
    expect(find.text('Draw pending'), findsNothing);
  });

  testWidgets(
    'detailed cards show the creator username instead of display name',
    (tester) async {
      await pump(
        tester,
        tile(
          null,
          artistName: 'Display Name',
          artistUsername: 'creator_handle',
        ),
      );

      expect(find.text('creator_handle'), findsOneWidget);
      expect(find.text('Display Name'), findsNothing);
    },
  );

  // The detail layout replaced a compact row that showed only a title and a
  // creator. Its reason to exist is the rest: what the piece costs, how many
  // exist, and how long the listing runs. A card that renders the title alone
  // is indistinguishable from the row it replaced.
  group('the detail card carries the buying information', () {
    PortfolioArtwork listed() => PortfolioArtwork(
      mintAccount: 'ArtMint11111111111111111111111111111111111',
      title: 'Sunset',
      imageUrl: '',
      artistName: 'Display Name',
      artistUsername: 'creator_handle',
      listingType: api.ListingType.buyNow,
      maxSupply: 10,
      supply: 3,
      buyNowMetadata: api.BuyNowMetadata(
        amount: 1.5,
        quantityLeft: 7,
        endsAt: DateTime.now().toUtc().add(const Duration(days: 2)),
      ),
    );

    testWidgets('renders price, edition, creator and listing countdown', (
      tester,
    ) async {
      await pump(tester, listed());

      expect(find.text('Limited edition of 10'), findsOneWidget);
      expect(find.text('creator_handle'), findsOneWidget);
      expect(find.text('Sunset'), findsOneWidget);
      expect(find.text('3 / 10 sold'), findsOneWidget);
      expect(find.textContaining('Live · Ends'), findsOneWidget);
      expect(
        find.textContaining('SOL'),
        findsOneWidget,
        reason: 'the price is the whole reason this layout exists',
      );
    });

    testWidgets('opens the options sheet on long-press, with no kebab', (
      tester,
    ) async {
      // A card is a full-width square plus four text rows, so it overflows the
      // default 800x600 surface and the title lands off-screen — untappable.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      PortfolioArtwork? pressed;
      await pump(tester, listed(), onLongPress: (a) => pressed = a);

      // The masonry and grid layouts are long-press too; a visible kebab here
      // would make the detail layout the odd one out.
      expect(find.byTooltip('More'), findsNothing);

      await tester.longPress(find.text('Sunset'));
      expect(pressed?.title, 'Sunset');
    });
  });
}
