import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/swap/data/swap_repository.dart';
import 'package:mallow_wallet/features/swap/services/swap_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'swap_bloc_test.mocks.dart';

/// Auth gate that always allows — these tests focus on the swap pipeline,
/// not the threshold logic itself (covered in transaction_auth_gate_test).
class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

/// Auth gate that always cancels — exercises the cancel branch of execute.
class _CancelAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => true;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.cancelled;
}

/// The operator's copy for a killed `solana:token-swap` cell — the only thing
/// that can tell a user whether their funds are safe, so it must reach them
/// verbatim.
const killMessage = 'Swaps are paused while we fix a routing bug.';

/// Auth gate standing in for a kill-switched cell: [TransactionAuthGate] returns
/// the `flowDisabled` outcome before it ever prompts.
class _KilledFlowAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => const TransactionAuthOutcome.flowDisabled(killMessage);
}

/// The session's active signing wallet — the taker every quote is built for.
const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

/// A second signable session wallet — the one the source picker switches to.
const otherWalletAddress = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';

@GenerateMocks([
  SwapRepository,
  WalletManager,
  SolanaRpcService,
  MallowApiClient,
  TokenPriceService,
  LedgerService,
  PreferencesService,
])
void main() {
  late MockSwapRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockMallowApiClient mockApi;
  late MockTokenPriceService mockPriceService;
  late MockPreferencesService mockPreferences;
  late PriorityFeeService priorityFee;
  late TransactionAuthGate authGate;

  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  const solToken = TokenBalance(
    mint: 'So11111111111111111111111111111111111111112',
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 1000000000,
    uiBalance: 1.0,
    pricePerToken: 200.0,
    totalUsdValue: 200.0,
    isNative: true,
  );

  const usdcToken = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 50000000,
    uiBalance: 50.0,
    pricePerToken: 1.0,
    totalUsdValue: 50.0,
  );

  // Real wire-format SignedTx with a single self-transfer (1 required
  // signer) so SignedTx.fromBytes inside the execute handler can parse it.
  // The mocked signCompiledTx then short-circuits the rest of the flow.
  final testSwapTransaction = _buildParseableTxBase64(testWalletAddress);

  final testOrder = UltraOrderResponseDto(
    inputMint: solToken.mint,
    outputMint: usdcToken.mint,
    inAmount: '1000000000', // 1 SOL
    outAmount: '200000000', // 200 USDC
    otherAmountThreshold: '198000000',
    requestId: 'req-1',
    transaction: testSwapTransaction,
    slippageBps: 50,
    inUsdValue: 200.0,
    outUsdValue: 199.5,
  );

  SwapBloc buildBloc() => SwapBloc(
    mockRepository,
    mockWalletManager,
    authGate,
    TransactionPipeline(
      mockWalletManager,
      MockSolanaRpcService(),
      authGate,
      mockApi,
      MockLedgerService(),
    ),
    mockPriceService,
    mockPreferences,
    priorityFee,
  );

  setUp(() {
    mockRepository = MockSwapRepository();
    mockWalletManager = MockWalletManager();
    mockApi = MockMallowApiClient();
    mockPriceService = MockTokenPriceService();
    mockPreferences = MockPreferencesService();
    authGate = _AllowAllAuthGate();

    when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(0.0);
    when(mockPreferences.swapSlippageBps).thenReturn(null);
    // Two prefs feed Jupiter: the swap-specific override, falling back to the
    // general Settings -> Priority Fee ceiling. Both start unset (Auto).
    when(mockPreferences.priorityFeeLamports).thenReturn(null);
    when(mockPreferences.swapPriorityFeeLamports).thenReturn(null);
    when(
      mockPreferences.setPriorityFeeLamports(any),
    ).thenAnswer((_) async => true);
    when(
      mockPreferences.setSwapPriorityFeeLamports(any),
    ).thenAnswer((_) async => true);
    // PriorityFeeService listens to this so a Reset App wipe re-seeds the
    // cached selections instead of leaving the old ceiling in place.
    when(mockPreferences.clearGeneration).thenReturn(ValueNotifier<int>(0));
    priorityFee = PriorityFeeService(mockPreferences);
    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    // Default checkTx stub — resolves immediately so the background
    // indexer poll completes without delaying tests.
    when(mockApi.checkTx(any)).thenAnswer((_) async => <String, dynamic>{});
  });

  group('SwapBloc', () {
    group('BalancesUpdated event', () {
      blocTest<SwapBloc, SwapState>(
        'seeds native SOL sell side and a default buy side on first load',
        build: buildBloc,
        act: (bloc) => bloc.add(const SwapEvent.balancesUpdated([solToken])),
        expect: () => [
          predicate<SwapState>(
            (s) =>
                s.sellToken == solToken &&
                s.buyToken?.symbol == 'mallowSOL' &&
                s.buyToken?.rawBalance == 0,
            'sell = native SOL, buy = zero-balance mallowSOL',
          ),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'refreshes the selected tokens with new balances',
        build: buildBloc,
        seed: () => const SwapState(sellToken: solToken, buyToken: usdcToken),
        act: (bloc) => bloc.add(
          SwapEvent.balancesUpdated([
            solToken.copyWith(rawBalance: 2000000000, uiBalance: 2.0),
            usdcToken.copyWith(rawBalance: 99000000, uiBalance: 99.0),
          ]),
        ),
        expect: () => [
          predicate<SwapState>(
            (s) =>
                s.sellToken?.uiBalance == 2.0 && s.buyToken?.uiBalance == 99.0,
            'both sides re-read from the new balance list',
          ),
        ],
      );
    });

    group('Token selection', () {
      blocTest<SwapBloc, SwapState>(
        'selecting the buy-side token as sell flips the sides',
        build: buildBloc,
        seed: () => const SwapState(sellToken: solToken, buyToken: usdcToken),
        act: (bloc) => bloc.add(const SwapEvent.setSellToken(usdcToken)),
        expect: () => [
          const SwapState(sellToken: usdcToken, buyToken: solToken),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'ignores edits once signing has started',
        build: buildBloc,
        seed: () => const SwapState(
          sellToken: solToken,
          flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
        ),
        act: (bloc) => bloc.add(const SwapEvent.setSellToken(usdcToken)),
        expect: () => <SwapState>[],
      );
    });

    group('SetAmount event', () {
      blocTest<SwapBloc, SwapState>(
        'updates the amount and invalidates the current quote',
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.setAmount('2')),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '2',
          ),
        ],
      );
    });

    group('GetQuote event', () {
      blocTest<SwapBloc, SwapState>(
        'transitions preparing → ready and passes the saved settings to '
        'Jupiter',
        setUp: () async {
          when(mockPreferences.swapSlippageBps).thenReturn(75);
          await priorityFee.set(123456);
          when(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          ).thenAnswer((_) async => testOrder);
        },
        build: buildBloc,
        seed: () => const SwapState(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          slippageBps: 75,
          priorityFeeLamports: 123456,
        ),
        act: (bloc) => bloc.add(const SwapEvent.getQuote()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            slippageBps: 75,
            priorityFeeLamports: 123456,
            flow: TxFlowPreparing<SwapQuoteData, SwapSuccessData>(),
          ),
          predicate<SwapState>((s) {
            final quote = s.quoteData;
            return quote != null &&
                quote.order == testOrder &&
                quote.outputAmount == 200.0 &&
                quote.rate == 200.0;
          }, 'TxFlowReady carrying the order + derived amounts'),
        ],
        verify: (_) {
          verify(
            mockRepository.getOrder(
              inputMint: solToken.mint,
              outputMint: usdcToken.mint,
              amount: 1000000000,
              taker: testWalletAddress,
              slippageBps: 75,
              priorityFeeLamports: 123456,
            ),
          ).called(1);
        },
      );

      blocTest<SwapBloc, SwapState>(
        'keeps showing the previous quote while a refresh is in flight',
        setUp: () {
          when(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          ).thenAnswer((_) async => testOrder.copyWith(requestId: 'req-2'));
        },
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.getQuote()),
        // No intermediate TxFlowPreparing — only the refreshed ready state.
        expect: () => [
          predicate<SwapState>(
            (s) => s.quoteData?.order.requestId == 'req-2',
            'ready state refreshed in place',
          ),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'emits failure when the order fetch fails',
        setUp: () {
          when(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          ).thenThrow(Exception('Network error'));
        },
        build: buildBloc,
        seed: () => const SwapState(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
        ),
        act: (bloc) => bloc.add(const SwapEvent.getQuote()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowPreparing<SwapQuoteData, SwapSuccessData>(),
          ),
          _isFailure(contains('Failed to get quote')),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'does not fetch when the form is incomplete',
        build: buildBloc,
        seed: () => const SwapState(sellToken: solToken, amount: '1.0'),
        act: (bloc) => bloc.add(const SwapEvent.getQuote()),
        expect: () => <SwapState>[],
        verify: (_) {
          verifyNever(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          );
        },
      );
    });

    group('SettingsChanged event', () {
      blocTest<SwapBloc, SwapState>(
        'reloads slippage and priority fee from preferences',
        build: buildBloc,
        act: (bloc) async {
          // Re-stub after build — the constructor already read the old
          // (null/Auto) values into the initial state.
          when(mockPreferences.swapSlippageBps).thenReturn(200);
          await priorityFee.set(50000);
          bloc.add(const SwapEvent.settingsChanged());
        },
        expect: () => [
          const SwapState(slippageBps: 200, priorityFeeLamports: 50000),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'is a no-op when the saved values are unchanged',
        build: buildBloc,
        act: (bloc) => bloc.add(const SwapEvent.settingsChanged()),
        expect: () => <SwapState>[],
      );
    });

    group('Execute event', () {
      blocTest<SwapBloc, SwapState>(
        'signs the order transaction and submits it to /execute',
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
          when(
            mockRepository.executeOrder(
              signedTransaction: anyNamed('signedTransaction'),
              requestId: anyNamed('requestId'),
            ),
          ).thenAnswer(
            (_) async => const UltraExecuteResponseDto(
              status: 'Success',
              signature: testSignature,
            ),
          );
        },
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
          ),
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowBroadcasting<SwapQuoteData, SwapSuccessData>(),
          ),
          _isSuccess(
            (s, r) =>
                s == testSignature &&
                r.inputAmount == 1.0 &&
                r.outputAmount == 200.0,
            'matching signature + amounts',
          ),
        ],
        verify: (_) {
          verify(
            mockRepository.executeOrder(
              signedTransaction: anyNamed('signedTransaction'),
              requestId: 'req-1',
            ),
          ).called(1);
        },
      );

      blocTest<SwapBloc, SwapState>(
        'fails without signing when the order carries no transaction',
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder.copyWith(
            transaction: '',
            errorMessage: 'Insufficient funds',
          ),
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [_isFailure(contains('Insufficient funds'))],
        verify: (_) {
          verifyNever(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          );
        },
      );

      blocTest<SwapBloc, SwapState>(
        'surfaces a Failed execute status as a swap failure',
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
          when(
            mockRepository.executeOrder(
              signedTransaction: anyNamed('signedTransaction'),
              requestId: anyNamed('requestId'),
            ),
          ).thenAnswer(
            (_) async => const UltraExecuteResponseDto(
              status: 'Failed',
              error: 'Slippage tolerance exceeded',
            ),
          );
        },
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
          ),
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowBroadcasting<SwapQuoteData, SwapSuccessData>(),
          ),
          _isFailure(contains('Slippage tolerance exceeded')),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'classifies an auth-gate cancel as a cancelled failure, '
        'without signing',
        setUp: () => authGate = _CancelAuthGate(),
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
          ),
          predicate<SwapState>(
            (s) => switch (s.flow) {
              TxFlowFailure(:final failure) => failure.isCancelled,
              _ => false,
            },
            'TxFlowFailure with isCancelled',
          ),
        ],
        verify: (_) {
          verifyNever(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          );
        },
      );

      // The sheet renders cancels silently (it re-quotes and says nothing), so
      // a kill classified as `cancelled` would swallow the operator's message
      // outright — the user would see a swap that just refuses to go through.
      // The kill must arrive as its own kind, carrying the copy verbatim and
      // *not* prefixed with "Swap failed".
      blocTest<SwapBloc, SwapState>(
        'classifies a kill-switched cell as flowDisabled — never cancelled — '
        'and surfaces the operator message verbatim, without signing',
        setUp: () => authGate = _KilledFlowAuthGate(),
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
          ),
          predicate<SwapState>(
            (s) => switch (s.flow) {
              TxFlowFailure(:final failure) =>
                failure.isFlowDisabled &&
                    !failure.isCancelled &&
                    failure.message == killMessage,
              _ => false,
            },
            'TxFlowFailure with isFlowDisabled and the operator message',
          ),
        ],
        verify: (_) {
          verifyNever(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          );
        },
      );
    });

    group('IndexedAck event', () {
      blocTest<SwapBloc, SwapState>(
        'flips the indexed flag on the matching success signature',
        build: buildBloc,
        seed: () => _success(
          sellToken: solToken,
          buyToken: usdcToken,
          signature: testSignature,
          inputAmount: 1.0,
          outputAmount: 200.0,
        ),
        act: (bloc) => bloc.add(
          const SwapEvent.indexedAck(signature: testSignature, ok: true),
        ),
        expect: () => [
          _isSuccess(
            (s, r) => s == testSignature && r.indexed == true,
            'indexed flipped to true',
          ),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'ignores an ack whose signature does not match the in-flight tx',
        build: buildBloc,
        seed: () => _success(
          sellToken: solToken,
          buyToken: usdcToken,
          signature: testSignature,
          inputAmount: 1.0,
          outputAmount: 200.0,
        ),
        act: (bloc) => bloc.add(
          const SwapEvent.indexedAck(
            signature: 'a-different-signature',
            ok: true,
          ),
        ),
        expect: () => <SwapState>[],
      );
    });

    // A Jupiter order is compiled around its taker's accounts, so a quote
    // produced for wallet A and signed by wallet B is a real loss-of-funds
    // path. Nothing derived for the previous wallet may survive a source
    // switch.
    group('SourceWalletChanged event', () {
      /// The wallet `WalletManager.getAddress()` currently resolves to — moved
      /// by the picker before `sourceWalletChanged` is dispatched.
      late String activeAddress;

      /// The old wallet's in-flight order, completed by hand so it can land
      /// *after* the switch.
      late Completer<UltraOrderResponseDto> staleOrder;

      setUp(() {
        activeAddress = testWalletAddress;
        staleOrder = Completer<UltraOrderResponseDto>();
        when(
          mockWalletManager.getAddress(),
        ).thenAnswer((_) async => activeAddress);
      });

      /// Stubs `getOrder` so the returned order's requestId identifies the
      /// taker it was quoted for.
      void stubOrderPerTaker() {
        when(
          mockRepository.getOrder(
            inputMint: anyNamed('inputMint'),
            outputMint: anyNamed('outputMint'),
            amount: anyNamed('amount'),
            taker: anyNamed('taker'),
            slippageBps: anyNamed('slippageBps'),
            priorityFeeLamports: anyNamed('priorityFeeLamports'),
          ),
        ).thenAnswer(
          (invocation) async => testOrder.copyWith(
            requestId: 'req-${invocation.namedArguments[#taker]}',
          ),
        );
      }

      blocTest<SwapBloc, SwapState>(
        'drops the previous wallet\'s quote and re-quotes for the new taker',
        setUp: () {
          stubOrderPerTaker();
          activeAddress = otherWalletAddress;
        },
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.sourceWalletChanged()),
        expect: () => [
          // The stale quote is gone *before* the new one is requested, so the
          // Swap CTA can't fire against the outgoing wallet in the gap.
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
          ),
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowPreparing<SwapQuoteData, SwapSuccessData>(),
          ),
          predicate<SwapState>(
            (s) =>
                s.quoteData?.taker == otherWalletAddress &&
                s.quoteData?.order.requestId == 'req-$otherWalletAddress',
            'a fresh quote carrying the new taker',
          ),
        ],
        verify: (_) {
          verify(
            mockRepository.getOrder(
              inputMint: solToken.mint,
              outputMint: usdcToken.mint,
              amount: 1000000000,
              taker: otherWalletAddress,
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          ).called(1);
        },
      );

      blocTest<SwapBloc, SwapState>(
        'discards an order that was still in flight for the old taker',
        setUp: () {
          when(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          ).thenAnswer((invocation) {
            final taker = invocation.namedArguments[#taker] as String;
            // The first (old-wallet) order hangs until the switch has landed.
            return taker == testWalletAddress
                ? staleOrder.future
                : Future.value(testOrder.copyWith(requestId: 'req-new'));
          });
        },
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) async {
          bloc.add(const SwapEvent.getQuote());
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // The picker has committed the switch by the time the bloc is told.
          activeAddress = otherWalletAddress;
          bloc.add(const SwapEvent.sourceWalletChanged());
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // Only now does the old wallet's order come back.
          staleOrder.complete(testOrder.copyWith(requestId: 'req-stale'));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        // Exactly three states: quote dropped, preparing, new quote. A fourth
        // carrying `req-stale` would be the stale-quote bug.
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
          ),
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowPreparing<SwapQuoteData, SwapSuccessData>(),
          ),
          predicate<SwapState>(
            (s) =>
                s.quoteData?.order.requestId == 'req-new' &&
                s.quoteData?.taker == otherWalletAddress,
            'only the new wallet\'s quote is surfaced',
          ),
        ],
      );

      blocTest<SwapBloc, SwapState>(
        'leaves a committed swap alone rather than tearing down its flow',
        setUp: stubOrderPerTaker,
        build: buildBloc,
        seed: () => const SwapState(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
        ),
        act: (bloc) => bloc.add(const SwapEvent.sourceWalletChanged()),
        expect: () => <SwapState>[],
        verify: (_) {
          verifyNever(
            mockRepository.getOrder(
              inputMint: anyNamed('inputMint'),
              outputMint: anyNamed('outputMint'),
              amount: anyNamed('amount'),
              taker: anyNamed('taker'),
              slippageBps: anyNamed('slippageBps'),
              priorityFeeLamports: anyNamed('priorityFeeLamports'),
            ),
          );
        },
      );

      blocTest<SwapBloc, SwapState>(
        'refuses to sign a quote built for a different wallet',
        setUp: () {
          activeAddress = otherWalletAddress;
          when(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).thenAnswer(
            (invocation) async =>
                invocation.namedArguments[#unsignedTx] as SignedTx,
          );
        },
        build: buildBloc,
        // Quoted for `testWalletAddress` (the helper's default taker) while
        // the active signer has since moved to `otherWalletAddress`.
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
        ),
        act: (bloc) => bloc.add(const SwapEvent.execute()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            amount: '1.0',
            flow: TxFlowSigning<SwapQuoteData, SwapSuccessData>(),
          ),
          _isFailure(contains('Wallet changed')),
        ],
        verify: (_) {
          verifyNever(
            mockWalletManager.signCompiledTx(
              unsignedTx: anyNamed('unsignedTx'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          );
          verifyNever(
            mockRepository.executeOrder(
              signedTransaction: anyNamed('signedTransaction'),
              requestId: anyNamed('requestId'),
            ),
          );
        },
      );
    });

    group('Reset event', () {
      blocTest<SwapBloc, SwapState>(
        'clears the amount and flow but keeps tokens and settings',
        build: buildBloc,
        seed: () => _quoteReady(
          sellToken: solToken,
          buyToken: usdcToken,
          amount: '1.0',
          order: testOrder,
          slippageBps: 100,
        ),
        act: (bloc) => bloc.add(const SwapEvent.reset()),
        expect: () => [
          const SwapState(
            sellToken: solToken,
            buyToken: usdcToken,
            slippageBps: 100,
          ),
        ],
      );
    });
  });
}

/// Test predicate — matches a [SwapState] whose flow is [TxFlowFailure]
/// with a message that satisfies [matcher].
Matcher _isFailure(Matcher messageMatcher) => predicate<SwapState>((s) {
  if (s.flow case TxFlowFailure(:final failure)) {
    return messageMatcher.matches(failure.message, <dynamic, dynamic>{});
  }
  return false;
}, 'TxFlowFailure with message matching');

/// Test predicate — matches a [SwapState] whose flow is [TxFlowSuccess]
/// and whose `(signature, result)` pair satisfies [check].
Matcher _isSuccess(
  bool Function(String signature, SwapSuccessData result) check,
  String describe,
) => predicate<SwapState>((s) {
  if (s.flow case TxFlowSuccess<SwapQuoteData, SwapSuccessData>(
    :final signature,
    :final result,
  )) {
    return check(signature, result);
  }
  return false;
}, 'TxFlowSuccess with $describe');

/// Test helper — builds a [SwapState] in the quote-ready flow phase.
SwapState _quoteReady({
  required TokenBalance sellToken,
  required TokenBalance buyToken,
  required String amount,
  required UltraOrderResponseDto order,
  int? slippageBps,
  String taker = testWalletAddress,
}) => SwapState(
  sellToken: sellToken,
  buyToken: buyToken,
  amount: amount,
  slippageBps: slippageBps,
  flow: TxFlowReady(
    SwapQuoteData(order: order, outputAmount: 200.0, rate: 200.0, taker: taker),
  ),
);

/// Test helper — builds a [SwapState] in the success flow phase.
SwapState _success({
  required TokenBalance sellToken,
  required TokenBalance buyToken,
  required String signature,
  required double inputAmount,
  required double outputAmount,
  bool? indexed,
}) => SwapState(
  sellToken: sellToken,
  buyToken: buyToken,
  flow: TxFlowSuccess(
    signature: signature,
    result: SwapSuccessData(
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      inputSymbol: sellToken.symbol,
      outputSymbol: buyToken.symbol,
      indexed: indexed,
    ),
  ),
);

/// Builds a base64-encoded SignedTx with a single self-transfer instruction
/// so it round-trips through `SignedTx.fromBytes` cleanly.
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
