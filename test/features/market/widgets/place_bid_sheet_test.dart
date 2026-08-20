import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/widgets/place_bid_sheet.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

/// Fake client — [TokenPriceService] only hits the network in `start()`, which
/// the sheet never invokes, so `priceOf` stays null and the USD suffix is
/// suppressed (irrelevant to the min-bid behavior under test).
class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

void main() {
  setUpAll(() {
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
  });

  // 1.5 SOL in lamports — the auction floor handed to the sheet.
  const minBidRaw = 1500000000;

  late _MockTokenBalanceBloc balanceBloc;

  /// Active-signer balances the sheet reads. [sol] is in whole SOL.
  TokenBalanceState solBalance(double sol) => TokenBalanceState.loaded(
    tokens: [
      TokenBalance(
        mint: solMint,
        symbol: 'SOL',
        name: 'Solana',
        decimals: 9,
        rawBalance: (sol * 1000000000).round(),
        uiBalance: sol,
        isNative: true,
      ),
    ],
    totalUsdValue: 0,
  );

  setUp(() {
    balanceBloc = _MockTokenBalanceBloc();
    // Comfortably above every amount the min-bid tests type.
    when(() => balanceBloc.state).thenReturn(solBalance(10));
  });

  Widget buildSheet({int? minBid = minBidRaw, AuctionMetadata? auction}) =>
      MaterialApp(
        home: Scaffold(
          body: PlaceBidSheet(
            artworkTitle: 'Amazing NFT',
            mintAccount: 'mint',
            currencyMint: solMint,
            minBidRaw: minBid,
            auction: auction,
            tokenBalanceBloc: balanceBloc,
          ),
        ),
      );

  VoidCallback? nextOnPressed(WidgetTester tester) =>
      tester.widget<MallowButton>(find.byType(MallowButton)).onPressed;

  testWidgets('shows the minimum bid hint in the bid currency', (tester) async {
    await tester.pumpWidget(buildSheet());
    await tester.pump();

    expect(find.text('Min: 1.50 SOL'), findsOneWidget);
  });

  testWidgets('a below-minimum bid disables Next and labels it "Bid too low"', (
    tester,
  ) async {
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();

    expect(find.text('Bid too low'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    // Disabled CTA cannot submit the under-floor bid.
    expect(nextOnPressed(tester), isNull);
  });

  testWidgets('a bid at the minimum enables Next', (tester) async {
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1.5');
    await tester.pump();

    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Bid too low'), findsNothing);
    expect(nextOnPressed(tester), isNotNull);
  });

  testWidgets('no floor is enforced when minBidRaw is absent', (tester) async {
    await tester.pumpWidget(buildSheet(minBid: null));
    await tester.pump();

    // No hint, and any positive amount is accepted.
    expect(find.textContaining('Min:'), findsNothing);
    await tester.enterText(find.byType(TextField), '0.0001');
    await tester.pump();
    expect(find.text('Next'), findsOneWidget);
    expect(nextOnPressed(tester), isNotNull);
  });

  testWidgets('shows the active signer balance in the bid currency', (
    tester,
  ) async {
    when(() => balanceBloc.state).thenReturn(solBalance(2.5));
    await tester.pumpWidget(buildSheet());
    await tester.pump();

    expect(
      find.textContaining('Balance: 2.5 SOL', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a bid above the balance disables Next and labels it '
      '"Insufficient funds"', (tester) async {
    when(() => balanceBloc.state).thenReturn(solBalance(2));
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();

    expect(find.text('Insufficient funds'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    // The unaffordable bid can't be submitted, by tap or by keyboard "done".
    expect(nextOnPressed(tester), isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Insufficient funds'), findsOneWidget);
  });

  testWidgets('a bid that would eat the gas reserve is insufficient', (
    tester,
  ) async {
    // Bidding the entire balance leaves nothing for the network fee — the same
    // verdict the confirm step reaches, surfaced before the tx is built.
    when(() => balanceBloc.state).thenReturn(solBalance(2));
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '2');
    await tester.pump();

    expect(find.text('Insufficient funds'), findsOneWidget);
    expect(nextOnPressed(tester), isNull);
  });

  testWidgets('an affordable bid keeps Next enabled', (tester) async {
    when(() => balanceBloc.state).thenReturn(solBalance(2));
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1.9');
    await tester.pump();

    expect(find.text('Next'), findsOneWidget);
    expect(nextOnPressed(tester), isNotNull);
  });

  testWidgets('no balance line and no false-disable before balances load', (
    tester,
  ) async {
    // Balances are still loading — gating on an unknown balance would block a
    // bid the wallet can actually afford.
    when(() => balanceBloc.state).thenReturn(const TokenBalanceState.loading());
    await tester.pumpWidget(buildSheet());
    await tester.enterText(find.byType(TextField), '1.5');
    await tester.pump();

    expect(find.textContaining('Balance:', findRichText: true), findsNothing);
    expect(find.text('Next'), findsOneWidget);
    expect(nextOnPressed(tester), isNotNull);
  });

  // Why this matters: a bidder who doesn't know the minimum increment bids
  // just over the current high and gets the transaction reverted (paying the
  // fee); a bidder who doesn't know about the end phase believes sniping in
  // the last minute works. The webapp states both facts in the same modal
  // (`AuctionInfoBox`) for exactly that reason (`auction.test`).
  //
  // The two window fields are INDEPENDENT on the wire and mean different
  // things in `mallow-auction`'s bid processor: `timeExtPeriod` is the window
  // that triggers an extension, `timeExtDelta` is how far the deadline moves.
  // Every case below keeps them different so a swap can't pass.
  group('auction info box', () {
    /// Live auction whose end phase is already open: started an hour ago,
    /// ends in 5 minutes, 15-minute end phase, 10-minute extension.
    AuctionMetadata endPhaseAuction() => AuctionMetadata(
      startsAt: DateTime.now().subtract(const Duration(hours: 1)),
      endsAt: DateTime.now().add(const Duration(minutes: 5)),
      timeExtPeriod: 900,
      timeExtDelta: 600,
      minBidIncrementBps: 500,
      bidMint: solMint,
    );

    testWidgets('states the increment and both anti-sniping numbers', (
      tester,
    ) async {
      await tester.pumpWidget(buildSheet(auction: endPhaseAuction()));
      await tester.pump();

      expect(find.text('Minimum bid increment'), findsOneWidget);
      expect(find.text('5%'), findsOneWidget);
      // The trigger window (period) and the extension length (delta) are
      // reported separately and are not interchangeable.
      expect(find.text('Last 15 minutes'), findsOneWidget);
      expect(find.text('10 minutes'), findsOneWidget);
    });

    testWidgets('a flat increment renders in the bid currency, not as %', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildSheet(
          auction: AuctionMetadata(
            startsAt: DateTime.now().subtract(const Duration(hours: 1)),
            endsAt: DateTime.now().add(const Duration(minutes: 5)),
            timeExtPeriod: 900,
            timeExtDelta: 600,
            minBidIncrement: 500000000,
            bidMint: solMint,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('0.5 SOL'), findsOneWidget);
    });

    testWidgets('an on-bid auction states its duration and increment', (
      tester,
    ) async {
      // No startsAt: the clock only begins on the first bid, so the bidder is
      // the one who starts it and needs to know for how long.
      await tester.pumpWidget(
        buildSheet(
          auction: const AuctionMetadata(
            duration: 86400,
            timeExtPeriod: 900,
            timeExtDelta: 600,
            minBidIncrementBps: 500,
            bidMint: solMint,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Auction duration'), findsOneWidget);
      expect(find.text('24 hours'), findsOneWidget);
      expect(find.text('Minimum bid increment'), findsOneWidget);
    });

    testWidgets('an auction with no end phase states nothing about one', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildSheet(
          auction: AuctionMetadata(
            startsAt: DateTime.now().subtract(const Duration(hours: 1)),
            endsAt: DateTime.now().add(const Duration(hours: 5)),
            timeExtPeriod: 0,
            timeExtDelta: 0,
            minBidIncrementBps: 500,
            bidMint: solMint,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('end phase'), findsNothing);
      expect(find.textContaining('Last '), findsNothing);
    });

    testWidgets('no auction, no box', (tester) async {
      await tester.pumpWidget(buildSheet());
      await tester.pump();

      expect(find.text('Minimum bid increment'), findsNothing);
    });
  });
}
