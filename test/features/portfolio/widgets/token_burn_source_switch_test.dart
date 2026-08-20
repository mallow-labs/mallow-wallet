import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/services/transaction_flow_state.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_burn_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/token_burn_confirm_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAggregator extends Mock implements SessionPortfolioAggregator {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockBurnBloc extends MockBloc<TokenBurnEvent, TokenBurnState>
    implements TokenBurnBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

const _mint = 'BONK_MINT';
const _addressA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _addressB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

WalletInfo _wallet(String id, String address) => WalletInfo(
  id: id,
  address: address,
  name: id,
  walletType: WalletType.hd,
  chain: 'solana',
);

SendSourceCandidate _candidate(String id, String address, double ui) =>
    SendSourceCandidate(
      wallet: _wallet(id, address),
      rawBalance: (ui * 100000).round(),
      uiBalance: ui,
    );

const _token = TokenBalance(
  mint: _mint,
  symbol: 'BONK',
  name: 'Bonk',
  decimals: 5,
  rawBalance: 1000000,
  uiBalance: 10,
  pricePerToken: 2,
  totalUsdValue: 20,
);

const _ready = TxFlowReady<TokenBurnPrep, TokenBurnSuccess>(
  TokenBurnPrep(
    txBase64: 'TX_FOR_A',
    estimatedFeeLamports: 5000,
    simulationResult: SimulationResult(success: true),
    simulatedPayerLamportsDelta: 2039280,
  ),
);

/// A token burn destroys the **active**
/// wallet's holding of a mint, but the portfolio aggregates holdings across the
/// whole session — so without a source picker the user has no way to say which
/// wallet's BONK is being destroyed, and no way to tell which one will be.
void main() {
  late _MockWalletManager wallets;
  late _MockAggregator aggregator;
  late _MockSessionManager session;
  late _MockBurnBloc burnBloc;
  late _MockTokenBalanceBloc balanceBloc;

  setUpAll(() {
    registerFallbackValue(const TokenBurnResetRequested());
    registerFallbackValue(_wallet('fallback', _addressA));
  });

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    wallets = _MockWalletManager();
    aggregator = _MockAggregator();
    session = _MockSessionManager();
    burnBloc = _MockBurnBloc();
    balanceBloc = _MockTokenBalanceBloc();

    whenListen(
      burnBloc,
      const Stream<TokenBurnState>.empty(),
      initialState: _ready,
    );
    whenListen(
      balanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    when(() => wallets.getAddress()).thenAnswer((_) async => _addressA);

    register<WalletManager>(wallets);
    register<SessionPortfolioAggregator>(aggregator);
    register<SessionManager>(session);
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
      () => sl.unregister<SessionManager>(),
    ]) {
      drop();
    }
  });

  void stubSources(List<SendSourceCandidate> candidates) {
    when(
      () => aggregator.sendSourcesForMint(chain: Chain.solana, mint: _mint),
    ).thenAnswer((_) async => candidates);
  }

  /// The confirm CTA spins for the whole switch and the picker rows spin while
  /// a switch commits — both are indefinite animations, so `pumpAndSettle`
  /// would never return here. Pump a fixed budget instead (sheet entrance
  /// animation + the tap-guard settle buffer).
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<TokenBurnBloc>.value(
            value: burnBloc,
            child: TokenBurnConfirmSheet(
              token: _token,
              tokenBalanceBloc: balanceBloc,
              onConfirmed: () {},
            ),
          ),
        ),
      ),
    );
    // Lets the post-frame simulate kickoff and the async source load land.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('no Switch affordance when no other session wallet holds the '
      'token', (tester) async {
    stubSources([_candidate('w-a', _addressA, 10)]);
    await mount(tester);

    // Why: offering a switch with a single candidate would open a picker whose
    // only row is the wallet already selected.
    expect(find.textContaining('Your wallet:'), findsOneWidget);
    expect(find.text('Switch'), findsNothing);
  });

  testWidgets('wallets that hold none of the mint are not candidates', (
    tester,
  ) async {
    // Wallet B is a signable session wallet but holds no BONK — burning from it
    // is impossible (no token account), so it must not count toward the >= 2
    // threshold that reveals the affordance.
    stubSources([
      _candidate('w-a', _addressA, 10),
      _candidate('w-b', _addressB, 0),
    ]);
    await mount(tester);

    expect(find.text('Switch'), findsNothing);
  });

  testWidgets('Switch appears once two session wallets hold the token', (
    tester,
  ) async {
    stubSources([
      _candidate('w-a', _addressA, 10),
      _candidate('w-b', _addressB, 5),
    ]);
    await mount(tester);

    expect(find.text('Switch'), findsOneWidget);
  });

  testWidgets('picker lists both wallets; picking the other one switches, '
      're-prepares and re-points the burned amount', (tester) async {
    stubSources([
      _candidate('w-a', _addressA, 10),
      _candidate('w-b', _addressB, 5),
    ]);
    when(() => session.selectSourceWallet(any())).thenAnswer((_) async {});
    await mount(tester);

    expect(find.text('Burn all 10 BONK'), findsOneWidget);

    await tester.tap(find.text('Switch'));
    await flush(tester);

    // Both holders are offered, with their own balances.
    expect(find.text('Bal: 10 BONK'), findsOneWidget);
    expect(find.text('Bal: 5 BONK'), findsOneWidget);

    // Once B is active, the sheet reloads against B.
    when(() => wallets.getAddress()).thenAnswer((_) async => _addressB);
    await tester.tap(find.text('Bal: 5 BONK'));
    await flush(tester);

    final switched =
        verify(() => session.selectSourceWallet(captureAny())).captured.single
            as WalletInfo;
    expect(switched.address, _addressB);

    // Why: the prepared tx, its fee and the simulated rent reclaim were all
    // derived for wallet A. Re-issuing prepare is what rebuilds them for B —
    // signing the old tx would burn the wrong wallet's holding.
    final prepared =
        verify(
              () => burnBloc.add(
                captureAny(that: isA<TokenBurnPrepareRequested>()),
              ),
            ).captured.last
            as TokenBurnPrepareRequested;
    expect(prepared.token.uiBalance, 5);
    // The auth gate's step-up threshold is derived from this value, so it has
    // to describe the wallet that actually signs.
    expect(prepared.token.totalUsdValue, 10);

    expect(find.text('Burn all 5 BONK'), findsOneWidget);
    expect(find.textContaining('BBBB'), findsWidgets);
  });

  testWidgets('a failed switch surfaces the error, stays on the previous '
      'wallet and never signs', (tester) async {
    stubSources([
      _candidate('w-a', _addressA, 10),
      _candidate('w-b', _addressB, 5),
    ]);
    // Async failure, matching the real atomic switch: the durable re-point is
    // rolled back and the awaited `/v0/login` error reaches the picker.
    when(
      () => session.selectSourceWallet(any()),
    ).thenAnswer((_) => Future<void>.error(Exception('offline')));
    await mount(tester);

    await tester.tap(find.text('Switch'));
    await flush(tester);
    await tester.tap(find.text('Bal: 5 BONK'));
    await flush(tester);

    // The shared picker owns the error surface and stays open for a retry.
    expect(
      find.text("Couldn't switch wallet. Please try again."),
      findsWidgets,
    );

    // Back out of the still-open picker and assert the flow never moved.
    await tester.tap(find.text('Cancel').last);
    await flush(tester);

    verifyNever(
      () => burnBloc.add(any(that: isA<TokenBurnPrepareRequested>())),
    );
    verifyNever(
      () => burnBloc.add(any(that: isA<TokenBurnConfirmRequested>())),
    );
    expect(find.text('Burn all 10 BONK'), findsOneWidget);
    expect(find.textContaining('AAAA'), findsWidgets);
  });
}
