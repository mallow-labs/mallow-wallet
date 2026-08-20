import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/token_burn_flow.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class _MockRpc extends Mock implements SolanaRpcService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuthGate extends Mock implements TransactionAuthGate {}

class _MockExecutor extends Mock implements TransactionExecutor {}

class _MockAggregator extends Mock implements SessionPortfolioAggregator {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockRemoteConfig extends Fake implements RemoteConfigService {
  @override
  final ValueListenable<RemoteConfig> config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  Future<void> refreshIfStale() async {}
}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

const _mint = 'BONK_MINT';
const _address = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

const _token = TokenBalance(
  mint: _mint,
  symbol: 'BONK',
  name: 'Bonk',
  decimals: 5,
  rawBalance: 800000,
  uiBalance: 8,
  // Priced at $0 so the auth gate takes its "known worthless" path and the
  // stub below is the only thing standing between the tap and the executor.
  pricePerToken: 0,
  totalUsdValue: 0,
);

const _wallet = WalletInfo(
  id: 'w-a',
  address: _address,
  name: 'A',
  walletType: WalletType.hd,
  chain: 'solana',
);

/// A burn broadcast whose confirmation never arrived before the blockhash
/// expired is *indeterminate*, not failed — the tokens may well be gone. Two
/// things follow, and this is what the test pins:
///
///   1. "Burn failed" is a claim we cannot make. It sends the user off to
///      re-acquire tokens they may still hold.
///   2. "Try again" re-signs a fresh burn of the same amount against the same
///      account. If the original lands too, the user burns twice — and a burn
///      is irreversible.
void main() {
  late _MockRpc rpc;
  late _MockWalletManager wallets;
  late _MockAuthGate authGate;
  late _MockExecutor executor;
  late _MockAggregator aggregator;
  late _MockTokenBalanceBloc balanceBloc;

  setUpAll(() {
    registerFallbackValue(const FlowKey.solana(AppFlow.tokenBurn));
  });

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    rpc = _MockRpc();
    wallets = _MockWalletManager();
    authGate = _MockAuthGate();
    executor = _MockExecutor();
    aggregator = _MockAggregator();
    balanceBloc = _MockTokenBalanceBloc();

    whenListen(
      balanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    when(() => wallets.getAddress()).thenAnswer((_) async => _address);
    when(() => wallets.isLocalSigner()).thenAnswer((_) async => true);
    when(
      () => aggregator.sendSourcesForMint(chain: Chain.solana, mint: _mint),
    ).thenAnswer(
      (_) async => [
        SendSourceCandidate(
          wallet: _wallet,
          rawBalance: _token.rawBalance,
          uiBalance: _token.uiBalance,
        ),
      ],
    );
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => 'TX');
    when(
      () => rpc.simulateWithDelta(
        address: any(named: 'address'),
        simulate: any(named: 'simulate'),
      ),
    ).thenAnswer(
      (_) async => const SimulationDelta(
        result: SimulationResult(success: true),
        lamportsDelta: 2039280,
      ),
    );
    when(
      () => authGate.authorize(
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
      ),
    ).thenAnswer((_) async => TransactionAuthOutcome.allowed);

    register<SolanaRpcService>(rpc);
    register<WalletManager>(wallets);
    register<TransactionAuthGate>(authGate);
    register<FeeConfig>(const FeeConfig());
    register<TransactionExecutor>(executor);
    register<SessionPortfolioAggregator>(aggregator);
    register<SessionManager>(_MockSessionManager());
    register<RemoteConfigService>(_MockRemoteConfig());
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<SolanaRpcService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<TransactionAuthGate>(),
      () => sl.unregister<FeeConfig>(),
      () => sl.unregister<TransactionExecutor>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<RemoteConfigService>(),
    ]) {
      drop();
    }
  });

  /// The sheet's CTA and source line animate indefinitely, so `pumpAndSettle`
  /// would never return — pump a fixed budget instead.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Runs the flow to the pipeline step's error body, with the executor
  /// reporting [error].
  Future<void> burnUntilError(WidgetTester tester, AppFailure error) async {
    when(
      () => executor.execute(
        txsBase64: any(named: 'txsBase64'),
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
        onStage: any(named: 'onStage'),
      ),
    ).thenAnswer((_) async {
      // Outlast the confirm→pipeline morph. The confirm sheet's own listener
      // pops the whole flow on a failure (a *prepare* failure is its case), and
      // the switcher keeps it mounted through the transition — so an instant
      // failure would never reach the pipeline body under test. A real
      // broadcast is seconds away, not frames.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return ResultFailure<String, AppFailure>(error);
    });

    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runTokenBurnFlow(
                context,
                token: _token,
                tokenBalanceBloc: balanceBloc,
              ),
              child: const Text('burn'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('burn'));
    await flush(tester);

    await tester.tap(find.text('Burn Token').last);
    await flush(tester);
  }

  testWidgets('a determinate failure keeps the failure headline and offers a '
      'retry', (tester) async {
    await burnUntilError(
      tester,
      const AppFailure.rpc('Instruction 1 failed: insufficient funds'),
    );

    expect(find.text('Burn failed'), findsOneWidget);

    // Retry resets the bloc back to idle so the flow can be re-run. Nothing
    // burned, so re-signing is safe.
    await tester.tap(find.text('Try again'));
    await flush(tester);
    expect(find.text('Burn failed'), findsNothing);
  });

  testWidgets('an unconfirmed broadcast is not framed as a failure and cannot '
      'be retried', (tester) async {
    await burnUntilError(
      tester,
      AppFailure.from(const SolanaTransactionUnconfirmedException('sigSTUCK')),
    );

    expect(find.text('Burn failed'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    // The exception's own copy points the user at Activity / the explorer.
    expect(find.textContaining('may still land'), findsOneWidget);

    // The button is still laid out (the sheet keeps a fixed footprint) but is
    // inert: one execute, and it stays one no matter how often it is tapped.
    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await flush(tester);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    verify(
      () => executor.execute(
        txsBase64: any(named: 'txsBase64'),
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
        onStage: any(named: 'onStage'),
      ),
    ).called(1);

    // …and the user is never stranded: Back still resets the flow, which pops
    // the sheet.
    await tester.tap(find.text('Back'));
    await flush(tester);
    expect(find.text('Not confirmed yet'), findsNothing);
  });
}
