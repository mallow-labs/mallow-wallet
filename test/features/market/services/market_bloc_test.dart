import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/core/realtime/models/account_update.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/market_account_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_edited_signal.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/features/curations/services/curation_attribution_store.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/sale/services/marketplace_config_service.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart'
    show kMallowFeeAddress;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'market_bloc_test.mocks.dart';

/// The chain authoritatively has no such account (`Listing` / `AuctionConfig`)
/// — the default for the accept-offer eligibility gate.
const MarketAccountRead absentRead = (
  status: OnChainReadStatus.absent,
  account: null,
  pda: 'PdA11111111111111111111111111111111111111111',
  viewSlot: 1,
);

/// The account exists, decoded from [raw].
MarketAccountRead presentRead(Map<String, dynamic> raw) => (
  status: OnChainReadStatus.present,
  account: AccountUpdate.fromJson(raw),
  pda: 'PdA11111111111111111111111111111111111111111',
  viewSlot: 1,
);

/// Always-allow auth gate so existing market tests stay focused on the
/// market pipeline. Threshold behavior is covered separately in
/// transaction_auth_gate_test.dart.
class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

TransactionPipeline _makePipeline(
  WalletManager walletManager,
  SolanaRpcService rpcService,
  TransactionAuthGate authGate,
  MallowApiClient api,
  LedgerService ledgerService,
) => TransactionPipeline(
  walletManager,
  rpcService,
  authGate,
  api,
  ledgerService,
);

@GenerateMocks([
  MallowApiClient,
  MallowApiV2Client,
  WalletManager,
  SolanaRpcService,
  AuthService,
  LedgerService,
  DasApiService,
  TokenPriceService,
  MarketplaceConfigService,
  MarketAccountRepository,
  CurationAttributionStore,
])
void main() {
  late MockMallowApiClient mockApi;
  late MockMallowApiV2Client mockApiV2;
  late MockWalletManager mockWalletManager;
  late MockSolanaRpcService mockRpcService;
  late MockAuthService mockAuthService;
  late MockLedgerService mockLedgerService;
  late MockDasApiService mockDasApi;
  late MockTokenPriceService mockPriceService;
  late MockMarketplaceConfigService mockMarketplaceConfig;
  late MockMarketAccountRepository mockMarketAccounts;
  late MockCurationAttributionStore mockCurationAttribution;
  late TransactionAuthGate authGate;
  // Captured emissions of the app-wide artwork fan-out signal.
  var editedMints = <String>[];
  StreamSubscription<String>? editedSub;

  const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testMintAccount = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  // Real wire-format SignedTx with a single self-transfer (1 required
  // signer) so SignedTx.fromBytes inside signSendConfirm can parse it.
  // The mocked signCompiledTx then short-circuits the rest of the flow
  // — we don't need the bytes to be on-chain-valid.
  final testTransactionBase64 = _buildParseableTxBase64(testWalletAddress);

  // A second, byte-distinct parseable tx standing in for the edition buy's
  // `initProofs` setup tx, so batch ORDER is assertable and not just length.
  final setupTransactionBase64 = _buildParseableTxBase64(
    testWalletAddress,
    lamports: 2,
  );

  // Provide dummy values for mockito to use for ApiResponse types
  setUpAll(() {
    provideDummy<BuyEditionTxsResponse>(
      BuyEditionTxsResponse(
        result: [
          BuyEditionTxItem(
            mintAccount: testMintAccount,
            tx: testTransactionBase64,
          ),
        ],
      ),
    );
    // The v1 fallback (`MallowApiClient.getBuyEditionTxs`) still returns the
    // v1 `BuyEditionTx` shape.
    provideDummy<ApiResponse<List<BuyEditionTx>>>(
      ApiResponse<List<BuyEditionTx>>(
        result: [
          BuyEditionTx(mintAccount: testMintAccount, tx: testTransactionBase64),
        ],
      ),
    );
    // Covers every v2 tx-builder that returns the `{ result: { tx } }`
    // envelope (burn, transfer, bid, offers, fixed-price, auctions).
    provideDummy<ApiResponse<UnsignedTxResponse>>(
      ApiResponse<UnsignedTxResponse>(
        result: UnsignedTxResponse(tx: testTransactionBase64),
      ),
    );
    provideDummy<ApiResponse<ArtworkResult>>(
      const ApiResponse<ArtworkResult>(
        result: ArtworkResult(
          item: NftDetail(mintAccount: testMintAccount, name: 'Dummy'),
        ),
      ),
    );
  });

  setUp(() {
    mockApi = MockMallowApiClient();
    mockApiV2 = MockMallowApiV2Client();
    mockWalletManager = MockWalletManager();
    mockRpcService = MockSolanaRpcService();
    mockAuthService = MockAuthService();
    mockLedgerService = MockLedgerService();
    mockDasApi = MockDasApiService();
    mockPriceService = MockTokenPriceService();
    mockMarketplaceConfig = MockMarketplaceConfigService();
    mockMarketAccounts = MockMarketAccountRepository();
    mockCurationAttribution = MockCurationAttributionStore();
    authGate = _AllowAllAuthGate();
    // No curation view recorded on this device by default — the buy requests
    // then carry no `curationShareSlug`. Attribution tests override.
    when(mockCurationAttribution.shareSlugFor(any)).thenReturn(null);
    // Default on-chain listing state for the accept-offer eligibility gate:
    // no mallow listing, no auction. Individual tests override.
    when(
      mockMarketAccounts.readListing(any),
    ).thenAnswer((_) async => absentRead);
    when(
      mockMarketAccounts.readAuctionConfig(any),
    ).thenAnswer((_) async => absentRead);
    when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(0.0);
    when(mockMarketplaceConfig.get()).thenAnswer(
      (_) async =>
          (primaryBps: 500, secondaryBps: 250, printFeeLamports: 11000000),
    );

    // Default stub for getAddress - used by all tests
    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    // Default to "external signer" so the bloc's signing state stays
    // stage-less (matches existing test expectations of
    // `MarketState.signing()`).
    when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => false);
    when(mockAuthService.currentAddress).thenReturn(testWalletAddress);
    when(
      mockLedgerService.signingState,
    ).thenAnswer((_) => const Stream<LedgerSigningState>.empty());
    // `signSendConfirm` swaps in a fresh blockhash for non-co-signed txs
    // before signing. The test fixture builds an unsigned (no
    // pre-attached signatures) tx so this branch always runs — return a
    // base58 placeholder long enough to deserialize as a 32-byte
    // blockhash. (Any 32-byte base58 string works; the mocked signer
    // doesn't actually validate it.)
    when(
      mockRpcService.getLatestBlockhash(),
    ).thenAnswer((_) async => '11111111111111111111111111111111');
  });

  // Real [MarketplaceActionFlow] over the same mocked low-level services the
  // bloc used directly before the flow was extracted — keeps these tests
  // exercising the actual prepare/execute/poll path (not a mocked seam) so
  // behavior parity holds.
  MarketplaceActionFlow makeFlow() => MarketplaceActionFlow(
    mockAuthService,
    TransactionExecutor(
      _makePipeline(
        mockWalletManager,
        mockRpcService,
        authGate,
        mockApi,
        mockLedgerService,
      ),
    ),
    _makePipeline(
      mockWalletManager,
      mockRpcService,
      authGate,
      mockApi,
      mockLedgerService,
    ),
  );

  group('MarketBloc', () {
    group('Buy event', () {
      group('1/1 artwork (usesBuySingleTx)', () {
        blocTest<MarketBloc, MarketState>(
          'uses the v2 fixed-price route for a SOL 1/1 buy',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
                .having(
                  (s) => s.data.mintAccount,
                  'mintAccount',
                  testMintAccount,
                )
                .having((s) => s.data.actionType, 'actionType', 'buy')
                .having((s) => s.data.transactionsBase64, 'transactions', [
                  testTransactionBase64,
                ]),
          ],
          verify: (_) {
            verify(mockApiV2.buyFixedPriceTx(any)).called(1);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'threads listing currency + price into totalCost (USDC) and '
          'routes the token 1/1 buy through the v2 fixed-price route',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
              // 25 USDC at 6 decimals = 25_000_000 atomic.
              pricePerUnit: MarketPrice(
                rawAmount: 25_000_000,
                currencyMint: usdcMint,
              ),
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
                .having(
                  (s) => s.data.totalCost.rawAmount,
                  'totalCost.rawAmount',
                  25_000_000,
                )
                .having(
                  (s) => s.data.totalCost.currencyMint,
                  'totalCost.currencyMint',
                  usdcMint,
                ),
          ],
          verify: (_) {
            verify(mockApiV2.buyFixedPriceTx(any)).called(1);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'multiplies pricePerUnit by quantity for editions',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
              quantity: 3,
              // 0.5 SOL per print, ×3 = 1.5 SOL.
              pricePerUnit: MarketPrice(
                rawAmount: 0.5e9,
                currencyMint: solMint,
              ),
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.data.totalCost.rawAmount,
              'totalCost.rawAmount',
              1.5e9,
            ),
          ],
        );

        blocTest<MarketBloc, MarketState>(
          'emits error when the v2 fixed-price route fails',
          setUp: () {
            when(
              mockApiV2.buyFixedPriceTx(any),
            ).thenThrow(Exception('API error'));
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (e) => e.failure.message,
              'message',
              contains('Failed to prepare transaction'),
            ),
          ],
        );
      });

      group('Edition artwork (usesBuyEditionTxs)', () {
        blocTest<MarketBloc, MarketState>(
          'transitions to loading then readyToSign for limited edition',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
                .having(
                  (s) => s.data.mintAccount,
                  'mintAccount',
                  testMintAccount,
                )
                .having((s) => s.data.actionType, 'actionType', 'buy'),
          ],
          verify: (_) {
            verify(mockApiV2.buyEditionTx(any)).called(1);
            verifyNever(mockApi.getBuyEditionTxs(any));
          },
        );

        // On-chain allowlist. `setupTx` is the `initProofs` tx that
        // creates the buyer's `proofs` PDA; every `result` tx READS that
        // account, so ordering is not cosmetic — a print broadcast first
        // fails on-chain and burns the buyer's fee. It is a *sibling* of
        // `result` on the wire and is OMITTED (never null) when no setup is
        // needed, which is what every currently-deployed backend does.
        blocTest<MarketBloc, MarketState>(
          'a response WITHOUT setupTx prepares exactly the result txs — no '
          'extra tx to sign, no behaviour change from the deployed backend',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
                .having(
                  (s) => s.data.transactionsBase64,
                  'transactionsBase64',
                  [testTransactionBase64],
                )
                .having((s) => s.data.hasSetupTx, 'hasSetupTx', isFalse),
          ],
        );

        blocTest<MarketBloc, MarketState>(
          'a response WITH setupTx puts it FIRST in the batch so the executor '
          'confirms it before any print is broadcast',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
                setupTx: setupTransactionBase64,
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
                .having(
                  (s) => s.data.transactionsBase64,
                  'transactionsBase64',
                  [setupTransactionBase64, testTransactionBase64],
                )
                .having((s) => s.data.hasSetupTx, 'hasSetupTx', isTrue),
          ],
        );

        blocTest<MarketBloc, MarketState>(
          'a failed setup tx aborts the buy — the print is never signed or '
          'broadcast against a proofs account that does not exist',
          setUp: () {
            when(
              mockWalletManager.signCompiledTx(
                unsignedTx: anyNamed('unsignedTx'),
                additionalSigners: anyNamed('additionalSigners'),
              ),
            ).thenAnswer(
              (invocation) async =>
                  invocation.namedArguments[#unsignedTx] as SignedTx,
            );
            // The setup tx is the first thing broadcast; failing it must stop
            // the batch rather than fall through to the prints.
            when(
              mockRpcService.sendTransaction(any),
            ).thenThrow(Exception('setup tx failed'));
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
            MarketPrepData(
              transactionsBase64: [
                setupTransactionBase64,
                testTransactionBase64,
              ],
              mintAccount: testMintAccount,
              actionType: 'buy',
              flow: AppFlow.editionBuy,
              totalCost: const MarketPrice(rawAmount: 1e9),
              estimatedFeeLamports: 5000,
              hasSetupTx: true,
            ),
          ),
          act: (bloc) => bloc.add(const MarketEvent.confirmAndSign()),
          expect: () => [
            const TxFlowSigning<MarketPrepData, MarketSuccessData>(),
            const TxFlowBroadcasting<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            // Exactly one send + one signature: the executor stopped at the
            // setup tx and the print never left the device.
            verify(mockRpcService.sendTransaction(any)).called(1);
            verify(
              mockWalletManager.signCompiledTx(
                unsignedTx: anyNamed('unsignedTx'),
                additionalSigners: anyNamed('additionalSigners'),
              ),
            ).called(1);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'skips the pre-sign simulation when the batch leads with a setup tx',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
                setupTx: setupTransactionBase64,
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) async {
            bloc.add(
              const MarketEvent.buy(
                mintAccount: testMintAccount,
                supplyType: SupplyType.limitedEdition,
              ),
            );
            await Future<void>.delayed(Duration.zero);
            bloc.add(const MarketEvent.simulate());
          },
          verify: (_) {
            // Simulating the setup tx would report rent for the proofs PDA as
            // the purchase cost; simulating the print behind it fails on the
            // account the setup has not created yet. Neither number belongs on
            // the confirmation sheet, so nothing is simulated at all.
            verifyNever(
              mockRpcService.simulateWithDelta(
                address: anyNamed('address'),
                simulate: anyNamed('simulate'),
              ),
            );
          },
        );

        blocTest<MarketBloc, MarketState>(
          'uses getBuyEditionTxs for open edition',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.openEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            verify(mockApiV2.buyEditionTx(any)).called(1);
            verifyNever(mockApi.getBuyEditionTxs(any));
          },
        );

        // A `edition-print` is a *secondary* resale of one already-minted
        // print — the single most common secondary-market purchase. Buying it
        // transfers that token; it does NOT mint a new print. Routing it to the
        // master-edition print builder (which is what the raw `supplyType`
        // heuristic did) builds a transaction for an artwork the seller isn't
        // selling. It must take the fixed-price builder, exactly like a 1/1,
        // and be tagged with the matching kill-switch cell so the entry gate
        // and the signing backstop name the builder that actually ran.
        blocTest<MarketBloc, MarketState>(
          'routes a secondary edition print to the fixed-price builder, not '
          'the master-edition print builder',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.editionPrint,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.data.flow,
              'flow',
              AppFlow.fixedPriceBuy,
            ),
          ],
          verify: (_) {
            verify(mockApiV2.buyFixedPriceTx(any)).called(1);
            verifyNever(mockApiV2.buyEditionTx(any));
            verifyNever(mockApi.getBuyEditionTxs(any));
          },
        );

        // The authoritative signal beats the indexer heuristic in BOTH
        // directions. A master edition whose supply is already exhausted can
        // be indexed as `edition-print`; the live DAS edition state (or the
        // server's `isMasterEdition`) says otherwise and the print builder is
        // the correct one. This is the pair that proves the sheet and the
        // builder read one decision — the sheet routes on the same value.
        blocTest<MarketBloc, MarketState>(
          'an authoritative isPrintableMasterEdition overrides the supplyType '
          'heuristic and takes the edition-print builder',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.editionPrint,
              isPrintableMasterEdition: true,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.data.flow,
              'flow',
              AppFlow.editionBuy,
            ),
          ],
          verify: (_) {
            verify(mockApiV2.buyEditionTx(any)).called(1);
            verifyNever(mockApiV2.buyFixedPriceTx(any));
          },
        );

        // The converse: an artwork the indexer calls an open/limited edition
        // whose live edition state says it is no longer printable must NOT be
        // sent to the print builder.
        blocTest<MarketBloc, MarketState>(
          'an authoritative isPrintableMasterEdition:false overrides an '
          'open-edition supplyType and takes the fixed-price builder',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.openEdition,
              isPrintableMasterEdition: false,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.data.flow,
              'flow',
              AppFlow.fixedPriceBuy,
            ),
          ],
          verify: (_) {
            verify(mockApiV2.buyFixedPriceTx(any)).called(1);
            verifyNever(mockApiV2.buyEditionTx(any));
          },
        );

        blocTest<MarketBloc, MarketState>(
          'falls back to v1 getBuyEditionTxs on the v2 deferral '
          '(off-chain-Merkle-gated editions)',
          setUp: () {
            // The deferral is the status AND the message — a bare 400 is an
            // ordinary rejection and has to propagate, not be replayed on v1.
            when(mockApiV2.buyEditionTx(any)).thenThrow(
              DioException(
                requestOptions: RequestOptions(
                  path: '/tx/fixed-price/buy-edition',
                ),
                response: Response(
                  requestOptions: RequestOptions(
                    path: '/tx/fixed-price/buy-edition',
                  ),
                  statusCode: 400,
                  data: const {
                    'error': {'message': 'User is not whitelisted'},
                  },
                ),
              ),
            );
            when(mockApi.getBuyEditionTxs(any)).thenAnswer(
              (_) async => ApiResponse<List<BuyEditionTx>>(
                result: [
                  BuyEditionTx(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            verify(mockApiV2.buyEditionTx(any)).called(1);
            verify(mockApi.getBuyEditionTxs(any)).called(1);
          },
        );
      });

      // SYOP ("set your own price") listings carry an on-chain price of 0, and
      // BOTH v2 builders default `maxPrice` to `listing.price`
      // (`req.max_price.unwrap_or(listing.price)`). So the
      // buyer's entered amount MUST travel on the wire — omitting it hands the
      // artist nothing. These tests pin the money path: the entered amount
      // reaches `maxPrice`, a fixed-price buy still sends none (so the backend
      // keeps using the listing price), and a *missing* SYOP amount fails the
      // prepare.
      //
      // An explicitly entered `0` is NOT refused — webapp parity. Its only
      // check is `buyerUIPrice == null` (`BuyEditionModal.onBuyClick`), so a
      // buyer who names 0 on a listing whose seller set no floor buys at 0.
      // The bug was mobile sending *nothing* and silently settling at 0; it was
      // never that 0 is an illegal price.
      group('SYOP listings (buyerSetsPrice)', () {
        // 2.5 SOL — the amount the buyer typed into SetPriceSheet.
        const enteredPrice = MarketPrice(
          rawAmount: 2.5e9,
          currencyMint: solMint,
        );

        blocTest<MarketBloc, MarketState>(
          'sends the entered price as maxPrice on a SYOP 1/1 buy',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
              pricePerUnit: enteredPrice,
              buyerSetsPrice: true,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            expect(req.maxPrice, 2500000000);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'sends the entered per-print price as maxPrice on a SYOP edition buy',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
              pricePerUnit: enteredPrice,
              buyerSetsPrice: true,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApiV2.buyEditionTx(captureAny)).captured.single
                    as BuyEditionTxsRequest;
            expect(req.maxPrice, 2500000000);
          },
        );

        // Curation referral attribution. The buy request is the ONLY carrier:
        // the backend turns `curationShareSlug` into a `curation:<SLUG>` memo
        // on the buyer-signed transaction and joins the indexed sale back to
        // the curator from it. Drop the field and the curator is silently
        // never credited — nothing downstream can reconstruct it.
        blocTest<MarketBloc, MarketState>(
          'stamps the recorded curation share slug on the v2 fixed-price buy',
          setUp: () {
            when(
              mockCurationAttribution.shareSlugFor(testMintAccount),
            ).thenReturn('ABCDEFGH');
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            expect(req.curationShareSlug, 'ABCDEFGH');
          },
        );

        blocTest<MarketBloc, MarketState>(
          'omits the curation share slug when this device recorded no '
          'curation view for the mint',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            // An unattributed buy must carry no slug at all — a placeholder
            // would be minted into a public on-chain memo and, worse, could
            // resolve to a real curation.
            expect(req.curationShareSlug, isNull);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'stamps the recorded curation share slug on the v2 edition buy too',
          setUp: () {
            when(
              mockCurationAttribution.shareSlugFor(testMintAccount),
            ).thenReturn('ABCDEFGH');
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApiV2.buyEditionTx(captureAny)).captured.single
                    as BuyEditionTxsRequest;
            expect(req.curationShareSlug, 'ABCDEFGH');
          },
        );

        blocTest<MarketBloc, MarketState>(
          'carries maxPrice into the v1 edition fallback too — an '
          'off-chain-Merkle-gated SYOP listing is a case v2 defers',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenThrow(
              DioException(
                requestOptions: RequestOptions(
                  path: '/tx/fixed-price/buy-edition',
                ),
                response: Response(
                  requestOptions: RequestOptions(
                    path: '/tx/fixed-price/buy-edition',
                  ),
                  statusCode: 400,
                  data: const {
                    'error': {'message': 'User is not whitelisted'},
                  },
                ),
              ),
            );
            when(mockApi.getBuyEditionTxs(any)).thenAnswer(
              (_) async => ApiResponse<List<BuyEditionTx>>(
                result: [
                  BuyEditionTx(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
              // 25 USDC at 6 decimals.
              pricePerUnit: MarketPrice(
                rawAmount: 25000000,
                currencyMint: usdcMint,
              ),
              buyerSetsPrice: true,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            final req =
                verify(mockApi.getBuyEditionTxs(captureAny)).captured.single
                    as GetBuyEditionTxsRequest;
            expect(req.maxPrice, 25000000);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'refuses a SYOP buy with no entered price at all — the one refusal',
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            // No `pricePerUnit` — what an empty price input would produce.
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
              buyerSetsPrice: true,
            ),
          ),
          expect: () => [
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            // The critical assertion: no transaction is ever requested, so no
            // 0-value purchase can be signed.
            verifyNever(mockApiV2.buyEditionTx(any));
            verifyNever(mockApi.getBuyEditionTxs(any));
            verifyNever(mockApiV2.buyFixedPriceTx(any));
          },
        );

        blocTest<MarketBloc, MarketState>(
          'allows a SYOP 1/1 buy the buyer explicitly priced at 0, sending '
          'maxPrice: 0 rather than refusing',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
              pricePerUnit: MarketPrice(rawAmount: 0, currencyMint: solMint),
              buyerSetsPrice: true,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) {
            // `0`, not null: the refusal is reserved for an absent price, so a
            // deliberate 0 must reach the wire as 0. Sending null here would be
            // indistinguishable from a fixed-price buy and let the backend's
            // `unwrap_or(listing.price)` decide instead of the buyer.
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            expect(req.maxPrice, 0);
          },
        );

        // A fixed-price buy carries the displayed (indexed) price as a
        // ceiling. Without one the backend filled at whatever `listing.price`
        // read at build time, so a seller raising the price inside that window
        // was charged silently to the buyer — the sheet said one number and
        // the wallet paid another. `maxPrice` is a slippage guard, not the
        // amount charged: the fill still uses `listing.price` and simply fails
        // if it exceeds the ceiling. Webapp parity: `useBuyNow` passes
        // `maxPrice: price.toNumber()`.
        blocTest<MarketBloc, MarketState>(
          'a fixed-price 1/1 buy sends the displayed price as a maxPrice '
          'ceiling, so a price raised behind the indexer cannot overcharge',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
              pricePerUnit: enteredPrice,
            ),
          ),
          verify: (_) {
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            expect(req.maxPrice, 2500000000);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'a fixed-price edition buy carries the same ceiling, per print',
          setUp: () {
            when(mockApiV2.buyEditionTx(any)).thenAnswer(
              (_) async => BuyEditionTxsResponse(
                result: [
                  BuyEditionTxItem(
                    mintAccount: testMintAccount,
                    tx: testTransactionBase64,
                  ),
                ],
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.limitedEdition,
              pricePerUnit: enteredPrice,
            ),
          ),
          verify: (_) {
            final req =
                verify(mockApiV2.buyEditionTx(captureAny)).captured.single
                    as BuyEditionTxsRequest;
            expect(req.maxPrice, 2500000000);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'a non-SYOP buy with no known price sends NO maxPrice — the caller '
          'null-coalesces a missing price to 0, and a 0 ceiling would refuse '
          'every paid listing',
          setUp: () {
            when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) => bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
              pricePerUnit: MarketPrice(rawAmount: 0, currencyMint: solMint),
            ),
          ),
          verify: (_) {
            final req =
                verify(mockApiV2.buyFixedPriceTx(captureAny)).captured.single
                    as BuyFixedPriceTxRequest;
            expect(req.maxPrice, isNull);
          },
        );
      });
    });

    group('Burn event', () {
      // The bloc resolves the token standard via DAS to run the burn gate;
      // collection membership and print-edition parentage are resolved
      // on-chain by the builder, so no artwork-index read is involved. The
      // default stub here describes a 1/1 NFT — individual tests override the
      // DAS response to exercise other paths.
      DigitalAsset dasFor({
        TokenStandard standard = TokenStandard.nft,
        String owner = testWalletAddress,
        int supply = 0,
        String? updateAuthority,
        int? currentSize,
        bool hasMasterEditionPlugin = false,
      }) => DigitalAsset(
        id: testMintAccount,
        tokenStandard: standard,
        isMutable: true,
        frozen: false,
        supply: supply,
        freezeDelegateFrozen: false,
        permanentFreezeDelegateFrozen: false,
        hasMasterEditionPlugin: hasMasterEditionPlugin,
        owner: owner,
        updateAuthority: updateAuthority,
        currentSize: currentSize,
      );

      setUp(() {
        when(mockApiV2.getBurnTx(any)).thenAnswer(
          (_) async => ApiResponse<UnsignedTxResponse>(
            result: UnsignedTxResponse(tx: testTransactionBase64),
          ),
        );
      });

      blocTest<MarketBloc, MarketState>(
        'builds burn tx for a 1/1 NFT and sends authority+asset',
        setUp: () {
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => dasFor());
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) =>
            bloc.add(const MarketEvent.burn(mintAccount: testMintAccount)),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.actionType, 'actionType', 'burn')
              .having((s) => s.data.mintAccount, 'mintAccount', testMintAccount)
              .having((s) => s.data.totalCost.rawAmount, 'rawAmount', 0)
              .having((s) => s.data.transactionsBase64, 'transactions', [
                testTransactionBase64,
              ]),
        ],
        verify: (_) {
          final req =
              verify(mockApiV2.getBurnTx(captureAny)).captured.single
                  as BurnTxRequest;
          // Wire-format rename — backend renamed `owner` to `authority`.
          // Guard against accidental regression.
          expect(req.authority, testWalletAddress);
          expect(req.asset, testMintAccount);
          expect(req.tokenStandard.value, 'nft');
          // Printed-edition parentage is resolved on-chain by the builder, so
          // the burn prepare must not pay for an artwork-index round trip.
          verifyNever(mockApi.getArtworkByMint(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'builds a core-collection burn without an index lookup',
        setUp: () {
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            // The burn gate requires the update authority for Core
            // Collections (there's no token holder), so the fixture
            // must model it or the pre-flight check refuses the burn.
            (_) async => dasFor(
              standard: TokenStandard.coreCollection,
              updateAuthority: testWalletAddress,
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) =>
            bloc.add(const MarketEvent.burn(mintAccount: testMintAccount)),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
        ],
        verify: (_) {
          final req =
              verify(mockApiV2.getBurnTx(captureAny)).captured.single
                  as BurnTxRequest;
          expect(req.tokenStandard.value, 'core-collection');
          // The route treats the asset itself as the collection, and resolves
          // membership on-chain — no index lookup on any Core path.
          verifyNever(mockApi.getArtworkByMint(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'isCollection skips the print-edition lookup for legacy collection '
        'NFTs — they are not in the artwork index, so getArtworkByMint '
        'would 404 and fail the whole burn prepare',
        setUp: () {
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => dasFor());
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) => bloc.add(
          const MarketEvent.burn(
            mintAccount: testMintAccount,
            isCollection: true,
          ),
        ),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
        ],
        verify: (_) {
          final req =
              verify(mockApiV2.getBurnTx(captureAny)).captured.single
                  as BurnTxRequest;
          expect(req.tokenStandard.value, 'nft');
          verifyNever(mockApi.getArtworkByMint(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'rejects unsupported standards (cnft) without hitting the API',
        setUp: () {
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => dasFor(standard: TokenStandard.cnft));
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) =>
            bloc.add(const MarketEvent.burn(mintAccount: testMintAccount)),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('not supported'),
          ),
        ],
        verify: (_) {
          verifyNever(mockApiV2.getBurnTx(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'refuses to prepare a burn of a non-empty Core collection — '
        'mpl-core rejects it on-chain (CollectionMustBeEmpty), so the '
        'pre-flight gate must fail cleanly instead of surfacing a raw '
        'simulation error later (webapp BurnModal parity)',
        setUp: () {
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => dasFor(
              standard: TokenStandard.coreCollection,
              updateAuthority: testWalletAddress,
              currentSize: 3,
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) => bloc.add(
          const MarketEvent.burn(
            mintAccount: testMintAccount,
            isCollection: true,
          ),
        ),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('cannot burn this collection'),
          ),
        ],
        verify: (_) {
          verifyNever(mockApiV2.getBurnTx(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'printed Core master editions get the webapp\'s specific refusal '
        'copy — the collection is non-empty because prints exist, and '
        '"you cannot burn this" alone would read as a bug to the artist',
        setUp: () {
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => dasFor(
              standard: TokenStandard.coreCollection,
              updateAuthority: testWalletAddress,
              currentSize: 5,
              hasMasterEditionPlugin: true,
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) =>
            bloc.add(const MarketEvent.burn(mintAccount: testMintAccount)),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('editions have already been printed'),
          ),
        ],
        verify: (_) {
          verifyNever(mockApiV2.getBurnTx(any));
        },
      );

      blocTest<MarketBloc, MarketState>(
        'surfaces error when no wallet is connected',
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn(null);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) =>
            bloc.add(const MarketEvent.burn(mintAccount: testMintAccount)),
        expect: () => [
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('No wallet connected'),
          ),
        ],
        verify: (_) {
          verifyNever(mockDasApi.getAsset(any));
        },
      );
    });

    group('Accept offer event', () {
      // The accept flow's on-chain split is decided by `disablePrimarySplit`.
      // Default is TRUE (webapp's AcceptNftOfferModal): a primary sale is split
      // like a secondary one, seller keeps the remainder. The confirmation
      // sheet's toggle re-dispatches with an explicit value to change that.
      const buyer = 'GpXqzXk1sxK5EjS3zC9tYqQ5m2m5aVw8yD8u6c9WcQ2k';
      const acceptAmount = MarketPrice(
        rawAmount: 1000000000,
        currencyMint: solMint,
      );
      // A non-native (USDC) offer whose associated-token-account resolution is
      // stubbed to fail, so `_resolveProceedsInputs` returns nulls and the
      // toggle re-prepare's simulation takes the simple `simulateWithDelta`
      // path instead of the settle-inspection path — keeps these race/revert
      // tests focused on the re-prepare lifecycle, not the proceeds maths.
      const acceptAmountUsdc = MarketPrice(
        rawAmount: 25_000_000,
        currencyMint: usdcMint,
      );

      /// Minimum asset shape that clears the eligibility gate: held by the
      /// connected seller, unfrozen, no royalty creators (so the direct-
      /// proceeds toggle resolves hidden and these tests stay focused on the
      /// request/lifecycle behavior they were written for).
      const eligibleAsset = DigitalAsset(
        id: testMintAccount,
        tokenStandard: TokenStandard.nft,
        isMutable: true,
        frozen: false,
        supply: 0,
        freezeDelegateFrozen: false,
        permanentFreezeDelegateFrozen: false,
        hasMasterEditionPlugin: false,
        owner: testWalletAddress,
      );

      /// Same asset, frozen — the state a mallow buy-now listing leaves the
      /// token in.
      const frozenAsset = DigitalAsset(
        id: testMintAccount,
        tokenStandard: TokenStandard.nft,
        isMutable: true,
        frozen: true,
        supply: 0,
        freezeDelegateFrozen: false,
        permanentFreezeDelegateFrozen: false,
        hasMasterEditionPlugin: false,
        owner: testWalletAddress,
      );

      MarketBloc buildBloc() => MarketBloc(
        mockApi,
        mockApiV2,
        mockWalletManager,
        mockRpcService,
        mockAuthService,
        mockDasApi,
        makeFlow(),
        mockPriceService,
        const FeeConfig(),
        mockMarketplaceConfig,
        mockMarketAccounts,
        mockCurationAttribution,
      );

      // Accepting an offer is irreversible and costs a signature, and both
      // hosts (artwork sheet + offers inbox) dispatch behind nothing but the
      // kill switch. The webapp refuses these states before signing; the
      // backend re-checks DAS ownership and the offer's buyer but NOT
      // buyer≠seller and NOT the frozen bit, so without this gate the user
      // signs a transaction that fails on-chain — or buys their own artwork
      // from themselves.
      group('eligibility gate', () {
        blocTest<MarketBloc, MarketState>(
          'refuses accepting your own offer without building a tx — the '
          'backend never checks buyer != seller',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => eligibleAsset);
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              // The connected wallet is both the holder and the bidder.
              buyer: testWalletAddress,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.failure.message,
              'message',
              'Cannot accept your own offer',
            ),
          ],
          verify: (_) => verifyNever(mockApiV2.acceptOfferTx(any)),
        );

        blocTest<MarketBloc, MarketState>(
          'refuses a frozen artwork with no mallow listing to delist — the '
          'accept instruction cannot move a frozen token',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => frozenAsset);
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.failure.message,
              'message',
              'This artwork is frozen',
            ),
          ],
          verify: (_) => verifyNever(mockApiV2.acceptOfferTx(any)),
        );

        // The legitimate frozen case. A mallow buy-now listing freezes the
        // token in the seller's wallet and the accept tx delists in the same
        // sequence — refusing here would break accepting an offer on a listed
        // artwork, which is the most common accept there is.
        blocTest<MarketBloc, MarketState>(
          'allows a frozen artwork that carries a mallow listing',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => frozenAsset);
            when(mockMarketAccounts.readListing(any)).thenAnswer(
              (_) async => presentRead(const {
                'pubkey': 'PdA11111111111111111111111111111111111111111',
                'accountType': 'listing',
                'price': '1000000000',
              }),
            );
            when(mockApiV2.acceptOfferTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) => verify(mockApiV2.acceptOfferTx(any)).called(1),
        );

        blocTest<MarketBloc, MarketState>(
          'refuses when a live auction on the artwork already carries a bid — '
          'accepting would sell it out from under the bidder',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => eligibleAsset);
            when(mockMarketAccounts.readAuctionConfig(any)).thenAnswer(
              (_) async => presentRead(const {
                'pubkey': 'PdA11111111111111111111111111111111111111111',
                'accountType': 'auctionConfig',
                'highestBidAmount': '2000000000',
                'highestBidder': 'B1dDeR1111111111111111111111111111111111111',
              }),
            );
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.failure.message,
              'message',
              contains('auction already has a bid'),
            ),
          ],
          verify: (_) => verifyNever(mockApiV2.acceptOfferTx(any)),
        );

        // An auction with no bid is still not acceptable — the artwork is
        // escrowed/committed to the auction, exactly as the webapp's
        // listing-type fallthrough decides.
        blocTest<MarketBloc, MarketState>(
          'refuses a bid-less auction on the listing type',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => eligibleAsset);
            when(mockMarketAccounts.readAuctionConfig(any)).thenAnswer(
              (_) async => presentRead(const {
                'pubkey': 'PdA11111111111111111111111111111111111111111',
                'accountType': 'auctionConfig',
                'highestBidAmount': '0',
              }),
            );
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.failure.message,
              'message',
              'Offers cannot be accepted on this listing',
            ),
          ],
          verify: (_) => verifyNever(mockApiV2.acceptOfferTx(any)),
        );

        blocTest<MarketBloc, MarketState>(
          'refuses when the connected wallet no longer holds the artwork',
          setUp: () {
            when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
              (_) async => const DigitalAsset(
                id: testMintAccount,
                tokenStandard: TokenStandard.nft,
                isMutable: true,
                frozen: false,
                supply: 0,
                freezeDelegateFrozen: false,
                permanentFreezeDelegateFrozen: false,
                hasMasterEditionPlugin: false,
                owner: 'S0me0therH01der11111111111111111111111111',
              ),
            );
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
              (s) => s.failure.message,
              'message',
              "You don't own this artwork",
            ),
          ],
          verify: (_) => verifyNever(mockApiV2.acceptOfferTx(any)),
        );

        // An undetermined PDA read (transport/decode failure) must never
        // manufacture a refusal — the accept still has to be reachable on a
        // flaky network, and the backend re-validates anyway.
        blocTest<MarketBloc, MarketState>(
          'an undetermined listing read does not refuse a frozen artwork',
          setUp: () {
            when(
              mockDasApi.getAsset(testMintAccount),
            ).thenAnswer((_) async => frozenAsset);
            when(mockMarketAccounts.readListing(any)).thenAnswer(
              (_) async => (
                status: OnChainReadStatus.unknown,
                account: null,
                pda: '',
                viewSlot: null,
              ),
            );
            when(mockApiV2.acceptOfferTx(any)).thenAnswer(
              (_) async => ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              ),
            );
          },
          build: buildBloc,
          act: (bloc) => bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmount,
            ),
          ),
          expect: () => [
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
            isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          ],
          verify: (_) => verify(mockApiV2.acceptOfferTx(any)).called(1),
        );
      });

      blocTest<MarketBloc, MarketState>(
        'defaults enablePrimarySplit to false on the AcceptOfferTxRequest',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          // Gate lookup — irrelevant to the request threading; the asset is
          // eligible and carries no creators, so the direct-proceeds toggle
          // resolves hidden.
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
          ),
        ),
        verify: (_) {
          final req =
              verify(mockApiV2.acceptOfferTx(captureAny)).captured.single
                  as AcceptOfferTxRequest;
          expect(req.enablePrimarySplit, isFalse);
          expect(req.buyer, buyer);
        },
      );

      blocTest<MarketBloc, MarketState>(
        'forwards an explicit disablePrimarySplit:false (toggle checked)',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
            disablePrimarySplit: false,
          ),
        ),
        verify: (_) {
          final req =
              verify(mockApiV2.acceptOfferTx(captureAny)).captured.single
                  as AcceptOfferTxRequest;
          expect(req.enablePrimarySplit, isTrue);
        },
      );

      // R1 (critical race): from the instant a toggle is dispatched the flow is
      // locked (TxFlowPreparing emitted synchronously, before any await), so a
      // Confirm tap racing the toggle fails the `_onConfirmAndSign` ready guard
      // and can NOT sign/broadcast the pre-toggle tx — the money can't route
      // contrary to the checkbox the user just flipped.
      blocTest<MarketBloc, MarketState>(
        'a toggle locks the flow so an immediately-following confirmAndSign '
        'never signs the pre-toggle tx',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(
            mockRpcService.resolveAssociatedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(Exception('no ata'));
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 1),
            ),
          );
          // A working signer, so a leaked confirm would actually sign — the
          // test proves the guard stops it from ever getting that far.
          when(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).thenAnswer(
            (invocation) async =>
                invocation.namedArguments[#unsignedTx] as SignedTx,
          );
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) async {
          bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmountUsdc,
            ),
          );
          // Let the initial prepare settle to a signable ready.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          // Toggle, then try to confirm in the SAME synchronous frame — the
          // classic race. The toggle's synchronous TxFlowPreparing must win.
          bloc.add(
            const MarketEvent.setAcceptOfferSplit(disablePrimarySplit: false),
          );
          bloc.add(const MarketEvent.confirmAndSign());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        verify: (_) {
          verifyNever(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          );
        },
      );

      // R3: a toggle re-prepare produces a fresh, unsimulated tx and no UI
      // dispatcher re-fires simulate on a re-prepare — so the bloc drives the
      // simulation itself, resolving the "You'll receive" breakdown after a
      // toggle instead of shimmering forever.
      blocTest<MarketBloc, MarketState>(
        'a toggle re-prepare re-simulates the rebuilt tx and flips the split',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(
            mockRpcService.resolveAssociatedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(Exception('no ata'));
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 42),
            ),
          );
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) async {
          bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmountUsdc,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(
            const MarketEvent.setAcceptOfferSplit(disablePrimarySplit: false),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        verify: (bloc) {
          // Only the toggle triggers a simulation — the initial prepare defers
          // to the confirmation sheet's mount (not exercised in a bloc test).
          verify(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).called(1);
          final state = bloc.state;
          expect(state, isA<TxFlowReady<MarketPrepData, MarketSuccessData>>());
          final ready = state as TxFlowReady<MarketPrepData, MarketSuccessData>;
          expect(ready.data.simulationResult?.success, isTrue);
          // The rebuilt prep carries the flipped split.
          expect(ready.data.disablePrimarySplit, isFalse);
        },
      );

      // R5: a display toggle must never lose an already-signable accept. When
      // the re-prepare build fails transiently the bloc reverts to the previous
      // ready (previous split + checkbox value) instead of emitting
      // TxFlowFailure — which the sheet's pre-confirm listener would treat as a
      // prepare failure and pop the whole sheet.
      blocTest<MarketBloc, MarketState>(
        'a failed toggle re-prepare reverts to the previous ready without '
        'emitting TxFlowFailure',
        setUp: () {
          var calls = 0;
          when(mockApiV2.acceptOfferTx(any)).thenAnswer((_) async {
            calls++;
            if (calls == 1) {
              return ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              );
            }
            throw Exception('transient rebuild failure');
          });
          when(
            mockRpcService.resolveAssociatedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(Exception('no ata'));
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) async {
          bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmountUsdc,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(
            const MarketEvent.setAcceptOfferSplit(disablePrimarySplit: false),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          // Initial ready keeps the default split (true).
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.disablePrimarySplit,
            'initial split',
            true,
          ),
          // Toggle locks the flow…
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          // …then the rebuild fails and reverts to the SAME previous ready —
          // split still true (the flip to false is discarded), never a
          // TxFlowFailure that would pop the sheet.
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.disablePrimarySplit,
            'reverted split',
            true,
          ),
        ],
      );

      // "You'll receive" is the only number an accept-offer sheet shows a
      // seller before an irreversible sale, and it was resolved *exclusively*
      // from a tx simulation — three RPC round-trips. When any of them failed
      // the amounts stayed null and the sheet shimmered indefinitely while
      // still offering Confirm. The webapp never simulates at all: it computes
      // the split arithmetically (`getProceedsSplits`). These pin that mobile
      // falls back to that same arithmetic, so the seller always sees what the
      // sale pays them.
      //
      // Fixture: a primary sale (`primarySaleHappened: false`) with no creator
      // shares, so `getProceedsSplits` reduces to the 5% primary marketplace
      // fee and 95% to the seller on a 1 SOL offer.
      group('proceeds fallback when the simulation cannot answer', () {
        void stubSimulateInputs() {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        }

        blocTest<MarketBloc, MarketState>(
          'a simulation that runs but fails resolves the arithmetic split '
          'instead of shimmering forever',
          setUp: () {
            stubSimulateInputs();
            when(
              mockRpcService.getBalanceForAddress(any),
            ).thenAnswer((_) async => 0);
            when(
              mockRpcService.simulateEncodedTransaction(
                any,
                inspectAccounts: anyNamed('inspectAccounts'),
              ),
            ).thenAnswer(
              (_) async =>
                  const SimulationResult(success: false, error: 'blockhash'),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) async {
            bloc.add(
              const MarketEvent.acceptOffer(
                mintAccount: testMintAccount,
                buyer: buyer,
                amount: acceptAmount,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            bloc.add(const MarketEvent.simulate());
            await Future<void>.delayed(const Duration(milliseconds: 50));
          },
          verify: (bloc) {
            final state =
                bloc.state as TxFlowReady<MarketPrepData, MarketSuccessData>;
            final proceeds = state.data.settleProceeds!;
            expect(proceeds.isResolved, isTrue);
            // 5% primary marketplace fee, the rest to the seller.
            expect(proceeds.marketFeeRaw, 50000000);
            expect(proceeds.sellerEarningsRaw, 950000000);
            expect(proceeds.royaltiesToOthersRaw, 0);
            expect(state.data.isSimulating, isFalse);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'an RPC that throws mid-simulation resolves the same fallback — the '
          'handler used to die with isSimulating still true',
          setUp: () {
            stubSimulateInputs();
            when(
              mockRpcService.getBalanceForAddress(any),
            ).thenThrow(Exception('rpc down'));
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) async {
            bloc.add(
              const MarketEvent.acceptOffer(
                mintAccount: testMintAccount,
                buyer: buyer,
                amount: acceptAmount,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            bloc.add(const MarketEvent.simulate());
            await Future<void>.delayed(const Duration(milliseconds: 50));
          },
          verify: (bloc) {
            final state =
                bloc.state as TxFlowReady<MarketPrepData, MarketSuccessData>;
            expect(state.data.isSimulating, isFalse);
            expect(state.data.settleProceeds!.sellerEarningsRaw, 950000000);
          },
        );

        blocTest<MarketBloc, MarketState>(
          'a simulation that DOES resolve still wins — it reflects the fee the '
          'program actually charges (discount tokens the client cannot see)',
          setUp: () {
            stubSimulateInputs();
            // Seller nets 0.9 SOL, fee account takes 0.02 — deliberately
            // different from the 0.95 / 0.05 the arithmetic would produce.
            when(
              mockRpcService.getBalanceForAddress(any),
            ).thenAnswer((_) async => 0);
            when(
              mockRpcService.simulateEncodedTransaction(
                any,
                inspectAccounts: anyNamed('inspectAccounts'),
              ),
            ).thenAnswer(
              (_) async => const SimulationResult(
                success: true,
                inspectedAccountLamports: {
                  testWalletAddress: 900000000,
                  kMallowFeeAddress: 20000000,
                },
              ),
            );
          },
          build: () => MarketBloc(
            mockApi,
            mockApiV2,
            mockWalletManager,
            mockRpcService,
            mockAuthService,
            mockDasApi,
            makeFlow(),
            mockPriceService,
            const FeeConfig(),
            mockMarketplaceConfig,
            mockMarketAccounts,
            mockCurationAttribution,
          ),
          act: (bloc) async {
            bloc.add(
              const MarketEvent.acceptOffer(
                mintAccount: testMintAccount,
                buyer: buyer,
                amount: acceptAmount,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
            bloc.add(const MarketEvent.simulate());
            await Future<void>.delayed(const Duration(milliseconds: 50));
          },
          verify: (bloc) {
            final state =
                bloc.state as TxFlowReady<MarketPrepData, MarketSuccessData>;
            final proceeds = state.data.settleProceeds!;
            // Seller earnings add the gas back (the seller is also the payer).
            expect(proceeds.sellerEarningsRaw, 900000000 + 5000);
            expect(proceeds.marketFeeRaw, 20000000);
          },
        );
      });

      // The one exception to R5's revert: a remote kill. Reverting would drop it
      // silently — no state change for the host to present from — and hand back
      // a Confirm the signing backstop will refuse anyway. The kill must reach
      // the host as a failure so the operator's copy gets shown.
      blocTest<MarketBloc, MarketState>(
        'a toggle re-prepare killed by the switch emits TxFlowFailure instead '
        'of reverting to ready, so the kill is not swallowed',
        setUp: () {
          var calls = 0;
          when(mockApiV2.acceptOfferTx(any)).thenAnswer((_) async {
            calls++;
            if (calls == 1) {
              return ApiResponse<UnsignedTxResponse>(
                result: UnsignedTxResponse(tx: testTransactionBase64),
              );
            }
            throw const TransactionFlowDisabledException(
              'Accepting offers is paused. Your offer is safe.',
            );
          });
          when(
            mockRpcService.resolveAssociatedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(Exception('no ata'));
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) async => eligibleAsset);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) async {
          bloc.add(
            const MarketEvent.acceptOffer(
              mintAccount: testMintAccount,
              buyer: buyer,
              amount: acceptAmountUsdc,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(
            const MarketEvent.setAcceptOfferSplit(disablePrimarySplit: false),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>()
              .having(
                (s) => s.failure.isFlowDisabled,
                'failure.isFlowDisabled',
                isTrue,
              )
              // Verbatim — never "Failed to prepare accept offer: …".
              .having(
                (s) => s.failure.message,
                'failure.message',
                'Accepting offers is paused. Your offer is safe.',
              ),
        ],
      );

      // The "Direct all proceeds to creators" gate (showDirectProceedsOption)
      // mirrors webapp `isSecondaryMarket` + `showDirectProceedsOption`, NOT
      // the old `updateAuthority == seller` predicate. testWalletAddress is the
      // connected seller; a creator address distinct from it makes the split a
      // real (non-no-op) redirect.
      const otherCreator = 'CreAtoR11111111111111111111111111111111111';
      const collectionMint = 'CoLLecT10n11111111111111111111111111111111';

      DigitalAsset gateAsset({
        required TokenStandard standard,
        bool primarySaleHappened = false,
        // Defaults to the connected seller — anything else is refused by the
        // eligibility gate before the proceeds gate is ever consulted.
        String owner = testWalletAddress,
        String? updateAuthority,
        String? collectionKey,
        int? royaltiesPluginBasisPoints,
        List<OnChainCreator> royaltiesPluginCreators = const [],
        List<OnChainCreator> tokenMetadataCreators = const [],
      }) => DigitalAsset(
        id: testMintAccount,
        tokenStandard: standard,
        isMutable: true,
        frozen: false,
        supply: 0,
        freezeDelegateFrozen: false,
        permanentFreezeDelegateFrozen: false,
        hasMasterEditionPlugin: false,
        owner: owner,
        updateAuthority: updateAuthority,
        collectionKey: collectionKey,
        primarySaleHappened: primarySaleHappened,
        royaltiesPluginBasisPoints: royaltiesPluginBasisPoints,
        royaltiesPluginCreators: royaltiesPluginCreators,
        tokenMetadataCreators: tokenMetadataCreators,
      );

      MarketBloc buildGateBloc() => MarketBloc(
        mockApi,
        mockApiV2,
        mockWalletManager,
        mockRpcService,
        mockAuthService,
        mockDasApi,
        makeFlow(),
        mockPriceService,
        const FeeConfig(),
        mockMarketplaceConfig,
        mockMarketAccounts,
        mockCurationAttribution,
      );

      // False-negative of the OLD predicate: a genuine primary sale
      // (primarySaleHappened == false) whose first creator isn't the seller
      // must SHOW the toggle even though the seller is NOT the update
      // authority. The removed `updateAuthority == seller` gate wrongly hid it.
      blocTest<MarketBloc, MarketState>(
        'shows the toggle on an unsold TM NFT even when the seller is not the '
        'update authority',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => gateAsset(
              standard: TokenStandard.nft,
              // Someone other than the seller holds the update authority.
              updateAuthority: otherCreator,
              tokenMetadataCreators: const [
                OnChainCreator(
                  address: otherCreator,
                  share: 100,
                  verified: true,
                ),
              ],
            ),
          );
        },
        build: buildGateBloc,
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
          ),
        ),
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.showDirectProceedsOption,
            'showDirectProceedsOption',
            true,
          ),
        ],
        verify: (_) {
          // Token-metadata standards never fetch the collection.
          verifyNever(mockDasApi.getAsset(collectionMint));
        },
      );

      // False-positive of the OLD predicate: once primarySaleHappened flips
      // true the asset trades secondary and the toggle must HIDE — even when
      // the seller IS the update authority (which the old gate keyed on).
      blocTest<MarketBloc, MarketState>(
        'hides the toggle once a TM NFT has had its primary sale, even when '
        'the seller is the update authority',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => gateAsset(
              standard: TokenStandard.nft,
              primarySaleHappened: true,
              updateAuthority: testWalletAddress,
              tokenMetadataCreators: const [
                OnChainCreator(
                  address: otherCreator,
                  share: 100,
                  verified: true,
                ),
              ],
            ),
          );
        },
        build: buildGateBloc,
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
          ),
        ),
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.showDirectProceedsOption,
            'showDirectProceedsOption',
            false,
          ),
        ],
      );

      // A Core asset carrying no royalties plugin of its own reads
      // creators from its parent collection's plugin (Helius doesn't merge
      // them), so the gate must fetch the collection to see the non-seller
      // creator and show the toggle. owner == collection.updateAuthority keeps
      // it a primary sale.
      blocTest<MarketBloc, MarketState>(
        'shows the toggle for a Core asset whose royalties live on its parent '
        'collection (second getAsset)',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => gateAsset(
              standard: TokenStandard.core,
              collectionKey: collectionMint,
              // No own royalties plugin.
            ),
          );
          when(mockDasApi.getAsset(collectionMint)).thenAnswer(
            (_) async => gateAsset(
              standard: TokenStandard.coreCollection,
              // owner == collection updateAuthority ⇒ primary sale. The seller
              // must also be the holder or the eligibility gate refuses first,
              // so both are the connected wallet.
              updateAuthority: testWalletAddress,
              royaltiesPluginBasisPoints: 500,
              royaltiesPluginCreators: const [
                OnChainCreator(
                  address: otherCreator,
                  share: 100,
                  verified: true,
                ),
              ],
            ),
          );
        },
        build: buildGateBloc,
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
          ),
        ),
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.showDirectProceedsOption,
            'showDirectProceedsOption',
            true,
          ),
        ],
        verify: (_) {
          verify(mockDasApi.getAsset(collectionMint)).called(1);
        },
      );

      // The collection fetch is best-effort: if it throws, the gate degrades
      // to asset-only computation (empty Core creators → toggle hidden) and
      // never crashes the prepare.
      blocTest<MarketBloc, MarketState>(
        'hides the toggle without crashing when the Core collection fetch '
        'throws',
        setUp: () {
          when(mockApiV2.acceptOfferTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(mockDasApi.getAsset(testMintAccount)).thenAnswer(
            (_) async => gateAsset(
              standard: TokenStandard.core,
              collectionKey: collectionMint,
            ),
          );
          when(
            mockDasApi.getAsset(collectionMint),
          ).thenThrow(Exception('collection lookup failed'));
        },
        build: buildGateBloc,
        act: (bloc) => bloc.add(
          const MarketEvent.acceptOffer(
            mintAccount: testMintAccount,
            buyer: buyer,
            amount: acceptAmount,
          ),
        ),
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.showDirectProceedsOption,
            'showDirectProceedsOption',
            false,
          ),
        ],
      );
    });

    group('Settle auction event', () {
      /// Holds the pre-flight's DAS read open so the state *during* it is
      /// assertable.
      late Completer<DigitalAsset> gate;

      const winningBid = MarketPrice(
        rawAmount: 1000000000,
        currencyMint: solMint,
      );

      /// The settled asset as the proceeds pre-flight's DAS read sees it.
      const settledAsset = DigitalAsset(
        id: testMintAccount,
        tokenStandard: TokenStandard.nft,
        isMutable: true,
        frozen: false,
        supply: 0,
        freezeDelegateFrozen: false,
        permanentFreezeDelegateFrozen: false,
        hasMasterEditionPlugin: false,
        owner: testWalletAddress,
      );

      // The artwork screen opens the confirm sheet the instant Settle is
      // tapped, and the sheet picks its layout off the flow state: anything
      // that isn't preparing/ready renders the gas-only "Network fee" row.
      // The proceeds pre-flight costs a DAS read (~a second on a cold RPC), so
      // a bloc that only reaches preparing *after* it flashes a fee line where
      // the seller's shimmering "You'll receive" belongs.
      blocTest<MarketBloc, MarketState>(
        'emits preparing before the proceeds pre-flight so the sheet never '
        'flashes the gas-only fee row',
        setUp: () {
          gate = Completer<DigitalAsset>();
          when(mockApiV2.settleAuctionTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
          when(
            mockDasApi.getAsset(testMintAccount),
          ).thenAnswer((_) => gate.future);
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        act: (bloc) async {
          bloc.add(
            const MarketEvent.settleAuction(
              mintAccount: testMintAccount,
              winningBid: winningBid,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            bloc.state,
            isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
            reason:
                'the confirm sheet is already open while the DAS read is in '
                'flight',
          );
          gate.complete(settledAsset);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        expect: () => [
          isA<TxFlowPreparing<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.settleProceeds?.grossBidRaw,
            'gross winning bid',
            1000000000,
          ),
        ],
      );
    });

    group('Simulate event', () {
      blocTest<MarketBloc, MarketState>(
        'simulates transaction successfully',
        setUp: () {
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 50000),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => [
          TxFlowReady<MarketPrepData, MarketSuccessData>(
            MarketPrepData(
              transactionsBase64: [testTransactionBase64],
              mintAccount: testMintAccount,
              actionType: 'buy',
              flow: AppFlow.fixedPriceBuy,
              totalCost: const MarketPrice(rawAmount: 1e9),
              estimatedFeeLamports: 5000,
              isSimulating: true,
            ),
          ),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.isSimulating, 'isSimulating', false)
              .having(
                (s) => s.data.simulationResult?.success,
                'simulation success',
                true,
              ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'handles simulation failure',
        setUp: () {
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(
                success: false,
                error: 'Insufficient funds',
              ),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => [
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.isSimulating,
            'isSimulating',
            true,
          ),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.isSimulating, 'isSimulating', false)
              .having(
                (s) => s.data.simulationResult?.success,
                'simulation success',
                false,
              )
              .having(
                (s) => s.data.simulationResult?.error,
                'error message',
                'Insufficient funds',
              ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'does nothing when not in readyToSign state',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => <MarketState>[],
      );

      // The burn flow specifically fetches the payer's pre-balance and
      // asks the RPC to return post-simulation lamports so the
      // confirmation sheet can render "You'll receive ~X SOL". Diff =
      // post − pre (already net of fee). These tests guard the wiring
      // because the breakdown only renders this row when the bloc
      // publishes the delta.
      blocTest<MarketBloc, MarketState>(
        'simulates burn and threads payer lamport delta into state',
        setUp: () {
          // Burn nets a rent refund (~0.002 SOL) minus the tx fee — a
          // positive post−pre delta the service computes and the bloc threads
          // straight into state.
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 5000),
              lamportsDelta: 1_995_000,
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'burn',
            flow: AppFlow.nftBurn,
            totalCost: const MarketPrice(rawAmount: 0),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => [
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.isSimulating,
            'isSimulating',
            true,
          ),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.isSimulating, 'isSimulating', false)
              .having(
                (s) => s.data.simulatedPayerLamportsDelta,
                'payer delta',
                1_995_000,
              ),
        ],
        verify: (_) {
          // The burn payer must be passed so the service inspects it and the
          // breakdown can render the refund row.
          final captured =
              verify(
                    mockRpcService.simulateWithDelta(
                      address: captureAnyNamed('address'),
                      simulate: anyNamed('simulate'),
                    ),
                  ).captured.single
                  as String?;
          expect(captured, testWalletAddress);
        },
      );

      blocTest<MarketBloc, MarketState>(
        'threads a null payer delta while still surfacing the sim result',
        setUp: () {
          // Service couldn't derive a delta (e.g. pre-balance fetch failed)
          // but the simulation itself succeeded — the bloc must still publish
          // the result, just without a refund row.
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 1),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'burn',
            flow: AppFlow.nftBurn,
            totalCost: const MarketPrice(rawAmount: 0),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => [
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.isSimulating,
            'isSimulating',
            true,
          ),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.isSimulating, 'isSimulating', false)
              .having(
                (s) => s.data.simulatedPayerLamportsDelta,
                'payer delta',
                isNull,
              )
              .having(
                (s) => s.data.simulationResult?.success,
                'simulation success',
                true,
              ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'passes a null address (no inspection) for non-burn action types',
        setUp: () {
          when(
            mockRpcService.simulateWithDelta(
              address: anyNamed('address'),
              simulate: anyNamed('simulate'),
            ),
          ).thenAnswer(
            (_) async => const SimulationDelta(
              result: SimulationResult(success: true, unitsConsumed: 1),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.simulate()),
        expect: () => [
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>()
              .having((s) => s.data.isSimulating, 'isSimulating', false)
              .having(
                (s) => s.data.simulatedPayerLamportsDelta,
                'payer delta',
                isNull,
              ),
        ],
        verify: (_) {
          // Avoid the extra pre-balance roundtrip on the hot buy/offer path:
          // a null address tells the service to skip inspection entirely.
          final captured =
              verify(
                    mockRpcService.simulateWithDelta(
                      address: captureAnyNamed('address'),
                      simulate: anyNamed('simulate'),
                    ),
                  ).captured.single
                  as String?;
          expect(captured, isNull);
        },
      );
    });

    group('ConfirmAndSign event', () {
      blocTest<MarketBloc, MarketState>(
        'emits signing then error when wallet signing fails',
        setUp: () {
          when(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).thenThrow(Exception('Mock signing failure'));
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.confirmAndSign()),
        expect: () => [
          const TxFlowSigning<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('Transaction failed'),
          ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'transitions through signing to broadcasting then error when broadcast fails',
        setUp: () {
          // Return the same SignedTx the helper passed in — fine for the
          // mock since sendTransaction won't actually inspect it.
          when(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).thenAnswer(
            (invocation) async =>
                invocation.namedArguments[#unsignedTx] as SignedTx,
          );
          when(
            mockRpcService.sendTransaction(any),
          ).thenThrow(Exception('Mock broadcast failure'));
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.confirmAndSign()),
        expect: () => [
          const TxFlowSigning<MarketPrepData, MarketSuccessData>(),
          const TxFlowBroadcasting<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>().having(
            (e) => e.failure.message,
            'message',
            contains('Transaction failed'),
          ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'does nothing when not in readyToSign state',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        act: (bloc) => bloc.add(const MarketEvent.confirmAndSign()),
        expect: () => <MarketState>[],
      );

      // Cancellation is a clean abort — the bloc routes it via
      // [AppFailure.cancelled] and surfaces the raw message verbatim
      // instead of prefixing it with "Transaction failed". This matters
      // because the confirmation sheet shows the error string to the user
      // and "Transaction failed: cancelled" would look like a hard failure.
      blocTest<MarketBloc, MarketState>(
        'classifies signing cancellation distinctly from other errors',
        setUp: () {
          when(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).thenThrow(
            const TransactionAuthCancelledException(
              TransactionAuthOutcome.cancelled,
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.confirmAndSign()),
        expect: () => [
          const TxFlowSigning<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowFailure<MarketPrepData, MarketSuccessData>>()
              .having(
                (e) => e.failure.message,
                'message',
                'Authentication cancelled.',
              )
              .having(
                (e) => e.failure.message,
                'no "Transaction failed" prefix',
                isNot(contains('Transaction failed')),
              ),
        ],
      );
    });

    group('Reset event', () {
      blocTest<MarketBloc, MarketState>(
        'resets to initial state from readyToSign',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => TxFlowReady<MarketPrepData, MarketSuccessData>(
          MarketPrepData(
            transactionsBase64: [testTransactionBase64],
            mintAccount: testMintAccount,
            actionType: 'buy',
            flow: AppFlow.fixedPriceBuy,
            totalCost: const MarketPrice(rawAmount: 1e9),
            estimatedFeeLamports: 5000,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.reset()),
        expect: () => [const TxFlowIdle<MarketPrepData, MarketSuccessData>()],
      );

      blocTest<MarketBloc, MarketState>(
        'resets to initial state from error',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowFailure<MarketPrepData, MarketSuccessData>(
          AppFailure.unknown('Some error'),
        ),
        act: (bloc) => bloc.add(const MarketEvent.reset()),
        expect: () => [const TxFlowIdle<MarketPrepData, MarketSuccessData>()],
      );

      blocTest<MarketBloc, MarketState>(
        'resets to initial state from a settled success (indexed != null)',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'buy',
            mintAccount: testMintAccount,
            indexed: true,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.reset()),
        expect: () => [const TxFlowIdle<MarketPrepData, MarketSuccessData>()],
      );

      // The pipeline sheet pops ~800ms after the optimistic (indexed=null)
      // success and resets — but the entry-indexing poll lands seconds later.
      // Resetting then would drop the ack on an idle state and the artwork
      // screen would never see the `indexed` flip that clears its pending-
      // indexer gate (the bid sheet would stay hidden). So a reset from an
      // optimistic success is deferred until the ack arrives.
      blocTest<MarketBloc, MarketState>(
        'defers reset from an optimistic success (indexed == null)',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'bid',
            mintAccount: testMintAccount,
          ),
        ),
        act: (bloc) => bloc.add(const MarketEvent.reset()),
        // No emission — the success state is held alive for the pending ack.
        expect: () => <MarketState>[],
      );

      // Once the deferred ack lands, the `indexed` flip is emitted first (so
      // listeners run their post-tx refresh) and only then does the held reset
      // tear the flow down to idle.
      blocTest<MarketBloc, MarketState>(
        'applies the deferred reset after the indexedAck flips indexed',
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'bid',
            mintAccount: testMintAccount,
          ),
        ),
        act: (bloc) {
          bloc.add(const MarketEvent.reset());
          bloc.add(
            const MarketEvent.indexedAck(signature: testSignature, ok: true),
          );
        },
        expect: () => const [
          TxFlowSuccess<MarketPrepData, MarketSuccessData>(
            signature: testSignature,
            result: MarketSuccessData(
              explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
              actionType: 'bid',
              mintAccount: testMintAccount,
              indexed: true,
            ),
          ),
          TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        ],
      );

      // The artwork *detail* screen refetches off the `indexed` flip, but the
      // browse/list surfaces that render the same piece — home rails,
      // collection and curation grids, profile grids — are not subscribed to
      // it. Without an app-wide fan-out they keep serving the pre-action
      // price and listing badge (webapp: `invalidateAssetQueries` runs on
      // every money mutation, not just on edits).
      blocTest<MarketBloc, MarketState>(
        'fans the acked mint out to the browse/list surfaces',
        setUp: () {
          final signal = ArtworkEditedSignal();
          if (sl.isRegistered<ArtworkEditedSignal>()) {
            sl.unregister<ArtworkEditedSignal>();
          }
          sl.registerSingleton<ArtworkEditedSignal>(signal);
          editedMints = [];
          editedSub = signal.stream.listen(editedMints.add);
        },
        tearDown: () async {
          await editedSub?.cancel();
          editedSub = null;
          if (sl.isRegistered<ArtworkEditedSignal>()) {
            sl.unregister<ArtworkEditedSignal>();
          }
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'buy',
            mintAccount: testMintAccount,
          ),
        ),
        act: (bloc) => bloc.add(
          const MarketEvent.indexedAck(signature: testSignature, ok: true),
        ),
        wait: const Duration(milliseconds: 10),
        verify: (_) => expect(editedMints, [testMintAccount]),
      );
    });

    // Every consumer of a market action gates its post-tx refetch on the
    // `indexed` flip — the offers inbox refresh (`marketOffersListenWhen` +
    // `_onMarketState`) and the artwork screen's pending-indexer gate clear.
    // `_onIndexedAck` drops an ack whose state moved on, so without a flush a
    // second action started before the first ack lands would strand the first
    // flow on `indexed == null`: the settled offer keeps a live Accept/Cancel
    // pill re-prompting the signer against a closed Offer PDA until a manual
    // pull-to-refresh. The deferred-reset path covers only the reset case.
    group('Pending indexer ack superseded by a second flow', () {
      blocTest<MarketBloc, MarketState>(
        'flushes the unacked success (indexed=false) before the second flow, '
        'and drops the late ack so exactly one flip is observed',
        setUp: () {
          when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        // Offer just accepted, chain-confirmed, indexer poll still in flight.
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'accept-offer',
            mintAccount: testMintAccount,
          ),
        ),
        act: (bloc) {
          // The pipeline sheet pops and resets — deferred, as before.
          bloc.add(const MarketEvent.reset());
          // …then the user immediately starts another market action.
          bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          );
          // The first flow's ack finally lands, now on the second flow's
          // state. `_onIndexedAck` drops it — which is why the flush had to
          // happen above.
          bloc.add(
            const MarketEvent.indexedAck(signature: testSignature, ok: true),
          );
        },
        expect: () => [
          // The flush: listeners see the flip and refetch the resolved row.
          const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
            signature: testSignature,
            result: MarketSuccessData(
              explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
              actionType: 'accept-offer',
              mintAccount: testMintAccount,
              indexed: false,
            ),
          ),
          // …then the second flow proceeds normally. No second `TxFlowSuccess`
          // for `testSignature` — the late ack was dropped, so the inbox
          // refresh fires exactly once.
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.actionType,
            'actionType',
            'buy',
          ),
        ],
      );

      blocTest<MarketBloc, MarketState>(
        'does not re-flip an already-acked success when a second flow starts',
        setUp: () {
          when(mockApiV2.buyFixedPriceTx(any)).thenAnswer(
            (_) async => ApiResponse<UnsignedTxResponse>(
              result: UnsignedTxResponse(tx: testTransactionBase64),
            ),
          );
        },
        build: () => MarketBloc(
          mockApi,
          mockApiV2,
          mockWalletManager,
          mockRpcService,
          mockAuthService,
          mockDasApi,
          makeFlow(),
          mockPriceService,
          const FeeConfig(),
          mockMarketplaceConfig,
          mockMarketAccounts,
          mockCurationAttribution,
        ),
        seed: () => const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
          signature: testSignature,
          result: MarketSuccessData(
            explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
            actionType: 'accept-offer',
            mintAccount: testMintAccount,
          ),
        ),
        act: (bloc) {
          // Normal path: the ack lands first…
          bloc.add(
            const MarketEvent.indexedAck(signature: testSignature, ok: true),
          );
          // …and only then does the next action start.
          bloc.add(
            const MarketEvent.buy(
              mintAccount: testMintAccount,
              supplyType: SupplyType.oneOfOne,
            ),
          );
        },
        expect: () => [
          // One flip, from the real ack — the flush must not add a second
          // (`indexed=false`) emission, which would double the inbox refetch.
          const TxFlowSuccess<MarketPrepData, MarketSuccessData>(
            signature: testSignature,
            result: MarketSuccessData(
              explorerUrl: 'https://orbmarkets.io/tx/$testSignature',
              actionType: 'accept-offer',
              mintAccount: testMintAccount,
              indexed: true,
            ),
          ),
          const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          isA<TxFlowReady<MarketPrepData, MarketSuccessData>>().having(
            (s) => s.data.actionType,
            'actionType',
            'buy',
          ),
        ],
      );
    });

    // The old `SupplyType routing` group here asserted
    // `SupplyTypeX.usesBuySingleTx` / `usesBuyEditionTxs` per supply type. The
    // buy builder no longer routes on those (they cannot tell a secondary
    // `edition-print` from a printable master), so the group pinned a decision
    // nothing makes any more. The routing decision now lives in
    // `resolvePrintableMasterEdition` and is covered per supply type in
    // `edition_buy_routing_test.dart`, with the bloc-level branch assertions
    // in the "Edition artwork" group above.
  });
}

/// Builds a base64-encoded SignedTx with a single self-transfer instruction
/// so it round-trips through `SignedTx.fromBytes` cleanly.
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
