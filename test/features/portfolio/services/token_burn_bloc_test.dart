import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/services/transaction_flow_state.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_burn_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockRpc extends Mock implements SolanaRpcService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuthGate extends Mock implements TransactionAuthGate {}

class _MockFeeConfig extends Mock implements FeeConfig {}

class _MockExecutor extends Mock implements TransactionExecutor {}

const _mint = 'BONK_MINT';
const _walletA = 'SOL_WALLET_A';
const _walletB = 'SOL_WALLET_B';

const _token = TokenBalance(
  mint: _mint,
  symbol: 'BONK',
  name: 'Bonk',
  decimals: 5,
  rawBalance: 100,
  uiBalance: 1,
  pricePerToken: 1,
  totalUsdValue: 1,
);

TokenBurnPrep? _prepOf(TokenBurnState state) =>
    state is TxFlowReady<TokenBurnPrep, TokenBurnSuccess> ? state.data : null;

/// The burn source line re-issues
/// `TokenBurnPrepareRequested` after the picker commits a signer switch. Every
/// number on the confirm sheet — the prepared tx, and the rent/fee delta
/// simulated against the payer — must then describe the newly-active wallet,
/// because that is the wallet whose holding gets destroyed.
void main() {
  late _MockRpc rpc;
  late _MockWalletManager wallets;
  late _MockAuthGate gate;
  late _MockFeeConfig fees;
  late _MockExecutor executor;

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(const FlowKey.solana(AppFlow.tokenBurn));
  });

  setUp(() {
    rpc = _MockRpc();
    wallets = _MockWalletManager();
    gate = _MockAuthGate();
    fees = _MockFeeConfig();
    executor = _MockExecutor();
    when(() => fees.baseTxFeeLamports).thenReturn(5000);
  });

  TokenBurnBloc build() => TokenBurnBloc(rpc, wallets, gate, fees, executor);

  /// Stub `simulateWithDelta` so it reports the delta the caller's inspected
  /// address is keyed to — that is what proves which payer was used.
  void stubSimulate(Map<String, int> deltaByAddress) {
    when(
      () => rpc.simulateWithDelta(
        address: any(named: 'address'),
        simulate: any(named: 'simulate'),
      ),
    ).thenAnswer((invocation) async {
      final address = invocation.namedArguments[#address] as String?;
      return SimulationDelta(
        result: const SimulationResult(success: true),
        lamportsDelta: deltaByAddress[address],
      );
    });
  }

  test(
    're-preparing re-derives the payer and re-runs simulateWithDelta',
    () async {
      when(() => wallets.getAddress()).thenAnswer((_) async => _walletA);
      when(
        () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
      ).thenAnswer((_) async => 'TX_FOR_A');
      stubSimulate({_walletA: 1000, _walletB: 2000});

      final bloc = build();
      bloc.add(const TokenBurnPrepareRequested(_token));
      await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);
      expect(_prepOf(bloc.state)!.simulatedPayerLamportsDelta, 1000);

      // The picker committed a switch to wallet B; the sheet re-prepares.
      when(() => wallets.getAddress()).thenAnswer((_) async => _walletB);
      when(
        () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
      ).thenAnswer((_) async => 'TX_FOR_B');

      bloc.add(const TokenBurnPrepareRequested(_token));
      await bloc.stream.firstWhere(
        (s) => _prepOf(s)?.txBase64 == 'TX_FOR_B' && _prepOf(s)!.isSimulating,
      );
      await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);

      final prep = _prepOf(bloc.state)!;
      expect(prep.txBase64, 'TX_FOR_B');
      // Why: the delta is keyed to the inspected address, so 2000 can only come
      // from a simulation run against wallet B's balance. A stale 1000 here would
      // mean the sheet is quoting the rent the *previous* wallet would reclaim.
      expect(prep.simulatedPayerLamportsDelta, 2000);
      verify(
        () => rpc.simulateWithDelta(
          address: _walletB,
          simulate: any(named: 'simulate'),
        ),
      ).called(1);
      await bloc.close();
    },
  );

  test('a simulation in flight when the wallet switches cannot emit over the '
      'new prepare', () async {
    // Hold the first simulation open so it resolves *after* the re-prepare.
    final firstSim = Completer<SimulationDelta>();
    var simCall = 0;
    when(
      () => rpc.simulateWithDelta(
        address: any(named: 'address'),
        simulate: any(named: 'simulate'),
      ),
    ).thenAnswer((invocation) {
      simCall++;
      if (simCall == 1) return firstSim.future;
      return Future.value(
        const SimulationDelta(
          result: SimulationResult(success: true),
          lamportsDelta: 2000,
        ),
      );
    });

    when(() => wallets.getAddress()).thenAnswer((_) async => _walletA);
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => 'TX_FOR_A');

    final bloc = build();
    bloc.add(const TokenBurnPrepareRequested(_token));
    await bloc.stream.firstWhere((s) => _prepOf(s)?.isSimulating ?? false);

    when(() => wallets.getAddress()).thenAnswer((_) async => _walletB);
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => 'TX_FOR_B');
    bloc.add(const TokenBurnPrepareRequested(_token));
    await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);
    expect(_prepOf(bloc.state)!.simulatedPayerLamportsDelta, 2000);

    // Wallet A's simulation lands late. It must be discarded: the tx on screen
    // is now wallet B's, and pairing it with A's reclaim figure is exactly the
    // stale-number path the rollout plan calls a loss-of-funds risk.
    firstSim.complete(
      const SimulationDelta(
        result: SimulationResult(success: true),
        lamportsDelta: 1000,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final prep = _prepOf(bloc.state)!;
    expect(prep.txBase64, 'TX_FOR_B');
    expect(prep.simulatedPayerLamportsDelta, 2000);
    await bloc.close();
  });

  test('a superseded prepare cannot emit its own tx either', () async {
    final firstBuild = Completer<String>();
    var buildCall = 0;
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) {
      buildCall++;
      if (buildCall == 1) return firstBuild.future;
      return Future.value('TX_FOR_B');
    });
    when(() => wallets.getAddress()).thenAnswer((_) async => _walletB);
    stubSimulate({_walletB: 2000});

    final bloc = build();
    bloc.add(const TokenBurnPrepareRequested(_token));
    bloc.add(const TokenBurnPrepareRequested(_token));
    await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);

    firstBuild.complete('TX_FOR_A');
    await Future<void>.delayed(Duration.zero);

    expect(_prepOf(bloc.state)!.txBase64, 'TX_FOR_B');
    await bloc.close();
  });

  test('confirm signs the tx prepared for the wallet switched to', () async {
    when(() => wallets.getAddress()).thenAnswer((_) async => _walletB);
    when(() => wallets.isLocalSigner()).thenAnswer((_) async => true);
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => 'TX_FOR_B');
    stubSimulate({_walletB: 2000});
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.allowed);
    when(
      () => executor.execute(
        txsBase64: any(named: 'txsBase64'),
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
        onStage: any(named: 'onStage'),
      ),
    ).thenAnswer((_) async => const ResultFailure(AppFailure.unknown('stop')));

    final bloc = build();
    bloc.add(const TokenBurnPrepareRequested(_token));
    await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);
    bloc.add(const TokenBurnConfirmRequested());
    await bloc.stream.firstWhere(
      (s) => s is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>,
    );

    final captured =
        verify(
              () => executor.execute(
                txsBase64: captureAny(named: 'txsBase64'),
                usdValue: any(named: 'usdValue'),
                flow: any(named: 'flow'),
                onStage: any(named: 'onStage'),
              ),
            ).captured.single
            as List<String>;
    expect(captured, ['TX_FOR_B']);
    await bloc.close();
  });

  // The burn pipeline step titles every failure "Burn failed" and drops the
  // message, so a kill classified as `cancelled` (or as any other kind) leaves
  // the user with no idea why the burn refused or whether their tokens are at
  // risk. `flowDisabled` is what routes it to the sheet that shows the
  // operator's copy verbatim.
  test('a kill-switched cell fails as flowDisabled with the operator '
      'message, and never reaches the executor', () async {
    const killMessage = 'Burns are paused while we investigate an indexer bug.';
    when(() => wallets.getAddress()).thenAnswer((_) async => _walletA);
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => 'TX_FOR_A');
    stubSimulate({_walletA: 1000});
    when(
      () => gate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer(
      (_) async => const TransactionAuthOutcome.flowDisabled(killMessage),
    );

    final bloc = build();
    bloc.add(const TokenBurnPrepareRequested(_token));
    await bloc.stream.firstWhere((s) => _prepOf(s)?.simulationResult != null);
    bloc.add(const TokenBurnConfirmRequested());
    final failure = await bloc.stream.firstWhere(
      (s) => s is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>,
    );

    final appFailure =
        (failure as TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>).failure;
    expect(appFailure.isFlowDisabled, isTrue);
    expect(appFailure.isCancelled, isFalse);
    expect(appFailure.message, killMessage);
    verifyNever(
      () => executor.execute(
        txsBase64: any(named: 'txsBase64'),
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
        onStage: any(named: 'onStage'),
      ),
    );
    await bloc.close();
  });
}
