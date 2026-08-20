import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/utils/token_amount.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/services/activity_refresh_signal.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/features/send/services/ethereum_transfer_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/services/tezos_transfer_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:wallet/wallet.dart' show EthereumAddress;
import 'package:solana/solana.dart'
    show ComputeBudgetInstruction, TokenProgramType;
import 'package:shared_preferences/shared_preferences.dart';

import 'send_bloc_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/utils/tezos_address.dart'
    show TezosTokenRef;

/// A representative live fee market for the Ethereum review path — enough for
/// [EthGasSelection.resolveFromPrefs] to resolve a Market-tier selection.
EthGasMarket _ethMarket() => EthGasMarket.fromSuggestedGasFees(const {
  'low': {'suggestedMaxPriorityFeePerGas': '1', 'suggestedMaxFeePerGas': '20'},
  'medium': {
    'suggestedMaxPriorityFeePerGas': '2',
    'suggestedMaxFeePerGas': '24',
  },
  'estimatedBaseFee': '11',
});

/// Operator copy for a killed send cell, rendered verbatim to the user.
const _killMessage =
    'Sends are paused while we fix a fee-estimation bug. '
    'Your funds are safe.';

/// Records the balance-invalidation signals a send path announces.
/// `BalanceOptimisticUpdater.recordNonSolanaTransfer` resolves the repository
/// off the locator and ends in [TokenRepository.notifyBalancesChanged], which
/// is the only method it reaches here.
class _SpyTokenRepository extends Fake implements TokenRepository {
  final signalled = <String>[];

  @override
  void notifyBalancesChanged(String walletAddress) =>
      signalled.add(walletAddress);
}

/// Always-allow gate so the send pipeline tests can focus on their own
/// behavior — TransactionAuthGate itself is covered separately.
class _AllowAllAuthGate implements TransactionAuthGate {
  @override
  bool requiresAuth(double? usdValue) => false;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async => TransactionAuthOutcome.allowed;
}

/// A resolution claim that records the hand-back instead of routing it through
/// the locator, so the bloc's early-exit wiring is testable without standing up
/// a real `PendingEvmTxTracker`.
class _SpyClaim extends PendingTxResolutionClaim {
  const _SpyClaim(super.walletAddress, super.nonce, this.onRelease);

  final void Function() onRelease;

  @override
  void release() => onRelease();
}

/// Records every USD value the bloc passed in and replays a configured
/// outcome. Lets the gate-integration tests assert both that the bloc
/// invoked the gate AND with what value, without standing up the real
/// biometric/PIN stack.
class _RecordingAuthGate implements TransactionAuthGate {
  _RecordingAuthGate(this._outcome);
  final TransactionAuthOutcome _outcome;
  final List<double?> calls = [];

  /// Kill-switch cell each call carried. Native and token sends are separate
  /// separate cells so an operator can kill one without the other; if the bloc
  /// ever passed one label for both, that granularity would be a lie.
  final List<FlowKey> flows = [];
  @override
  bool requiresAuth(double? usdValue) => true;
  @override
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async {
    calls.add(usdValue);
    flows.add(flow);
    return _outcome;
  }
}

@GenerateMocks([
  SolanaRpcService,
  WalletManager,
  TokenPriceService,
  TransactionExecutor,
  TezosTransferService,
  EthereumTransferService,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The bloc returns the executor's Result verbatim; mockito needs a dummy
    // for the non-nullable Result return type when a call isn't explicitly
    // stubbed (e.g. tests that never reach execute).
    provideDummy<Result<String, AppFailure>>(
      const ResultFailure(AppFailure.unknown('dummy')),
    );
    // The Ethereum Max-send path stubs `nativeBalance` (a non-nullable BigInt
    // future); recording that stub needs a BigInt dummy.
    provideDummy<BigInt>(BigInt.zero);
  });

  late MockSolanaRpcService mockRpcService;
  late MockWalletManager mockWalletManager;
  late MockTokenPriceService mockPriceService;
  late MockTransactionExecutor mockExecutor;
  late MockTezosTransferService mockTezos;
  late MockEthereumTransferService mockEthereum;
  late TransactionAuthGate authGate;

  const testWalletAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testRecipientAddress = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  const testToken = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 50000000,
    uiBalance: 50.0,
    pricePerToken: 1.0,
    totalUsdValue: 50.0,
  );

  // A cached balance whose double carries more precision than the token's 6
  // decimals — used by the Max cached-fallback test to prove the fallback
  // floors rather than rounds up past what is actually held.
  const testTokenOddBalance = TokenBalance(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    rawBalance: 12345678,
    uiBalance: 12.3456789,
    pricePerToken: 1.0,
    totalUsdValue: 12.35,
  );

  /// Stub the exact-fee quote a native-SOL Max prices its amount against.
  /// [feeLamports] is the whole transaction cost (base + priority), which is
  /// what the Max subtracts from the balance.
  void stubSolFeePlan({required int feeLamports}) {
    when(
      mockRpcService.planSolTransferFee(
        destination: anyNamed('destination'),
        provisionalLamports: anyNamed('provisionalLamports'),
      ),
    ).thenAnswer(
      (_) async => SolTransferFeePlan(
        budget: ComputeBudgetPlan(
          instructions: [
            ComputeBudgetInstruction.setComputeUnitPrice(
              microLamports: 1500000,
            ),
            ComputeBudgetInstruction.setComputeUnitLimit(units: 11000),
          ],
          computeUnits: 11000,
          microLamportsPerUnit: 1500000,
        ),
        feeLamports: feeLamports,
      ),
    );
  }

  setUp(() async {
    mockRpcService = MockSolanaRpcService();
    mockWalletManager = MockWalletManager();
    mockPriceService = MockTokenPriceService();
    mockExecutor = MockTransactionExecutor();
    mockTezos = MockTezosTransferService();
    mockEthereum = MockEthereumTransferService();
    authGate = _AllowAllAuthGate();
    // Below-threshold by default — individual tests can override.
    when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(0.0);

    when(
      mockWalletManager.getAddress(),
    ).thenAnswer((_) async => testWalletAddress);
    when(mockWalletManager.isLocalSigner()).thenAnswer((_) async => true);

    // Default tx-build + executor stubs so execute-path tests only restate the
    // bits they assert on. The bloc builds the transfer tx client-side then
    // routes sign → broadcast through the executor; the failure test overrides
    // the executor to return a Result.failure.
    when(
      mockRpcService.buildSolTransferTx(
        destination: anyNamed('destination'),
        lamports: anyNamed('lamports'),
        pinnedBudget: anyNamed('pinnedBudget'),
      ),
    ).thenAnswer((_) async => 'unsigned-tx-base64');
    when(
      mockRpcService.buildSplTransferTx(
        destination: anyNamed('destination'),
        tokenMint: anyNamed('tokenMint'),
        amount: anyNamed('amount'),
      ),
    ).thenAnswer((_) async => 'unsigned-tx-base64');
    // SPL Max reads the true raw balance off the token account rather than
    // the cached double — see the "Max never exceeds the raw balance" test.
    // The holding this returns already carries that raw `amount`, so the Max
    // path issues no second balance RPC.
    when(
      mockRpcService.requireOwnedTokenAccount(
        owner: anyNamed('owner'),
        mint: anyNamed('mint'),
      ),
    ).thenAnswer(
      (_) async => (
        address: 'TokenAccount1111111111111111111111111111111',
        program: TokenProgramType.tokenProgram,
        amount: 50000000,
      ),
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
    ).thenAnswer((invocation) async {
      // Drive the stage callback exactly as the real executor does so the
      // bloc's signing → broadcasting transition is exercised through the
      // executor (not emitted up front). This default models a non-Ledger
      // send (no [ledgerAwaitingDevice] stage); the Ledger path has its own
      // test that drives that stage and asserts the device-specific copy.
      final onStage =
          invocation.namedArguments[#onStage]
              as void Function(ExecutorStageEvent)?;
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

    // SendBloc resolves the user's preferred explorer via `sl<PreferencesService>()`
    // when emitting SendSuccess. Register a real one backed by mocked prefs so
    // the default 'solscan' key is returned.
    SharedPreferences.setMockInitialValues({});
    if (sl.isRegistered<PreferencesService>()) {
      await sl.unregister<PreferencesService>();
    }
    sl.registerSingleton<PreferencesService>(await PreferencesService.create());
  });

  tearDown(() async {
    if (sl.isRegistered<PreferencesService>()) {
      await sl.unregister<PreferencesService>();
    }
  });

  group('SendBloc', () {
    group('SetRecipient event', () {
      blocTest<SendBloc, SendState>(
        'updates recipient in input state with valid address',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        act: (bloc) =>
            bloc.add(const SendEvent.setRecipient(testRecipientAddress)),
        expect: () => [const SendState.input(recipient: testRecipientAddress)],
      );

      blocTest<SendBloc, SendState>(
        'sets error for invalid address format',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        act: (bloc) => bloc.add(const SendEvent.setRecipient('invalid')),
        expect: () => [
          const SendState.input(
            recipient: 'invalid',
            recipientError: 'Invalid Solana address',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'clears error when address is empty',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(
          recipient: 'invalid',
          recipientError: 'Invalid Solana address',
        ),
        act: (bloc) => bloc.add(const SendEvent.setRecipient('')),
        expect: () => [const SendState.input()],
      );
    });

    group('SetAmount event', () {
      blocTest<SendBloc, SendState>(
        'updates amount in input state',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        act: (bloc) => bloc.add(const SendEvent.setAmount('1.5')),
        expect: () => [const SendState.input(amount: '1.5')],
      );

      blocTest<SendBloc, SendState>(
        'sets error for invalid amount',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        act: (bloc) => bloc.add(const SendEvent.setAmount('-1')),
        expect: () => [
          const SendState.input(
            amount: '-1',
            amountError: 'Enter a valid amount',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'sets error when amount exceeds token balance',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(token: testToken),
        act: (bloc) => bloc.add(const SendEvent.setAmount('100.0')),
        expect: () => [
          const SendState.input(
            token: testToken,
            amount: '100.0',
            amountError: 'Insufficient balance',
          ),
        ],
      );
    });

    group('SetToken event', () {
      blocTest<SendBloc, SendState>(
        'updates token and clears amount',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(amount: '1.5'),
        act: (bloc) => bloc.add(const SendEvent.setToken(testToken)),
        expect: () => [const SendState.input(token: testToken)],
      );

      blocTest<SendBloc, SendState>(
        'clears token when set to null',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(token: testToken, amount: '10.0'),
        act: (bloc) => bloc.add(const SendEvent.setToken(null)),
        expect: () => [const SendState.input()],
      );
    });

    group('SetMaxAmount event', () {
      // Max must leave the account at EXACTLY zero. Solana rejects a
      // transaction that leaves a wallet holding more than nothing but less
      // than the rent-exempt minimum (`InsufficientFundsForRent`, raised at
      // preflight — after the user has signed), so a Max built by reserving a
      // worst-case fee and living with the difference is a Max the chain
      // refuses. The amount is therefore priced off the transaction's exact
      // fee, and the plan that priced it is what gets signed.
      blocTest<SendBloc, SendState>(
        'prices max SOL off the exact fee, leaving the account at zero',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000); // 1 SOL
          stubSolFeePlan(feeLamports: 21500);
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(recipient: testRecipientAddress),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [
          // 1 SOL − 21 500 lamports of fee, to the lamport. Not a round buffer:
          // the residue is 0, which is the only legal way to empty a wallet.
          const SendState.input(
            recipient: testRecipientAddress,
            amount: '0.9999785',
          ),
        ],
        verify: (_) {
          verify(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).called(1);
          // Priced against the real recipient: the fee is simulated for that
          // destination, not for a placeholder.
          verify(
            mockRpcService.planSolTransferFee(
              destination: testRecipientAddress,
              provisionalLamports: anyNamed('provisionalLamports'),
            ),
          ).called(1);
        },
      );

      // The fee the amount was priced against must be the fee that is signed.
      // Re-probing the network at execute time would re-price the transaction
      // after the amount was frozen, and the difference lands as dust the
      // runtime rejects.
      blocTest<SendBloc, SendState>(
        'signs the Max with the compute budget that priced it',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000);
          stubSolFeePlan(feeLamports: 21500);
          when(
            mockRpcService.buildSolTransferTx(
              destination: anyNamed('destination'),
              lamports: anyNamed('lamports'),
              pinnedBudget: anyNamed('pinnedBudget'),
            ),
          ).thenAnswer((_) async => 'tx-base64');
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              onStage: anyNamed('onStage'),
            ),
          ).thenAnswer((_) async => const ResultSuccess('sig'));
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(recipient: testRecipientAddress),
        act: (bloc) async {
          bloc.add(const SendEvent.setMaxAmount());
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.validateAndProceed());
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.execute());
        },
        expect: () => anything,
        verify: (_) {
          verify(
            mockRpcService.buildSolTransferTx(
              destination: testRecipientAddress,
              lamports: 999978500,
              pinnedBudget: argThat(isNotNull, named: 'pinnedBudget'),
            ),
          ).called(1);
        },
      );

      // Without an exact fee there is no emptying the account — an inexact one
      // leaves dust the runtime rejects as rent-paying. So a failed quote falls
      // back to the largest *partial* send, which always lands, rather than to
      // '0', which would read as a dead Max button on an RPC blip.
      blocTest<SendBloc, SendState>(
        'falls back to the largest rent-safe amount when the fee quote fails',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000); // 1 SOL
          when(
            mockRpcService.planSolTransferFee(
              destination: anyNamed('destination'),
              provisionalLamports: anyNamed('provisionalLamports'),
            ),
          ).thenThrow(Exception('fee probe unreachable'));
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(recipient: testRecipientAddress),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [
          SendState.input(
            recipient: testRecipientAddress,
            amount: TokenAmount.lamportsToSol(
              BigInt.from(
                1000000000 -
                    worstCaseSolTxFeeLamports -
                    kSolRentExemptMinimumLamports,
              ),
            ),
          ),
        ],
        verify: (bloc) {
          // Not pinned: this amount is an ordinary send, and claiming it as the
          // priced Max would exempt it from the rent floor it depends on.
          expect(
            bloc.isSolMaxAmount(
              (bloc.state as SendInput).amount,
              testRecipientAddress,
            ),
            isFalse,
          );
        },
      );

      // The pin is keyed to the amount it priced. Editing the amount gives it
      // up, because any other amount is an ordinary send that has to leave the
      // account rent-exempt rather than empty.
      blocTest<SendBloc, SendState>(
        'drops the pinned budget once the amount is edited',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000);
          stubSolFeePlan(feeLamports: 21500);
          when(
            mockRpcService.buildSolTransferTx(
              destination: anyNamed('destination'),
              lamports: anyNamed('lamports'),
              pinnedBudget: anyNamed('pinnedBudget'),
            ),
          ).thenAnswer((_) async => 'tx-base64');
          when(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              onStage: anyNamed('onStage'),
            ),
          ).thenAnswer((_) async => const ResultSuccess('sig'));
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(recipient: testRecipientAddress),
        act: (bloc) async {
          bloc.add(const SendEvent.setMaxAmount());
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.setAmount('0.5'));
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.validateAndProceed());
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.execute());
        },
        expect: () => anything,
        verify: (_) {
          verify(
            mockRpcService.buildSolTransferTx(
              destination: testRecipientAddress,
              lamports: 500000000,
              pinnedBudget: null,
            ),
          ).called(1);
        },
      );

      blocTest<SendBloc, SendState>(
        'sets max token amount (full balance)',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(token: testToken),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [const SendState.input(token: testToken, amount: '50')],
      );

      // `uiBalance` is a double. For a large or high-decimal balance it
      // rounds *up* past what the account actually holds, so a Max built from
      // it produces an amount the transfer instruction cannot cover — and the
      // failure lands on-chain, after the user has signed. The EVM branch was
      // hardened for exactly this; the SPL branch now reads the same raw
      // base-unit balance the transfer will move.
      blocTest<SendBloc, SendState>(
        'SPL Max reads the raw token-account balance, not the rounded double',
        build: () {
          when(
            mockRpcService.requireOwnedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenAnswer(
            (_) async => (
              address: 'TokenAccount1111111111111111111111111111111',
              program: TokenProgramType.tokenProgram,
              amount: 49999999,
            ),
          );
          return SendBloc(
            mockRpcService,
            mockWalletManager,
            authGate,
            mockPriceService,
            const FeeConfig(),
            mockExecutor,
            mockTezos,
            mockEthereum,
            sl<PreferencesService>(),
          );
        },
        seed: () => const SendState.input(token: testToken),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [
          // 49_999_999 base units at 6 decimals — NOT the cached 50.0.
          const SendState.input(token: testToken, amount: '49.999999'),
        ],
      );

      // The raw balance comes off the holding `requireOwnedTokenAccount`
      // already read. A follow-up `getTokenAccountAmount` would be a second RPC
      // for a value we hold — and, because that method swallows every error and
      // returns 0, a transient blip on it would fill Max with '0' *without*
      // reaching the cached-balance catch below. So it must not be called.
      blocTest<SendBloc, SendState>(
        'SPL Max uses the holding amount and issues no second balance RPC',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(token: testToken),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [const SendState.input(token: testToken, amount: '50')],
        verify: (_) {
          verify(
            mockRpcService.requireOwnedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).called(1);
          verifyNever(mockRpcService.getTokenAccountAmount(any));
        },
      );

      // With the swallowing second RPC gone, a genuine live-read failure
      // (RPC blip, no holding yet) now actually reaches the catch — Max falls
      // back to the *cached* balance floored to the token's decimals, never to
      // '0', which would silently understate the user's spendable balance.
      blocTest<SendBloc, SendState>(
        'SPL Max falls back to the floored cached balance when the live read '
        'throws',
        build: () {
          when(
            mockRpcService.requireOwnedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(StateError('rpc blip'));
          return SendBloc(
            mockRpcService,
            mockWalletManager,
            authGate,
            mockPriceService,
            const FeeConfig(),
            mockExecutor,
            mockTezos,
            mockEthereum,
            sl<PreferencesService>(),
          );
        },
        // uiBalance carries more precision than 6 decimals can hold, so the
        // fallback must floor rather than round up past what is held.
        seed: () => const SendState.input(token: testTokenOddBalance),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [
          const SendState.input(
            token: testTokenOddBalance,
            amount: '12.345678',
          ),
        ],
      );

      // The fallback used to rebuild the atomic amount as
      // `uiBalance × 10^decimals` floored into an int. `decimals` is
      // issuer-controlled (a u8 on the mint, and Token-2022 airdrops declare
      // whatever they like), so that product overflows int64 — where
      // `double.floor()` neither throws nor saturates predictably (1e30 floors
      // to 5_076_944_270_305_263_616). A wallet holding one whole token was
      // offered a Max of '0.000000000005076944270305263616'. The atomic
      // balance the row already carries is the only trustworthy source.
      const highDecimalToken = TokenBalance(
        mint: 'AiRdRoPSpam1111111111111111111111111111111',
        symbol: 'SPAM',
        name: 'Airdropped spam',
        decimals: 30,
        // One whole token is 1e30 atomic units — far past the int64 ceiling
        // the model clamps `rawBalance` at, so `uiBalance` is all that is left.
        rawBalance: 9223372036854775807,
        uiBalance: 1.0,
      );

      blocTest<SendBloc, SendState>(
        'SPL cached fallback offers the held balance for a high-decimal token, '
        'never a wrapped double',
        build: () {
          when(
            mockRpcService.requireOwnedTokenAccount(
              owner: anyNamed('owner'),
              mint: anyNamed('mint'),
            ),
          ).thenThrow(StateError('rpc blip'));
          return SendBloc(
            mockRpcService,
            mockWalletManager,
            authGate,
            mockPriceService,
            const FeeConfig(),
            mockExecutor,
            mockTezos,
            mockEthereum,
            sl<PreferencesService>(),
          );
        },
        seed: () => const SendState.input(token: highDecimalToken),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [
          const SendState.input(token: highDecimalToken, amount: '1'),
        ],
      );

      blocTest<SendBloc, SendState>(
        'sets zero when SOL balance insufficient for fees',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer(
            // Covers the base fee but not the priority fee the transaction is
            // allowed to bid, so there is nothing left to send.
            (_) async => worstCaseSolTxFeeLamports - 1,
          );
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        act: (bloc) => bloc.add(const SendEvent.setMaxAmount()),
        expect: () => [const SendState.input(amount: '0')],
      );
    });

    // The native branch used to have no max at all (`double.infinity`),
    // so an over-balance SOL amount cleared the form and was only caught by a
    // snackbar on the confirm sheet — after the user had committed to it.
    group('native SOL amount validation', () {
      SendBloc build() => SendBloc(
        mockRpcService,
        mockWalletManager,
        authGate,
        mockPriceService,
        const FeeConfig(),
        mockExecutor,
        mockTezos,
        mockEthereum,
        sl<PreferencesService>(),
      );

      /// Pick the funding wallet (which primes the balance read), let the
      /// async prime land, then type [amount].
      Future<void> typeAfterSourcePicked(SendBloc bloc, String amount) async {
        bloc.add(
          const SendEvent.setSource(
            chain: Chain.solana,
            address: testWalletAddress,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        bloc.add(SendEvent.setAmount(amount));
      }

      blocTest<SendBloc, SendState>(
        'rejects more SOL than the wallet holds',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000); // 1 SOL
        },
        build: build,
        act: (bloc) => typeAfterSourcePicked(bloc, '2'),
        expect: () => [
          const SendState.input(
            amount: '2',
            amountError: 'Insufficient balance',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'names the fee-and-rent floor when a typed amount overshoots it',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000); // 1 SOL
        },
        build: build,
        // 0.9999 SOL is affordable, but it would leave the account holding a
        // few hundred thousand lamports — more than nothing and less than the
        // rent-exempt minimum, which the runtime rejects outright. Saying
        // "Insufficient balance" to a user looking at a 1 SOL balance would
        // read as a lie, and letting it through would surface as an opaque
        // preflight failure after the biometric gate.
        act: (bloc) => typeAfterSourcePicked(bloc, '0.9999'),
        expect: () => [
          const SendState.input(
            amount: '0.9999',
            amountError: 'Send the max, or leave 0.0009 SOL for fees and rent',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'accepts an amount inside the spendable balance',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000);
        },
        build: build,
        act: (bloc) => typeAfterSourcePicked(bloc, '0.5'),
        expect: () => [const SendState.input(amount: '0.5')],
      );

      // The guard has to agree with the Max button to the lamport, or the one
      // amount Max just offered comes back flagged as unaffordable.
      blocTest<SendBloc, SendState>(
        'accepts the Max amount itself',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenAnswer((_) async => 1000000000);
          stubSolFeePlan(feeLamports: 21500);
        },
        build: build,
        // The Max necessarily sits above the partial-send floor — it leaves
        // nothing at all. The guard has to recognise the amount it just
        // priced, or it flags the one number the Max button offered.
        act: (bloc) async {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.solana,
              address: testWalletAddress,
            ),
          );
          bloc.add(const SendEvent.setRecipient(testRecipientAddress));
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.setMaxAmount());
          await Future<void>.delayed(Duration.zero);
          bloc.add(const SendEvent.setAmount('0.9999785'));
        },
        // Re-validating the Max amount leaves the state untouched — bloc drops
        // an emit equal to the current state, so the absence of a third entry
        // *is* the assertion: no `amountError` was attached.
        expect: () => [
          const SendState.input(recipient: testRecipientAddress),
          const SendState.input(
            recipient: testRecipientAddress,
            amount: '0.9999785',
          ),
        ],
        verify: (bloc) => expect(
          (bloc.state as SendInput).amountError,
          isNull,
          reason: 'the priced Max must not be flagged by the rent floor',
        ),
      );

      blocTest<SendBloc, SendState>(
        'stays quiet while the balance is unknown — never false-disable',
        setUp: () {
          when(
            mockRpcService.getBalanceForAddress(testWalletAddress),
          ).thenThrow(Exception('rpc down'));
        },
        build: build,
        act: (bloc) => typeAfterSourcePicked(bloc, '99999'),
        expect: () => [const SendState.input(amount: '99999')],
      );
    });

    group('ValidateAndProceed event', () {
      blocTest<SendBloc, SendState>(
        'transitions to ready state with valid SOL transfer',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(
          recipient: testRecipientAddress,
          amount: '1.0',
        ),
        act: (bloc) => bloc.add(const SendEvent.validateAndProceed()),
        expect: () => [
          const SendState.input(
            recipient: testRecipientAddress,
            amount: '1.0',
            isValidating: true,
          ),
          const SendState.ready(
            recipient: testRecipientAddress,
            amountString: '1.0',
            amount: 1.0,
            token: null,
            estimatedFeeLamports: 5000,
            totalCost: 1.000005, // amount + fee
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'transitions to ready state with valid token transfer',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.input(
          recipient: testRecipientAddress,
          amount: '25.0',
          token: testToken,
        ),
        act: (bloc) => bloc.add(const SendEvent.validateAndProceed()),
        expect: () => [
          const SendState.input(
            recipient: testRecipientAddress,
            amount: '25.0',
            token: testToken,
            isValidating: true,
          ),
          const SendState.ready(
            recipient: testRecipientAddress,
            amountString: '25.0',
            amount: 25.0,
            token: testToken,
            estimatedFeeLamports: 5000,
            totalCost: 25.0, // No fee added for token transfer
          ),
        ],
      );
    });

    group('Execute event', () {
      blocTest<SendBloc, SendState>(
        'successfully sends SOL transfer',
        // buildSolTransferTx + executor.execute are stubbed in setUp.
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          const SendState.success(
            signature: testSignature,
            // `ENV` defaults to production, so the link carries no cluster
            // parameter. The devnet form is covered in explorer_utils_test.
            explorerUrl: 'https://solscan.io/tx/$testSignature',
          ),
        ],
        verify: (_) {
          // Send builds the SOL transfer tx, then routes sign/broadcast
          // through the shared executor — no bespoke sendSol path.
          verify(
            mockRpcService.buildSolTransferTx(
              destination: testRecipientAddress,
              lamports: 1000000000,
            ),
          ).called(1);
          verify(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              tracker: anyNamed('tracker'),
              onStage: anyNamed('onStage'),
              useLedger: anyNamed('useLedger'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).called(1);
        },
      );

      blocTest<SendBloc, SendState>(
        'successfully sends SPL token transfer',
        // buildSplTransferTx + executor.execute are stubbed in setUp.
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '25.0',
          amount: 25.0,
          token: testToken,
          estimatedFeeLamports: 5000,
          totalCost: 25.0,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          const SendState.success(
            signature: testSignature,
            // `ENV` defaults to production, so the link carries no cluster
            // parameter. The devnet form is covered in explorer_utils_test.
            explorerUrl: 'https://solscan.io/tx/$testSignature',
          ),
        ],
        verify: (_) {
          verify(
            mockRpcService.buildSplTransferTx(
              destination: testRecipientAddress,
              tokenMint: testToken.mint,
              amount: 25000000,
            ),
          ).called(1);
          verify(
            mockExecutor.execute(
              txsBase64: anyNamed('txsBase64'),
              usdValue: anyNamed('usdValue'),
              flow: anyNamed('flow'),
              tracker: anyNamed('tracker'),
              onStage: anyNamed('onStage'),
              useLedger: anyNamed('useLedger'),
              additionalSigners: anyNamed('additionalSigners'),
            ),
          ).called(1);
        },
      );

      blocTest<SendBloc, SendState>(
        'Ledger send surfaces the device-approval state before broadcasting',
        setUp: () {
          // A Ledger sign passes through [ledgerAwaitingDevice] between the
          // approval prompt and broadcast. The bloc must emit a distinct
          // signing(onLedger: true) so the sheet swaps to the
          // "Approve on your Ledger device" copy instead of prematurely
          // reading "Confirming on Solana…" while the device still waits.
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
          ).thenAnswer((invocation) async {
            final onStage =
                invocation.namedArguments[#onStage]
                    as void Function(ExecutorStageEvent)?;
            onStage?.call(
              const ExecutorStageEvent(
                stage: ExecutorStage.awaitingApproval,
                index: 0,
                total: 1,
              ),
            );
            onStage?.call(
              const ExecutorStageEvent(
                stage: ExecutorStage.ledgerAwaitingDevice,
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
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          const SendState.signing(),
          const SendState.signing(onLedger: true),
          const SendState.broadcasting(),
          const SendState.success(
            signature: testSignature,
            explorerUrl: 'https://solscan.io/tx/$testSignature',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'emits error state when transaction fails',
        setUp: () {
          // The shared executor surfaces a broadcast/confirm failure as a
          // Result.failure; the bloc renders its message verbatim.
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
          ).thenAnswer((invocation) async {
            // An "insufficient funds" failure surfaces at broadcast, so the
            // executor reaches the broadcasting stage before failing — the
            // bloc shows signing → broadcasting, then the error.
            final onStage =
                invocation.namedArguments[#onStage]
                    as void Function(ExecutorStageEvent)?;
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
            return const ResultFailure(
              AppFailure.unknown('Transaction failed: insufficient funds'),
            );
          });
        },
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          isA<SendError>().having(
            (e) => e.message,
            'message',
            contains('Transaction failed'),
          ),
        ],
      );
    });

    group('Biometric gate', () {
      // Build a SendBloc with a configurable gate so we can assert all three
      // AC paths: below-threshold skip, above-threshold required, missing
      // price requires auth (fail-closed).
      late _RecordingAuthGate recordingGate;

      SendBloc buildBloc() => SendBloc(
        mockRpcService,
        mockWalletManager,
        recordingGate,
        mockPriceService,
        const FeeConfig(),
        mockExecutor,
        mockTezos,
        mockEthereum,
        sl<PreferencesService>(),
      );

      setUp(() {
        recordingGate = _RecordingAuthGate(TransactionAuthOutcome.allowed);
      });

      blocTest<SendBloc, SendState>(
        'below \$100 SOL: skips re-auth (passes 0 USD outflow to the gate)',
        setUp: () {
          when(
            mockPriceService.usdValueOfRaw(any, any),
          ).thenReturn(50.0); // below threshold
          // buildSolTransferTx + executor.execute stubbed in setUp.
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        verify: (_) {
          // Gate is always called once (it owns the threshold decision),
          // but with a below-threshold value — so it shouldn't prompt.
          expect(recordingGate.calls, [50.0]);
          // A null token is a native SOL send, so it must key the
          // `solana:native-send` cell — not `token-send`.
          expect(recordingGate.flows, [
            const FlowKey.solana(AppFlow.nativeSend),
          ]);
        },
      );

      blocTest<SendBloc, SendState>(
        'above \$100 SOL: requires auth and submits when allowed',
        setUp: () {
          when(
            mockPriceService.usdValueOfRaw(any, any),
          ).thenReturn(250.0); // above threshold
          // buildSolTransferTx + executor.execute stubbed in setUp.
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        verify: (_) {
          expect(recordingGate.calls, [250.0]);
          verify(
            mockRpcService.buildSolTransferTx(
              destination: testRecipientAddress,
              lamports: 1000000000,
            ),
          ).called(1);
        },
      );

      blocTest<SendBloc, SendState>(
        'above \$100 SOL: cancels and never signs when gate rejects',
        setUp: () {
          recordingGate = _RecordingAuthGate(TransactionAuthOutcome.cancelled);
          when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(500.0);
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          isA<SendError>().having(
            (e) => e.previousState?.recipient,
            'preserved recipient',
            testRecipientAddress,
          ),
        ],
        verify: (_) {
          // Critical: must NOT have built or signed anything. A signing path
          // that runs after a cancelled gate is a hard regression.
          verifyNever(
            mockRpcService.buildSolTransferTx(
              destination: anyNamed('destination'),
              lamports: anyNamed('lamports'),
            ),
          );
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

      // The pipeline step titles every error "Transaction failed" and never
      // renders `SendError.message`, so unless the kill stays identifiable the
      // operator's copy — the only thing that can say whether funds are safe —
      // is lost entirely. `killFailure` is what the sheet routes to
      // [handleFlowDisabled].
      blocTest<SendBloc, SendState>(
        'kill-switched cell: reports flowDisabled with the operator message '
        'verbatim, preserves the form, and never builds or signs',
        setUp: () {
          recordingGate = _RecordingAuthGate(
            const TransactionAuthOutcome.flowDisabled(_killMessage),
          );
          when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(500.0);
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        expect: () => [
          isA<SendError>()
              // Verbatim: never "Send failed: …" — the copy is written for the
              // incident and read by the user as-is.
              .having((e) => e.message, 'operator message', _killMessage)
              .having(
                (e) => e.previousState?.recipient,
                'preserved recipient',
                testRecipientAddress,
              ),
        ],
        verify: (bloc) {
          final kill = bloc.killFailure;
          expect(kill, isNotNull);
          expect(kill!.isFlowDisabled, isTrue);
          // A kill must not read as a user cancel: send's silent-cancel-style
          // branches would swallow it.
          expect(kill.isCancelled, isFalse);
          expect(kill.message, _killMessage);
          verifyNever(
            mockRpcService.buildSolTransferTx(
              destination: anyNamed('destination'),
              lamports: anyNamed('lamports'),
            ),
          );
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

      blocTest<SendBloc, SendState>(
        'a reset clears the recorded kill so a later error is not mistaken '
        'for one',
        setUp: () {
          recordingGate = _RecordingAuthGate(
            const TransactionAuthOutcome.flowDisabled(_killMessage),
          );
          when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(500.0);
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) async {
          bloc.add(const SendEvent.execute());
          await Future<void>.delayed(Duration.zero);
          // The sheet dismisses the kill sheet and hands the form back — a
          // stale kill here would make the *next* failure present as one.
          bloc.add(const SendEvent.reset());
        },
        verify: (bloc) => expect(bloc.killFailure, isNull),
      );

      blocTest<SendBloc, SendState>(
        'missing price (null USD): forwards null to the gate (fail-closed)',
        setUp: () {
          // Simulates a price service that hasn't received its first poll
          // yet, or a mint the backend doesn't price — the AC says this
          // must require auth, not silently allow.
          when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(null);
          // buildSolTransferTx + executor.execute stubbed in setUp.
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        verify: (_) {
          // The bloc passes `null` straight through so the gate's
          // `requiresAuth(null) → true` rule kicks in. The gate itself
          // is stubbed to allow here so the send completes — this test
          // is asserting the bloc's contract with the gate, not the
          // gate's internal classification (that's covered separately).
          expect(recordingGate.calls, [null]);
        },
      );

      blocTest<SendBloc, SendState>(
        'unpriced SPL token: forwards null to the gate (fail-closed)',
        setUp: () {
          // SECURITY (fail-closed): the balance feed carried NO price for this
          // mint (price_info absent — a feed outage, indexer gap, or a
          // newly-listed-but-valuable token all look identical here). We must
          // NOT treat that as "worthless" and skip step-up auth: doing so would
          // let a valuable token slip out ungated whenever its price lookup
          // missed. The bloc must forward null so the gate prompts.
          when(mockPriceService.usdValueOfRaw(any, any)).thenReturn(null);
          when(
            mockRpcService.buildSplTransferTx(
              destination: anyNamed('destination'),
              tokenMint: anyNamed('tokenMint'),
              amount: anyNamed('amount'),
            ),
          ).thenAnswer((_) async => 'base64tx');
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: TokenBalance(
            mint: 'DUSTawucrTsGU8hcqRdHDCbuYhCPADMLM2VcCb8VnFnQ',
            symbol: 'DUST',
            name: 'Unpriced Dust',
            decimals: 6,
            rawBalance: 1000000,
            uiBalance: 1.0,
            // No pricePerToken / totalUsdValue — the price is unknown.
          ),
          estimatedFeeLamports: 5000,
          totalCost: 1.0,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        verify: (_) {
          // Unknown value, not $0 — the gate must be given the chance to prompt.
          expect(recordingGate.calls, [null]);
        },
      );

      blocTest<SendBloc, SendState>(
        'known-zero-value SPL token: passes 0 USD so worthless dust skips '
        're-auth',
        setUp: () {
          // The feed AFFIRMATIVELY priced this holding at $0 (totalUsdValue: 0)
          // — we know it is worth nothing, so burning/sending dust need not
          // demand step-up auth. This is the ONLY case that may skip the gate.
          when(
            mockRpcService.buildSplTransferTx(
              destination: anyNamed('destination'),
              tokenMint: anyNamed('tokenMint'),
              amount: anyNamed('amount'),
            ),
          ).thenAnswer((_) async => 'base64tx');
        },
        build: buildBloc,
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: TokenBalance(
            mint: 'DUSTawucrTsGU8hcqRdHDCbuYhCPADMLM2VcCb8VnFnQ',
            symbol: 'DUST',
            name: 'Worthless Dust',
            decimals: 6,
            rawBalance: 1000000,
            uiBalance: 1.0,
            pricePerToken: 0,
            totalUsdValue: 0,
          ),
          estimatedFeeLamports: 5000,
          totalCost: 1.0,
        ),
        act: (bloc) => bloc.add(const SendEvent.execute()),
        verify: (_) {
          expect(recordingGate.calls, [0.0]);
        },
      );
    });

    group('Reset event', () {
      blocTest<SendBloc, SendState>(
        'preserves recipient/amount when resetting from ready state',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.ready(
          recipient: testRecipientAddress,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: 1.000005,
        ),
        act: (bloc) => bloc.add(const SendEvent.reset()),
        // The confirmation sheet dismissal dispatches reset(); the screen's
        // text controllers still hold the typed values, so the bloc keeps
        // them too — otherwise re-tapping Review proceeds with empty input.
        expect: () => [
          const SendState.input(recipient: testRecipientAddress, amount: '1.0'),
        ],
      );

      blocTest<SendBloc, SendState>(
        'resets to initial input state from error state without previousState',
        build: () => SendBloc(
          mockRpcService,
          mockWalletManager,
          authGate,
          mockPriceService,
          const FeeConfig(),
          mockExecutor,
          mockTezos,
          mockEthereum,
          sl<PreferencesService>(),
        ),
        seed: () => const SendState.error(message: 'Some error'),
        act: (bloc) => bloc.add(const SendEvent.reset()),
        expect: () => [const SendState.input()],
      );
    });

    group('canSubmit getter', () {
      test('returns false when recipient is empty', () {
        const state = SendState.input(amount: '1.0');
        expect(state.canSubmit, isFalse);
      });

      test('returns false when amount is empty', () {
        const state = SendState.input(recipient: testRecipientAddress);
        expect(state.canSubmit, isFalse);
      });

      test('returns false when recipient has error', () {
        const state = SendState.input(
          recipient: 'invalid',
          recipientError: 'Invalid address',
          amount: '1.0',
        );
        expect(state.canSubmit, isFalse);
      });

      test('returns false when amount has error', () {
        const state = SendState.input(
          recipient: testRecipientAddress,
          amount: '-1',
          amountError: 'Invalid amount',
        );
        expect(state.canSubmit, isFalse);
      });

      test('returns true when all fields valid', () {
        const state = SendState.input(
          recipient: testRecipientAddress,
          amount: '1.0',
        );
        expect(state.canSubmit, isTrue);
      });

      test('returns false for non-input states', () {
        const signingState = SendState.signing();
        expect(signingState.canSubmit, isFalse);

        const successState = SendState.success(
          signature: 'sig',
          explorerUrl: 'url',
        );
        expect(successState.canSubmit, isFalse);
      });
    });

    // Once the funding wallet is a Tezos wallet, the bloc must
    // validate recipients as Tezos addresses and route execute() through the
    // client-side forge/sign/inject stack ([TezosTransferService]) rather than
    // the Solana [TransactionExecutor]. The Solana path stays untouched.
    group('Tezos chain', () {
      var tezosActivityRefreshes = 0;
      late _SpyTokenRepository tezosBalanceSignals;
      const tezosSource = 'tz1WCBJKr1rRivyCnN9hREpRAMqrLdmqDcym';
      const tezosRecipient = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
      const tezosWalletId = 'tez-wallet-1';
      const tezosOpHash = 'ooNsRAKZ8dQpB9Zg8mQ2ZqcQxkq8wjF7pB3rGqz3n9Wvw2XyZ4a';

      SendBloc buildTezosBloc() => SendBloc(
        mockRpcService,
        mockWalletManager,
        authGate,
        mockPriceService,
        const FeeConfig(),
        mockExecutor,
        mockTezos,
        mockEthereum,
        sl<PreferencesService>(),
      );

      blocTest<SendBloc, SendState>(
        'rejects a Solana address once the source is a Tezos wallet',
        build: buildTezosBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(testRecipientAddress));
        },
        // testRecipientAddress is a valid *Solana* address; under a Tezos
        // source it must fail Base58Check tz1/2/3/KT1 validation.
        expect: () => [
          const SendState.input(
            recipient: testRecipientAddress,
            recipientError: 'Invalid Tezos address',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'accepts a tz1 address once the source is a Tezos wallet',
        build: buildTezosBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(tezosRecipient));
        },
        expect: () => [const SendState.input(recipient: tezosRecipient)],
      );

      // Max must be simulated against the *recipient*: what the transfer costs
      // turns on whether that address exists yet (a fresh tz1 burns 0.06425 XTZ
      // to allocate), so a Max computed without it is either short or — as the
      // flat 0.1 XTZ headroom this replaces was — strands most of a small
      // wallet the user asked to empty.
      blocTest<SendBloc, SendState>(
        'native XTZ Max offers the balance less the simulated cost',
        setUp: () {
          when(
            mockTezos.maxNativeSendable(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
            ),
          ).thenAnswer((_) async => BigInt.from(4935650));
        },
        build: buildTezosBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(tezosRecipient));
          bloc.add(const SendEvent.setMaxAmount());
        },
        expect: () => [
          const SendState.input(recipient: tezosRecipient),
          const SendState.input(recipient: tezosRecipient, amount: '4.93565'),
        ],
        verify: (_) {
          verify(
            mockTezos.maxNativeSendable(
              walletId: tezosWalletId,
              source: tezosSource,
              destination: tezosRecipient,
            ),
          ).called(1);
        },
      );

      // Sending to a never-funded tz1 costs the sender a 0.06425 XTZ storage
      // burn on top of the ~0.0004 XTZ baker fee. Quoting the fee alone made
      // the review screen understate the real cost by ~160×, so the review
      // total must carry fee + burn.
      blocTest<SendBloc, SendState>(
        'review total includes the fresh-address storage burn, not just the fee',
        setUp: () {
          when(
            mockTezos.estimateNativeTransfer(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountMutez: anyNamed('amountMutez'),
            ),
          ).thenAnswer(
            (_) async => TezosSendEstimate(
              feeMutez: BigInt.from(400),
              burnMutez: BigInt.from(64250),
              gasLimit: 1400,
              storageLimit: 267,
              includesReveal: true,
            ),
          );
        },
        build: buildTezosBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(tezosRecipient));
          bloc.add(const SendEvent.setAmount('1.0'));
          bloc.add(const SendEvent.validateAndProceed());
        },
        expect: () => anything,
        verify: (bloc) => expect(
          bloc.state,
          isA<SendReady>().having(
            (s) => s.totalCost,
            'totalCost',
            // 1 XTZ amount + 0.0004 baker fee + 0.06425 allocation burn.
            closeTo(1.0 + 0.0004 + 0.06425, 1e-9),
          ),
        ),
      );

      blocTest<SendBloc, SendState>(
        'execute forges/signs/injects via TezosTransferService, not the '
        'Solana executor',
        setUp: () {
          when(
            mockTezos.sendNativeTransfer(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountMutez: anyNamed('amountMutez'),
              onBroadcasting: anyNamed('onBroadcasting'),
            ),
          ).thenAnswer((invocation) async {
            // The service fires onBroadcasting once signed and about to inject,
            // driving the signing → broadcasting transition.
            (invocation.namedArguments[#onBroadcasting] as void Function()?)
                ?.call();
            return tezosOpHash;
          });
        },
        build: buildTezosBloc,
        seed: () => SendState.ready(
          recipient: tezosRecipient,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 1.0004,
          tezosEstimate: TezosSendEstimate(
            feeMutez: BigInt.from(400),
            burnMutez: BigInt.zero,
            gasLimit: 1400,
            storageLimit: 0,
            includesReveal: false,
          ),
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          isA<SendSuccess>().having(
            (s) => s.signature,
            'signature',
            tezosOpHash,
          ),
        ],
        verify: (_) {
          verify(
            mockTezos.sendNativeTransfer(
              walletId: tezosWalletId,
              source: tezosSource,
              destination: tezosRecipient,
              amountMutez: BigInt.from(1000000),
              onBroadcasting: anyNamed('onBroadcasting'),
            ),
          ).called(1);
          // The Solana executor must never run for a Tezos send.
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

      // A confirmed XTZ send is an activity row, and nothing else discovers it:
      // the EVM path is prodded by `PendingEvmTxTracker` and the Solana path
      // fires this from its own success branch, but this bloc runs no indexer
      // poll. Without it the "Recent activity" sheet stayed on the pre-send
      // state until something unrelated refreshed it.
      blocTest<SendBloc, SendState>(
        'a confirmed send prods the activity feed',
        setUp: () {
          when(
            mockTezos.sendNativeTransfer(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountMutez: anyNamed('amountMutez'),
              onBroadcasting: anyNamed('onBroadcasting'),
            ),
          ).thenAnswer((_) async => tezosOpHash);

          final signal = ActivityRefreshSignal();
          if (sl.isRegistered<ActivityRefreshSignal>()) {
            sl.unregister<ActivityRefreshSignal>();
          }
          sl.registerSingleton<ActivityRefreshSignal>(signal);
          addTearDown(() => sl.unregister<ActivityRefreshSignal>());
          final sub = signal.stream.listen((_) => tezosActivityRefreshes++);
          addTearDown(sub.cancel);
          tezosActivityRefreshes = 0;
        },
        build: buildTezosBloc,
        seed: () => SendState.ready(
          recipient: tezosRecipient,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 1.0004,
          tezosEstimate: TezosSendEstimate(
            feeMutez: BigInt.from(400),
            burnMutez: BigInt.zero,
            gasLimit: 1400,
            storageLimit: 0,
            includesReveal: false,
          ),
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        wait: const Duration(milliseconds: 50),
        verify: (_) => expect(tezosActivityRefreshes, 1),
      );

      // WHY: an injected-but-unobserved operation is indeterminate, not sent.
      // Two things must hold, and each has its own way of hurting the user:
      //  1. It must NOT reach the success branch — that branch refreshes
      //     balances, which against a still-in-flight operation writes the
      //     pre-send number back into the cache and announces it as post-send.
      //     Unlike Ethereum there is no pending-tx tracker to correct it later.
      //  2. It must be flagged `unconfirmed` so SendPipelineView drops the
      //     retry button. A blind retry re-forges and re-injects; if the
      //     original lands too, the user has sent twice.
      blocTest<SendBloc, SendState>(
        'an inclusion timeout is an unconfirmed error, and announces no '
        'balances',
        setUp: () {
          when(
            mockTezos.sendNativeTransfer(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountMutez: anyNamed('amountMutez'),
              onBroadcasting: anyNamed('onBroadcasting'),
            ),
          ).thenAnswer((invocation) async {
            (invocation.namedArguments[#onBroadcasting] as void Function()?)
                ?.call();
            throw const TezosOperationUnconfirmedException(tezosOpHash);
          });
          tezosBalanceSignals = _SpyTokenRepository();
          if (sl.isRegistered<TokenRepository>()) {
            sl.unregister<TokenRepository>();
          }
          sl.registerSingleton<TokenRepository>(tezosBalanceSignals);
          addTearDown(() => sl.unregister<TokenRepository>());
        },
        build: buildTezosBloc,
        seed: () => SendState.ready(
          recipient: tezosRecipient,
          amountString: '1.0',
          amount: 1.0,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 1.0004,
          tezosEstimate: TezosSendEstimate(
            feeMutez: BigInt.from(400),
            burnMutez: BigInt.zero,
            gasLimit: 1400,
            storageLimit: 0,
            includesReveal: false,
          ),
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.tezos,
              address: tezosSource,
              walletId: tezosWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          isA<SendError>().having((s) => s.unconfirmed, 'unconfirmed', isTrue),
        ],
        verify: (_) async {
          await pumpEventQueue();
          expect(tezosBalanceSignals.signalled, isEmpty);
        },
      );

      // An FA2 holding used to fall through every branch above as if it were
      // native XTZ: the review estimated an XTZ transfer, the confirm screen
      // read "N XTZ · Tezos", and execute injected an XTZ transfer of N to the
      // recipient — the wrong asset, in the wrong denomination, after the user
      // had approved something else.
      group('FA2 token', () {
        const fa2Contract = 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o';
        const fa2Token = TokenBalance(
          mint: '$fa2Contract-3',
          symbol: 'USDt',
          name: 'Tether USD',
          decimals: 6,
          rawBalance: 23252886,
          uiBalance: 23.252886,
          pricePerToken: 0.998489,
          totalUsdValue: 23.217,
          chain: Chain.tezos,
        );

        final fa2Estimate = TezosSendEstimate(
          feeMutez: BigInt.from(1200),
          burnMutez: BigInt.from(16750),
          gasLimit: 5300,
          storageLimit: 77,
          includesReveal: false,
        );

        void stubTokenEstimate() {
          when(
            mockTezos.estimateTokenTransfer(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              token: anyNamed('token'),
              amountRaw: anyNamed('amountRaw'),
            ),
          ).thenAnswer((_) async => fa2Estimate);
        }

        blocTest<SendBloc, SendState>(
          'review estimates an FA transfer and keeps the token on SendReady',
          setUp: stubTokenEstimate,
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(const SendEvent.setToken(fa2Token));
            bloc.add(const SendEvent.setRecipient(tezosRecipient));
            bloc.add(const SendEvent.setAmount('2.5'));
            bloc.add(const SendEvent.validateAndProceed());
          },
          expect: () => anything,
          verify: (bloc) {
            expect(
              bloc.state,
              isA<SendReady>()
                  // Preserved, not collapsed to null: this is the single field
                  // the confirm step reads for the symbol and name it shows.
                  .having((s) => s.token, 'token', fa2Token)
                  // The XTZ fee is not added to a token total — it is paid
                  // separately, in a different asset.
                  .having((s) => s.totalCost, 'totalCost', closeTo(2.5, 1e-9))
                  .having((s) => s.tezosEstimate, 'tezosEstimate', fa2Estimate),
            );
            verify(
              mockTezos.estimateTokenTransfer(
                walletId: tezosWalletId,
                source: tezosSource,
                destination: tezosRecipient,
                token: TezosTokenRef(
                  contract: fa2Contract,
                  tokenId: BigInt.from(3),
                ),
                // Scaled by the *token's* 6 decimals, and never routed through
                // the native mutez path.
                amountRaw: BigInt.from(2500000),
              ),
            ).called(1);
            verifyNever(
              mockTezos.estimateNativeTransfer(
                walletId: anyNamed('walletId'),
                source: anyNamed('source'),
                destination: anyNamed('destination'),
                amountMutez: anyNamed('amountMutez'),
              ),
            );
          },
        );

        blocTest<SendBloc, SendState>(
          'execute sends the FA token, never native XTZ',
          setUp: () {
            when(
              mockTezos.sendTokenTransfer(
                walletId: anyNamed('walletId'),
                source: anyNamed('source'),
                destination: anyNamed('destination'),
                token: anyNamed('token'),
                amountRaw: anyNamed('amountRaw'),
                onBroadcasting: anyNamed('onBroadcasting'),
              ),
            ).thenAnswer((invocation) async {
              (invocation.namedArguments[#onBroadcasting] as void Function()?)
                  ?.call();
              return tezosOpHash;
            });
          },
          build: buildTezosBloc,
          seed: () => SendState.ready(
            recipient: tezosRecipient,
            amountString: '2.5',
            amount: 2.5,
            token: fa2Token,
            estimatedFeeLamports: 0,
            totalCost: 2.5,
            tezosEstimate: fa2Estimate,
          ),
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(const SendEvent.execute());
          },
          expect: () => [
            const SendState.signing(),
            const SendState.broadcasting(),
            isA<SendSuccess>().having(
              (s) => s.signature,
              'signature',
              tezosOpHash,
            ),
          ],
          verify: (_) {
            verify(
              mockTezos.sendTokenTransfer(
                walletId: tezosWalletId,
                source: tezosSource,
                destination: tezosRecipient,
                token: TezosTokenRef(
                  contract: fa2Contract,
                  tokenId: BigInt.from(3),
                ),
                amountRaw: BigInt.from(2500000),
                onBroadcasting: anyNamed('onBroadcasting'),
              ),
            ).called(1);
            // The bug this replaces: "2.5" reached sendNativeTransfer as
            // 2_500_000 mutez and moved 2.5 XTZ to the recipient.
            verifyNever(
              mockTezos.sendNativeTransfer(
                walletId: anyNamed('walletId'),
                source: anyNamed('source'),
                destination: anyNamed('destination'),
                amountMutez: anyNamed('amountMutez'),
                onBroadcasting: anyNamed('onBroadcasting'),
              ),
            );
          },
        );

        blocTest<SendBloc, SendState>(
          'Max offers the whole token balance, not the XTZ balance',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(const SendEvent.setToken(fa2Token));
            bloc.add(const SendEvent.setMaxAmount());
          },
          expect: () => anything,
          verify: (bloc) {
            // The fee is paid in XTZ, so none of the token is held back — and
            // the figure comes from the atomic rawBalance, not the double
            // uiBalance, which rounds up past what is held.
            expect(
              bloc.state,
              isA<SendInput>().having((s) => s.amount, 'amount', '23.252886'),
            );
            // The native-XTZ Max simulation must not fire for a token Max.
            verifyNever(
              mockTezos.maxNativeSendable(
                walletId: anyNamed('walletId'),
                source: anyNamed('source'),
                destination: anyNamed('destination'),
              ),
            );
          },
        );

        // 18-decimal FA1.2s are real on Tezos mainnet (kUSD, PLY), and
        // `TokenBalance` clamps any atomic balance past int64 — which for 18
        // decimals is only ~9.22 tokens. Reading the clamp as the balance makes
        // Max silently offer 9.223372036854775807 of a 20-token holding.
        blocTest<SendBloc, SendState>(
          'Max on a clamped 18-decimal balance falls back to uiBalance, '
          'truncated so it can never exceed what is held',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            // 20 kUSD = 2e19 atomic units, past int64's 9.223…e18 ceiling.
            bloc.add(
              const SendEvent.setToken(
                TokenBalance(
                  mint: 'KT1K9gCRgaLRFKTErYt1wVxA3Frb9FjasjTV',
                  symbol: 'kUSD',
                  name: 'Kolibri USD',
                  decimals: 18,
                  rawBalance: 9223372036854775807,
                  uiBalance: 20,
                  chain: Chain.tezos,
                ),
              ),
            );
            bloc.add(const SendEvent.setMaxAmount());
          },
          expect: () => anything,
          verify: (bloc) {
            expect(
              bloc.state,
              isA<SendInput>().having((s) => s.amount, 'amount', '20'),
            );
          },
        );

        blocTest<SendBloc, SendState>(
          'a clamped Max truncates downward rather than rounding up',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(
              const SendEvent.setToken(
                TokenBalance(
                  mint: 'KT1K9gCRgaLRFKTErYt1wVxA3Frb9FjasjTV',
                  symbol: 'kUSD',
                  name: 'Kolibri USD',
                  decimals: 18,
                  rawBalance: 9223372036854775807,
                  uiBalance: 20.1234567891,
                  chain: Chain.tezos,
                ),
              ),
            );
            bloc.add(const SendEvent.setMaxAmount());
          },
          expect: () => anything,
          verify: (bloc) {
            final amount = (bloc.state as SendInput).amount;
            // Truncated at six places — never rounded up to 20.123457, which
            // would be more than the wallet holds.
            expect(amount, '20.123456');
            expect(double.parse(amount), lessThan(20.1234567891));
          },
        );

        // `decimals` is issuer-controlled metadata (a u8 the backend passes
        // through unclamped), so an airdropped spam token can declare more
        // places than `toStringAsFixed` accepts. Formatting the fallback at the
        // declared width threw a RangeError straight out of the event handler:
        // no BlocObserver, no catch on this branch, so the error escaped to the
        // zone and Max silently did nothing.
        blocTest<SendBloc, SendState>(
          'Max survives a token declaring more decimals than a double can be '
          'formatted to',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(
              const SendEvent.setToken(
                TokenBalance(
                  mint: 'KT1SpamContractAddressWithAbsurdDecimals-0',
                  symbol: 'SPAM',
                  name: 'Airdropped spam',
                  decimals: 21,
                  rawBalance: 9223372036854775807,
                  uiBalance: 12.5,
                  chain: Chain.tezos,
                ),
              ),
            );
            bloc.add(const SendEvent.setMaxAmount());
          },
          expect: () => anything,
          verify: (bloc) {
            // Still the real holding — capping the format width must not cost
            // the user the balance the fallback is there to offer.
            expect(
              bloc.state,
              isA<SendInput>().having((s) => s.amount, 'amount', '12.5'),
            );
          },
        );

        // At 1e21 and above `toStringAsFixed` gives up and returns exponent
        // notation ('1e+21'), which `parseTokenAmount` cannot parse. There is
        // no sane number to offer for a holding that large, but the failure has
        // to stay inside the handler: a fallback of '0' is recoverable (type an
        // amount), an uncaught error is not.
        blocTest<SendBloc, SendState>(
          'Max falls back to zero on a balance too large to format, rather '
          'than throwing out of the handler',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            bloc.add(
              const SendEvent.setToken(
                TokenBalance(
                  mint: 'KT1SpamContractAddressWithAbsurdSupply-0',
                  symbol: 'SPAM',
                  name: 'Airdropped spam',
                  decimals: 6,
                  rawBalance: 9223372036854775807,
                  uiBalance: 1e21,
                  chain: Chain.tezos,
                ),
              ),
            );
            bloc.add(const SendEvent.setMaxAmount());
          },
          expect: () => anything,
          verify: (bloc) {
            expect(
              bloc.state,
              isA<SendInput>().having((s) => s.amount, 'amount', '0'),
            );
          },
        );

        blocTest<SendBloc, SendState>(
          'refuses to review a holding whose KT1 no longer decodes',
          build: buildTezosBloc,
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.tezos,
                address: tezosSource,
                walletId: tezosWalletId,
              ),
            );
            // A row cached before the balances mapper stopped lower-casing
            // Tezos contracts. Falling back to the native path here would move
            // XTZ; the only safe answer is to stop.
            bloc.add(
              SendEvent.setToken(
                fa2Token.copyWith(mint: fa2Contract.toLowerCase()),
              ),
            );
            bloc.add(const SendEvent.setRecipient(tezosRecipient));
            bloc.add(const SendEvent.setAmount('2.5'));
            bloc.add(const SendEvent.validateAndProceed());
          },
          expect: () => anything,
          verify: (bloc) {
            expect(bloc.state, isA<SendError>());
            verifyNever(
              mockTezos.estimateNativeTransfer(
                walletId: anyNamed('walletId'),
                source: anyNamed('source'),
                destination: anyNamed('destination'),
                amountMutez: anyNamed('amountMutez'),
              ),
            );
          },
        );
      });
    });

    group('Ethereum chain', () {
      const ethSource = '0x742d35Cc6634C0532925a3b844Bc454e4438f44e';
      const ethRecipient = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
      const ethWalletId = 'eth-wallet-1';
      const ethTxHash =
          '0x88df016429689c079f3b2f6ad39fa052532c56795b733da78a91ebe6a713944b';

      // ERC-20 (USDC on Ethereum): non-null token carrying the contract as its
      // mint, so the send routes through the token-transfer path.
      const ethErc20Token = TokenBalance(
        mint: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
        symbol: 'USDC',
        name: 'USD Coin',
        decimals: 6,
        rawBalance: 50000000,
        uiBalance: 50.0,
        pricePerToken: 1.0,
        totalUsdValue: 50.0,
        chain: Chain.ethereum,
      );

      // A representative EIP-1559 estimate; the fee math itself is covered by
      // EthereumTransferService — these tests only assert routing.
      final ethEstimate = EthereumSendEstimate(
        gasLimit: 21000,
        estimatedGasUsed: BigInt.from(21000),
        maxFeePerGas: BigInt.from(40000000000),
        maxPriorityFeePerGas: BigInt.from(1500000000),
        effectiveGasPrice: BigInt.from(21500000000),
      );

      SendBloc buildEthBloc() => SendBloc(
        mockRpcService,
        mockWalletManager,
        authGate,
        mockPriceService,
        const FeeConfig(),
        mockExecutor,
        mockTezos,
        mockEthereum,
        sl<PreferencesService>(),
      );

      // The validated transfer the review-step gate would produce. `prepare`
      // returns it; `execute` signs it. In these seeded-ready tests `_ethPrepared`
      // is empty, so the bloc re-prepares at execute time — hence both are stubbed.
      final ethPrepared = PreparedEthTransfer(
        walletId: ethWalletId,
        source: ethSource,
        to: EthereumAddress.fromHex(ethRecipient),
        value: BigInt.parse('500000000000000000'),
        data: null,
        estimate: ethEstimate,
      );

      void stubEthTransfer() {
        when(
          mockEthereum.prepare(
            walletId: anyNamed('walletId'),
            source: anyNamed('source'),
            destination: anyNamed('destination'),
            amountRaw: anyNamed('amountRaw'),
            token: anyNamed('token'),
          ),
        ).thenAnswer((_) async => ethPrepared);
        when(
          mockEthereum.execute(
            any,
            feeOverride: anyNamed('feeOverride'),
            onBroadcasting: anyNamed('onBroadcasting'),
            onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
          ),
        ).thenAnswer((invocation) async {
          // The service fires onBroadcasting once signed and about to broadcast,
          // driving the signing → broadcasting transition.
          (invocation.namedArguments[#onBroadcasting] as void Function()?)
              ?.call();
          // …then onBroadcastRegistered once the node accepted the tx and the
          // pending-tx tracker owns its nonce, carrying the resolution claim.
          // Only that second signal makes the pipeline's early-exit "Done" safe
          // to offer.
          (invocation.namedArguments[#onBroadcastRegistered]
                  as void Function(PendingTxResolutionClaim?)?)
              ?.call(null);
          return ethTxHash;
        });
      }

      // WHY: taking the pipeline's "Done" early exit pops the send sheet and
      // closes this bloc while the funnel is still waiting for inclusion, so the
      // success step will never render. The claim the funnel took out on the
      // nonce silences the tracker's app-wide toast — the only report left — so
      // closing without having reported must hand it back.
      var claimReleases = 0;

      // Catches the balance-invalidation signal `BalanceOptimisticUpdater`
      // resolves off the locator, so a send path can be held to whether it
      // announces one.
      late _SpyTokenRepository balanceSignals;

      blocTest<SendBloc, SendState>(
        'closing while broadcasting hands the resolution claim back',
        setUp: () {
          claimReleases = 0;
          when(
            mockEthereum.prepare(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountRaw: anyNamed('amountRaw'),
              token: anyNamed('token'),
            ),
          ).thenAnswer((_) async => ethPrepared);
          when(
            mockEthereum.execute(
              any,
              feeOverride: anyNamed('feeOverride'),
              onBroadcasting: anyNamed('onBroadcasting'),
              onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
            ),
          ).thenAnswer((invocation) {
            (invocation.namedArguments[#onBroadcasting] as void Function()?)
                ?.call();
            (invocation.namedArguments[#onBroadcastRegistered]
                    as void Function(PendingTxResolutionClaim?)?)
                ?.call(_SpyClaim(ethSource, 7, () => claimReleases++));
            // Never completes: the inclusion wait is still running when the user
            // taps "Done", which is what closes the bloc.
            return Completer<String>().future;
          });
        },
        build: buildEthBloc,
        seed: () => SendState.ready(
          recipient: ethRecipient,
          amountString: '0.5',
          amount: 0.5,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 0.5,
          ethereumEstimate: ethEstimate,
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          // Terminal for this bloc: no success step ever renders.
          const SendState.broadcasting(pendingRegistered: true),
        ],
        // blocTest closes the bloc before verify runs — the early exit itself.
        verify: (_) async {
          expect(claimReleases, 1);
          // The sheet can close before the inclusion wait emits success. The
          // address is still saved at broadcast registration, so it appears
          // in the next Ethereum send sheet.
          await pumpEventQueue();
          expect(sl<PreferencesService>().recentSendAddresses, [ethRecipient]);
        },
      );

      blocTest<SendBloc, SendState>(
        'rejects a Solana address once the source is an Ethereum wallet',
        build: buildEthBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(testRecipientAddress));
        },
        expect: () => [
          const SendState.input(
            recipient: testRecipientAddress,
            recipientError: 'Invalid Ethereum address',
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'accepts a 0x address once the source is an Ethereum wallet',
        build: buildEthBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(ethRecipient));
        },
        expect: () => [const SendState.input(recipient: ethRecipient)],
      );

      // [ethRecipient] with its 4th character's case flipped: still 40 valid
      // hex chars, so the old bare-regex gate accepted it and the transfer was
      // built for a *different* address. Nothing downstream can catch it — the
      // calldata assertion compares against this same string and the Alchemy
      // simulation only checks the amount — so the form gate is the last line
      // of defence before an unrecoverable send.
      const ethRecipientBadChecksum =
          '0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
      blocTest<SendBloc, SendState>(
        'rejects a mixed-case Ethereum address that fails its EIP-55 checksum',
        build: buildEthBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(ethRecipientBadChecksum));
        },
        expect: () => [
          const SendState.input(
            recipient: ethRecipientBadChecksum,
            recipientError: kEvmChecksumFailedMessage,
          ),
        ],
      );

      blocTest<SendBloc, SendState>(
        'execute broadcasts native ETH via EthereumTransferService, not the '
        'Solana executor',
        setUp: stubEthTransfer,
        build: buildEthBloc,
        seed: () => SendState.ready(
          recipient: ethRecipient,
          amountString: '0.5',
          amount: 0.5,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 0.5,
          ethereumEstimate: ethEstimate,
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          // Two distinct broadcasting states, and the order matters: the first
          // is "signed, going on the wire" (the pipeline must NOT offer its
          // early exit yet — sendRawTransaction can still throw and this bloc is
          // the only place that error can surface), the second is "the pending
          // tracker owns this nonce" (leaving is now safe).
          const SendState.broadcasting(),
          const SendState.broadcasting(pendingRegistered: true),
          isA<SendSuccess>().having((s) => s.signature, 'signature', ethTxHash),
        ],
        verify: (_) {
          // 0.5 ETH == 5·10^17 wei — kept as BigInt end-to-end (overflows int).
          // The gate runs in prepare (native token: null); execute signs it.
          verify(
            mockEthereum.prepare(
              walletId: ethWalletId,
              source: ethSource,
              destination: ethRecipient,
              amountRaw: BigInt.parse('500000000000000000'),
            ),
          ).called(1);
          verify(
            mockEthereum.execute(
              any,
              feeOverride: anyNamed('feeOverride'),
              onBroadcasting: anyNamed('onBroadcasting'),
              onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
            ),
          ).called(1);
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

      blocTest<SendBloc, SendState>(
        'execute broadcasts an ERC-20 transfer carrying the token + base units',
        setUp: stubEthTransfer,
        build: buildEthBloc,
        seed: () => SendState.ready(
          recipient: ethRecipient,
          amountString: '10',
          amount: 10.0,
          token: ethErc20Token,
          estimatedFeeLamports: 0,
          totalCost: 10.0,
          ethereumEstimate: ethEstimate,
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          const SendState.broadcasting(pendingRegistered: true),
          isA<SendSuccess>(),
        ],
        verify: (_) {
          // 10 USDC at 6 decimals == 10_000_000 base units, and the ERC-20's
          // TokenBalance rides through prepare so the gate/builder can target
          // the contract; execute then signs the validated transfer.
          verify(
            mockEthereum.prepare(
              walletId: ethWalletId,
              source: ethSource,
              destination: ethRecipient,
              amountRaw: BigInt.from(10000000),
              token: ethErc20Token,
            ),
          ).called(1);
          verify(
            mockEthereum.execute(
              any,
              feeOverride: anyNamed('feeOverride'),
              onBroadcasting: anyNamed('onBroadcasting'),
              onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
            ),
          ).called(1);
        },
      );

      // WHY: `execute` returning a hash is NOT proof the transaction landed —
      // the EVM funnel returns it on an inclusion-wait timeout too, with the tx
      // still in the mempool. Refetching balances here would write the *pre-send*
      // row back into the cache and announce it as the post-send balance, which
      // is the very bug the post-send refresh exists to fix. Only
      // `PendingEvmTxTracker` sees a receipt, so it owns the refresh — unlike
      // the Tezos path above, whose service awaits inclusion itself.
      blocTest<SendBloc, SendState>(
        'a successful execute does not announce new balances — success here is '
        'not inclusion',
        setUp: () {
          stubEthTransfer();
          balanceSignals = _SpyTokenRepository();
          if (sl.isRegistered<TokenRepository>()) {
            sl.unregister<TokenRepository>();
          }
          sl.registerSingleton<TokenRepository>(balanceSignals);
          addTearDown(() => sl.unregister<TokenRepository>());
        },
        build: buildEthBloc,
        seed: () => SendState.ready(
          recipient: ethRecipient,
          amountString: '0.5',
          amount: 0.5,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 0.5,
          ethereumEstimate: ethEstimate,
        ),
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.execute());
        },
        expect: () => [
          const SendState.signing(),
          const SendState.broadcasting(),
          const SendState.broadcasting(pendingRegistered: true),
          isA<SendSuccess>(),
        ],
        verify: (_) async {
          await pumpEventQueue();
          expect(balanceSignals.signalled, isEmpty);
        },
      );

      // WHY (FINDING 2, variant a — CONTRACT RECIPIENT): a Max native send to a
      // contract wallet (Safe/Argent) runs the recipient's receive/fallback, so
      // its transfer costs more than the flat 21 000-gas EOA path — here 50 000
      // gas → 60 000 padded. The reserve MUST use that real per-recipient limit
      // (via nativeSendGasLimitFor), not the flat nativeSendGasLimit (25 200):
      // execute() floors the signed limit UP to prepare's 60 000, so reserving
      // only 25 200 would price `value + 60 000×cap` above the balance and the
      // node would reject "insufficient funds for gas * price + value" AFTER the
      // user passed review + biometric auth. With balance = 0.5 ETH + the exact
      // 60 000×102 gwei reserve, Max must resolve to exactly 0.5 ETH.
      blocTest<SendBloc, SendState>(
        'Max native send to a contract recipient reserves the real per-recipient '
        'gas limit at the persisted custom caps',
        setUp: () async {
          // Persisted custom fee: 100 gwei base + 2 gwei tip → 102 gwei cap. The
          // stale gas limit is deliberately huge to prove it is NOT applied —
          // the reserve uses the per-recipient estimate (60 000), not 999 999.
          SharedPreferences.setMockInitialValues({
            'pref_eth_gas_mode': 'custom',
            'pref_eth_gas_max_base_fee_gwei': 100.0,
            'pref_eth_gas_priority_fee_gwei': 2.0,
            'pref_eth_gas_limit': 999999,
          });
          if (sl.isRegistered<PreferencesService>()) {
            await sl.unregister<PreferencesService>();
          }
          sl.registerSingleton<PreferencesService>(
            await PreferencesService.create(),
          );
          when(mockEthereum.gasMarket()).thenAnswer(
            (_) async => EthGasMarket.fromSuggestedGasFees(const {
              'low': {
                'suggestedMaxPriorityFeePerGas': '1',
                'suggestedMaxFeePerGas': '20',
              },
              'medium': {
                'suggestedMaxPriorityFeePerGas': '2',
                'suggestedMaxFeePerGas': '24',
              },
              'estimatedBaseFee': '11',
            }),
          );
          // Contract recipient: prepare estimates 60 000 padded gas (> the flat
          // 25 200 EOA limit the old reserve used).
          when(
            mockEthereum.nativeSendGasLimitFor(
              source: anyNamed('source'),
              destination: anyNamed('destination'),
            ),
          ).thenAnswer((_) async => 60000);
          // 0.5 ETH + reserve(60 000 × 102 gwei = 6 120 000 000 000 000 wei).
          when(
            mockEthereum.nativeBalance(ethSource),
          ).thenAnswer((_) async => BigInt.parse('506120000000000000'));
        },
        build: buildEthBloc,
        act: (bloc) {
          bloc.add(
            const SendEvent.setSource(
              chain: Chain.ethereum,
              address: ethSource,
              walletId: ethWalletId,
            ),
          );
          bloc.add(const SendEvent.setRecipient(ethRecipient));
          bloc.add(const SendEvent.setMaxAmount());
        },
        expect: () => [
          const SendState.input(recipient: ethRecipient),
          const SendState.input(recipient: ethRecipient, amount: '0.5'),
        ],
        verify: (_) {
          // Reserved against the resolved selection's balance/caps over the real
          // per-recipient limit, never the service's flat getFeeData fallback.
          verify(mockEthereum.gasMarket()).called(1);
          verify(mockEthereum.nativeBalance(ethSource)).called(1);
          verify(
            mockEthereum.nativeSendGasLimitFor(
              source: anyNamed('source'),
              destination: anyNamed('destination'),
            ),
          ).called(1);
          verifyNever(mockEthereum.maxNativeSendable(any));
        },
      );

      // FINDING 5 (stale-transfer hazard) + FINDING 8b (concurrent fee market).
      // The review step caches the validated prepared transfer for execute to
      // sign. These tests prove the cache is never signed once it no longer
      // matches the live ready state, and that the fee-market fetch (now kicked
      // off concurrently with prepare) stays non-fatal.
      group('prepared cache + concurrent fee market', () {
        // A second, distinct valid recipient so a superseded review caches a
        // different destination than the live ready state.
        const ethRecipient2 = '0x1111111111111111111111111111111111111111';
        // 0.5 ETH / 0.7 ETH in wei — the two amounts under test.
        final halfEthWei = BigInt.parse('500000000000000000');

        // Every prepare call's (destination, amountRaw), so a test can prove
        // which transfer was (re-)prepared and when.
        late List<(String, BigInt)> prepareCalls;
        // The prepared transfer execute ultimately signed.
        late PreparedEthTransfer signedPrepared;
        // Gates the FIRST review's fee-market fetch so that review can be
        // suspended AFTER it caches its prepared but BEFORE it emits ready.
        late Completer<EthGasMarket> marketGate;

        // prepare echoes its (destination, amountRaw) into the returned prepared
        // so `signedPrepared` reveals exactly what execute signed.
        void stubEchoPrepare() {
          when(
            mockEthereum.prepare(
              walletId: anyNamed('walletId'),
              source: anyNamed('source'),
              destination: anyNamed('destination'),
              amountRaw: anyNamed('amountRaw'),
              token: anyNamed('token'),
            ),
          ).thenAnswer((inv) async {
            final dest = inv.namedArguments[#destination] as String;
            final raw = inv.namedArguments[#amountRaw] as BigInt;
            prepareCalls.add((dest, raw));
            return PreparedEthTransfer(
              walletId: ethWalletId,
              source: ethSource,
              to: EthereumAddress.fromHex(dest),
              value: raw,
              data: null,
              estimate: ethEstimate,
            );
          });
        }

        void stubGatedMarket() {
          var calls = 0;
          when(mockEthereum.gasMarket()).thenAnswer((_) async {
            calls++;
            // Only the first review blocks; later reviews resolve immediately.
            return calls == 1 ? marketGate.future : _ethMarket();
          });
        }

        void stubCapturingExecute() {
          when(
            mockEthereum.execute(
              any,
              feeOverride: anyNamed('feeOverride'),
              onBroadcasting: anyNamed('onBroadcasting'),
              onBroadcastRegistered: anyNamed('onBroadcastRegistered'),
            ),
          ).thenAnswer((inv) async {
            signedPrepared =
                inv.positionalArguments.first as PreparedEthTransfer;
            (inv.namedArguments[#onBroadcasting] as void Function()?)?.call();
            return ethTxHash;
          });
        }

        setUp(() {
          prepareCalls = [];
          marketGate = Completer<EthGasMarket>();
        });

        // WHY (FINDING 8b): the fee-market fetch runs concurrently with prepare
        // now. A market failure must still degrade to a null market/selection
        // and never block the review — the concurrency change must not alter the
        // non-fatal semantics.
        blocTest<SendBloc, SendState>(
          'a failed fee-market fetch still reaches ready with a null gas '
          'selection (concurrency stays non-fatal)',
          setUp: () {
            stubEchoPrepare();
            // gasMarket completes with an error (a feeHistory outage).
            when(
              mockEthereum.gasMarket(),
            ).thenAnswer((_) async => throw Exception('feeHistory down'));
          },
          build: buildEthBloc,
          seed: () =>
              const SendState.input(recipient: ethRecipient, amount: '0.5'),
          act: (bloc) {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.ethereum,
                address: ethSource,
                walletId: ethWalletId,
              ),
            );
            bloc.add(const SendEvent.validateAndProceed());
          },
          verify: (bloc) {
            final s = bloc.state as SendReady;
            expect(s.ethereumEstimate, isNotNull);
            expect(s.ethGasMarket, isNull);
            expect(s.ethGasSelection, isNull);
          },
        );

        // WHY (FINDING 5, part a): an amount edit landing while a review is in
        // flight must invalidate (clear) the cached prepared, so execute
        // re-prepares from the ready state instead of signing the orphaned one.
        blocTest<SendBloc, SendState>(
          'an amount edit mid-review clears the cache so execute re-prepares '
          'from the ready state',
          setUp: () {
            stubEchoPrepare();
            stubGatedMarket();
            stubCapturingExecute();
          },
          build: buildEthBloc,
          act: (bloc) async {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.ethereum,
                address: ethSource,
                walletId: ethWalletId,
              ),
            );
            bloc.add(const SendEvent.setRecipient(ethRecipient));
            bloc.add(const SendEvent.setAmount('0.5'));
            await Future<void>.delayed(Duration.zero);
            // Review caches (ethRecipient, 0.5 ETH), then parks on the gated
            // market fetch before emitting ready.
            bloc.add(const SendEvent.validateAndProceed());
            await Future<void>.delayed(Duration.zero);
            // The user edits the amount while the review is parked — this clears
            // the cached prepared.
            bloc.add(const SendEvent.setAmount('0.7'));
            await Future<void>.delayed(Duration.zero);
            // Release the review — it emits ready(0.5) with the cache cleared.
            marketGate.complete(_ethMarket());
            await Future<void>.delayed(Duration.zero);
            bloc.add(const SendEvent.execute());
            await Future<void>.delayed(Duration.zero);
          },
          verify: (_) {
            // Signed the ready state's 0.5 ETH to ethRecipient.
            expect(signedPrepared.value, halfEthWei);
            expect(
              signedPrepared.to.with0x.toLowerCase(),
              ethRecipient.toLowerCase(),
            );
            // prepare ran twice for 0.5 ETH — the review AND the execute
            // re-prepare — proving the cache was cleared (a live cache would
            // have been reused, so prepare would have run only once).
            expect(prepareCalls.where((c) => c.$2 == halfEthWei).length, 2);
          },
        );

        // WHY (FINDING 5, part b — load-bearing): when the cache holds a
        // prepared from a SUPERSEDED review (different recipient + amount than
        // the live ready state), execute must re-prepare from the ready state
        // and NEVER sign the stale cache. The signed recipient/amount must be
        // the ones on the ready state.
        blocTest<SendBloc, SendState>(
          'execute re-prepares from the live ready state when the cache was '
          'overwritten by a superseded review (never signs the stale prepared)',
          setUp: () {
            stubEchoPrepare();
            stubGatedMarket();
            stubCapturingExecute();
          },
          build: buildEthBloc,
          act: (bloc) async {
            bloc.add(
              const SendEvent.setSource(
                chain: Chain.ethereum,
                address: ethSource,
                walletId: ethWalletId,
              ),
            );
            bloc.add(const SendEvent.setRecipient(ethRecipient));
            bloc.add(const SendEvent.setAmount('0.5'));
            await Future<void>.delayed(Duration.zero);
            // Review #1: caches (ethRecipient, 0.5 ETH), parks on the gated
            // market fetch.
            bloc.add(const SendEvent.validateAndProceed());
            await Future<void>.delayed(Duration.zero);
            // Supersede it: edit to a different recipient + amount and review
            // again. Review #2 overwrites the cache with (ethRecipient2, 0.7)
            // and emits its ready state.
            bloc.add(const SendEvent.setRecipient(ethRecipient2));
            bloc.add(const SendEvent.setAmount('0.7'));
            bloc.add(const SendEvent.validateAndProceed());
            await Future<void>.delayed(Duration.zero);
            // Release review #1 — it emits ready(ethRecipient, 0.5) LAST, so the
            // live ready state is (ethRecipient, 0.5) while the cache still
            // points at review #2's (ethRecipient2, 0.7).
            marketGate.complete(_ethMarket());
            await Future<void>.delayed(Duration.zero);
            bloc.add(const SendEvent.execute());
            await Future<void>.delayed(Duration.zero);
          },
          verify: (_) {
            // Signed the LIVE ready state (ethRecipient, 0.5 ETH), NOT the stale
            // cache (ethRecipient2, 0.7 ETH).
            expect(signedPrepared.value, halfEthWei);
            expect(
              signedPrepared.to.with0x.toLowerCase(),
              ethRecipient.toLowerCase(),
            );
            // execute re-prepared for ethRecipient rather than reusing the
            // ethRecipient2 cache.
            expect(
              prepareCalls
                  .where(
                    (c) => c.$1.toLowerCase() == ethRecipient.toLowerCase(),
                  )
                  .length,
              2,
            );
            expect(
              prepareCalls
                  .where((c) => c.$1.toLowerCase() == ethRecipient2)
                  .length,
              1,
            );
          },
        );
      });
    });
  });
}
