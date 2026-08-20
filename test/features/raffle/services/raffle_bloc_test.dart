import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
// Only the kill-switch exception: this file's [TransactionAuthCancelledException]
// is `core/crypto/exceptions.dart`'s, and the gate declares a same-named one.
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart'
    show TransactionFlowDisabledException;
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_pipeline.dart';
import 'package:mallow_wallet/features/raffle/data/raffle_repository.dart';
import 'package:mallow_wallet/features/raffle/services/raffle_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'raffle_bloc_test.mocks.dart';

@GenerateMocks([
  RaffleRepository,
  AuthService,
  TransactionPipeline,
  TransactionExecutor,
])
void main() {
  late MockRaffleRepository mockRepo;
  late MockAuthService mockAuth;
  late MockTransactionPipeline mockPipeline;
  late MockTransactionExecutor mockExecutor;

  const testAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const testRaffleKey = 'RAFFLE_KEY_123';
  const testTxBase64 = 'unsigned-raffle-tx-base64';
  const testSignature =
      '5wHu1qwD7TjGq5mXg1hXNxoZMmcMvisPLfkxGqzxJxbVnC4ZDvDpKsWvBsYxSxSvGmEzMfZZVFKLiCjMrpLnBqTJ';

  setUpAll(() {
    // mockito needs a dummy for the executor's non-nullable Result return
    // type even though every called path is explicitly stubbed.
    provideDummy<Result<String, AppFailure>>(const ResultSuccess(''));
  });

  setUp(() {
    mockRepo = MockRaffleRepository();
    mockAuth = MockAuthService();
    mockPipeline = MockTransactionPipeline();
    mockExecutor = MockTransactionExecutor();
    when(mockAuth.currentAddress).thenReturn(testAddress);
  });

  // Real [MarketplaceActionFlow] over the same mocked low-level services the
  // bloc used directly before the flow was extracted — keeps these tests
  // exercising the actual prepare path (not a mocked seam) so behavior parity
  // holds.
  MarketplaceActionFlow makeFlow() =>
      MarketplaceActionFlow(mockAuth, mockExecutor, mockPipeline);

  RaffleBloc buildBloc() => RaffleBloc(mockRepo, makeFlow());

  /// Stub the buy-tickets prepare + executor so a buy flow walks the full
  /// lifecycle: build → readyToSign, then sign → broadcasting → success.
  void stubBuyTicketsSuccess() {
    when(
      mockRepo.getBuyTicketsTx(
        buyer: anyNamed('buyer'),
        raffleKey: anyNamed('raffleKey'),
        ticketCount: anyNamed('ticketCount'),
      ),
    ).thenAnswer((_) async => testTxBase64);
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

  group('RaffleBloc state-sequence parity', () {
    // The bespoke RaffleState (loading/readyToSign/signing/broadcasting/
    // success) is hand-mapped to the six ActionFlowSink edges — not driven by
    // txFlowSink. This asserts the full prepare→sign→broadcast→success
    // sequence threads through the sink in the exact order the UI relied on
    // before that extraction, so the migration is behaviour-preserving.
    blocTest<RaffleBloc, RaffleState>(
      'buy-tickets walks loading→readyToSign→signing→broadcasting→success',
      setUp: stubBuyTicketsSuccess,
      build: buildBloc,
      act: (bloc) async {
        bloc.add(
          const RaffleEvent.buyTickets(
            raffleKey: testRaffleKey,
            ticketCount: 1,
          ),
        );
        // Wait for the prepare phase to land on readyToSign before signing —
        // confirmAndSign no-ops unless the bloc is already in RaffleReadyToSign.
        await bloc.stream.firstWhere((s) => s is RaffleReadyToSign);
        bloc.add(const RaffleEvent.confirmAndSign());
      },
      expect: () => [
        const RaffleState.loading(),
        const RaffleState.readyToSign(
          transactionBase64: testTxBase64,
          raffleKey: testRaffleKey,
          actionType: 'buy-tickets',
          flow: AppFlow.raffleBuyTickets,
        ),
        const RaffleState.signing(),
        const RaffleState.broadcasting(),
        const RaffleState.success(
          signature: testSignature,
          actionType: 'buy-tickets',
        ),
      ],
    );
  });

  group('RaffleBloc prepare error mapping', () {
    // The raffle prepare handlers now share a single _runPrepare helper that
    // routes thrown errors through AppFailure.from. The whole reason for the
    // helper is to keep error UX consistent and to classify cancellation
    // distinctly — verify both halves of that contract here.

    blocTest<RaffleBloc, RaffleState>(
      'maps network error to RaffleError with the helper-provided prefix',
      setUp: () {
        when(
          mockRepo.getBuyTicketsTx(
            buyer: anyNamed('buyer'),
            raffleKey: anyNamed('raffleKey'),
            ticketCount: anyNamed('ticketCount'),
          ),
        ).thenThrow(Exception('boom'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const RaffleEvent.buyTickets(raffleKey: testRaffleKey, ticketCount: 1),
      ),
      expect: () => [
        const RaffleState.loading(),
        isA<RaffleError>().having(
          (e) => e.message,
          'message',
          contains('Failed to prepare ticket purchase'),
        ),
      ],
    );

    blocTest<RaffleBloc, RaffleState>(
      'classifies TransactionAuthCancelledException as cancellation',
      setUp: () {
        when(
          mockRepo.getCancelRaffleTx(
            creator: anyNamed('creator'),
            raffleKey: anyNamed('raffleKey'),
          ),
        ).thenThrow(TransactionAuthCancelledException('Cancelled by user'));
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const RaffleEvent.cancel(raffleKey: testRaffleKey)),
      // Cancellation still surfaces as RaffleError (UI surface) but the
      // failure went through AppFailure.cancelled internally — verify the
      // user-facing message preserves the cancellation copy verbatim.
      expect: () => [
        const RaffleState.loading(),
        isA<RaffleError>().having(
          (e) => e.message,
          'message',
          contains('Cancelled by user'),
        ),
      ],
    );
  });

  group('RaffleBloc auth gating', () {
    blocTest<RaffleBloc, RaffleState>(
      'emits error when no wallet is connected',
      setUp: () => when(mockAuth.currentAddress).thenReturn(null),
      build: buildBloc,
      act: (bloc) => bloc.add(
        const RaffleEvent.buyTickets(raffleKey: testRaffleKey, ticketCount: 1),
      ),
      expect: () => [
        const RaffleState.loading(),
        isA<RaffleError>().having(
          (e) => e.message,
          'message',
          'No wallet connected',
        ),
      ],
    );
  });

  group('RaffleBloc kill switch', () {
    // The four raffle actions are four independent kill-switch cells and the
    // sign step is a separate event from the prepare, so the classified failure
    // has to survive onto [RaffleError] — the screen presents the operator's
    // copy in `FlowUnavailableSheet` instead of a snackbar, and can only tell a
    // kill from a real error by its kind.
    blocTest<RaffleBloc, RaffleState>(
      'carries a flowDisabled failure onto RaffleError instead of flattening '
      'it to a message',
      setUp: () {
        when(
          mockRepo.getClaimNftTx(
            caller: anyNamed('caller'),
            raffleKey: anyNamed('raffleKey'),
          ),
        ).thenThrow(
          const TransactionFlowDisabledException(
            'Raffle claims are paused. Your prize is safe.',
          ),
        );
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const RaffleEvent.claimNft(raffleKey: testRaffleKey)),
      expect: () => [
        const RaffleState.loading(),
        isA<RaffleError>()
            .having(
              (e) => e.failure?.isFlowDisabled,
              'failure.isFlowDisabled',
              isTrue,
            )
            // Rendered verbatim: the operator's copy must not be prefixed with
            // "Failed to prepare claim".
            .having(
              (e) => e.message,
              'message',
              'Raffle claims are paused. Your prize is safe.',
            ),
      ],
    );
  });
}
