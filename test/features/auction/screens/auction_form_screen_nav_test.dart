import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/auction/screens/auction_form_screen.dart';
import 'package:mallow_wallet/features/auction/services/auction_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockAuctionBloc extends MockBloc<AuctionEvent, AuctionState>
    implements AuctionBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

void main() {
  late MockAuctionBloc mockBloc;
  late MockTokenBalanceBloc mockTokenBalanceBloc;
  late StreamController<AuctionState> stateController;

  final testArtwork = PortfolioArtwork(
    mintAccount: '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  // A valid review-step state entered from the artwork detail screen, so the
  // success body offers the View auction / Done CTAs.
  AuctionState reviewState({required AuctionFlowState flow}) => AuctionState(
    step: AuctionStep.review,
    entryFromArtworkDetail: true,
    selectedArtwork: testArtwork,
    reservePrice: 1000000000,
    flow: flow,
  );

  const signature = 'sig-1';

  setUp(() async {
    mockBloc = MockAuctionBloc();
    mockTokenBalanceBloc = MockTokenBalanceBloc();
    stateController = StreamController<AuctionState>.broadcast();

    // The form fires Listing analytics on the flow's terminal states. Register
    // an uninitialized AnalyticsService — track() no-ops (never calls init), so
    // it satisfies the sl<AnalyticsService>() lookup without network/config.
    if (!sl.isRegistered<AnalyticsService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(
          Dio(),
          await PreferencesService.create(),
          const FlutterSecureStorage(),
        ),
      );
    }

    final initial = reviewState(flow: const TxFlowIdle());
    whenListen(mockBloc, stateController.stream, initialState: initial);
    whenListen(
      mockTokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    if (sl.isRegistered<AuctionBloc>()) sl.unregister<AuctionBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
    sl.registerFactory<AuctionBloc>(() => mockBloc);
    sl.registerFactory<TokenBalanceBloc>(() => mockTokenBalanceBloc);
  });

  tearDown(() async {
    await stateController.close();
    if (sl.isRegistered<AuctionBloc>()) sl.unregister<AuctionBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
  });

  testWidgets(
    'a TxFlowSuccess → TxFlowSuccess (indexed-ack) transition does not '
    're-open the pipeline sheet',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AuctionFormScreen(mintAccount: testArtwork.mintAccount),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('New Auction'), findsOneWidget);

      // Broadcast succeeds: the listener opens the pipeline sheet once and it
      // swaps to its success body, presenting the "View auction" / "Done"
      // CTAs (navigation is now user-driven via these CTAs, not an automatic
      // pop chain).
      stateController.add(
        reviewState(
          flow: const TxFlowSuccess<void, AuctionSuccessData>(
            signature: signature,
            result: AuctionSuccessData(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('View auction'),
        findsOneWidget,
        reason: 'success shows the View auction CTA',
      );

      // The indexer ack lands: a second TxFlowSuccess with `indexed` flipped
      // null→true. It is structurally distinct (Equatable) but the same
      // runtimeType, so the form's `listenWhen` runtimeType guard must NOT
      // re-invoke the listener and stack a duplicate sheet. The success body
      // still rebuilds on the flip via its own BlocBuilder.
      stateController.add(
        reviewState(
          flow: const TxFlowSuccess<void, AuctionSuccessData>(
            signature: signature,
            result: AuctionSuccessData(indexed: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('View auction'),
        findsOneWidget,
        reason: 'the indexer-ack re-emit must not stack a second sheet',
      );
    },
  );

  // "Try again" on the auction pipeline dispatches `requestList` — it builds
  // and signs a brand-new listing transaction. So when the broadcast outcome is
  // unknown (`SolanaTransactionUnconfirmedException`: the blockhash expired
  // before we ever saw the transaction land) an enabled retry can put the same
  // artwork on the block twice, and "Listing failed" asserts something we do
  // not know. Determinate failures keep the retry — nothing moved, re-listing
  // is safe.
  group('unconfirmed broadcast', () {
    Future<void> pumpWithFlow(
      WidgetTester tester,
      AuctionFlowState flow,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AuctionFormScreen(mintAccount: testArtwork.mintAccount),
        ),
      );
      await tester.pumpAndSettle();
      stateController.add(reviewState(flow: flow));
      await tester.pumpAndSettle();
    }

    testWidgets('a determinate failure keeps the failure headline and offers a '
        'retry', (tester) async {
      await pumpWithFlow(
        tester,
        const TxFlowFailure<void, AuctionSuccessData>(
          AppFailure.rpc('Instruction 2 failed: Custom error 6003'),
        ),
      );

      expect(find.text('Listing failed'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      verify(() => mockBloc.add(const AuctionEvent.requestList())).called(1);
    });

    testWidgets('an unconfirmed broadcast is not framed as a failure and '
        'cannot be retried', (tester) async {
      await pumpWithFlow(
        tester,
        TxFlowFailure<void, AuctionSuccessData>(
          AppFailure.from(
            const SolanaTransactionUnconfirmedException('sigSTUCK'),
          ).prefixedWith('Listing failed'),
        ),
      );

      expect(find.text('Listing failed'), findsNothing);
      expect(find.text('Not confirmed yet'), findsOneWidget);
      // The exception's own copy points the user at Activity / the explorer and
      // must survive the bloc's prefixing verbatim.
      expect(find.textContaining('may still land'), findsOneWidget);

      // The button is still laid out (the sheet keeps a fixed footprint) but is
      // inert — tapping it must not sign a second listing.
      await tester.tap(find.text('Try again'), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => mockBloc.add(const AuctionEvent.requestList()));

      // …and the user is never stranded: Back still dismisses the sheet.
      await tester.tap(find.text('Back'));
      await tester.pump();
      verify(() => mockBloc.add(const AuctionEvent.dismissError())).called(1);
    });
  });

  // Pins the `listenWhen` guard directly. The widget test above is gated in
  // practice by the screen's `_sheetOpen` latch, so it stays green even if the
  // guard regresses to full equality; these assert the predicate itself.
  group('auctionFlowTypeChanged (listenWhen guard)', () {
    test('is false for an indexer-ack success→success re-emit '
        '(Equatable-distinct, same runtimeType)', () {
      final prev = reviewState(
        flow: const TxFlowSuccess<void, AuctionSuccessData>(
          signature: signature,
          result: AuctionSuccessData(),
        ),
      );
      final next = reviewState(
        flow: const TxFlowSuccess<void, AuctionSuccessData>(
          signature: signature,
          result: AuctionSuccessData(indexed: true),
        ),
      );
      // Precondition the guard relies on: the two successes are distinct
      // values (so a full-equality listenWhen WOULD re-fire) but share a
      // runtimeType.
      expect(prev.flow, isNot(next.flow));
      expect(prev.flow.runtimeType, next.flow.runtimeType);
      // So the guard suppresses the re-emit. Regressing to full equality
      // flips this to true and fails here.
      expect(auctionFlowTypeChanged(prev, next), isFalse);
    });

    test('is true when the flow crosses subtypes (idle→success)', () {
      final prev = reviewState(flow: const TxFlowIdle());
      final next = reviewState(
        flow: const TxFlowSuccess<void, AuctionSuccessData>(
          signature: signature,
          result: AuctionSuccessData(),
        ),
      );
      expect(auctionFlowTypeChanged(prev, next), isTrue);
    });
  });
}
