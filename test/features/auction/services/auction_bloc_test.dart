import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/stale_tx_tracker.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/core/services/transaction_signing.dart'
    show addressLookupTableProgramId;
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkDetails, ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/auction/data/auction_repository.dart';
import 'package:mallow_wallet/features/auction/data/rewards_repository.dart';
import 'package:mallow_wallet/features/auction/services/auction_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/sale/services/marketplace_config_service.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'auction_bloc_test.mocks.dart';

/// Minimal fake: the auction indexed-ack fires `publishLocal` to refresh
/// subscribed screens. These flow tests only need it to no-op.
class _NoopMarketRealtime extends Fake implements MarketRealtimeService {
  @override
  void publishLocal({
    required String mintAccount,
    required String signature,
    required List<String> programs,
    int slot = 0,
  }) {}
}

@GenerateMocks([
  AuctionRepository,
  RewardsRepository,
  WalletManager,
  DasApiService,
  ArtworkRepository,
  AuthService,
  TransactionExecutor,
  TransactionPipeline,
  MarketplaceConfigService,
])
void main() {
  late MockAuctionRepository mockAuctionRepo;
  late MockRewardsRepository mockRewardsRepo;
  late MockWalletManager mockWalletManager;
  late MockDasApiService mockDasApi;
  late MockArtworkRepository mockArtworkRepo;
  late MockAuthService mockAuth;
  late MockTransactionExecutor mockExecutor;
  late MockTransactionPipeline mockPipeline;
  late MockMarketplaceConfigService mockMarketplaceConfig;

  const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';
  // Real wire-format transactions rather than opaque strings, so the two
  // members of a setup+auction batch are byte-distinct and the assertions
  // below can pin ORDER, not just length. The executor is mocked, so the
  // bytes never have to be on-chain-valid — only different from each other.
  final testTxBase64 = _buildParseableTxBase64(testWalletAddress);

  // Stands in for the address-lookup-table `setupTx` the backend attaches to a
  // cNFT auction whose settle would not fit the packet raw.
  final setupTxBase64 = _buildParseableTxBase64(testWalletAddress, lamports: 2);

  // The real thing: a `setupTx` that CREATES the lookup table, before and
  // after the backend recompiles it against a live slot. Only `recent_slot`
  // differs — which is the whole point of the bug below. A client-side
  // blockhash refresh cannot tell the dead one from the live one.
  final staleLutSetupTx = _lutSetupTxBase64(
    testWalletAddress,
    recentSlot: 400000000,
  );
  final freshLutSetupTx = _lutSetupTxBase64(
    testWalletAddress,
    recentSlot: 400000512,
  );

  /// The `{ result: { tx, setupTx? } }` envelope `POST /v2/tx/auctions/create`
  /// answers with. [setupTx] is null for every non-compressed listing.
  ApiResponse<UnsignedTxWithSetupResponse> createAuctionResponse({
    String? setupTx,
  }) => ApiResponse<UnsignedTxWithSetupResponse>(
    result: UnsignedTxWithSetupResponse(tx: testTxBase64, setupTx: setupTx),
  );

  final testArtwork = PortfolioArtwork(
    mintAccount: '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  // A reserve price comfortably above any token's minimum so the pricing
  // validator passes — the value itself is irrelevant to the flow tests, we
  // just need `pricingError == null` so requestList reaches the executor.
  const validReservePrice = 1000000000000;

  setUpAll(() {
    // mockito needs a dummy for the executor's non-nullable Result return
    // type even though every called path is explicitly stubbed.
    provideDummy<Result<String, AppFailure>>(const ResultSuccess(''));
    // `ApiResponse` is a freezed *sealed* class, so mockito cannot synthesise
    // a smart fake for the create-auction envelope on its own.
    provideDummy<ApiResponse<UnsignedTxWithSetupResponse>>(
      createAuctionResponse(),
    );
  });

  setUp(() {
    mockAuctionRepo = MockAuctionRepository();
    mockRewardsRepo = MockRewardsRepository();
    mockWalletManager = MockWalletManager();
    mockDasApi = MockDasApiService();
    mockArtworkRepo = MockArtworkRepository();
    mockAuth = MockAuthService();
    mockExecutor = MockTransactionExecutor();
    mockPipeline = MockTransactionPipeline();
    mockMarketplaceConfig = MockMarketplaceConfigService();

    when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => true);
    when(mockMarketplaceConfig.get()).thenAnswer(
      (_) async =>
          (primaryBps: 500, secondaryBps: 250, printFeeLamports: 11000000),
    );
  });

  // Real [MarketplaceActionFlow] over the same mocked low-level services the
  // bloc used directly before the flow was extracted — keeps these tests
  // exercising the actual execute/poll path (not a mocked seam) so behavior
  // parity holds.
  // AuthService is not used in the auction execute path (no requireWallet check);
  // it's injected purely to satisfy the constructor.
  MarketplaceActionFlow makeFlow() =>
      MarketplaceActionFlow(mockAuth, mockExecutor, mockPipeline);

  AuctionBloc buildBloc() => AuctionBloc(
    mockAuctionRepo,
    mockRewardsRepo,
    mockWalletManager,
    mockDasApi,
    mockArtworkRepo,
    makeFlow(),
    _NoopMarketRealtime(),
    TxLandedSlots(),
    mockMarketplaceConfig,
  );

  AuctionState validSeed() => AuctionState(
    userPubkey: testWalletAddress,
    selectedArtwork: testArtwork,
    reservePrice: validReservePrice,
  );

  /// Stub the executor to walk a successful tx through the awaiting-approval →
  /// broadcasting stages and return the on-chain signature.
  void stubExecutorSuccess() {
    when(
      mockAuctionRepo.getCreateAuctionTx(any),
    ).thenAnswer((_) async => createAuctionResponse());
    when(
      mockExecutor.execute(
        txsBase64: anyNamed('txsBase64'),
        usdValue: anyNamed('usdValue'),
        flow: anyNamed('flow'),
        tracker: anyNamed('tracker'),
        onStage: anyNamed('onStage'),
        useLedger: anyNamed('useLedger'),
        additionalSigners: anyNamed('additionalSigners'),
      ),
    ).thenAnswer((inv) async {
      final onStage =
          inv.namedArguments[#onStage] as void Function(ExecutorStageEvent)?;
      onStage?.call(
        const ExecutorStageEvent(
          stage: ExecutorStage.awaitingApproval,
          index: 0,
          total: 1,
        ),
      );
      onStage?.call(
        const ExecutorStageEvent(
          stage: ExecutorStage.broadcasting,
          index: 0,
          total: 1,
        ),
      );
      return const ResultSuccess(testSignature);
    });
  }

  group('AuctionState', () {
    test('initial state carries TxFlowIdle', () {
      expect(
        const AuctionState().flow,
        isA<TxFlowIdle<void, AuctionSuccessData>>(),
      );
    });

    test('progressFraction returns 1.0 when flow is TxFlowSuccess', () {
      final state = AuctionState(
        selectedArtwork: testArtwork,
        flow: const TxFlowSuccess(
          signature: testSignature,
          result: AuctionSuccessData(),
        ),
      );
      expect(state.progressFraction, 1.0);
    });

    test('pricingError flags a missing reserve price', () {
      const state = AuctionState();
      expect(state.pricingError, 'Reserve starting bid is required');
    });

    test('pricingError is null for a valid reserve + default increment', () {
      const state = AuctionState(reservePrice: validReservePrice);
      expect(state.pricingError, isNull);
    });

    test('AuctionSuccessData.copyWith updates indexed', () {
      const initial = AuctionSuccessData();
      final updated = initial.copyWith(indexed: true);
      expect(updated.indexed, true);
      expect(initial.indexed, null);
    });
  });

  // "Direct all proceeds to creators" toggle (webapp `disablePrimarySplit`
  // parity), mirroring the fixed-price coverage: on a PRIMARY auction the flag
  // decides who keeps the post-fee remainder — creators (split enabled) or the
  // seller (split disabled).
  group('disablePrimarySplit', () {
    const otherCreator = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

    AuctionState primaryAuction({
      required bool disablePrimarySplit,
      List<ArtworkRoyaltySplit>? shares,
      bool isSecondary = false,
    }) => AuctionState(
      userPubkey: testWalletAddress,
      isSecondaryMarket: isSecondary,
      selectedArtwork: testArtwork,
      reservePrice: validReservePrice,
      royaltyShares:
          shares ??
          const [ArtworkRoyaltySplit(address: otherCreator, sharePercent: 100)],
      royaltyBps: 1000, // 10%
      // primaryFeeBps / secondaryFeeBps left at their 500 / 250 defaults —
      // the primary sale here carries a 5% mallow fee.
      disablePrimarySplit: disablePrimarySplit,
    );

    double? pctFor(List<ProceedsSplit> splits, ProceedsLabel label) => splits
        .where((s) => s.label == label)
        .fold<double?>(null, (acc, s) => (acc ?? 0) + s.proceedsPct);

    test('showDirectProceedsOption gates like the webapp', () {
      expect(
        primaryAuction(disablePrimarySplit: false).showDirectProceedsOption,
        isTrue,
      );
      expect(
        primaryAuction(
          disablePrimarySplit: false,
          isSecondary: true,
        ).showDirectProceedsOption,
        isFalse,
      );
      expect(
        primaryAuction(
          disablePrimarySplit: false,
          shares: const [
            ArtworkRoyaltySplit(address: testWalletAddress, sharePercent: 100),
          ],
        ).showDirectProceedsOption,
        isFalse,
      );
    });

    test('split enabled routes the post-fee remainder to creators', () {
      final splits = primaryAuction(disablePrimarySplit: false).proceedsSplits;
      expect(pctFor(splits, ProceedsLabel.mallow), 5);
      expect(pctFor(splits, ProceedsLabel.creator), 95);
      expect(pctFor(splits, ProceedsLabel.you), isNull);
    });

    test('split disabled keeps the remainder for the seller', () {
      final splits = primaryAuction(disablePrimarySplit: true).proceedsSplits;
      expect(pctFor(splits, ProceedsLabel.mallow), 5);
      expect(pctFor(splits, ProceedsLabel.creator), 10);
      expect(pctFor(splits, ProceedsLabel.you), 85);
    });

    test('the flag is inverted onto the CreateAuctionTxRequest', () {
      // The wire field is the positive form: the v2 endpoint disables the
      // split whenever `enablePrimarySplit` is absent or false.
      expect(
        primaryAuction(
          disablePrimarySplit: true,
        ).toRequest().enablePrimarySplit,
        isFalse,
      );
      expect(
        primaryAuction(
          disablePrimarySplit: false,
        ).toRequest().enablePrimarySplit,
        isTrue,
      );
    });
  });

  group('requestList', () {
    blocTest<AuctionBloc, AuctionState>(
      'emits Preparing → Ready → Signing → Broadcasting → Success on happy path',
      setUp: stubExecutorSuccess,
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowReady<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowBroadcasting<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, AuctionSuccessData>>().having(
            (f) => f.signature,
            'signature',
            testSignature,
          ),
        ),
      ],
    );

    blocTest<AuctionBloc, AuctionState>(
      'kicks off the background indexer check after a successful broadcast',
      setUp: stubExecutorSuccess,
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      verify: (_) {
        verify(
          mockPipeline.runIndexerCheck(
            signature: testSignature,
            requireEntry: true,
            onAck: anyNamed('onAck'),
            isClosed: anyNamed('isClosed'),
          ),
        ).called(1);
      },
    );

    blocTest<AuctionBloc, AuctionState>(
      'emits TxFlowFailure with listing-failed prefix when backend build fails',
      setUp: () {
        when(
          mockAuctionRepo.getCreateAuctionTx(any),
        ).thenThrow(Exception('network error'));
      },
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowFailure<void, AuctionSuccessData>>().having(
            (f) => f.failure.message,
            'message',
            contains('Listing failed'),
          ),
        ),
      ],
      verify: (_) {
        // Backend build threw before signing — the executor must never run.
        verifyNever(
          mockExecutor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
            tracker: anyNamed('tracker'),
            onStage: anyNamed('onStage'),
            useLedger: anyNamed('useLedger'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        );
      },
    );

    blocTest<AuctionBloc, AuctionState>(
      'preserves the cancel message verbatim when the user cancels signing',
      setUp: () {
        when(
          mockAuctionRepo.getCreateAuctionTx(any),
        ).thenAnswer((_) async => createAuctionResponse());
        when(
          mockExecutor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
            tracker: anyNamed('tracker'),
            onStage: anyNamed('onStage'),
            useLedger: anyNamed('useLedger'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        ).thenAnswer((_) async => const ResultFailure(AppFailure.cancelled()));
      },
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowReady<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          // Cancel message is already user-facing — it must NOT get the
          // "Listing failed:" prefix.
          isA<TxFlowFailure<void, AuctionSuccessData>>()
              .having((f) => f.failure.isCancelled, 'isCancelled', true)
              .having((f) => f.failure.message, 'message', 'Cancelled'),
        ),
      ],
    );

    blocTest<AuctionBloc, AuctionState>(
      'emits TxFlowFailure for an invalid reserve price without calling backend',
      build: buildBloc,
      seed: () => AuctionState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        // reservePrice defaults to 0 → pricingError set.
      ),
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowFailure<void, AuctionSuccessData>>(),
        ),
      ],
      verify: (_) {
        verifyNever(mockAuctionRepo.getCreateAuctionTx(any));
      },
    );

    // `POST /v2/tx/auctions/create` answers with a `setupTx` whenever the
    // auction is on a compressed NFT whose eventual settle would not fit the
    // 1232-byte packet raw: it creates the address lookup table the auction
    // `tx` is *already compiled against*. [TransactionExecutor.execute] signs
    // and CONFIRMS each tx before starting the next, so putting the setup
    // first is the confirmation barrier that makes the table exist by the time
    // the auction tx names it — and makes a setup failure abort before the
    // auction tx is ever broadcast. Send them the other way round (or drop the
    // setup, as this wallet did until plan 049 step 0) and the auction tx
    // references a lookup table that does not exist and fails on-chain, with
    // an error that reads to the user like a mallow bug. Order is therefore
    // the assertion, not batch length.
    blocTest<AuctionBloc, AuctionState>(
      'signs the LUT setup tx before the auction tx when the backend sends one',
      setUp: () {
        stubExecutorSuccess();
        when(mockAuctionRepo.getCreateAuctionTx(any)).thenAnswer(
          (_) async => createAuctionResponse(setupTx: setupTxBase64),
        );
      },
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      verify: (_) {
        final batch =
            verify(
                  mockExecutor.execute(
                    txsBase64: captureAnyNamed('txsBase64'),
                    usdValue: anyNamed('usdValue'),
                    flow: anyNamed('flow'),
                    tracker: anyNamed('tracker'),
                    onStage: anyNamed('onStage'),
                    useLedger: anyNamed('useLedger'),
                    additionalSigners: anyNamed('additionalSigners'),
                  ),
                ).captured.single
                as List<String>;
        expect(batch, [setupTxBase64, testTxBase64]);
      },
    );

    // The mirror of the above: a 1/1, an edition print or any cNFT that fits
    // raw gets no `setupTx`, and must not be charged for a lookup table it
    // does not need — one prompt, one signature, one rent payment.
    blocTest<AuctionBloc, AuctionState>(
      'sends the auction tx alone when the backend omits setupTx',
      setUp: stubExecutorSuccess,
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      verify: (_) {
        final batch =
            verify(
                  mockExecutor.execute(
                    txsBase64: captureAnyNamed('txsBase64'),
                    usdValue: anyNamed('usdValue'),
                    flow: anyNamed('flow'),
                    tracker: anyNamed('tracker'),
                    onStage: anyNamed('onStage'),
                    useLedger: anyNamed('useLedger'),
                    additionalSigners: anyNamed('additionalSigners'),
                  ),
                ).captured.single
                as List<String>;
        expect(batch, [testTxBase64]);
      },
    );

    // An external signer is prompted once per tx. Without the step count in
    // the copy both prompts read identically ("Awaiting approval…"), so the
    // second one looks like the sheet hung on the first and the user backs out
    // of a listing that is half-signed — the setup rent is already spent and
    // no auction exists. The suffix format is the contract
    // `signingLabelForStage` parses, so it is asserted verbatim.
    blocTest<AuctionBloc, AuctionState>(
      'numbers each approval prompt on a setup+auction batch',
      setUp: () {
        when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => false);
        when(mockAuctionRepo.getCreateAuctionTx(any)).thenAnswer(
          (_) async => createAuctionResponse(setupTx: setupTxBase64),
        );
        when(
          mockExecutor.execute(
            txsBase64: anyNamed('txsBase64'),
            usdValue: anyNamed('usdValue'),
            flow: anyNamed('flow'),
            tracker: anyNamed('tracker'),
            onStage: anyNamed('onStage'),
            useLedger: anyNamed('useLedger'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        ).thenAnswer((inv) async {
          final onStage =
              inv.namedArguments[#onStage]
                  as void Function(ExecutorStageEvent)?;
          final txs = inv.namedArguments[#txsBase64] as List<String>;
          for (var i = 0; i < txs.length; i++) {
            onStage?.call(
              ExecutorStageEvent(
                stage: ExecutorStage.awaitingApproval,
                index: i,
                total: txs.length,
              ),
            );
          }
          return const ResultSuccess(testSignature);
        });
      },
      build: buildBloc,
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowReady<void, AuctionSuccessData>>(),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, AuctionSuccessData>>().having(
            (f) => f.stage,
            'stage',
            'Awaiting approval… (1 of 2)',
          ),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, AuctionSuccessData>>().having(
            (f) => f.stage,
            'stage',
            'Awaiting approval… (2 of 2)',
          ),
        ),
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, AuctionSuccessData>>(),
        ),
      ],
    );
  });

  // ── The LUT `setupTx`'s recent_slot, which no blockhash refresh touches ──
  //
  // `/v2/tx/auctions/create` is not server-co-signed, so `signSendConfirm`'s
  // `_refreshBlockhashIfSafe` rewrites the batch's blockhash on the way out and
  // the transaction never *looks* stale. The `recent_slot` that
  // `create_lookup_table` bakes into the setup tx runs on a
  // different clock — the last ~512 slots, roughly 3.4 minutes — and the
  // refresh leaves those bytes untouched. A confirm sheet left open past that
  // window therefore broadcasts a setup tx that is already dead, and because
  // the setup LEADS the batch the failure lands on the FIRST transaction of the
  // listing, with an on-chain error nothing on screen explains.
  //
  // Handing `_flow.execute` the same tracker `_flow.prepare` built with is the
  // only thing that lets [TransactionExecutor] re-ask the builder instead of
  // re-signing bytes it cannot freshen. These tests drive the REAL executor —
  // the rebuild decision (`needsBuilderRebuild` → `createsLookupTable`) is the
  // behaviour under test, so it must not be stubbed away.
  group('LUT setupTx staleness', () {
    late int builds;
    late int rewardPosts;
    late List<String> signed;

    AuctionBloc buildBlocWith(StaleTxTracker<List<String>> tracker) =>
        AuctionBloc(
          mockAuctionRepo,
          mockRewardsRepo,
          mockWalletManager,
          mockDasApi,
          mockArtworkRepo,
          MarketplaceActionFlow(
            mockAuth,
            TransactionExecutor(mockPipeline),
            mockPipeline,
          ),
          _NoopMarketRealtime(),
          TxLandedSlots(),
          mockMarketplaceConfig,
          txTracker: tracker,
        );

    setUp(() {
      builds = 0;
      rewardPosts = 0;
      signed = <String>[];

      // Build #1 is the batch the user sees on the confirm sheet; every later
      // build is the backend recompiling the lookup table against a live slot.
      when(mockAuctionRepo.getCreateAuctionTx(any)).thenAnswer((_) async {
        builds++;
        return createAuctionResponse(
          setupTx: builds == 1 ? staleLutSetupTx : freshLutSetupTx,
        );
      });
      when(mockRewardsRepo.postRewardsDescription(any)).thenAnswer((_) async {
        rewardPosts++;
        return 'rw-$rewardPosts';
      });
      when(
        mockPipeline.signAndBroadcast(
          unsignedTxBase64: anyNamed('unsignedTxBase64'),
          usdValue: anyNamed('usdValue'),
          flow: anyNamed('flow'),
          additionalSigners: anyNamed('additionalSigners'),
          onSigned: anyNamed('onSigned'),
          onLedgerSigning: anyNamed('onLedgerSigning'),
          useLedger: anyNamed('useLedger'),
          rpcOverride: anyNamed('rpcOverride'),
        ),
      ).thenAnswer((inv) async {
        signed.add(inv.namedArguments[#unsignedTxBase64] as String);
        return const ResultSuccess(testSignature);
      });
    });

    /// Stands in for the ~3.4 minutes the confirm sheet sat open. The tracker
    /// under test is built with a zero-length staleness window, so any real
    /// elapsed time between the build and the executor's pre-flight check is
    /// enough to make the batch stale — no clock seam required.
    void stubLingeringSheet() {
      when(mockWalletManager.isLocalSigner()).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return true;
      });
    }

    blocTest<AuctionBloc, AuctionState>(
      'a stale [setupTx, tx] batch goes back to the builder instead of being '
      'signed with a refreshed blockhash',
      setUp: stubLingeringSheet,
      build: () => buildBlocWith(
        StaleTxTracker<List<String>>(staleAfter: Duration.zero),
      ),
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        expect(
          builds,
          2,
          reason:
              'the sheet outlived the baked recent_slot, so the batch has to '
              'be re-asked; without a tracker on execute the executor has '
              'nothing to re-ask and silently sends the dead one',
        );
        expect(
          signed,
          [freshLutSetupTx, testTxBase64],
          reason:
              'a refreshed blockhash makes the stale setup tx look fresh while '
              'its recent_slot is already dead — the FIRST transaction of the '
              'listing then fails on-chain for a reason nothing on screen '
              'explains, so the rebuilt setup must be what is broadcast',
        );
      },
    );

    blocTest<AuctionBloc, AuctionState>(
      'a batch confirmed inside the slot window is NOT rebuilt',
      build: () => buildBlocWith(
        StaleTxTracker<List<String>>(staleAfter: const Duration(minutes: 5)),
      ),
      seed: validSeed,
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        expect(
          builds,
          1,
          reason:
              'a rebuild is not free: it asks the backend for a whole new '
              'lookup table, so a still-live setup tx must be sent as built',
        );
        expect(signed, [staleLutSetupTx, testTxBase64]);
      },
    );

    // The rebuild replays the `prepare` build closure verbatim. Anything with a
    // side effect therefore has to stay OUT of that closure —
    // `postRewardsDescription` persists a rewards row and hands back its id,
    // and a second POST would orphan the first row while the listing's memo
    // points at only one of them.
    blocTest<AuctionBloc, AuctionState>(
      'a rebuild re-asks for the transactions but never re-posts the rewards '
      'description',
      setUp: stubLingeringSheet,
      build: () => buildBlocWith(
        StaleTxTracker<List<String>>(staleAfter: Duration.zero),
      ),
      seed: () => AuctionState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        reservePrice: validReservePrice,
        includeRewards: true,
        rewardsDescription: 'Signed print shipped to the winner',
      ),
      act: (bloc) => bloc.add(const AuctionEvent.requestList()),
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        expect(builds, 2, reason: 'the rebuild path must actually have run');
        expect(
          rewardPosts,
          1,
          reason:
              'a replayed POST would persist a duplicate rewards row and '
              'orphan the first — the closure may only rebuild transactions',
        );
        final requests = verify(
          mockAuctionRepo.getCreateAuctionTx(captureAny),
        ).captured.cast<CreateAuctionTxRequest>();
        expect(
          requests.map((r) => r.memo).toList(),
          ['rewards:rw-1', 'rewards:rw-1'],
          reason:
              'the rebuilt listing must carry the memo of the row that was '
              'actually persisted, not a second one created by the replay',
        );
      },
    );
  });

  group('dismissError / indexedAck', () {
    blocTest<AuctionBloc, AuctionState>(
      'dismissError resets flow to TxFlowIdle',
      build: buildBloc,
      seed: () => AuctionState(
        selectedArtwork: testArtwork,
        flow: const TxFlowFailure(AppFailure.unknown('Listing failed: err')),
      ),
      act: (bloc) => bloc.add(const AuctionEvent.dismissError()),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowIdle<void, AuctionSuccessData>>(),
        ),
      ],
    );

    blocTest<AuctionBloc, AuctionState>(
      'indexedAck flips AuctionSuccessData.indexed for the matching signature',
      build: buildBloc,
      seed: () => AuctionState(
        selectedArtwork: testArtwork,
        flow: const TxFlowSuccess(
          signature: testSignature,
          result: AuctionSuccessData(),
        ),
      ),
      act: (bloc) => bloc.add(
        const AuctionEvent.indexedAck(signature: testSignature, ok: true),
      ),
      expect: () => [
        isA<AuctionState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, AuctionSuccessData>>().having(
            (f) => f.result.indexed,
            'indexed',
            true,
          ),
        ),
      ],
    );

    blocTest<AuctionBloc, AuctionState>(
      'indexedAck is a no-op when the signature does not match',
      build: buildBloc,
      seed: () => AuctionState(
        selectedArtwork: testArtwork,
        flow: const TxFlowSuccess(
          signature: testSignature,
          result: AuctionSuccessData(),
        ),
      ),
      act: (bloc) => bloc.add(
        const AuctionEvent.indexedAck(signature: 'different', ok: true),
      ),
      expect: () => <Matcher>[],
    );
  });

  // Entering the flow via the sell chooser (no mint) and picking an artwork
  // must hydrate royalty/fee/secondary-market state, exactly like `started`
  // does with a preselected mint. Without this the review step keeps
  // the empty defaults and the gate can never render / the split is wrong.
  group('picker-path hydration', () {
    const otherCreator = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

    // A picked artwork whose mint differs from the DAS-stubbed one, so we can
    // assert hydration keyed the lookup off the selection.
    final pickedArtwork = PortfolioArtwork(
      mintAccount: 'PickedMint1111111111111111111111111111111111',
      title: 'Picked',
      imageUrl: '',
      artistName: 'Artist',
    );

    DigitalAsset nft({required bool primarySaleHappened}) => DigitalAsset(
      id: pickedArtwork.mintAccount,
      tokenStandard: TokenStandard.nft,
      isMutable: true,
      frozen: false,
      supply: 0,
      freezeDelegateFrozen: false,
      permanentFreezeDelegateFrozen: false,
      hasMasterEditionPlugin: false,
      owner: testWalletAddress,
      updateAuthority: otherCreator,
      primarySaleHappened: primarySaleHappened,
    );

    ArtworkDetails detailWithCreatorShares() => ArtworkDetails(
      mintAccount: pickedArtwork.mintAccount,
      title: 'Picked',
      imageUrl: '',
      description: '',
      artistName: 'Artist',
      artistAddress: otherCreator,
      royaltyPercent: '10',
      royaltySplits: const [
        ArtworkRoyaltySplit(address: otherCreator, sharePercent: 100),
      ],
    );

    setUp(() {
      when(
        mockWalletManager.getAddress(),
      ).thenAnswer((_) async => testWalletAddress);
    });

    test('selecting a primary NFT hydrates the gate (shown)', () async {
      when(
        mockDasApi.getAsset(pickedArtwork.mintAccount),
      ).thenAnswer((_) async => nft(primarySaleHappened: false));
      when(
        mockArtworkRepo.getArtworkDetail(pickedArtwork.mintAccount),
      ).thenAnswer((_) async => detailWithCreatorShares());

      final bloc = buildBloc();
      // Enter with no mint (sell-chooser path), then pick.
      bloc.add(const AuctionEvent.started());
      await Future<void>.delayed(Duration.zero);
      bloc.add(AuctionEvent.selectArtwork(pickedArtwork));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        bloc.state.selectedArtwork?.mintAccount,
        pickedArtwork.mintAccount,
      );
      expect(bloc.state.isSecondaryMarket, isFalse);
      expect(bloc.state.royaltyShares, isNotEmpty);
      expect(bloc.state.showDirectProceedsOption, isTrue);
      await bloc.close();
    });

    test(
      'selecting a resold NFT classifies as secondary (gate hidden)',
      () async {
        when(
          mockDasApi.getAsset(pickedArtwork.mintAccount),
        ).thenAnswer((_) async => nft(primarySaleHappened: true));
        when(
          mockArtworkRepo.getArtworkDetail(pickedArtwork.mintAccount),
        ).thenAnswer((_) async => detailWithCreatorShares());

        final bloc = buildBloc();
        bloc.add(const AuctionEvent.started());
        await Future<void>.delayed(Duration.zero);
        bloc.add(AuctionEvent.selectArtwork(pickedArtwork));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(bloc.state.isSecondaryMarket, isTrue);
        expect(bloc.state.showDirectProceedsOption, isFalse);
        await bloc.close();
      },
    );

    test('a stale hydration does not overwrite a newer selection', () async {
      final other = PortfolioArtwork(
        mintAccount: 'OtherMint22222222222222222222222222222222222',
        title: 'Other',
        imageUrl: '',
        artistName: 'Artist',
      );
      // First pick's DAS lookup hangs; it later resolves to a PRIMARY asset.
      final slow = Completer<DigitalAsset>();
      when(
        mockDasApi.getAsset(pickedArtwork.mintAccount),
      ).thenAnswer((_) => slow.future);
      // Second pick resolves immediately as a SECONDARY asset.
      when(mockDasApi.getAsset(other.mintAccount)).thenAnswer(
        (_) async => DigitalAsset(
          id: other.mintAccount,
          tokenStandard: TokenStandard.nft,
          isMutable: true,
          frozen: false,
          supply: 0,
          freezeDelegateFrozen: false,
          permanentFreezeDelegateFrozen: false,
          hasMasterEditionPlugin: false,
          owner: testWalletAddress,
          updateAuthority: otherCreator,
          primarySaleHappened: true,
        ),
      );
      when(
        mockArtworkRepo.getArtworkDetail(any),
      ).thenAnswer((_) => Future<ArtworkDetails>.error(Exception('no detail')));

      final bloc = buildBloc();
      bloc.add(const AuctionEvent.started());
      await Future<void>.delayed(Duration.zero);
      bloc.add(AuctionEvent.selectArtwork(pickedArtwork)); // stale, hangs
      await Future<void>.delayed(Duration.zero);
      bloc.add(AuctionEvent.selectArtwork(other)); // newer, wins
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Newer selection resolved to secondary.
      expect(bloc.state.selectedArtwork?.mintAccount, other.mintAccount);
      expect(bloc.state.isSecondaryMarket, isTrue);

      // Now let the stale (primary) lookup finish — it must NOT clobber the
      // newer selection's secondary classification.
      slow.complete(nft(primarySaleHappened: false));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.selectedArtwork?.mintAccount, other.mintAccount);
      expect(bloc.state.isSecondaryMarket, isTrue);
      await bloc.close();
    });

    // A DAS future that rejects while the marketplace-config round-trip is
    // still awaiting must not surface as an uncaught zone error (Sentry noise
    // / test flake). Handlers are attached at future creation.
    test('rejecting DAS + detail futures during config await degrade '
        'gracefully with no uncaught error', () async {
      final configGate = Completer<MarketplaceFees>();
      when(mockMarketplaceConfig.get()).thenAnswer((_) => configGate.future);
      when(
        mockDasApi.getAsset(any),
      ).thenAnswer((_) => Future<DigitalAsset>.error(Exception('das down')));
      when(mockArtworkRepo.getArtworkDetail(any)).thenAnswer(
        (_) => Future<ArtworkDetails>.error(Exception('detail down')),
      );

      final bloc = buildBloc();
      bloc.add(
        const AuctionEvent.started(mintAccount: 'AnyMint1111111111111111'),
      );
      // Let the rejected futures settle while config is still pending — this
      // is the window the old unlistened-future code leaked into the zone.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      configGate.complete((
        primaryBps: 500,
        secondaryBps: 250,
        printFeeLamports: 11000000,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Graceful degradation: no asset → primary default, empty breakdown.
      expect(bloc.state.isSecondaryMarket, isFalse);
      expect(bloc.state.royaltyShares, isEmpty);
      await bloc.close();
    });
  });
}

/// A base64 tx carrying the address-lookup-table program's `CreateLookupTable`
/// instruction — the shape the backend's `alt::create_and_extend_ixs`
/// emits for the `setupTx` on a deep-tree cNFT auction. Deliberately NOT
/// pre-signed: `/v2/tx/auctions/create` is never co-signed, which is exactly
/// why a client-side blockhash refresh hides the dying [recentSlot].
String _lutSetupTxBase64(String payerAddress, {required int recentSlot}) {
  final payer = Ed25519HDPublicKey.fromBase58(payerAddress);
  final table = Ed25519HDPublicKey(List<int>.filled(32, 0x44));
  final ix = Instruction(
    programId: Ed25519HDPublicKey.fromBase58(addressLookupTableProgramId),
    accounts: [
      AccountMeta.writeable(pubKey: table, isSigner: false),
      AccountMeta.writeable(pubKey: payer, isSigner: true),
    ],
    // bincode: u32 LE variant 0 (CreateLookupTable), u64 LE recent_slot, bump.
    data: ByteArray.merge([
      ByteArray.u32(0),
      ByteArray.u64(recentSlot),
      ByteArray.u8(255),
    ]),
  );
  final compiled = Message.only(ix).compile(
    recentBlockhash: '11111111111111111111111111111111',
    feePayer: payer,
  );
  return SignedTx(
    signatures: List<Signature>.generate(
      compiled.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: payer),
    ),
    compiledMessage: compiled,
  ).encode();
}

/// Builds a base64-encoded SignedTx with a single self-transfer instruction so
/// it round-trips through `SignedTx.fromBytes` cleanly. [lamports] only exists
/// to make two otherwise-identical fixtures byte-distinct.
String _buildParseableTxBase64(String walletAddress, {int lamports = 1}) {
  final pubkey = Ed25519HDPublicKey.fromBase58(walletAddress);
  final message = Message.only(
    SystemInstruction.transfer(
      fundingAccount: pubkey,
      recipientAccount: pubkey,
      lamports: lamports,
    ),
  );
  return SignedTx(
    compiledMessage: message.compile(
      recentBlockhash: '11111111111111111111111111111111',
      feePayer: pubkey,
    ),
  ).encode();
}
