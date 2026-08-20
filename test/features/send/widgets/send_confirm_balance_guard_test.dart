import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/utils/token_amount.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/tezos_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/features/send/models/recipient_advisory.dart';
import 'package:mallow_wallet/features/send/services/ethereum_transfer_service.dart';
import 'package:mallow_wallet/features/send/services/recipient_advisory_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/services/tezos_transfer_service.dart';
import 'package:mallow_wallet/features/send/widgets/send_confirm_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_pipeline_view.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The confirm step's last-line balance guards, after they were narrowed from
/// the shared (session-**aggregate**) `TokenBalanceBloc` to the wallet actually
/// funding the send.
///
/// Narrowing was right — an aggregate summed across session wallets waves
/// through a spend the chain then rejects, *after* the user cleared biometrics.
/// But the narrowed guards then treated "this wallet holds nothing" and "we
/// haven't read this wallet's balance yet" as the same thing, and allowed both:
///
///  * Solana — `_sourceTokens` is only populated for an adopted source wallet,
///    and the fallback (`_sourceWallet = null`) is reached *precisely*
///    when no wallet holds a fundable balance
///    ([SendSourceCandidate.qualifies] requires `rawBalance > 0`). So the one
///    case the guard exists for skipped it.
///  * Ethereum / Tezos — the source's rows were read through `TokenRepository`,
///    which is Helius/Solana-only and cache-first. A session that never opened
///    the tokens tab for that chain (switched off in Active Networks, or a cold
///    start straight into Send) had no rows, so the amount+gas pre-check
///    silently did nothing.
///
/// Each test below asserts the *user-visible* consequence: a friendly snackbar
/// and no `SendEvent.execute()` — i.e. the biometric gate is never reached.
/// The "balance not loaded yet" test is the control for the opposite failure:
/// [checkBalance]'s "don't false-disable on entry" rule must survive the fix,
/// so an unreadable balance still allows the send through to the chain.

class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

class _FakeWalletManager extends Fake implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _solActive;
}

class _FakeAggregator extends Fake implements SessionPortfolioAggregator {
  _FakeAggregator(this.candidates);

  final List<SendSourceCandidate> candidates;

  @override
  Future<List<SendSourceCandidate>> sendSourcesForMint({
    required Chain chain,
    required String mint,
    bool refresh = false,
  }) async => candidates;
}

class _FakeSessionManager extends Fake implements SessionManager {
  _FakeSessionManager(this.chainWallet);

  final WalletInfo? chainWallet;

  @override
  WalletInfo? sessionWalletForChain(Chain chain) => chainWallet;

  @override
  Future<void> selectSourceWallet(WalletInfo wallet) async {}
}

/// Per-chain balance source. [cached] answers the cache-first read, [network]
/// the refresh; [networkThrows] models an unreachable balance service, which
/// must read as *unknown* rather than zero.
class _Balances {
  _Balances({
    this.cached = const [],
    this.network = const [],
    this.networkThrows = false,
  });

  final List<TokenBalance> cached;
  final List<TokenBalance> network;
  final bool networkThrows;

  /// Addresses this source was asked about — proves which service the sheet
  /// routed a given chain's funding wallet to.
  final List<String> queried = [];

  Future<List<TokenBalance>> readCache(String address) async {
    queried.add(address);
    return cached;
  }

  Future<List<TokenBalance>> readNetwork(String address) async {
    queried.add(address);
    if (networkThrows) throw Exception('balance service unreachable');
    return network;
  }
}

class _FakeTokenRepository extends Fake implements TokenRepository {
  _FakeTokenRepository(this.balances);

  final _Balances balances;

  @override
  Future<List<TokenBalance>> getCachedBalances(String walletAddress) =>
      balances.readCache(walletAddress);

  @override
  Future<List<TokenBalance>> getTokenBalances(String walletAddress) =>
      balances.readNetwork(walletAddress);
}

class _FakeEthereumTokenService extends Fake implements EthereumTokenService {
  _FakeEthereumTokenService(this.balances);

  final _Balances balances;

  @override
  Future<List<TokenBalance>> getCachedBalances(String address) =>
      balances.readCache(address);

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) =>
      balances.readNetwork(address);
}

class _FakeTezosTokenService extends Fake implements TezosTokenService {
  _FakeTezosTokenService(this.balances);

  final _Balances balances;

  @override
  Future<List<TokenBalance>> getCachedBalances(String address) =>
      balances.readCache(address);

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) =>
      balances.readNetwork(address);
}

class _FakeWalletRepository extends Fake implements WalletRepository {
  @override
  Future<Map<String, ({String name, String avatarSeed})>> accountsForAddresses(
    List<String> addresses,
  ) async => const {};
}

class _FakeProfileLookupService extends Fake implements ProfileLookupService {
  @override
  Future<Map<String, UserPreview>> profilesForAddresses(
    List<String> addresses,
  ) async => const {};
}

class _FakeTokenPriceService extends Fake implements TokenPriceService {
  @override
  double? priceOf(String? mint) => null;

  @override
  double? usdValueOfRaw(num? rawAmount, String? mint) => null;
}

class _FakeRecipientAdvisoryService extends Fake
    implements RecipientAdvisoryService {
  @override
  Future<RecipientAdvisory?> detect({
    required Chain chain,
    required String address,
  }) async => null;
}

// ── Fixtures ─────────────────────────────────────────────────────────────────

const _solActive = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solRecipient = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

const _ethSource = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
const _ethRecipient = '0x2222222222222222222222222222222222222222';

const _tezSource = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
const _tezRecipient = 'tz1burnburnburnburnburnburnburjAYjjX';

TokenBalance _sol({required int lamports}) => TokenBalance(
  mint: TokenBalance.solMint,
  symbol: 'SOL',
  name: 'Solana',
  decimals: 9,
  rawBalance: lamports,
  uiBalance: lamports / 1e9,
  isNative: true,
);

const _usdc = TokenBalance(
  mint: _usdcMint,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
);

TokenBalance _eth({required double uiBalance}) => TokenBalance(
  mint: TokenBalance.evmNativeSentinel,
  symbol: 'ETH',
  name: 'Ethereum',
  decimals: 18,
  rawBalance: (uiBalance * 1e18).toInt(),
  uiBalance: uiBalance,
  isNative: true,
  chain: Chain.ethereum,
);

TokenBalance _xtz({required int mutez}) => TokenBalance(
  mint: TokenBalance.tezosNativeSentinel,
  symbol: 'XTZ',
  name: 'Tezos',
  decimals: 6,
  rawBalance: mutez,
  uiBalance: mutez / 1e6,
  isNative: true,
  chain: Chain.tezos,
);

/// An FA2 holding: a case-exact `KT1…` mint (token id 0 encodes bare) with the
/// token's own 6 decimals, which are *not* mutez.
TokenBalance _usdt({required int raw}) => TokenBalance(
  mint: 'KT1XnTn74bUtxHfDtBmm2bGZAQfhPbvKWR8o',
  symbol: 'USDt',
  name: 'Tether USD',
  decimals: 6,
  rawBalance: raw,
  uiBalance: raw / 1e6,
  chain: Chain.tezos,
);

WalletInfo _wallet(String address, Chain chain) => WalletInfo(
  id: 'wallet-1',
  address: address,
  name: 'Wallet 1',
  walletType: WalletType.hd,
  chain: chain.toDbString(),
);

SendSourceCandidate _candidate(WalletInfo wallet, int rawBalance) =>
    SendSourceCandidate(
      wallet: wallet,
      rawBalance: rawBalance,
      uiBalance: rawBalance / 1e6,
    );

final _ethEstimate = EthereumSendEstimate(
  gasLimit: 21000,
  estimatedGasUsed: BigInt.from(21000),
  maxFeePerGas: BigInt.from(30000000000),
  maxPriorityFeePerGas: BigInt.from(1000000000),
  // 21000 × 20 gwei = 0.00042 ETH.
  effectiveGasPrice: BigInt.from(20000000000),
);

/// A calm mainnet where the node's `getFeeData` tip and Infura's Low tier
/// disagree by ~5x — 0.3 gwei base fee, a 1.5 gwei node tip, but a Low tier
/// capped at 0.35 gwei. That gap is the whole point: a Max priced off the Low
/// cap leaves only a Low-sized reserve behind.
final _lowGasMarket = EthGasMarket(
  baseFeeWei: BigInt.from(300000000), // 0.3 gwei
  priorityLowWei: BigInt.zero,
  priorityHighWei: BigInt.from(50000000),
  congestion: 0.1,
  historicalBaseFeeMinWei: BigInt.zero,
  historicalBaseFeeMaxWei: BigInt.zero,
  historicalPriorityMinWei: BigInt.zero,
  historicalPriorityMaxWei: BigInt.zero,
  low: EthGasTier(
    mode: EthGasMode.low,
    maxFeePerGas: BigInt.from(350000000), // 0.35 gwei
    maxPriorityFeePerGas: BigInt.from(50000000), // 0.05 gwei
    minWaitMs: 30000,
    maxWaitMs: 60000,
  ),
  market: EthGasTier(
    mode: EthGasMode.market,
    maxFeePerGas: BigInt.from(2100000000), // 2.1 gwei
    maxPriorityFeePerGas: BigInt.from(1500000000), // 1.5 gwei
    minWaitMs: 5000,
    maxWaitMs: 15000,
  ),
);

/// The Low tier resolved over the padded native-send gas limit (21 000 × 1.2).
final _lowGasSelection = EthGasSelection.fromTier(
  _lowGasMarket.low,
  gasLimit: 25200,
);

/// `prepare`'s estimate, whose `effectiveGasPrice` always comes from the node's
/// `eth_getFeeData` (0.3 gwei base + 1.5 gwei tip) — never from the tier the
/// user picked. Its `feeEth` is therefore 21 000 × 1.8 gwei = 0.0000378 ETH,
/// ~5x the Low fee the confirm screen shows.
final _ethEstimateNodeFeeData = EthereumSendEstimate(
  gasLimit: 25200,
  estimatedGasUsed: BigInt.from(21000),
  maxFeePerGas: BigInt.from(2100000000),
  maxPriorityFeePerGas: BigInt.from(1500000000),
  effectiveGasPrice: BigInt.from(1800000000), // 1.8 gwei
);

final _tezEstimate = TezosSendEstimate(
  feeMutez: BigInt.from(500),
  burnMutez: BigInt.zero,
  gasLimit: 1400,
  storageLimit: 0,
  includesReveal: false,
);

void main() {
  late _MockSendBloc sendBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late StreamController<SendState> sendStates;
  late ValueNotifier<RemoteConfig> config;
  late _Balances solanaBalances;
  late _Balances ethereumBalances;
  late _Balances tezosBalances;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<void> setUpSheet({
    required Chain chain,
    required List<SendSourceCandidate> candidates,
    WalletInfo? sessionWallet,
    _Balances? solana,
    _Balances? ethereum,
    _Balances? tezos,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();

    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    solanaBalances = solana ?? _Balances();
    ethereumBalances = ethereum ?? _Balances();
    tezosBalances = tezos ?? _Balances();

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(_FakeWalletManager());
    register<WalletRepository>(_FakeWalletRepository());
    register<ProfileLookupService>(_FakeProfileLookupService());
    register<TokenPriceService>(_FakeTokenPriceService());
    register<RecipientAdvisoryService>(_FakeRecipientAdvisoryService());
    register<SessionManager>(_FakeSessionManager(sessionWallet));
    register<TokenRepository>(_FakeTokenRepository(solanaBalances));
    register<EthereumTokenService>(_FakeEthereumTokenService(ethereumBalances));
    register<TezosTokenService>(_FakeTezosTokenService(tezosBalances));
    register<SessionPortfolioAggregator>(_FakeAggregator(candidates));
  }

  setUp(() {
    sendStates = StreamController<SendState>.broadcast();
    sendBloc = _MockSendBloc();
    tokenBalanceBloc = _MockTokenBalanceBloc();
    whenListen(
      sendBloc,
      sendStates.stream,
      initialState: const SendState.input(),
    );
    // Not a Max unless a test says so: the gate asks the bloc whether the
    // amount is the drain-the-account figure it priced, and only that one is
    // allowed to leave the wallet empty rather than rent-exempt.
    when(() => sendBloc.isSolMaxAmount(any(), any())).thenReturn(false);
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      // The tokens-tab instance: the session AGGREGATE. Every fixture below
      // funds it generously, so any guard that falls back to it passes — which
      // is exactly the regression these tests exist to catch.
      initialState: TokenBalanceState.loaded(
        tokens: [_sol(lamports: 5000000000), _usdc],
        totalUsdValue: 0,
      ),
    );

    config = ValueNotifier(RemoteConfig.permissive);
    final remoteConfig = MockRemoteConfigService();
    when(() => remoteConfig.config).thenReturn(config);
    when(remoteConfig.refreshIfStale).thenAnswer((_) async {});
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    sl.registerFactory<RemoteConfigService>(() => remoteConfig);
  });

  tearDown(() async {
    await sendStates.close();
    config.dispose();
    for (final drop in [
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<WalletRepository>(),
      () => sl.unregister<ProfileLookupService>(),
      () => sl.unregister<TokenPriceService>(),
      () => sl.unregister<RecipientAdvisoryService>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<TokenRepository>(),
      () => sl.unregister<EthereumTokenService>(),
      () => sl.unregister<TezosTokenService>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
      () => sl.unregister<RemoteConfigService>(),
    ]) {
      drop();
    }
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Pumps the sheet on [token], then drives it to the confirm step by emitting
  /// [ready] — the same transition [SendBloc] makes after review.
  Future<void> pumpToConfirm(
    WidgetTester tester,
    TokenBalance token,
    SendState ready,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<TokenBalanceBloc>.value(value: tokenBalanceBloc),
              BlocProvider<SendBloc>.value(value: sendBloc),
            ],
            child: SendSheet(initialToken: token),
          ),
        ),
      ),
    );
    await flush(tester);
    sendStates.add(ready);
    await flush(tester);
    expect(find.byType(SendConfirmStep), findsWidgets);
  }

  /// Taps the confirm step's Send CTA. The sheet also mounts two invisible
  /// sizing probes of the same step; those are `IgnorePointer`-wrapped, so
  /// `hitTestable` picks out the one copy a user can actually press.
  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(find.text('Send').hitTestable());
    await flush(tester);
  }

  /// The send never left the confirm step: no execute event, so no biometric
  /// gate and no pipeline.
  void expectBlocked(WidgetTester tester, {required String message}) {
    expect(find.text(message), findsOneWidget);
    verifyNever(() => sendBloc.add(const SendEvent.execute()));
    expect(find.byType(SendPipelineView), findsNothing);
  }

  void expectSent(WidgetTester tester) {
    expect(find.textContaining('Insufficient'), findsNothing);
    verify(() => sendBloc.add(const SendEvent.execute())).called(1);
  }

  // ── Solana ─────────────────────────────────────────────────────────────────

  testWidgets(
    'Solana: no session wallet holds the mint — the signer is checked and the '
    'send is stopped before the biometric gate',
    (tester) async {
      // The aggregate says 5 USDC (a sibling/view-only wallet holds it), so the
      // row was offered on the tokens tab. No wallet *qualifies* as a source,
      // so the sheet falls back to the active signer — which holds
      // SOL for fees but no USDC at all.
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), 0)],
        solana: _Balances(network: [_sol(lamports: 50000000)]),
      );
      await pumpToConfirm(
        tester,
        _usdc,
        const SendState.ready(
          recipient: _solRecipient,
          amountString: '5',
          amount: 5,
          token: _usdc,
          estimatedFeeLamports: 5000,
          totalCost: 5,
        ),
      );

      await tapSend(tester);

      expectBlocked(tester, message: 'Insufficient USDC — need 5 more');
      expect(
        solanaBalances.queried,
        contains(_solActive),
        reason:
            'the fallback signer is the wallet that will sign, so it is the '
            'wallet whose balance the guard has to read',
      );
    },
  );

  testWidgets(
    'Solana: a source adopted off a stale cache, but read back empty, is '
    'stopped — an empty *answer* is a zero balance, not an unread one',
    (tester) async {
      // The candidate qualified on cached rows; by the time the network
      // answered, the wallet had been emptied elsewhere. The reply is an empty
      // list — which is the same shape as "nothing loaded yet", and was
      // therefore waved through.
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), 9000000)],
        // Network answers with no rows at all: the wallet was emptied.
        solana: _Balances(cached: [_sol(lamports: 9000000)]),
      );
      await pumpToConfirm(
        tester,
        _sol(lamports: 9000000),
        const SendState.ready(
          recipient: _solRecipient,
          amountString: '0.005',
          amount: 0.005,
          token: null, // native SOL collapses to a null token
          estimatedFeeLamports: 5000,
          totalCost: 0.005,
        ),
      );

      await tapSend(tester);

      // 0.005 SOL, plus what the transaction can cost, plus the rent-exempt
      // minimum this partial send has to leave behind — against a wallet read
      // back empty.
      final deficit = TokenAmount.formatTokenAmount(
        BigInt.from(
          5000000 + worstCaseSolTxFeeLamports + kSolRentExemptMinimumLamports,
        ),
        9,
      );
      expectBlocked(tester, message: 'Insufficient SOL — need $deficit more');
    },
  );

  testWidgets(
    'Solana: a native Max — the balance less its exact fee — is not refused '
    'by the confirm gate',
    (tester) async {
      // A Max deliberately empties the wallet: it is priced off a live balance
      // read as `balance − exact fee`, so the fee is already inside the amount
      // and there is nothing left to reserve. Requiring anything on top — the
      // old flat 0.001 SOL cushion, or the rent floor every *partial* send
      // must clear — refuses the one amount the Max button just offered, after
      // the user has committed to it.
      const balance = 50000000; // 0.05 SOL
      const maxAmount = '0.0499785'; // balance − 21 500 lamports of fee
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), balance)],
        solana: _Balances(network: [_sol(lamports: balance)]),
      );
      when(
        () => sendBloc.isSolMaxAmount(maxAmount, _solRecipient),
      ).thenReturn(true);
      await pumpToConfirm(
        tester,
        _sol(lamports: balance),
        SendState.ready(
          recipient: _solRecipient,
          amountString: maxAmount,
          amount: double.parse(maxAmount),
          token: null, // native SOL collapses to a null token
          estimatedFeeLamports: 5000,
          totalCost: double.parse(maxAmount),
        ),
      );

      await tapSend(tester);

      expectSent(tester);
    },
  );

  testWidgets(
    'Solana: a partial native send that would leave the wallet rent-paying is '
    'stopped before the biometric gate',
    (tester) async {
      // Solana rejects a transaction that leaves a wallet holding more than
      // nothing but less than the rent-exempt minimum — after signing, as an
      // opaque preflight failure. An amount that clears the fee but not the
      // rent floor has to be caught here instead.
      const balance = 50000000; // 0.05 SOL
      const amount = '0.0499'; // leaves ~78 500 lamports: dust, not empty
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), balance)],
        solana: _Balances(network: [_sol(lamports: balance)]),
      );
      await pumpToConfirm(
        tester,
        _sol(lamports: balance),
        SendState.ready(
          recipient: _solRecipient,
          amountString: amount,
          amount: double.parse(amount),
          token: null,
          estimatedFeeLamports: 5000,
          totalCost: double.parse(amount),
        ),
      );

      await tapSend(tester);

      expect(find.textContaining('Insufficient SOL'), findsOneWidget);
      verifyNever(() => sendBloc.add(const SendEvent.execute()));
    },
  );

  testWidgets(
    'Solana: the funding wallet covers the spend — the send still goes through',
    (tester) async {
      // The guard must not become a blanket block; a funded source proceeds.
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), 5000000)],
        solana: _Balances(network: [_sol(lamports: 50000000), _usdc]),
      );
      await pumpToConfirm(
        tester,
        _usdc,
        const SendState.ready(
          recipient: _solRecipient,
          amountString: '5',
          amount: 5,
          token: _usdc,
          estimatedFeeLamports: 5000,
          totalCost: 5,
        ),
      );

      await tapSend(tester);

      expectSent(tester);
    },
  );

  testWidgets(
    'Solana: an unreadable balance is NOT treated as zero — the send proceeds '
    "and the chain decides (checkBalance's don't-false-disable rule)",
    (tester) async {
      // Balance service down: cache empty, network throws. Blocking here would
      // strand a fully funded user behind a snackbar they cannot clear.
      await setUpSheet(
        chain: Chain.solana,
        candidates: [_candidate(_wallet(_solActive, Chain.solana), 5000000)],
        solana: _Balances(networkThrows: true),
      );
      await pumpToConfirm(
        tester,
        _usdc,
        const SendState.ready(
          recipient: _solRecipient,
          amountString: '5',
          amount: 5,
          token: _usdc,
          estimatedFeeLamports: 5000,
          totalCost: 5,
        ),
      );

      await tapSend(tester);

      expectSent(tester);
    },
  );

  // ── Ethereum ───────────────────────────────────────────────────────────────

  testWidgets(
    'Ethereum: a cold balance cache is filled from the ETH service, not the '
    'Solana repository, so the amount+gas pre-check actually runs',
    (tester) async {
      // Ethereum switched off in Active Networks (or a cold start straight into
      // Send): nothing ever wrote this address's rows, and `TokenRepository`
      // could not produce them anyway — it is Helius/Solana-only.
      final ethWallet = _wallet(_ethSource, Chain.ethereum);
      await setUpSheet(
        chain: Chain.ethereum,
        candidates: [_candidate(ethWallet, 1000000000000000)],
        sessionWallet: ethWallet,
        ethereum: _Balances(network: [_eth(uiBalance: 0.001)]),
      );
      await pumpToConfirm(
        tester,
        _eth(uiBalance: 0.001),
        SendState.ready(
          recipient: _ethRecipient,
          amountString: '1',
          amount: 1,
          token: null, // native ETH collapses to a null token
          estimatedFeeLamports: 0,
          totalCost: 1,
          ethereumEstimate: _ethEstimate,
        ),
      );

      await tapSend(tester);

      expectBlocked(
        tester,
        message: 'Insufficient ETH for the amount plus fee.',
      );
      expect(
        ethereumBalances.queried,
        contains(_ethSource),
        reason: 'the ETH source must be read through EthereumTokenService',
      );
      expect(
        solanaBalances.queried,
        isEmpty,
        reason:
            'TokenRepository is Helius/Solana-only — routing an ETH address '
            'through it answers empty and silently disarms this guard',
      );
    },
  );

  testWidgets(
    'Ethereum: a native Max on the Low tier is priced against the SELECTED '
    'fee, not the node getFeeData fee — otherwise the guard refuses the one '
    'amount the Max button just offered',
    (tester) async {
      // `SendBloc._maxNativeSendable` reserves `gasLimit × selection.
      // maxFeePerGas` for the tier in prefs — on Low that is 25 200 × 0.35 gwei
      // = 0.00000882 ETH, so Max offers 0.01 − 0.00000882 = 0.00999118 ETH.
      //
      // The confirm screen *displays* the Low fee (21 000 × 0.35 gwei =
      // 0.00000735 ETH) because it recomputes from `ethGasSelection`. The guard
      // must price it the same way. Reading `estimate.feeEth` instead uses the
      // node's `getFeeData` (21 000 × 1.8 gwei = 0.0000378 ETH), which alone
      // exceeds the Low reserve — so a Max the app itself just computed reads
      // as a 0.0000378-ETH shortfall and is blocked at the last step.
      //
      // Market hides this: its reserve (25 200 × 2.1 gwei) swallows the node
      // fee, which is why only Low reproduces it.
      final ethWallet = _wallet(_ethSource, Chain.ethereum);
      await setUpSheet(
        chain: Chain.ethereum,
        candidates: [_candidate(ethWallet, 10000000000000000)],
        sessionWallet: ethWallet,
        ethereum: _Balances(network: [_eth(uiBalance: 0.01)]),
      );
      await pumpToConfirm(
        tester,
        _eth(uiBalance: 0.01),
        SendState.ready(
          recipient: _ethRecipient,
          amountString: '0.00999118',
          amount: 0.00999118,
          token: null, // native ETH collapses to a null token
          estimatedFeeLamports: 0,
          totalCost: 0.00999118,
          ethereumEstimate: _ethEstimateNodeFeeData,
          ethGasMarket: _lowGasMarket,
          ethGasSelection: _lowGasSelection,
        ),
      );

      await tapSend(tester);

      expectSent(tester);
    },
  );

  testWidgets(
    'Ethereum: the tier-aware fee still blocks a genuine shortfall — a Low '
    'selection does not disarm the guard',
    (tester) async {
      // Same Low tier, but the amount is the whole balance rather than
      // `balance − reserve`. The Low fee (0.00000735 ETH) has nothing left to
      // come out of, so this must still be stopped before the biometric gate.
      final ethWallet = _wallet(_ethSource, Chain.ethereum);
      await setUpSheet(
        chain: Chain.ethereum,
        candidates: [_candidate(ethWallet, 10000000000000000)],
        sessionWallet: ethWallet,
        ethereum: _Balances(network: [_eth(uiBalance: 0.01)]),
      );
      await pumpToConfirm(
        tester,
        _eth(uiBalance: 0.01),
        SendState.ready(
          recipient: _ethRecipient,
          amountString: '0.01',
          amount: 0.01,
          token: null,
          estimatedFeeLamports: 0,
          totalCost: 0.01,
          ethereumEstimate: _ethEstimateNodeFeeData,
          ethGasMarket: _lowGasMarket,
          ethGasSelection: _lowGasSelection,
        ),
      );

      await tapSend(tester);

      expectBlocked(
        tester,
        message: 'Insufficient ETH for the amount plus fee.',
      );
    },
  );

  // ── Tezos ──────────────────────────────────────────────────────────────────

  testWidgets(
    'Tezos: a cold balance cache is filled from the Tezos service, so the '
    'amount+fee pre-check actually runs',
    (tester) async {
      final tezWallet = _wallet(_tezSource, Chain.tezos);
      await setUpSheet(
        chain: Chain.tezos,
        candidates: [_candidate(tezWallet, 500000)],
        sessionWallet: tezWallet,
        tezos: _Balances(network: [_xtz(mutez: 500000)]),
      );
      await pumpToConfirm(
        tester,
        _xtz(mutez: 500000),
        SendState.ready(
          recipient: _tezRecipient,
          amountString: '1',
          amount: 1,
          token: null, // native XTZ collapses to a null token
          estimatedFeeLamports: 0,
          totalCost: 1,
          tezosEstimate: _tezEstimate,
        ),
      );

      await tapSend(tester);

      expectBlocked(tester, message: 'Insufficient XTZ — need 0.5005 more');
      expect(
        tezosBalances.queried,
        contains(_tezSource),
        reason: 'the XTZ source must be read through TezosTokenService',
      );
      expect(solanaBalances.queried, isEmpty);
    },
  );

  // ── Tezos FA2 ──────────────────────────────────────────────────────────────
  //
  // An FA send is the one case on this chain where the moved asset and the fee
  // asset differ. Before FA sends existed the Tezos branch assumed they were
  // the same: it read the amount as mutez and checked it against the XTZ row,
  // so a 23 USDt send was compared against 23 XTZ — and the confirm step above
  // it said "23 XTZ · Tezos" while the operation moved the token.

  testWidgets('Tezos FA2: the confirm step names the token, not XTZ', (
    tester,
  ) async {
    final tezWallet = _wallet(_tezSource, Chain.tezos);
    await setUpSheet(
      chain: Chain.tezos,
      candidates: [_candidate(tezWallet, 23252886)],
      sessionWallet: tezWallet,
      tezos: _Balances(network: [_xtz(mutez: 500000), _usdt(raw: 23252886)]),
    );
    await pumpToConfirm(
      tester,
      _usdt(raw: 23252886),
      SendState.ready(
        recipient: _tezRecipient,
        amountString: '2.5',
        amount: 2.5,
        token: _usdt(raw: 23252886),
        estimatedFeeLamports: 0,
        totalCost: 2.5,
        tezosEstimate: _tezEstimate,
      ),
    );

    // The reported bug, as an assertion.
    expect(find.text('2.5 USDt'), findsWidgets);
    expect(find.text('Tether USD'), findsWidgets);
    expect(find.text('2.5 XTZ'), findsNothing);
    // The *network* is still Tezos and the fee is still quoted in XTZ — only
    // the sent asset changed.
    expect(find.text('Tezos'), findsWidgets);
  });

  testWidgets(
    'Tezos FA2: a token shortfall is caught before the biometric gate',
    (tester) async {
      final tezWallet = _wallet(_tezSource, Chain.tezos);
      await setUpSheet(
        chain: Chain.tezos,
        candidates: [_candidate(tezWallet, 1000000)],
        sessionWallet: tezWallet,
        // Plenty of XTZ for the fee, but only 1 USDt held.
        tezos: _Balances(network: [_xtz(mutez: 5000000), _usdt(raw: 1000000)]),
      );
      await pumpToConfirm(
        tester,
        _usdt(raw: 1000000),
        SendState.ready(
          recipient: _tezRecipient,
          amountString: '2.5',
          amount: 2.5,
          token: _usdt(raw: 1000000),
          estimatedFeeLamports: 0,
          totalCost: 2.5,
          tezosEstimate: _tezEstimate,
        ),
      );

      await tapSend(tester);
      expectBlocked(tester, message: 'Insufficient USDt balance.');
    },
  );

  testWidgets(
    'Tezos FA2: holding the token but no XTZ still cannot pay the fee',
    (tester) async {
      final tezWallet = _wallet(_tezSource, Chain.tezos);
      await setUpSheet(
        chain: Chain.tezos,
        candidates: [_candidate(tezWallet, 23252886)],
        sessionWallet: tezWallet,
        // The token is there; the gas asset is not. Checking only the token
        // would wave this through to a node rejection after biometrics.
        tezos: _Balances(network: [_usdt(raw: 23252886)]),
      );
      await pumpToConfirm(
        tester,
        _usdt(raw: 23252886),
        SendState.ready(
          recipient: _tezRecipient,
          amountString: '2.5',
          amount: 2.5,
          token: _usdt(raw: 23252886),
          estimatedFeeLamports: 0,
          totalCost: 2.5,
          tezosEstimate: _tezEstimate,
        ),
      );

      await tapSend(tester);
      expectBlocked(tester, message: 'Insufficient XTZ for the network fee.');
    },
  );

  testWidgets(
    'Tezos FA: a clamped 18-decimal balance is unknown, not a shortfall',
    (tester) async {
      // kUSD holds 18 decimals, so anything past ~9.22 tokens clamps to int64
      // in `TokenBalance`. Comparing a 15-token send against that clamp refuses
      // a send the wallet can fund — and does it *after* review, where
      // `run_operation` already simulated the transfer against the contract's
      // real ledger. Unknown must allow through, per checkBalance's rule.
      const kusd = TokenBalance(
        mint: 'KT1K9gCRgaLRFKTErYt1wVxA3Frb9FjasjTV',
        symbol: 'kUSD',
        name: 'Kolibri USD',
        decimals: 18,
        rawBalance: 9223372036854775807,
        uiBalance: 20,
        chain: Chain.tezos,
      );
      final tezWallet = _wallet(_tezSource, Chain.tezos);
      await setUpSheet(
        chain: Chain.tezos,
        candidates: [_candidate(tezWallet, 9223372036854775807)],
        sessionWallet: tezWallet,
        tezos: _Balances(network: [_xtz(mutez: 5000000), kusd]),
      );
      await pumpToConfirm(
        tester,
        kusd,
        SendState.ready(
          recipient: _tezRecipient,
          amountString: '15',
          amount: 15,
          token: kusd,
          estimatedFeeLamports: 0,
          totalCost: 15,
          tezosEstimate: _tezEstimate,
        ),
      );

      await tapSend(tester);
      expectSent(tester);
    },
  );

  testWidgets(
    'Tezos FA: the fee check covers the storage burn, not the baker fee alone',
    (tester) async {
      // Writing the recipient's ledger entry burns storage, and the burn dwarfs
      // the fee — 0.06425 XTZ vs ~0.0005. A guard that checked `feeMutez` alone
      // would wave this through to a node rejection *after* biometrics, which
      // is the whole reason the confirm step quotes fee + burn.
      final burnHeavy = TezosSendEstimate(
        feeMutez: BigInt.from(500),
        burnMutez: BigInt.from(64250),
        gasLimit: 5300,
        storageLimit: 267,
        includesReveal: false,
      );
      final tezWallet = _wallet(_tezSource, Chain.tezos);
      await setUpSheet(
        chain: Chain.tezos,
        candidates: [_candidate(tezWallet, 23252886)],
        sessionWallet: tezWallet,
        // 1000 mutez clears the 500-mutez fee but not the 64 750 total.
        tezos: _Balances(network: [_xtz(mutez: 1000), _usdt(raw: 23252886)]),
      );
      await pumpToConfirm(
        tester,
        _usdt(raw: 23252886),
        SendState.ready(
          recipient: _tezRecipient,
          amountString: '2.5',
          amount: 2.5,
          token: _usdt(raw: 23252886),
          estimatedFeeLamports: 0,
          totalCost: 2.5,
          tezosEstimate: burnHeavy,
        ),
      );

      await tapSend(tester);
      expectBlocked(tester, message: 'Insufficient XTZ for the network fee.');
    },
  );

  testWidgets('Tezos FA2: enough of both reaches execute', (tester) async {
    final tezWallet = _wallet(_tezSource, Chain.tezos);
    await setUpSheet(
      chain: Chain.tezos,
      candidates: [_candidate(tezWallet, 23252886)],
      sessionWallet: tezWallet,
      tezos: _Balances(network: [_xtz(mutez: 5000000), _usdt(raw: 23252886)]),
    );
    await pumpToConfirm(
      tester,
      _usdt(raw: 23252886),
      SendState.ready(
        recipient: _tezRecipient,
        amountString: '2.5',
        amount: 2.5,
        token: _usdt(raw: 23252886),
        estimatedFeeLamports: 0,
        totalCost: 2.5,
        tezosEstimate: _tezEstimate,
      ),
    );

    await tapSend(tester);
    expectSent(tester);
  });
}
