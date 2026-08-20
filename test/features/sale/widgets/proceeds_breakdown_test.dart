import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/auction/services/auction_bloc.dart';
import 'package:mallow_wallet/features/auction/steps/auction_review_step.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart';
import 'package:mallow_wallet/features/sale/widgets/proceeds_breakdown.dart';

/// SOL-like token: 9 on-chain decimals so `950000000` renders as `0.95`.
const _token = MallowToken(
  symbol: 'SOL',
  mint: 'So11111111111111111111111111111111111111112',
  decimals: 9,
  inputDecimals: 4,
  minListingPrice: 10000000,
);

class _MockAuctionBloc extends MockBloc<AuctionEvent, AuctionState>
    implements AuctionBloc {}

void main() {
  ProceedsSplit split(
    ProceedsLabel label,
    String address,
    double pct,
    int amountRaw,
  ) => ProceedsSplit(
    label: label,
    address: address,
    proceedsPct: pct,
    amountRaw: amountRaw,
  );

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  group('ProceedsBreakdown percentage mode (priceRaw == null)', () {
    testWidgets('renders each split as N% and no token amounts', (
      tester,
    ) async {
      await pump(
        tester,
        ProceedsBreakdown(
          splits: [
            // 95.0 must render as "95", not "95.0"; 2.5 keeps its decimal.
            split(ProceedsLabel.creator, 'Cre1111111111111111111111', 95, 0),
            split(ProceedsLabel.you, 'Sel2222222222222222222222', 2.5, 0),
            split(ProceedsLabel.mallow, kMallowFeeAddress, 2.5, 0),
          ],
          token: _token,
          priceRaw: null,
        ),
      );

      expect(find.text('95%'), findsOneWidget);
      expect(find.text('2.5%'), findsNWidgets(2));
      // No absolute amounts, and no "editing" em-dash sentinel.
      expect(find.textContaining('SOL'), findsNothing);
      expect(find.text('—'), findsNothing);
    });
  });

  group('ProceedsBreakdown amount mode (priceRaw non-null)', () {
    testWidgets('renders token amounts derived from price (unchanged)', (
      tester,
    ) async {
      await pump(
        tester,
        ProceedsBreakdown(
          splits: [
            split(
              ProceedsLabel.creator,
              'Cre1111111111111111111111',
              95,
              950000000,
            ),
          ],
          token: _token,
          priceRaw: 1000000000, // 1 SOL
        ),
      );

      expect(find.text('0.95 SOL'), findsOneWidget);
      expect(find.text('95%'), findsNothing);
    });

    testWidgets('renders em-dash while price is still 0', (tester) async {
      await pump(
        tester,
        ProceedsBreakdown(
          splits: [
            split(ProceedsLabel.creator, 'Cre1111111111111111111111', 95, 0),
          ],
          token: _token,
          priceRaw: 0,
        ),
      );

      expect(find.text('—'), findsOneWidget);
    });
  });

  group('AuctionReviewStep', () {
    testWidgets('shows proceeds as percentages, not reserve-derived amounts '
        '(webapp parity: hammer price unknown at listing time)', (
      tester,
    ) async {
      // Primary sale, split enabled: after the 5% marketplace fee the whole
      // 95% goes to the single creator. Reserve is 1 SOL — if the widget
      // rendered amounts, the creator row would read "0.95 SOL".
      const seller = 'Sel2222222222222222222222';
      final state = const AuctionState().copyWith(
        userPubkey: seller,
        royaltyShares: const [
          ArtworkRoyaltySplit(
            address: 'Cre1111111111111111111111',
            sharePercent: 100,
          ),
        ],
        royaltyBps: 500,
        primaryFeeBps: 500,
        secondaryFeeBps: 250,
        reservePrice: 1000000000,
      );

      final bloc = _MockAuctionBloc();
      whenListen(bloc, const Stream<AuctionState>.empty(), initialState: state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlocProvider<AuctionBloc>.value(
              value: bloc,
              child: const AuctionReviewStep(),
            ),
          ),
        ),
      );

      expect(find.text('95%'), findsOneWidget);
      expect(find.text('5%'), findsOneWidget);
      // The reserve-derived amount must NOT appear in the proceeds rows.
      expect(find.text('0.95 SOL'), findsNothing);
    });
  });
}
