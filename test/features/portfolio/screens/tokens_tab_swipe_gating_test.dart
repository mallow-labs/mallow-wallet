import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/active_networks.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/screens/tokens_tab_content.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockAnalytics extends Mock implements AnalyticsService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockAggregator extends Mock implements SessionPortfolioAggregator {}

class _MockActiveNetworks extends Mock implements ActiveNetworks {}

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

/// The tab renders `StakeStatusSection` above the sort row, which resolves its
/// own `StakingBloc` from the locator. Held at its default (no data) state, so
/// the section collapses and this file keeps testing only swipe gating.
class _MockStakingBloc extends MockBloc<StakingEvent, StakingState>
    implements StakingBloc {}

const _signableMint = 'SIGNABLE_MINT';
const _watchOnlyMint = 'WATCH_ONLY_MINT';

/// The session's signable Solana wallet, and the active selection — both, so
/// the tab-wide send gate is open and only the per-mint gate is under test.
const _activeWallet = WalletInfo(
  id: 'w-a',
  address: 'AAAA',
  name: 'A',
  walletType: WalletType.hd,
  chain: 'solana',
);

TokenBalance _token(String mint, String symbol, {Chain chain = Chain.solana}) =>
    TokenBalance(
      mint: mint,
      symbol: symbol,
      name: symbol,
      decimals: 5,
      rawBalance: 500000,
      uiBalance: 5,
      pricePerToken: 1,
      totalUsdValue: 5,
      isVerified: true,
      chain: chain,
    );

/// The swipe row's key, as built by the tokens tab.
Finder _swipeFor(String mint, {Chain chain = Chain.solana}) =>
    find.byKey(ValueKey('swipe_${chain}_$mint'));

/// A Profile session aggregates holdings across its linked wallets, and reading
/// balances needs no key — so a token held only by a **watch-only** session
/// wallet still shows up in the list. Neither swipe action can complete for it
/// (send has no source to offer, burn has no wallet to sign the close), so the
/// row must not advertise them.
void main() {
  late _MockWalletManager wallets;
  late _MockWalletRepository walletRepo;
  late _MockAggregator aggregator;
  late _MockCastBloc castBloc;
  late _MockTokenBalanceBloc balanceBloc;
  late _MockSessionManager session;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    wallets = _MockWalletManager();
    walletRepo = _MockWalletRepository();
    aggregator = _MockAggregator();
    castBloc = _MockCastBloc();
    balanceBloc = _MockTokenBalanceBloc();

    final analytics = _MockAnalytics();
    when(
      () => analytics.track(
        any(),
        properties: any(named: 'properties'),
        entryPoint: any(named: 'entryPoint'),
        isOnchainTx: any(named: 'isOnchainTx'),
      ),
    ).thenAnswer((_) async {});

    session = _MockSessionManager();
    when(() => session.sessionWallets).thenReturn(const []);
    // The tab hosts PortfolioActionButtonsRow, whose Swap/Stake chain gate
    // asks the session for a signer per chain. An empty session disables both,
    // which is irrelevant to swipe gating but must not throw.
    for (final chain in Chain.values) {
      when(() => session.sessionWalletForChain(chain)).thenReturn(null);
      when(() => session.sessionWalletsForChain(chain)).thenReturn(const []);
    }
    // …except Solana, where the session must hold a signable wallet: the
    // tab-wide `enableSwipe` gate (`sessionCanSend`) now requires a signer on
    // the chain itself, not merely a signable active selection. Without it the
    // whole tab is un-swipeable and the per-mint gate under test never runs.
    when(
      () => session.sessionWalletForChain(Chain.solana),
    ).thenReturn(_activeWallet);
    when(
      () => session.sessionWalletsForChain(Chain.solana),
    ).thenReturn(const [_activeWallet]);

    // The tab's now-casting reserve resolves CastBloc from GetIt.
    whenListen(
      castBloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.idle(),
    );
    whenListen(
      balanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: TokenBalanceState.loaded(
        tokens: [
          _token(_signableMint, 'SIGN'),
          _token(_watchOnlyMint, 'WATCH'),
        ],
        totalUsdValue: 10,
      ),
    );
    when(
      () => wallets.onWalletChanged,
    ).thenAnswer((_) => const Stream<String>.empty());
    // The *active* wallet is signable — the tab-wide `enableSwipe` gate is
    // satisfied, so anything hidden below is the per-token gate at work.
    when(
      () => walletRepo.getActiveWallet(),
    ).thenAnswer((_) async => _activeWallet);

    // The tab hides a chain's 0-balance gas row when the user switches that
    // network off; every chain is on here.
    final networks = _MockActiveNetworks();
    when(networks.disabled).thenAnswer((_) async => const <Chain>{});
    when(() => networks.changes).thenAnswer((_) => const Stream<void>.empty());

    register<AnalyticsService>(analytics);
    register<ActiveNetworks>(networks);
    register<WalletManager>(wallets);
    register<WalletRepository>(walletRepo);
    register<SessionManager>(session);
    register<SessionPortfolioAggregator>(aggregator);
    register<CastBloc>(castBloc);

    final stakingBloc = _MockStakingBloc();
    whenListen(
      stakingBloc,
      const Stream<StakingState>.empty(),
      initialState: const StakingState(),
    );
    register<StakingBloc>(stakingBloc);
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<AnalyticsService>(),
      () => sl.unregister<ActiveNetworks>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<WalletRepository>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
      () => sl.unregister<CastBloc>(),
      () => sl.unregister<StakingBloc>(),
    ]) {
      drop();
    }
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: balanceBloc,
            child: const TokensTabContent(),
          ),
        ),
      ),
    );
    // Lets the async active-wallet and signable-mint scans land.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a token only watch-only wallets hold is not swipeable, while '
      'one a signable wallet holds still is', (tester) async {
    when(
      () => aggregator.signableSolanaMints(),
    ).thenAnswer((_) async => {_signableMint});

    await mount(tester);

    expect(_swipeFor(_signableMint), findsOneWidget);
    // Why: the row would offer Send and Burn that both dead-end — send's source
    // picker filters to signable wallets and would be empty, and the burn tx
    // has no wallet that can sign the close.
    expect(_swipeFor(_watchOnlyMint), findsNothing);
  });

  testWidgets('a failed scan leaves every row swipeable rather than blanking '
      'the tab', (tester) async {
    // Why: the balance cache is a local read that can fail independently of the
    // wallets themselves; degrading to "nothing is actionable" would be a far
    // worse outcome than letting the flows do their own refusal.
    when(
      () => aggregator.signableSolanaMints(),
    ).thenThrow(Exception('cache unavailable'));

    await mount(tester);

    expect(_swipeFor(_signableMint), findsOneWidget);
    expect(_swipeFor(_watchOnlyMint), findsOneWidget);
  });

  group('non-Solana rows', () {
    /// Why: a session can hold no Solana wallet at all. Swipe-to-send is the
    /// tab's primary send affordance, and gating it on `chain == solana` left
    /// a Tezos/Ethereum-only session with rows that ignored the gesture — even
    /// though the send sheet signs both chains by explicit wallet id.
    void useSession(List<WalletInfo> sessionWallets, List<TokenBalance> rows) {
      when(() => session.sessionWallets).thenReturn(sessionWallets);
      for (final w in sessionWallets) {
        when(() => session.sessionWalletForChain(w.chainEnum)).thenReturn(w);
        when(() => session.sessionWalletsForChain(w.chainEnum)).thenReturn([w]);
      }
      whenListen(
        balanceBloc,
        const Stream<TokenBalanceState>.empty(),
        initialState: TokenBalanceState.loaded(tokens: rows, totalUsdValue: 10),
      );
      // No Solana rows in these sessions, so the Solana-only scan is empty.
      when(
        () => aggregator.signableSolanaMints(),
      ).thenAnswer((_) async => const <String>{});
    }

    const tezosWallet = WalletInfo(
      id: 'w-xtz',
      address: 'tz1AAAA',
      name: 'XTZ',
      walletType: WalletType.hd,
      chain: 'tezos',
    );

    testWidgets('a Tezos row is swipeable when the session can sign on Tezos', (
      tester,
    ) async {
      useSession(
        const [tezosWallet],
        [_token('XTZ_NATIVE', 'XTZ', chain: Chain.tezos)],
      );

      await mount(tester);

      expect(
        _swipeFor('XTZ_NATIVE', chain: Chain.tezos),
        findsOneWidget,
        reason: 'a Tezos-only session must still be able to swipe-to-send',
      );
    });

    testWidgets('a Tezos row is not swipeable when the session\'s only Tezos '
        'wallet cannot sign a transfer', (tester) async {
      // Why: a Tezos *ledger* wallet passes `canSign` but
      // `signTezosOperation` throws for it, so the swipe would dead-end after
      // the source is picked.
      useSession(
        const [
          WalletInfo(
            id: 'w-xtz-ledger',
            address: 'tz1LEDGER',
            name: 'XTZ Ledger',
            walletType: WalletType.ledger,
            chain: 'tezos',
          ),
        ],
        [_token('XTZ_NATIVE', 'XTZ', chain: Chain.tezos)],
      );

      await mount(tester);

      expect(_swipeFor('XTZ_NATIVE', chain: Chain.tezos), findsNothing);
    });

    testWidgets('an Ethereum row is swipeable, and neither non-Solana row '
        'offers burn', (tester) async {
      useSession(
        const [
          tezosWallet,
          WalletInfo(
            id: 'w-eth',
            address: '0xAAAA',
            name: 'ETH',
            walletType: WalletType.hd,
            chain: 'ethereum',
          ),
        ],
        [
          _token('ETH_NATIVE', 'ETH', chain: Chain.ethereum),
          _token('XTZ_NATIVE', 'XTZ', chain: Chain.tezos),
        ],
      );

      await mount(tester);

      expect(_swipeFor('ETH_NATIVE', chain: Chain.ethereum), findsOneWidget);

      /// Drags [row] without releasing, so the panel is asserted on without
      /// tripping the action (a release past threshold opens the send sheet).
      Future<void> peek(Finder row, double dx) async {
        final gesture = await tester.startGesture(tester.getCenter(row));
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump();
      }

      // The gesture is live, not just the key: a right-drag reveals Send.
      await peek(_swipeFor('ETH_NATIVE', chain: Chain.ethereum), 120);
      expect(find.text('Send'), findsOneWidget);

      // Why: burn builds an SPL burn+close tx, which exists only on Solana —
      // a left-drag on these rows must stay inert.
      for (final row in [
        _swipeFor('ETH_NATIVE', chain: Chain.ethereum),
        _swipeFor('XTZ_NATIVE', chain: Chain.tezos),
      ]) {
        await peek(row, -120);
        expect(find.text('Burn'), findsNothing);
      }
    });
  });
}
