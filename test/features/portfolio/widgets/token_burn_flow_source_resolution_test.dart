import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
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
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockRpc extends Mock implements SolanaRpcService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuthGate extends Mock implements TransactionAuthGate {}

class _MockExecutor extends Mock implements TransactionExecutor {}

class _MockAggregator extends Mock implements SessionPortfolioAggregator {}

class _MockSessionManager extends Mock implements SessionManager {}

/// Nothing killed — the entry gate's fail-open baseline.
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
const _addressA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _addressB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _addressC = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';

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

/// The portfolio row: the session's holdings of the mint *merged* across
/// wallets (8 BONK = B's 5 + C's 3), which is what the tokens tab hands to the
/// burn flow.
const _token = TokenBalance(
  mint: _mint,
  symbol: 'BONK',
  name: 'Bonk',
  decimals: 5,
  rawBalance: 800000,
  uiBalance: 8,
  pricePerToken: 2,
  totalUsdValue: 16,
);

/// A burn destroys the **active** wallet's token account, but the tokens tab
/// aggregates a Profile session's wallets into one row per mint. Swiping to burn
/// such a row used to build the tx against whichever wallet happened to be
/// active — which, when that wallet holds none of the mint, fails the build
/// outright ("This wallet holds no token account for …") and pops the sheet
/// before its own "Switch" line can be reached. The flow must therefore re-point
/// the signer at a wallet that actually holds the mint *before* preparing.
void main() {
  late _MockRpc rpc;
  late _MockWalletManager wallets;
  late _MockAggregator aggregator;
  late _MockSessionManager session;
  late _MockTokenBalanceBloc balanceBloc;
  late GlobalKey<NavigatorState> navKey;

  /// Flipped by the `selectSourceWallet` stub and read by the tx-build stub, so
  /// the tests can assert the switch landed *before* the build rather than just
  /// that both happened.
  late bool switched;

  setUpAll(() {
    registerFallbackValue(_wallet('fallback', _addressA));
  });

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    rpc = _MockRpc();
    wallets = _MockWalletManager();
    aggregator = _MockAggregator();
    session = _MockSessionManager();
    balanceBloc = _MockTokenBalanceBloc();
    navKey = GlobalKey<NavigatorState>();
    switched = false;

    whenListen(
      balanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    when(() => wallets.getAddress()).thenAnswer((_) async => _addressA);
    when(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).thenAnswer((_) async => switched ? 'TX_AFTER_SWITCH' : 'TX_FOR_ACTIVE');
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

    register<SolanaRpcService>(rpc);
    register<WalletManager>(wallets);
    register<TransactionAuthGate>(_MockAuthGate());
    register<FeeConfig>(const FeeConfig());
    register<TransactionExecutor>(_MockExecutor());
    register<SessionPortfolioAggregator>(aggregator);
    register<SessionManager>(session);
    // The flow's kill-switch entry gate reads this before anything else; a
    // permissive config is the "nothing killed" baseline these tests assume.
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

  void stubSources(List<SendSourceCandidate> candidates) {
    when(
      () => aggregator.sendSourcesForMint(chain: Chain.solana, mint: _mint),
    ).thenAnswer((_) async => candidates);
  }

  /// Commits the switch the way the real [SessionManager] does: the active
  /// wallet the tx builder reads moves to the chosen wallet.
  void stubSwitchSucceeds() {
    when(() => session.selectSourceWallet(any())).thenAnswer((
      invocation,
    ) async {
      final target = invocation.positionalArguments.first as WalletInfo;
      when(() => wallets.getAddress()).thenAnswer((_) async => target.address);
      switched = true;
    });
  }

  /// The sheet's CTA and the source line animate indefinitely, so
  /// `pumpAndSettle` would never return — pump a fixed budget instead.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Starts the flow from a real route context and pumps until it either
  /// settles on the confirm sheet or bails out. The flow's own result lands in
  /// [pending] — awaiting it here would hang on the sheet the flow is showing.
  late Future<bool> pending;

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        navigatorKey: navKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => pending = runTokenBurnFlow(
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
  }

  testWidgets('switches to the wallet that holds the mint before building the '
      'tx, and burns that wallet\'s balance', (tester) async {
    // The active wallet holds no BONK at all — the case that used to dead-end.
    stubSources([
      _candidate('w-a', _addressA, 0),
      _candidate('w-b', _addressB, 5),
      _candidate('w-c', _addressC, 3),
    ]);
    stubSwitchSucceeds();

    await start(tester);

    final target =
        verify(() => session.selectSourceWallet(captureAny())).captured.single
            as WalletInfo;
    // Largest holder wins when the active wallet holds none.
    expect(target.address, _addressB);

    // Why: [SolanaRpcService.buildBurnAndCloseTx] resolves the owner from the
    // *active* wallet. Building before the switch commits is precisely the
    // "wallet holds no token account" failure this guards against.
    expect(
      verify(
            () => rpc.buildBurnAndCloseTx(
              tokenMint: captureAny(named: 'tokenMint'),
            ),
          ).captured.single
          as String,
      _mint,
    );
    expect(switched, isTrue);

    // The header (and the auth gate's USD step-up threshold, derived from the
    // same value) must describe B's 5 BONK — not the 8 BONK session aggregate,
    // of which only 5 will actually burn.
    expect(find.text('Burn all 5 BONK'), findsOneWidget);

    // Unwind the sheet the flow is holding open. Its result is not what these
    // tests assert on, so `pending` is deliberately left unawaited — the flow
    // only completes once the dismissal animation has run out.
    navKey.currentState!.pop();
    await flush(tester);
  });

  testWidgets('leaves the active wallet alone when it holds the mint, but '
      'still quotes only that wallet\'s balance', (tester) async {
    stubSources([
      _candidate('w-a', _addressA, 5),
      _candidate('w-b', _addressB, 3),
    ]);
    stubSwitchSucceeds();

    await start(tester);

    // Why: moving the user's app-wide wallet for a burn the active wallet can
    // already sign is a side effect they never asked for.
    verifyNever(() => session.selectSourceWallet(any()));
    verify(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    ).called(1);

    // Why: the burn destroys A's 5 BONK and nothing else. Quoting the 8 BONK
    // session aggregate would promise a burn of B's holding too — and it is the
    // figure the auth gate's step-up threshold is derived from.
    expect(find.text('Burn all 5 BONK'), findsOneWidget);

    // Unwind the sheet the flow is holding open. Its result is not what these
    // tests assert on, so `pending` is deliberately left unawaited — the flow
    // only completes once the dismissal animation has run out.
    navKey.currentState!.pop();
    await flush(tester);
  });

  testWidgets('a failed switch aborts before signing anything', (tester) async {
    stubSources([
      _candidate('w-a', _addressA, 0),
      _candidate('w-b', _addressB, 5),
    ]);
    when(
      () => session.selectSourceWallet(any()),
    ).thenAnswer((_) => Future<void>.error(Exception('offline')));

    await start(tester);

    expect(await pending, isFalse);
    // Why: with the signer still on a wallet that holds nothing, preparing
    // could only produce the opaque build failure — say so instead.
    verifyNever(
      () => rpc.buildBurnAndCloseTx(tokenMint: any(named: 'tokenMint')),
    );
    expect(
      find.text(
        "Couldn't switch to the wallet that holds this token. Please try again.",
      ),
      findsOneWidget,
    );
  });
}
