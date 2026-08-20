import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkDetails, ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/auction/data/rewards_repository.dart';
import 'package:mallow_wallet/features/fixed_price/data/fixed_price_repository.dart';
import 'package:mallow_wallet/features/fixed_price/services/fixed_price_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/sale/services/marketplace_config_service.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'fixed_price_bloc_test.mocks.dart';

class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

@GenerateMocks([
  MallowApiClient,
  WalletManager,
  SolanaRpcService,
  AuthService,
  LedgerService,
  DasApiService,
  FixedPriceRepository,
  RewardsRepository,
  ArtworkRepository,
  MarketplaceConfigService,
  MarketRealtimeService,
])
void main() {
  late MockMallowApiClient mockApi;
  late MockWalletManager mockWalletManager;
  late MockSolanaRpcService mockRpcService;
  late MockLedgerService mockLedgerService;
  late MockDasApiService mockDasApi;
  late MockFixedPriceRepository mockFixedPriceRepo;
  late MockRewardsRepository mockRewardsRepo;
  late MockArtworkRepository mockArtworkRepo;
  late MockMarketplaceConfigService mockMarketplaceConfig;
  late MockMarketRealtimeService mockRealtime;

  const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  late String testTxBase64;

  final testArtwork = PortfolioArtwork(
    mintAccount: '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  setUpAll(() {
    provideDummy<ApiResponse<CreateFixedPriceTxResponse>>(
      const ApiResponse<CreateFixedPriceTxResponse>(
        result: CreateFixedPriceTxResponse(tx: 'dummy'),
      ),
    );
  });

  setUp(() {
    mockApi = MockMallowApiClient();
    mockWalletManager = MockWalletManager();
    mockRpcService = MockSolanaRpcService();
    mockLedgerService = MockLedgerService();
    mockDasApi = MockDasApiService();
    mockFixedPriceRepo = MockFixedPriceRepository();
    mockRewardsRepo = MockRewardsRepository();
    mockArtworkRepo = MockArtworkRepository();
    mockMarketplaceConfig = MockMarketplaceConfigService();
    mockRealtime = MockMarketRealtimeService();

    testTxBase64 = _buildParseableTxBase64(testWalletAddress);

    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => true);
    when(
      mockLedgerService.signingState,
    ).thenAnswer((_) => const Stream.empty());
    when(mockMarketplaceConfig.get()).thenAnswer(
      (_) async =>
          (primaryBps: 500, secondaryBps: 250, printFeeLamports: 11000000),
    );
  });

  FixedPriceBloc buildBloc() {
    // A real pipeline over mocked RPC primitives so signSendConfirm runs
    // end-to-end; the flow wraps that same pipeline (the single signing path
    // the bloc now routes through via MarketplaceActionFlow).
    final pipeline = TransactionPipeline(
      mockWalletManager,
      mockRpcService,
      _AllowAllAuthGate(),
      mockApi,
      mockLedgerService,
    );
    final flow = MarketplaceActionFlow(
      MockAuthService(),
      TransactionExecutor(pipeline),
      pipeline,
    );
    return FixedPriceBloc(
      mockFixedPriceRepo,
      mockRewardsRepo,
      mockWalletManager,
      mockDasApi,
      mockArtworkRepo,
      mockMarketplaceConfig,
      mockRealtime,
      flow,
      const FeeConfig(),
      TxLandedSlots(),
    );
  }

  group('FixedPriceState', () {
    test('initial state carries TxFlowIdle', () {
      expect(
        const FixedPriceState().flow,
        isA<TxFlowIdle<void, FixedPriceSuccessData>>(),
      );
    });

    test('progressFraction returns 1.0 when flow is TxFlowSuccess', () {
      const state = FixedPriceState(
        entryFromArtworkDetail: true,
        step: FixedPriceStep.review,
        flow: TxFlowSuccess(
          signature: testSignature,
          result: FixedPriceSuccessData(),
        ),
      );
      expect(state.progressFraction, 1.0);
    });

    test('FixedPriceSuccessData.copyWith updates indexed', () {
      const initial = FixedPriceSuccessData();
      final updated = initial.copyWith(indexed: true);
      expect(updated.indexed, true);
      expect(initial.indexed, null);
    });
  });

  // "Direct all proceeds to creators" toggle (webapp `disablePrimarySplit`
  // parity). The point of the flag is that on a PRIMARY sale it decides who
  // keeps the post-fee remainder: creators (split enabled) or the seller
  // (split disabled). These tests pin that behaviour, not just the boolean
  // plumbing.
  group('disablePrimarySplit', () {
    const seller = testWalletAddress;
    const otherCreator = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

    FixedPriceState primaryListing({
      required bool disablePrimarySplit,
      List<ArtworkRoyaltySplit>? shares,
      bool isSecondary = false,
    }) => FixedPriceState(
      userPubkey: seller,
      isSecondaryMarket: isSecondary,
      selectedArtwork: testArtwork,
      price: 1000000000,
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

    test('showDirectProceedsOption gates on a primary sale with a non-seller '
        'first creator', () {
      // Shown: primary sale, creator shares, seller isn't the first creator.
      expect(
        primaryListing(disablePrimarySplit: false).showDirectProceedsOption,
        isTrue,
      );
      // Hidden on a secondary sale — the flag is a no-op there.
      expect(
        primaryListing(
          disablePrimarySplit: false,
          isSecondary: true,
        ).showDirectProceedsOption,
        isFalse,
      );
      // Hidden when the seller IS the first creator (nothing to redirect).
      expect(
        primaryListing(
          disablePrimarySplit: false,
          shares: const [
            ArtworkRoyaltySplit(address: seller, sharePercent: 100),
          ],
        ).showDirectProceedsOption,
        isFalse,
      );
      // Hidden with no creator shares.
      expect(
        primaryListing(
          disablePrimarySplit: false,
          shares: const [],
        ).showDirectProceedsOption,
        isFalse,
      );
    });

    test('split enabled routes the post-fee remainder to creators', () {
      final splits = primaryListing(disablePrimarySplit: false).proceedsSplits;
      // 5% mallow fee, remaining 95% all to the (non-seller) creator; the
      // seller — not a creator here — receives nothing directly.
      expect(pctFor(splits, ProceedsLabel.mallow), 5);
      expect(pctFor(splits, ProceedsLabel.creator), 95);
      expect(pctFor(splits, ProceedsLabel.you), isNull);
    });

    test('split disabled keeps the remainder for the seller', () {
      final splits = primaryListing(disablePrimarySplit: true).proceedsSplits;
      // Creator gets only the 10% royalty; the seller keeps 95% − 10% = 85%.
      expect(pctFor(splits, ProceedsLabel.mallow), 5);
      expect(pctFor(splits, ProceedsLabel.creator), 10);
      expect(pctFor(splits, ProceedsLabel.you), 85);
    });

    test('the flag is inverted onto the CreateFixedPriceTxRequest', () {
      // The wire field is the positive form: the v2 endpoint disables the
      // split whenever `enablePrimarySplit` is absent or false.
      expect(
        primaryListing(
          disablePrimarySplit: true,
        ).toRequest(priorityFeeLamports: 1).enablePrimarySplit,
        isFalse,
      );
      expect(
        primaryListing(
          disablePrimarySplit: false,
        ).toRequest(priorityFeeLamports: 1).enablePrimarySplit,
        isTrue,
      );
    });
  });

  group('requestList', () {
    void stubSignAndBroadcast({String? overrideTx}) {
      when(mockFixedPriceRepo.getCreateBuyNowTx(any)).thenAnswer(
        (_) async => ApiResponse<CreateFixedPriceTxResponse>(
          result: CreateFixedPriceTxResponse(tx: overrideTx ?? testTxBase64),
        ),
      );
      // signSendConfirm refreshes the blockhash for non-co-signed txs.
      when(
        mockRpcService.getLatestBlockhash(),
      ).thenAnswer((_) async => '11111111111111111111111111111111');
      when(
        mockWalletManager.signCompiledTx(
          unsignedTx: anyNamed('unsignedTx'),
          additionalSigners: anyNamed('additionalSigners'),
        ),
      ).thenAnswer((inv) async => inv.namedArguments[#unsignedTx] as SignedTx);
      when(
        mockRpcService.sendTransaction(any),
      ).thenAnswer((_) async => testSignature);
      when(
        mockRpcService.awaitConfirmationOrThrow(
          testSignature,
          rebroadcast: anyNamed('rebroadcast'),
        ),
      ).thenAnswer((_) async {});
    }

    blocTest<FixedPriceBloc, FixedPriceState>(
      'emits Preparing → Ready → Signing → Broadcasting → Success on happy path',
      setUp: stubSignAndBroadcast,
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      expect: () => [
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, FixedPriceSuccessData>>(),
        ),
        // _flow.prepare emits Ready once the batch is built. The flow then
        // immediately proceeds to execute without waiting for a user confirm.
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowReady<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowBroadcasting<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, FixedPriceSuccessData>>(),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'TxFlowSuccess carries the broadcast signature',
      setUp: stubSignAndBroadcast,
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      expect: () => [
        anything, // TxFlowPreparing
        anything, // TxFlowReady
        anything, // TxFlowSigning
        anything, // TxFlowBroadcasting
        isA<FixedPriceState>().having(
          (s) =>
              (s.flow as TxFlowSuccess<void, FixedPriceSuccessData>).signature,
          'signature',
          testSignature,
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'emits TxFlowFailure when backend build fails',
      setUp: () {
        when(
          mockFixedPriceRepo.getCreateBuyNowTx(any),
        ).thenThrow(Exception('network error'));
      },
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      expect: () => [
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowFailure<void, FixedPriceSuccessData>>(),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'TxFlowFailure message has listing-failed prefix when signing throws',
      setUp: () {
        when(mockFixedPriceRepo.getCreateBuyNowTx(any)).thenAnswer(
          (_) async => ApiResponse<CreateFixedPriceTxResponse>(
            result: CreateFixedPriceTxResponse(tx: testTxBase64),
          ),
        );
        when(
          mockRpcService.getLatestBlockhash(),
        ).thenAnswer((_) async => '11111111111111111111111111111111');
        when(
          mockWalletManager.signCompiledTx(
            unsignedTx: anyNamed('unsignedTx'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        ).thenThrow(Exception('wallet rejected'));
      },
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      expect: () => [
        anything, // TxFlowPreparing
        anything, // TxFlowReady (prepare succeeded; signing then throws)
        anything, // TxFlowSigning
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowFailure<void, FixedPriceSuccessData>>().having(
            (f) => f.failure.message,
            'message',
            contains('Listing failed'),
          ),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'emits TxFlowFailure when price is invalid (no network calls)',
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      expect: () => [
        // A pricing-validation failure is classified as `validation` (not
        // `unknown`) and surfaces the raw message without the "Listing
        // failed:" prefix that real tx failures carry.
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowFailure<void, FixedPriceSuccessData>>()
              .having((f) => f.failure.kind, 'kind', AppFailureKind.validation)
              .having(
                (f) => f.failure.message,
                'message',
                isNot(contains('Listing failed')),
              ),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'dismissError resets flow to TxFlowIdle',
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
        flow: const TxFlowFailure(AppFailure.unknown('Listing failed: err')),
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.dismissError()),
      expect: () => [
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowIdle<void, FixedPriceSuccessData>>(),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'indexedAck updates FixedPriceSuccessData.indexed',
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
        flow: const TxFlowSuccess(
          signature: testSignature,
          result: FixedPriceSuccessData(),
        ),
      ),
      act: (bloc) => bloc.add(
        const FixedPriceEvent.indexedAck(signature: testSignature, ok: true),
      ),
      expect: () => [
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, FixedPriceSuccessData>>().having(
            (f) => f.result.indexed,
            'indexed',
            true,
          ),
        ),
      ],
    );

    blocTest<FixedPriceBloc, FixedPriceState>(
      'indexedAck is a no-op when signature does not match',
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
        flow: const TxFlowSuccess(
          signature: testSignature,
          result: FixedPriceSuccessData(),
        ),
      ),
      act: (bloc) => bloc.add(
        const FixedPriceEvent.indexedAck(
          signature: 'different_signature',
          ok: true,
        ),
      ),
      expect: () => <Matcher>[],
    );
  });

  group('two-step listing (LUT setup tx)', () {
    blocTest<FixedPriceBloc, FixedPriceState>(
      'signs both setup tx and listing tx in one execute call, emitting TxFlowSuccess',
      setUp: () {
        when(mockFixedPriceRepo.getCreateBuyNowTx(any)).thenAnswer(
          (_) async => ApiResponse<CreateFixedPriceTxResponse>(
            result: CreateFixedPriceTxResponse(
              tx: testTxBase64,
              setupTx: testTxBase64,
            ),
          ),
        );
        when(
          mockRpcService.getLatestBlockhash(),
        ).thenAnswer((_) async => '11111111111111111111111111111111');
        when(
          mockWalletManager.signCompiledTx(
            unsignedTx: anyNamed('unsignedTx'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        ).thenAnswer(
          (inv) async => inv.namedArguments[#unsignedTx] as SignedTx,
        );
        when(
          mockRpcService.sendTransaction(any),
        ).thenAnswer((_) async => testSignature);
        when(
          mockRpcService.awaitConfirmationOrThrow(
            testSignature,
            rebroadcast: anyNamed('rebroadcast'),
          ),
        ).thenAnswer((_) async {});
      },
      build: buildBloc,
      seed: () => FixedPriceState(
        userPubkey: testWalletAddress,
        selectedArtwork: testArtwork,
        price: 10000000, // 0.01 SOL, at minimum listing price
      ),
      act: (bloc) => bloc.add(const FixedPriceEvent.requestList()),
      verify: (_) {
        // signCompiledTx called twice — setup tx then listing tx, both chained
        // inside the single _flow.execute call via TransactionExecutor's loop.
        verify(
          mockWalletManager.signCompiledTx(
            unsignedTx: anyNamed('unsignedTx'),
            additionalSigners: anyNamed('additionalSigners'),
          ),
        ).called(2);
      },
      expect: () => [
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowPreparing<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowReady<void, FixedPriceSuccessData>>(),
        ),
        // Signing stage for the setup tx (index 0 of 2).
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, FixedPriceSuccessData>>(),
        ),
        // Broadcasting the setup tx.
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowBroadcasting<void, FixedPriceSuccessData>>(),
        ),
        // Signing stage for the listing tx (index 1 of 2).
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSigning<void, FixedPriceSuccessData>>(),
        ),
        // Broadcasting the listing tx.
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowBroadcasting<void, FixedPriceSuccessData>>(),
        ),
        isA<FixedPriceState>().having(
          (s) => s.flow,
          'flow',
          isA<TxFlowSuccess<void, FixedPriceSuccessData>>(),
        ),
      ],
    );
  });

  // Picking an artwork via the sell chooser (no preselected mint) must
  // hydrate royalty/fee/secondary-market state exactly like `started`, and
  // rejecting DAS futures during the config await must not leak an uncaught
  // zone error.
  group('picker-path hydration', () {
    const otherCreator = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

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

    test('selecting a primary NFT hydrates the gate (shown)', () async {
      when(
        mockDasApi.getAsset(pickedArtwork.mintAccount),
      ).thenAnswer((_) async => nft(primarySaleHappened: false));
      when(
        mockArtworkRepo.getArtworkDetail(pickedArtwork.mintAccount),
      ).thenAnswer((_) async => detailWithCreatorShares());

      final bloc = buildBloc();
      bloc.add(const FixedPriceEvent.started());
      await Future<void>.delayed(Duration.zero);
      bloc.add(FixedPriceEvent.selectArtwork(pickedArtwork));
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
        bloc.add(const FixedPriceEvent.started());
        await Future<void>.delayed(Duration.zero);
        bloc.add(FixedPriceEvent.selectArtwork(pickedArtwork));
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
      final slow = Completer<DigitalAsset>();
      when(
        mockDasApi.getAsset(pickedArtwork.mintAccount),
      ).thenAnswer((_) => slow.future);
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
      bloc.add(const FixedPriceEvent.started());
      await Future<void>.delayed(Duration.zero);
      bloc.add(FixedPriceEvent.selectArtwork(pickedArtwork)); // stale, hangs
      await Future<void>.delayed(Duration.zero);
      bloc.add(FixedPriceEvent.selectArtwork(other)); // newer, wins
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.selectedArtwork?.mintAccount, other.mintAccount);
      expect(bloc.state.isSecondaryMarket, isTrue);

      slow.complete(nft(primarySaleHappened: false));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.selectedArtwork?.mintAccount, other.mintAccount);
      expect(bloc.state.isSecondaryMarket, isTrue);
      await bloc.close();
    });

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
        const FixedPriceEvent.started(mintAccount: 'AnyMint1111111111111111'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      configGate.complete((
        primaryBps: 500,
        secondaryBps: 250,
        printFeeLamports: 11000000,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.isSecondaryMarket, isFalse);
      expect(bloc.state.royaltyShares, isEmpty);
      await bloc.close();
    });
  });
}

String _buildParseableTxBase64(String walletAddress) {
  final pubkey = Ed25519HDPublicKey.fromBase58(walletAddress);
  final message = Message.only(
    SystemInstruction.transfer(
      fundingAccount: pubkey,
      recipientAccount: pubkey,
      lamports: 1,
    ),
  );
  return SignedTx(
    compiledMessage: message.compile(
      recentBlockhash: '11111111111111111111111111111111',
      feePayer: pubkey,
    ),
  ).encode();
}
