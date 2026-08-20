import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/market/widgets/market_confirmation_sheet.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mallow_wallet/shared/widgets/mallow_checkbox.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

Finder findSvgIcon(String assetPath) => find.byWidgetPredicate(
  (w) => w is MallowSvgIcon && w.assetPath == assetPath,
);

/// Fake API client — we never call any methods on it; the
/// [TokenPriceService] only hits the network in [TokenPriceService.start],
/// which we don't invoke in widget tests. Keeps `priceOf` returning
/// null so the USD subtitle is suppressed.
class _FakeMallowApiClient extends Fake implements MallowApiClient {}

void main() {
  late MockMarketBloc mockBloc;

  const testMintAccount = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const testTotalCostSol = 1.5;
  const testFeeLamports = 5000;
  const testArtworkTitle = 'Amazing NFT';
  const testTransactionBase64 =
      'AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAQAHCg==';

  setUpAll(() async {
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
    // FeeDetailsDisclosure (rendered inside the cost breakdown) reads the
    // shared "fee details expanded" preference from GetIt, so the sheet
    // can't mount without a registered PreferencesService.
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
  });

  late MockTokenBalanceBloc mockTokenBalanceBloc;

  setUp(() {
    mockBloc = MockMarketBloc();
    mockTokenBalanceBloc = MockTokenBalanceBloc();
    when(
      () => mockTokenBalanceBloc.state,
    ).thenReturn(const TokenBalanceState.initial());
  });

  Widget buildTestWidget({
    String actionType = 'buy',
    String mintAccount = testMintAccount,
    MarketPrice totalCost = const MarketPrice(
      rawAmount: testTotalCostSol * 1e9,
    ),
    int estimatedFeeLamports = testFeeLamports,
    String? artworkTitle,
    String? artworkImageUrl,
    MarketPrice? escrowedOfferAmount,
    int editionMintFeeLamports = 0,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: BlocProvider<MarketBloc>.value(
          value: mockBloc,
          child: MarketConfirmationSheet(
            actionType: actionType,
            mintAccount: mintAccount,
            totalCost: totalCost,
            estimatedFeeLamports: estimatedFeeLamports,
            tokenBalanceBloc: mockTokenBalanceBloc,
            artworkTitle: artworkTitle,
            artworkImageUrl: artworkImageUrl,
            escrowedOfferAmount: escrowedOfferAmount,
            editionMintFeeLamports: editionMintFeeLamports,
          ),
        ),
      ),
    );
  }

  // Helper to create a readyToSign state with all required fields
  MarketState readyToSignState({
    bool isSimulating = false,
    SimulationResult? simulationResult,
    String actionType = 'buy',
    AppFlow flow = AppFlow.fixedPriceBuy,
    MarketPrice totalCost = const MarketPrice(
      rawAmount: testTotalCostSol * 1e9,
    ),
    int? simulatedPayerLamportsDelta,
    int? mallowFeeLamports,
    SettleProceeds? settleProceeds,
    bool disablePrimarySplit = false,
    bool showDirectProceedsOption = false,
  }) {
    return TxFlowReady<MarketPrepData, MarketSuccessData>(
      MarketPrepData(
        transactionsBase64: [testTransactionBase64],
        mintAccount: testMintAccount,
        actionType: actionType,
        flow: flow,
        totalCost: totalCost,
        estimatedFeeLamports: testFeeLamports,
        isSimulating: isSimulating,
        simulationResult: simulationResult,
        simulatedPayerLamportsDelta: simulatedPayerLamportsDelta,
        mallowFeeLamports: mallowFeeLamports,
        settleProceeds: settleProceeds,
        disablePrimarySplit: disablePrimarySplit,
        showDirectProceedsOption: showDirectProceedsOption,
      ),
    );
  }

  group('MarketConfirmationSheet', () {
    group('renders correctly for buy', () {
      testWidgets('shows Confirm Purchase title for buy', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Confirm Purchase'), findsOneWidget);
      });

      testWidgets('shows Price label for buy', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Price'), findsOneWidget);
      });

      testWidgets('shows Buy Now button for buy', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Buy Now'), findsOneWidget);
      });

      testWidgets('shows price amount', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        // Price row uses PriceFormatter which truncates SOL to 3 display
        // decimals (per the token registry), so 1.5 SOL renders as
        // "1.5 SOL". The Total row aggregates price + fee for SOL
        // listings, so "1.5 SOL" should appear at least once.
        expect(find.textContaining('1.5 SOL'), findsAtLeast(1));
      });

      testWidgets('shows network fee', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Network Fee'), findsOneWidget);
        expect(find.textContaining('0.000005'), findsOneWidget);
      });

      testWidgets('omits the offer-only Solana rent line for buy', (
        tester,
      ) async {
        // The reclaimable rent is specific to the Offer PDA, which only the
        // make-offer flow opens — a buy must not surface it.
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Solana rent (reclaimable)'), findsNothing);
      });

      testWidgets('shows aggregate Total cost with a Fee details disclosure', (
        tester,
      ) async {
        // QA redesign: the summed total stays visible
        // while the per-line Price / Network Fee breakdown lives inside the
        // collapsible "Fee details" section.
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Total cost'), findsOneWidget);
        expect(find.text('Fee details'), findsOneWidget);
      });

      testWidgets('shows Cancel button', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('Cancel'), findsOneWidget);
      });
    });

    group('non-SOL listings', () {
      // 25 USDC = 25_000_000 atomic (USDC has 6 decimals per the registry).
      const usdcPrice = MarketPrice(
        rawAmount: 25_000_000,
        currencyMint:
            'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', // usdcMint
      );

      testWidgets('renders the listing currency symbol', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(totalCost: usdcPrice));
        await tester.pumpWidget(buildTestWidget(totalCost: usdcPrice));
        expect(find.textContaining('USDC'), findsAtLeast(1));
      });

      testWidgets('keeps Total cost in the listing currency (no SOL sum)', (
        tester,
      ) async {
        // For non-SOL listings the price + SOL fee can't be summed into
        // a single number, so "Total cost" shows the listing-currency
        // price and the SOL fee stays inside the Fee details disclosure.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(totalCost: usdcPrice));
        await tester.pumpWidget(buildTestWidget(totalCost: usdcPrice));
        expect(find.text('Total cost'), findsOneWidget);
        expect(find.text('Total'), findsNothing);
      });

      testWidgets('still renders network fee in SOL', (tester) async {
        // Network fees are always SOL regardless of listing currency.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(totalCost: usdcPrice));
        await tester.pumpWidget(buildTestWidget(totalCost: usdcPrice));
        expect(find.text('Network Fee'), findsOneWidget);
        expect(find.textContaining('0.000005'), findsOneWidget);
      });
    });

    group('renders correctly for offer', () {
      testWidgets('shows Make Offer title for offer', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'offer'));

        // The confirm step keeps the Make Offer title.
        expect(find.text('Place Offer'), findsOneWidget);
      });

      testWidgets('shows Offer Amount label for offer', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'offer'));

        expect(find.text('Offer Amount'), findsOneWidget);
      });

      testWidgets('shows Place Offer button for offer', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'offer'));

        expect(find.text('Make Offer'), findsOneWidget);
      });

      testWidgets('shows reclaimable Solana rent line for offer', (
        tester,
      ) async {
        // Making an offer prepays rent for the on-chain Offer PDA, which is
        // returned when the offer settles — so it surfaces as its own
        // reclaimable line inside the Fee details breakdown. 3,160,640
        // lamports renders as "-0.003161 SOL" at 6-decimal precision.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'offer'));

        expect(find.text('Solana rent (reclaimable)'), findsOneWidget);
        expect(find.textContaining('0.003161'), findsOneWidget);
      });
    });

    group('renders correctly for cancel-offer', () {
      testWidgets('shows Cancel Offer title and CTA', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'cancel-offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'cancel-offer'));

        expect(find.text('Cancel Offer'), findsAtLeastNWidgets(1));
      });

      testWidgets('shows returned Solana rent line for cancel-offer', (
        tester,
      ) async {
        // Cancelling closes the on-chain Offer PDA, returning its prepaid
        // rent to the buyer — so it surfaces as an incoming "+" line inside
        // the Fee details breakdown. 3,160,640 lamports renders as
        // "+0.003161 SOL" at 6-decimal precision.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'cancel-offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'cancel-offer'));

        expect(find.text('Solana rent (returned)'), findsOneWidget);
        expect(find.textContaining('0.003161'), findsOneWidget);
      });

      testWidgets('omits the reclaimable offer line for cancel-offer', (
        tester,
      ) async {
        // The "(reclaimable)" framing belongs to the make-offer flow; the
        // cancel flow must show the rent as returned, not prepaid.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'cancel-offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'cancel-offer'));

        expect(find.text('Solana rent (reclaimable)'), findsNothing);
      });

      testWidgets('sums offer and rent into the Total returned headline', (
        tester,
      ) async {
        // Cancelling returns the escrowed offer plus the Offer-PDA rent:
        // 1.5 SOL + 0.003160640 SOL = 1.503160640 SOL, which renders as
        // "+1.503 SOL" at the 3-decimal SOL display cap. The headline label
        // reframes the figure as money coming back, not a cost.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'cancel-offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'cancel-offer'));

        expect(find.text('Total returned'), findsOneWidget);
        expect(find.text('+1.503 SOL'), findsOneWidget);
      });

      testWidgets('renders the Total returned amount in the positive color', (
        tester,
      ) async {
        // The returned total is an inflow, so it's coloured with the
        // positive (green) accent rather than the default total accent.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'cancel-offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'cancel-offer'));

        final valueFinder = find.text('+1.503 SOL');
        final positive = tester.element(valueFinder).mallowColors.positive;
        final valueText = tester.widget<Text>(valueFinder);
        expect(valueText.style?.color, positive);
      });
    });

    group('artwork preview', () {
      testWidgets('shows artwork title when provided', (tester) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(
          buildTestWidget(artworkTitle: testArtworkTitle),
        );

        // Title appears as a TextSpan inside a Text.rich; matched via the
        // substring finder so the surrounding " / @username" or mint fragment
        // doesn't break the match.
        expect(find.textContaining(testArtworkTitle), findsOneWidget);
      });

      testWidgets('shows default Artwork text when title not provided', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(
          buildTestWidget(artworkImageUrl: 'https://x.com'),
        );

        expect(find.textContaining('Artwork'), findsOneWidget);
      });

      testWidgets(
        'omits secondary label when no username/name/creator are provided',
        (tester) async {
          when(() => mockBloc.state).thenReturn(readyToSignState());

          await tester.pumpWidget(
            buildTestWidget(artworkTitle: testArtworkTitle),
          );

          // The artwork mint is intentionally never used as a fallback —
          // creators are addressed by username, display name, or update
          // authority. Without any of those, the headline shows just the
          // title with no trailing " / …" fragment.
          expect(find.textContaining('9WzDXw'), findsNothing);
          expect(find.textContaining(' / '), findsNothing);
        },
      );

      testWidgets('hides artwork preview when no title or image', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());

        // Should not show the artwork preview section
        expect(find.text('Artwork'), findsNothing);
      });
    });

    group('simulation status', () {
      testWidgets('stays silent while simulation is in progress', (
        tester,
      ) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(isSimulating: true));

        await tester.pumpWidget(buildTestWidget());

        // The loading state is intentionally invisible so the review sheet
        // stays quiet for the happy path — the spinner only appears in the
        // burn-specific "Estimating SOL refund…" row, not at sheet level.
        expect(find.text('Simulating transaction...'), findsNothing);
      });

      testWidgets('stays silent when simulation succeeds', (tester) async {
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            simulationResult: const SimulationResult(
              success: true,
              unitsConsumed: 50000,
            ),
          ),
        );

        await tester.pumpWidget(buildTestWidget());

        // Success state is intentionally invisible.
        expect(findSvgIcon('assets/icons/checkmark.svg'), findsNothing);
      });

      testWidgets('shows warning when simulation fails', (tester) async {
        // Increase surface size to avoid overflow in test
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            simulationResult: const SimulationResult(
              success: false,
              error: 'Insufficient funds',
            ),
          ),
        );

        await tester.pumpWidget(
          buildTestWidget(artworkTitle: testArtworkTitle),
        );

        expect(findSvgIcon('assets/icons/alert_triangle.svg'), findsOneWidget);
        expect(find.text('Transaction may fail'), findsOneWidget);
        expect(find.text('Insufficient funds'), findsOneWidget);
      });
    });

    group('button states', () {
      testWidgets('disables Buy Now button when simulating', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(isSimulating: true));

        await tester.pumpWidget(buildTestWidget());

        // The Buy Now button should exist but be disabled
        final buyButton = find.widgetWithText(ElevatedButton, 'Buy Now');
        expect(buyButton, findsOneWidget);
      });

      // Note: signing/broadcasting are now owned by TransactionPipelineSheet,
      // not this sheet — the confirmation sheet pops on confirm.
    });

    group('interactions', () {
      testWidgets('adds confirmAndSign event when Buy Now is tapped', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(readyToSignState());

        await tester.pumpWidget(buildTestWidget());
        await tester.tap(find.text('Buy Now'));
        await tester.pump();

        verify(
          () => mockBloc.add(const MarketEvent.confirmAndSign()),
        ).called(1);
      });

      testWidgets('adds confirmAndSign event when Place Offer is tapped', (
        tester,
      ) async {
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'offer'));

        await tester.pumpWidget(buildTestWidget(actionType: 'offer'));
        await tester.tap(find.text('Place Offer'));
        await tester.pump();

        verify(
          () => mockBloc.add(const MarketEvent.confirmAndSign()),
        ).called(1);
      });
    });

    // Burn re-uses the same sheet but with a custom breakdown — no
    // listing currency / price row, plus a rent-refund line driven by
    // the bloc's simulated payer-balance delta. These tests guard the
    // breakdown contract because the wiring crosses bloc → widget.
    group('renders correctly for burn', () {
      const totalCostZero = MarketPrice(rawAmount: 0);

      testWidgets('shows Burn Artwork title and CTA', (tester) async {
        when(() => mockBloc.state).thenReturn(
          readyToSignState(actionType: 'burn', totalCost: totalCostZero),
        );

        await tester.pumpWidget(
          buildTestWidget(actionType: 'burn', totalCost: totalCostZero),
        );

        expect(find.text('Burn Artwork'), findsAtLeastNWidgets(1));
      });

      testWidgets(
        "renders rent-refund row and 'You'll receive' total when delta is positive",
        (tester) async {
          // 0.002 SOL gross rent reclaim minus the ~0.000005 SOL fee
          // leaves ~0.001995 SOL net — matches the (net + fee) maths in
          // _buildBurnBreakdown.
          when(() => mockBloc.state).thenReturn(
            readyToSignState(
              actionType: 'burn',
              flow: AppFlow.nftBurn,
              totalCost: totalCostZero,
              simulatedPayerLamportsDelta: 1_995_000,
            ),
          );

          await tester.pumpWidget(
            buildTestWidget(actionType: 'burn', totalCost: totalCostZero),
          );

          expect(find.text('Network fee'), findsOneWidget);
          expect(find.text('Rent reclaimed'), findsOneWidget);
          expect(find.text("You'll receive"), findsOneWidget);
        },
      );

      testWidgets(
        'falls back to fee-only layout with spinner while simulating',
        (tester) async {
          when(() => mockBloc.state).thenReturn(
            readyToSignState(
              actionType: 'burn',
              flow: AppFlow.nftBurn,
              totalCost: totalCostZero,
              isSimulating: true,
            ),
          );

          await tester.pumpWidget(
            buildTestWidget(actionType: 'burn', totalCost: totalCostZero),
          );

          expect(find.text('Network fee'), findsOneWidget);
          expect(find.text('Estimating SOL refund…'), findsOneWidget);
          // No misleading "You'll receive" row until the delta lands.
          expect(find.text("You'll receive"), findsNothing);
          expect(find.text('Rent reclaimed'), findsNothing);
        },
      );

      testWidgets('omits rent-reclaim rows when delta is non-positive', (
        tester,
      ) async {
        // Rare but possible — the asset has no rent left to reclaim.
        // We should not surface a negative or zero "you'll receive"
        // figure; fall back to the fee-only layout.
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'burn',
            flow: AppFlow.nftBurn,
            totalCost: totalCostZero,
            simulatedPayerLamportsDelta: 0,
          ),
        );

        await tester.pumpWidget(
          buildTestWidget(actionType: 'burn', totalCost: totalCostZero),
        );

        expect(find.text('Network fee'), findsOneWidget);
        expect(find.text('Rent reclaimed'), findsNothing);
        expect(find.text("You'll receive"), findsNothing);
      });

      testWidgets(
        'shimmers the Network fee while the burn tx is still preparing',
        (tester) async {
          // The burn flow opens this sheet immediately on tap — before the burn
          // tx is built — so the fee isn't known yet. It must shimmer (not
          // render a placeholder "0"), the refund figures stay hidden until the
          // post-Ready simulation runs, and the CTA is disabled — you can't sign
          // a tx that doesn't exist yet.
          when(() => mockBloc.state).thenReturn(
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          );

          await tester.pumpWidget(
            buildTestWidget(actionType: 'burn', totalCost: totalCostZero),
          );

          // Label stays visible above its shimmering value.
          expect(find.text('Network fee'), findsOneWidget);
          expect(find.byType(ShimmerBox), findsAtLeast(1));
          // No refund figures until the simulation lands.
          expect(find.text("You'll receive"), findsNothing);
          expect(find.text('Rent reclaimed'), findsNothing);
          expect(find.text('Estimating SOL refund…'), findsNothing);
          // CTA disabled until the prepared tx arrives.
          final cta = tester.widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Burn Artwork'),
          );
          expect(cta.onPressed, isNull);
        },
      );
    });

    // Edition buys carry a flat on-chain "mallow fee" (the print fee) on top
    // of the listing price, broken out as its own line. The remaining SOL
    // cost (rent + protocol + tx fee) collapses into "Network fee", derived
    // from the simulated payer-balance delta. Presence of `mallowFeeLamports`
    // is what switches the sheet into this edition layout.
    group('renders correctly for edition buy', () {
      const printFeeLamports = 11_000_000; // 0.011 SOL, the default print fee.

      testWidgets('shows a mallow fee line on top of the listing price', (
        tester,
      ) async {
        // price 1.5 SOL + 0.011 mallow fee + 0.002 network = 1.513 SOL total.
        // delta is the net SOL spent: -(price + mallow + network).
        const network = 2_000_000;
        const delta = -(1_500_000_000 + printFeeLamports + network);
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            mallowFeeLamports: printFeeLamports,
            simulatedPayerLamportsDelta: delta,
          ),
        );

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('mallow fee'), findsOneWidget);
        // 0.011 SOL print fee, rendered at 6-decimal fee precision.
        expect(find.textContaining('0.011'), findsOneWidget);
        // Network fee is everything else the simulation says the payer spends.
        expect(find.text('Network fee'), findsOneWidget);
        expect(find.textContaining('0.002'), findsOneWidget);
        // Headline sums price + mallow fee + network for SOL listings.
        expect(find.text('1.513 SOL'), findsOneWidget);
      });

      testWidgets('shimmers the network fee while simulation is in flight', (
        tester,
      ) async {
        // No delta yet — the mallow fee is known immediately, but the network
        // estimate (and headline total) wait on the simulation.
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            mallowFeeLamports: printFeeLamports,
            isSimulating: true,
          ),
        );

        await tester.pumpWidget(buildTestWidget());

        expect(find.text('mallow fee'), findsOneWidget);
        expect(find.text('Network fee'), findsOneWidget);
      });

      testWidgets('keeps Total cost in the listing currency for token '
          'editions', (tester) async {
        // 25 USDC edition: the price is paid in the token, so only the SOL
        // mallow fee + network land in the disclosure, and the headline stays
        // in USDC rather than summing across currencies.
        const usdcPrice = MarketPrice(
          rawAmount: 25_000_000,
          currencyMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        );
        const network = 2_000_000;
        const delta = -(printFeeLamports + network); // price not in SOL.
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            totalCost: usdcPrice,
            mallowFeeLamports: printFeeLamports,
            simulatedPayerLamportsDelta: delta,
          ),
        );

        await tester.pumpWidget(buildTestWidget(totalCost: usdcPrice));

        expect(find.text('mallow fee'), findsOneWidget);
        expect(find.text('Network fee'), findsOneWidget);
        // Headline stays the token price — no SOL sum.
        expect(find.textContaining('USDC'), findsAtLeast(1));
        expect(find.text('Total cost'), findsOneWidget);
      });
    });

    group('renders correctly for settle-auction', () {
      // Seller settling a 2 SOL winning bid: 0.1 SOL mallow fee + 0.2 SOL
      // royalties to OTHER creators leaves the seller 1.7 SOL. Amounts are
      // resolved (simulation has landed).
      const sellerProceeds = SettleProceeds(
        grossBidRaw: 2_000_000_000,
        currencyMint: null, // SOL
        marketFeeRaw: 100_000_000,
        royaltiesToOthersRaw: 200_000_000,
        sellerEarningsRaw: 1_700_000_000,
      );

      testWidgets('shows the seller earnings headline and fee breakdown', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'settle-auction',
            settleProceeds: sellerProceeds,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'settle-auction'));

        // Headline is the seller's net take, not the gross winning bid.
        expect(find.text("You'll receive"), findsOneWidget);
        expect(find.textContaining('1.7 SOL'), findsAtLeast(1));
        // Disclosure itemises the deductions — "mallow fee", not "Market fee".
        expect(find.text('Winning bid'), findsOneWidget);
        expect(find.text('mallow fee'), findsOneWidget);
        expect(find.text('Creator royalties'), findsOneWidget);
        expect(find.text('Network fee'), findsOneWidget);
      });

      testWidgets('renders sub-unit amounts for a 0-input-decimal token', (
        tester,
      ) async {
        // Regression: SMORES lists in whole numbers (inputDecimals: 0), so a
        // 1 SMORES bid splitting into 0.93 / 0.02 / 0.05 was truncating every
        // fractional line to "0". The breakdown must render at the token's
        // on-chain precision.
        const smoresMint = 'smoEhMZMweWBnpd1QoU4ZjuVNBxMFchqy4NRMBbtW7V';
        const smoresProceeds = SettleProceeds(
          grossBidRaw: 1_000_000, // 1 SMORES (6 decimals)
          currencyMint: smoresMint,
          marketFeeRaw: 20_000, // 0.02
          royaltiesToOthersRaw: 50_000, // 0.05
          sellerEarningsRaw: 930_000, // 0.93
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'settle-auction',
            settleProceeds: smoresProceeds,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'settle-auction'));

        expect(find.textContaining('0.93 SMORES'), findsOneWidget);
        expect(find.textContaining('0.02 SMORES'), findsOneWidget);
        expect(find.textContaining('0.05 SMORES'), findsOneWidget);
        expect(find.textContaining('1 SMORES'), findsOneWidget);
      });

      testWidgets('omits the Royalties line when none go to other creators', (
        tester,
      ) async {
        // Sole-creator / primary sale: the seller keeps all royalties, so
        // there is nothing to deduct and the line must not appear.
        const noOtherRoyalties = SettleProceeds(
          grossBidRaw: 2_000_000_000,
          marketFeeRaw: 100_000_000,
          royaltiesToOthersRaw: 0,
          sellerEarningsRaw: 1_900_000_000,
          currencyMint: null,
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'settle-auction',
            settleProceeds: noOtherRoyalties,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'settle-auction'));

        expect(find.text("You'll receive"), findsOneWidget);
        expect(find.text('Creator royalties'), findsNothing);
      });

      testWidgets(
        'shimmers earnings + fee while the simulation is unresolved',
        (tester) async {
          // Before the sim lands only the gross winning bid is known — the
          // earnings + mallow fee shimmer rather than showing a wrong 0.
          const pending = SettleProceeds(
            grossBidRaw: 1_000_000,
            currencyMint:
                'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', // USDC
          );
          when(() => mockBloc.state).thenReturn(
            readyToSignState(
              actionType: 'settle-auction',
              settleProceeds: pending,
              isSimulating: true,
            ),
          );

          await tester.pumpWidget(
            buildTestWidget(actionType: 'settle-auction'),
          );

          // Labels render even while their values shimmer.
          expect(find.text("You'll receive"), findsOneWidget);
          expect(find.text('Winning bid'), findsOneWidget);
          expect(find.text('mallow fee'), findsOneWidget);
          // No royalties line until amounts resolve.
          expect(find.text('Creator royalties'), findsNothing);
        },
      );

      testWidgets('falls back to a gas-only row when there are no proceeds', (
        tester,
      ) async {
        // Winner-claim and no-bid settles carry no proceeds data — the sheet
        // shows only the network fee, never an earnings headline.
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(actionType: 'settle-auction'));

        await tester.pumpWidget(buildTestWidget(actionType: 'settle-auction'));

        expect(find.text('Network Fee'), findsOneWidget);
        expect(find.text("You'll receive"), findsNothing);
      });

      testWidgets(
        "shimmers the You'll receive line while the settle tx is still preparing",
        (tester) async {
          // Settle opened immediately on tap (artwork screen) — before
          // TxFlowReady the proceeds aren't resolved, so the earnings headline
          // is a skeleton (built from the known gross winning bid passed as
          // totalCost) and the CTA is disabled until the tx is ready.
          when(() => mockBloc.state).thenReturn(
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          );

          await tester.pumpWidget(
            buildTestWidget(actionType: 'settle-auction'),
          );

          expect(find.text("You'll receive"), findsOneWidget);
          expect(find.byType(ShimmerBox), findsAtLeast(1));
          final cta = tester.widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Settle'),
          );
          expect(cta.onPressed, isNull);
        },
      );
    });

    // Accepting an offer pays the seller the offer amount minus the mallow fee
    // and creator royalties — the same simulation-resolved split as an auction
    // settle, surfaced through the shared _buildSettleBreakdown. Presence of
    // settleProceeds switches the sheet into the itemised "You'll receive"
    // layout; without it the sheet falls back to the gross price breakdown.
    group('renders correctly for accept-offer', () {
      // Seller accepting a 1.5 SOL offer: 0.075 SOL mallow fee + 0.15 SOL
      // royalties to OTHER creators leaves the seller 1.275 SOL. Resolved.
      const sellerProceeds = SettleProceeds(
        grossBidRaw: 1_500_000_000,
        currencyMint: null, // SOL
        marketFeeRaw: 75_000_000,
        royaltiesToOthersRaw: 150_000_000,
        sellerEarningsRaw: 1_275_000_000,
      );

      testWidgets('shows the seller earnings headline and fee breakdown', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'accept-offer',
            settleProceeds: sellerProceeds,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

        // Headline is the seller's net take, not the gross offer.
        expect(find.text("You'll receive"), findsOneWidget);
        expect(find.textContaining('1.275 SOL'), findsAtLeast(1));
        // Disclosure itemises the deductions — gross line is "Offer amount",
        // not "Winning bid".
        expect(find.text('Offer amount'), findsOneWidget);
        expect(find.text('Winning bid'), findsNothing);
        expect(find.text('mallow fee'), findsOneWidget);
        expect(find.text('Creator royalties'), findsOneWidget);
        expect(find.text('Network fee'), findsOneWidget);
      });

      testWidgets(
        'shows the "Direct all proceeds to creators" toggle and dispatches '
        'setAcceptOfferSplit with a flipped disablePrimarySplit',
        (tester) async {
          when(() => mockBloc.state).thenReturn(
            readyToSignState(
              actionType: 'accept-offer',
              settleProceeds: sellerProceeds,
              // Default: the split is disabled, so the checkbox reads unchecked
              // ("direct to creators" == !disablePrimarySplit).
              disablePrimarySplit: true,
              showDirectProceedsOption: true,
            ),
          );

          await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

          expect(find.text('Direct all proceeds to creators'), findsOneWidget);

          // Tapping dispatches the dedicated toggle event — the bloc re-prepares
          // from its stored args, so the sheet no longer reconstructs the full
          // accept event from display-only prep fields.
          await tester.tap(find.text('Direct all proceeds to creators'));
          await tester.pump();

          verify(
            () => mockBloc.add(
              const MarketEvent.setAcceptOfferSplit(disablePrimarySplit: false),
            ),
          ).called(1);
        },
      );

      testWidgets(
        'keeps the toggle visible (disabled) while a re-prepare is in flight '
        '(R4) — TxFlowPreparing carries no prep, but the last gate + value are '
        'cached so the control the user tapped never vanishes mid-round-trip',
        (tester) async {
          // Start at a resolved accept-offer ready with the toggle shown.
          whenListen(
            mockBloc,
            Stream<MarketState>.fromIterable([
              readyToSignState(
                actionType: 'accept-offer',
                settleProceeds: sellerProceeds,
                disablePrimarySplit: true,
                showDirectProceedsOption: true,
              ),
              // The toggle tap drives the bloc into Preparing (prep == null).
              const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            ]),
            initialState: readyToSignState(
              actionType: 'accept-offer',
              settleProceeds: sellerProceeds,
              disablePrimarySplit: true,
              showDirectProceedsOption: true,
            ),
          );

          await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));
          await tester.pump(); // drain the Preparing emission.

          // Still visible after the state dropped to Preparing.
          expect(find.text('Direct all proceeds to creators'), findsOneWidget);
          // ...but disabled: a toggle is only actionable from a resolved ready.
          final checkbox = tester.widget<MallowCheckbox>(
            find.byType(MallowCheckbox),
          );
          expect(checkbox.enabled, isFalse);
        },
      );

      testWidgets('hides the toggle when showDirectProceedsOption is false', (
        tester,
      ) async {
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'accept-offer',
            settleProceeds: sellerProceeds,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

        expect(find.text('Direct all proceeds to creators'), findsNothing);
      });

      testWidgets('omits the Royalties line when none go to other creators', (
        tester,
      ) async {
        // Sole-creator / primary sale: the seller keeps all royalties, so
        // there is nothing to deduct and the line must not appear.
        const noOtherRoyalties = SettleProceeds(
          grossBidRaw: 1_500_000_000,
          marketFeeRaw: 75_000_000,
          royaltiesToOthersRaw: 0,
          sellerEarningsRaw: 1_425_000_000,
          currencyMint: null,
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            actionType: 'accept-offer',
            settleProceeds: noOtherRoyalties,
          ),
        );

        await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

        expect(find.text("You'll receive"), findsOneWidget);
        expect(find.text('Creator royalties'), findsNothing);
      });

      testWidgets(
        'falls back to the gross price breakdown when there are no proceeds',
        (tester) async {
          // Proceeds-account resolution failed at prep time — the sheet still
          // renders, but without the fee/royalty itemisation it shows the gross
          // offer under the "You'll receive" headline.
          when(
            () => mockBloc.state,
          ).thenReturn(readyToSignState(actionType: 'accept-offer'));

          await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

          expect(find.text("You'll receive"), findsOneWidget);
          expect(find.text('Offer Amount'), findsOneWidget);
          // No fee/royalty breakdown without resolved proceeds.
          expect(find.text('mallow fee'), findsNothing);
          expect(find.text('Creator royalties'), findsNothing);
        },
      );

      testWidgets(
        "shimmers the You'll receive line while the tx is still preparing",
        (tester) async {
          // The Offers screen opens this sheet immediately on tap, before the
          // accept-offer tx is built. Until TxFlowReady the seller's take isn't
          // known, so the headline renders as a skeleton (not a placeholder
          // zero) and the CTA is disabled — you can't sign a tx that doesn't
          // exist yet.
          when(() => mockBloc.state).thenReturn(
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          );

          await tester.pumpWidget(buildTestWidget(actionType: 'accept-offer'));

          // Label stays visible above its shimmering value.
          expect(find.text("You'll receive"), findsOneWidget);
          expect(find.byType(ShimmerBox), findsAtLeast(1));
          // CTA disabled until the prepared tx arrives.
          final cta = tester.widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Accept Offer'),
          );
          expect(cta.onPressed, isNull);
        },
      );
    });
  });

  // Updating an offer must gate on the *delta*, not the full new price.
  //
  // "Update offer" re-uses the `offer` action type: the backend builder emits
  // an `updateOffer` re-bid when the buyer already has one, and that only moves
  // the difference on-chain — the existing amount stays escrowed in the Offer
  // PDA. Demanding the whole new price in free balance makes a raise
  // impossible for anyone whose funds are already committed, leaving
  // cancel-and-re-offer (which forfeits queue position) as the only route.
  // Webapp parity: `useUpdateOffer` gates on
  // `balanceByMint[mint] > price - offer.price`.
  group('update-offer balance requirement', () {
    const sol = 'So11111111111111111111111111111111111111112';
    MarketPrice solPrice(double amount) =>
        MarketPrice(rawAmount: amount * 1e9, currencyMint: sol);

    group('marketRequiredRawAmount', () {
      test(
        'raising 5 SOL → 6 SOL requires only the 1 SOL difference, so a wallet '
        'with 1.2 SOL free can raise instead of being told it needs 6',
        () {
          expect(
            marketRequiredRawAmount(
              actionType: 'offer',
              totalCost: solPrice(6),
              escrowedOfferAmount: solPrice(5),
            ),
            1000000000,
          );
        },
      );

      test('lowering 5 SOL → 4 SOL carries no payment requirement — the chain '
          'refunds the difference, it never asks for one', () {
        expect(
          marketRequiredRawAmount(
            actionType: 'offer',
            totalCost: solPrice(4),
            escrowedOfferAmount: solPrice(5),
          ),
          0,
        );
      });

      test(
        'a first offer (nothing escrowed) still requires the full amount',
        () {
          expect(
            marketRequiredRawAmount(
              actionType: 'offer',
              totalCost: solPrice(6),
            ),
            6000000000,
          );
        },
      );

      test(
        'an escrowed offer in a different currency is not subtracted — the two '
        'amounts are denominated in different mints and are not comparable',
        () {
          expect(
            marketRequiredRawAmount(
              actionType: 'offer',
              totalCost: solPrice(6),
              escrowedOfferAmount: const MarketPrice(
                rawAmount: 5000000,
                currencyMint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
              ),
            ),
            6000000000,
          );
        },
      );

      test(
        'the escrow discount is scoped to offers — a buy is never an update, '
        'so it must keep requiring the full price',
        () {
          expect(
            marketRequiredRawAmount(
              actionType: 'buy',
              totalCost: solPrice(6),
              escrowedOfferAmount: solPrice(5),
            ),
            6000000000,
          );
        },
      );

      test('gas-only actions stay ungated', () {
        expect(
          marketRequiredRawAmount(
            actionType: 'cancel-offer',
            totalCost: solPrice(6),
          ),
          isNull,
        );
      });
    });

    testWidgets(
      'raising an offer from 5 to 6 SOL goes through with 1.2 SOL free — the '
      'escrowed 5 SOL is already committed and must not be demanded twice',
      (tester) async {
        whenListen(
          mockTokenBalanceBloc,
          const Stream<TokenBalanceState>.empty(),
          initialState: TokenBalanceState.loaded(
            tokens: [TokenBalance.nativeSol(lamports: (1.2 * 1e9).round())],
            totalUsdValue: 0,
            address: 'W1',
          ),
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(actionType: 'offer', totalCost: solPrice(6)),
        );

        await tester.pumpWidget(
          buildTestWidget(
            actionType: 'offer',
            totalCost: solPrice(6),
            escrowedOfferAmount: solPrice(5),
          ),
        );
        await tester.tap(find.text('Place Offer'));
        await tester.pump();

        verify(
          () => mockBloc.add(const MarketEvent.confirmAndSign()),
        ).called(1);
      },
    );

    testWidgets(
      'a genuinely unaffordable raise is still blocked — the delta rule '
      'relaxes the amount required, it does not remove the gate',
      (tester) async {
        whenListen(
          mockTokenBalanceBloc,
          const Stream<TokenBalanceState>.empty(),
          initialState: TokenBalanceState.loaded(
            tokens: [TokenBalance.nativeSol(lamports: (0.2 * 1e9).round())],
            totalUsdValue: 0,
            address: 'W1',
          ),
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(actionType: 'offer', totalCost: solPrice(6)),
        );

        await tester.pumpWidget(
          buildTestWidget(
            actionType: 'offer',
            totalCost: solPrice(6),
            escrowedOfferAmount: solPrice(5),
          ),
        );
        await tester.tap(find.text('Place Offer'));
        await tester.pump();

        verifyNever(() => mockBloc.add(const MarketEvent.confirmAndSign()));
      },
    );
  });

  // An edition print mints a fresh asset: beyond the listing price the
  // buyer pays the standard's rent + Metaplex protocol fee (+ the buyer's ATA
  // on the legacy standard) and the flat marketplace print fee — 0.015–0.033
  // SOL, all of it in SOL. The gate used to see only the 0.001 SOL reserve, so
  // a wallet that could pay the price but not the fee was waved through to a
  // signature that could only fail on-chain; on an SPL-priced edition the gap
  // was the entire fee. Webapp parity: `useBuyNow`'s `requiredSolLamports`.
  group('edition mint fee in the balance gate', () {
    const sol = 'So11111111111111111111111111111111111111112';
    const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
    MarketPrice solPrice(double amount) =>
        MarketPrice(rawAmount: amount * 1e9, currencyMint: sol);

    group('marketAdditionalSolLamports', () {
      test('an edition buy requires the print fee AND the per-print rent', () {
        expect(
          marketAdditionalSolLamports(
            actionType: 'buy',
            prepMallowFeeLamports: 11000000,
            editionMintFeeLamports: 4000000,
          ),
          15000000,
        );
      });

      test('a 1/1 buy mints nothing — no print fee prepared, so nothing extra '
          'is required even if the host quoted a fee', () {
        expect(
          marketAdditionalSolLamports(
            actionType: 'buy',
            prepMallowFeeLamports: null,
            editionMintFeeLamports: 4000000,
          ),
          0,
        );
      });

      test('non-buy actions never carry a mint fee', () {
        expect(
          marketAdditionalSolLamports(
            actionType: 'offer',
            prepMallowFeeLamports: 11000000,
            editionMintFeeLamports: 4000000,
          ),
          0,
        );
      });
    });

    testWidgets(
      'an edition buy priced in USDC is blocked when the wallet holds the USDC '
      'and the gas reserve but not the SOL mint fee',
      (tester) async {
        const price = MarketPrice(rawAmount: 10000000, currencyMint: usdc);
        whenListen(
          mockTokenBalanceBloc,
          const Stream<TokenBalanceState>.empty(),
          initialState: TokenBalanceState.loaded(
            tokens: [
              TokenBalance.nativeSol(lamports: 1000000),
              const TokenBalance(
                mint: usdc,
                symbol: 'USDC',
                name: 'USD Coin',
                decimals: 6,
                rawBalance: 10000000,
                uiBalance: 10,
              ),
            ],
            totalUsdValue: 0,
            address: 'W1',
          ),
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            flow: AppFlow.editionBuy,
            totalCost: price,
            mallowFeeLamports: 11000000,
          ),
        );

        await tester.pumpWidget(
          buildTestWidget(totalCost: price, editionMintFeeLamports: 4000000),
        );
        await tester.tap(find.text('Buy Now'));
        await tester.pump();

        verifyNever(() => mockBloc.add(const MarketEvent.confirmAndSign()));
      },
    );

    testWidgets(
      'the same buy goes through once the wallet holds the mint fee in SOL',
      (tester) async {
        const price = MarketPrice(rawAmount: 10000000, currencyMint: usdc);
        whenListen(
          mockTokenBalanceBloc,
          const Stream<TokenBalanceState>.empty(),
          initialState: TokenBalanceState.loaded(
            tokens: [
              TokenBalance.nativeSol(lamports: 1000000 + 15000000),
              const TokenBalance(
                mint: usdc,
                symbol: 'USDC',
                name: 'USD Coin',
                decimals: 6,
                rawBalance: 10000000,
                uiBalance: 10,
              ),
            ],
            totalUsdValue: 0,
            address: 'W1',
          ),
        );
        when(() => mockBloc.state).thenReturn(
          readyToSignState(
            flow: AppFlow.editionBuy,
            totalCost: price,
            mallowFeeLamports: 11000000,
          ),
        );

        await tester.pumpWidget(
          buildTestWidget(totalCost: price, editionMintFeeLamports: 4000000),
        );
        await tester.tap(find.text('Buy Now'));
        await tester.pump();

        verify(
          () => mockBloc.add(const MarketEvent.confirmAndSign()),
        ).called(1);
      },
    );

    testWidgets(
      'a 1/1 buy is unaffected — no print fee on the prepared tx, so a wallet '
      'holding price + reserve still confirms',
      (tester) async {
        whenListen(
          mockTokenBalanceBloc,
          const Stream<TokenBalanceState>.empty(),
          initialState: TokenBalanceState.loaded(
            tokens: [
              TokenBalance.nativeSol(lamports: (1 * 1e9).round() + 1000000),
            ],
            totalUsdValue: 0,
            address: 'W1',
          ),
        );
        when(
          () => mockBloc.state,
        ).thenReturn(readyToSignState(totalCost: solPrice(1)));

        await tester.pumpWidget(buildTestWidget(totalCost: solPrice(1)));
        await tester.tap(find.text('Buy Now'));
        await tester.pump();

        verify(
          () => mockBloc.add(const MarketEvent.confirmAndSign()),
        ).called(1);
      },
    );
  });
}
