import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/tezos_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_recipient_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Picking a Tezos or Ethereum token used to re-point the **global** wallet
/// selection — `SessionManager.selectSourceWallet`, which is a
/// `WalletManager.switchWalletById` plus an awaited `/v0/login`, and is never
/// restored. It fired on token selection, with no user action at all.
///
/// It bought nothing. Tezos and Ethereum sign by explicit wallet id
/// (`signTezosOperation(walletId, …)` / `signEthereumTransaction(walletId, …)`),
/// which the sheet already threads through `SendEvent.setSource`. What it cost
/// was the backend login identity: that address keys the `wallet-sig` cookie
/// `verifySignedWalletV2` checks, so moving it re-authorizes every
/// `owner == req.loginAddress` write (hide/download, curation edit, profile
/// edit) onto a wallet the user never chose to log in as. It also collapsed the
/// portfolio, because `TokenBalanceBloc` resolves its Solana scope from the
/// global selection.
///
/// Solana is the control: its executor signs with whatever
/// `loadSelectedWalletId()` returns, so there the switch is the only way the
/// chosen source can sign, and it must still happen.
class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

/// The globally selected wallet — always Solana's signer, whatever chain the
/// send is on. Recording the calls proves the Tezos/Ethereum paths stop using
/// it to seed the sender.
class _FakeWalletManager extends Fake implements WalletManager {
  final List<Chain> getAddressCalls = [];

  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async {
    getAddressCalls.add(chain);
    return _solActive;
  }
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

/// Records every global signer switch the sheet attempts.
class _RecordingSessionManager extends Fake implements SessionManager {
  final List<WalletInfo> switched = [];
  WalletInfo? chainWallet;

  @override
  WalletInfo? sessionWalletForChain(Chain chain) => chainWallet;

  @override
  Future<void> selectSourceWallet(WalletInfo wallet) async {
    switched.add(wallet);
  }
}

class _FakeTokenRepository extends Fake implements TokenRepository {
  @override
  Future<List<TokenBalance>> getCachedBalances(String walletAddress) async =>
      const [];

  @override
  Future<List<TokenBalance>> getTokenBalances(String walletAddress) async =>
      const [];
}

/// The source wallet's balances are loaded per chain — `TokenRepository` is
/// Solana-only. Registered so a Tezos/Ethereum source resolves through its own
/// service instead of a missing-registration error the sheet would swallow.
class _FakeEthereumTokenService extends Fake implements EthereumTokenService {
  @override
  Future<List<TokenBalance>> getCachedBalances(String address) async =>
      const [];

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) async => const [];
}

class _FakeTezosTokenService extends Fake implements TezosTokenService {
  @override
  Future<List<TokenBalance>> getCachedBalances(String address) async =>
      const [];

  @override
  Future<List<TokenBalance>> getTokenBalances(String address) async => const [];
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

/// The globally-selected (Solana) wallet — deliberately NOT the source of any
/// non-Solana send below.
const _solActive = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solOtherAddr = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _tezAddr = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
const _ethAddr = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';

/// Second wallets on the same chain — a session holding two is exactly when
/// adopting a source used to fire the global switch.
const _tezOther = 'tz1burnburnburnburnburnburnburjAYjjX';
const _ethOther = '0x2222222222222222222222222222222222222222';

const _splMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

WalletInfo _wallet(
  String address,
  Chain chain, {
  String id = 'wallet-1',
  WalletType walletType = WalletType.hd,
}) => WalletInfo(
  id: id,
  address: address,
  name: 'Wallet',
  walletType: walletType,
  chain: chain.toDbString(),
);

TokenBalance _token(Chain chain) => TokenBalance(
  mint: switch (chain) {
    Chain.tezos => TokenBalance.tezosNativeSentinel,
    Chain.ethereum => TokenBalance.evmNativeSentinel,
    Chain.solana => _splMint,
  },
  symbol: switch (chain) {
    Chain.tezos => 'XTZ',
    Chain.ethereum => 'ETH',
    Chain.solana => 'USDC',
  },
  name: 'Token',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
  isNative: chain != Chain.solana,
  chain: chain,
);

void main() {
  late _MockSendBloc sendBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late _RecordingSessionManager session;
  late _FakeWalletManager walletManager;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  /// [sourceAddress] is the wallet holding the token — the one the sheet adopts
  /// as the source.
  ///
  /// [sessionDefaultAddress] is what `SessionManager.sessionWalletForChain`
  /// answers: the chain's *default* wallet, which seeds `_selfAddress`. Passing
  /// a different address is what makes these tests bite — with source ==
  /// default, `_setSource`'s `wallet.address != _selfAddress` short-circuits the
  /// switch on its own and the chain guard is never exercised. Two wallets on
  /// one chain is also precisely when the old code fired the switch.
  Future<void> setUpSheet({
    required String sourceAddress,
    required Chain chain,
    required TokenBalance token,
    String? sessionDefaultAddress,
    WalletType sessionDefaultType = WalletType.hd,
    List<SendSourceCandidate>? candidates,
    List<String> recents = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();
    for (final address in recents.reversed) {
      await prefs.saveRecentSendAddress(address);
    }

    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    walletManager = _FakeWalletManager();
    session = _RecordingSessionManager()
      ..chainWallet = _wallet(
        sessionDefaultAddress ?? sourceAddress,
        chain,
        id: 'wallet-default',
        walletType: sessionDefaultType,
      );

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(walletManager);
    register<WalletRepository>(_FakeWalletRepository());
    register<ProfileLookupService>(_FakeProfileLookupService());
    register<SessionManager>(session);
    register<TokenRepository>(_FakeTokenRepository());
    register<EthereumTokenService>(_FakeEthereumTokenService());
    register<TezosTokenService>(_FakeTezosTokenService());
    register<SessionPortfolioAggregator>(
      _FakeAggregator(
        candidates ??
            [
              SendSourceCandidate(
                wallet: _wallet(sourceAddress, chain),
                rawBalance: token.rawBalance,
                uiBalance: token.uiBalance,
              ),
            ],
      ),
    );
  }

  setUpAll(() {
    registerFallbackValue(const SendEvent.execute());
  });

  setUp(() {
    sendBloc = _MockSendBloc();
    tokenBalanceBloc = _MockTokenBalanceBloc();
    whenListen(
      sendBloc,
      const Stream<SendState>.empty(),
      initialState: const SendState.input(),
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.loaded(
        tokens: [],
        totalUsdValue: 0,
      ),
    );
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<WalletRepository>(),
      () => sl.unregister<ProfileLookupService>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<TokenRepository>(),
      () => sl.unregister<EthereumTokenService>(),
      () => sl.unregister<TezosTokenService>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
    ]) {
      drop();
    }
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pumpSheet(WidgetTester tester, TokenBalance token) async {
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
  }

  /// The source the sheet actually committed to the bloc.
  SendSetSource? dispatchedSource() {
    final events = verify(() => sendBloc.add(captureAny())).captured;
    return events.whereType<SendSetSource>().lastOrNull;
  }

  for (final (chain, sourceAddress, otherAddress) in [
    (Chain.tezos, _tezAddr, _tezOther),
    (Chain.ethereum, _ethAddr, _ethOther),
  ]) {
    final label = chain.label;

    testWidgets(
      '$label: adopting a source never re-points the global signer, even when '
      'it differs from the chain default — the login identity gates unrelated '
      'writes and the chain signs by wallet id',
      (tester) async {
        final token = _token(chain);
        await setUpSheet(
          sourceAddress: sourceAddress,
          chain: chain,
          token: token,
          // The chain's default wallet is a *different* one, so the sheet is
          // genuinely adopting a non-default source — the case that fired the
          // switch.
          sessionDefaultAddress: otherAddress,
        );
        await pumpSheet(tester, token);

        expect(
          session.switched,
          isEmpty,
          reason: 'selectSourceWallet would move AuthService.currentAddress',
        );
      },
    );

    testWidgets(
      '$label: the wallet id still reaches SendBloc — with nothing global '
      'moved, setSource is the ONLY thing pointing the send at the source',
      (tester) async {
        final token = _token(chain);
        await setUpSheet(
          sourceAddress: sourceAddress,
          chain: chain,
          token: token,
          sessionDefaultAddress: otherAddress,
        );
        await pumpSheet(tester, token);

        final source = dispatchedSource();
        expect(source, isNotNull);
        expect(source!.chain, chain);
        expect(source.address, sourceAddress);
        // Null here means the sign/inject path has no key to use and the flow
        // dead-ends at Next — the failure mode of dropping the switch without
        // threading the id.
        expect(source.walletId, isNotNull);
      },
    );

    testWidgets(
      '$label: the sender is seeded from the session wallet on the send\'s '
      'own chain, never the globally-selected Solana address',
      (tester) async {
        final token = _token(chain);
        await setUpSheet(
          sourceAddress: sourceAddress,
          chain: chain,
          token: token,
        );
        await pumpSheet(tester, token);

        // `getAddress()` answers the Solana selection whatever chain is asked
        // for. Seeding `_selfAddress` from it left the self-send guard
        // comparing recipients against a wallet on the wrong chain — it could
        // never match, so the guard was silently disarmed.
        expect(dispatchedSource()?.address, isNot(_solActive));
        expect(
          walletManager.getAddressCalls,
          isEmpty,
          reason: 'the global selection is irrelevant to a $label send',
        );
      },
    );
  }

  testWidgets(
    'Tezos: a Ledger-only session seeds no sender — the self-send guard and '
    'source resolution must gate on the same predicate',
    (tester) async {
      // `sessionWalletForChain` gates on `canSign`, which a Tezos Ledger passes;
      // `canSignSendTransfer` (what the source resolver and the aggregator use)
      // does not — `signTezosOperation` throws for Ledger. Seeding the sender
      // from the looser gate pointed the self-send guard at a wallet that can
      // never fund the send, so it filtered a *recipient the user may legitimately
      // send to* out of Recents while no source was adopted at all.
      final token = _token(Chain.tezos);
      await setUpSheet(
        sourceAddress: _tezAddr,
        chain: Chain.tezos,
        token: token,
        sessionDefaultAddress: _tezAddr,
        sessionDefaultType: WalletType.ledger,
        // The aggregator already excludes it, so there is no candidate at all.
        candidates: const [],
        recents: [_tezAddr, _tezOther],
      );
      await pumpSheet(tester, token);

      final step = tester.widget<SendRecipientStep>(
        find.byType(SendRecipientStep),
      );
      expect(
        step.sourceAddress,
        isNull,
        reason: 'the Ledger wallet is not adopted as a source',
      );
      expect(
        step.recents.map((r) => r.address),
        containsAll(<String>[_tezAddr, _tezOther]),
        reason:
            'nothing is funding this send, so no address may be treated as '
            'the sender',
      );
    },
  );

  testWidgets(
    'Solana: the switch still happens — its executor signs with the globally '
    'selected wallet, so the selection IS the mechanism',
    (tester) async {
      final token = _token(Chain.solana);
      await setUpSheet(
        // A Solana wallet that is NOT the active selection, so a switch is
        // genuinely required for the chosen source to sign.
        sourceAddress: _solOtherAddr,
        chain: Chain.solana,
        token: token,
      );
      await pumpSheet(tester, token);

      expect(session.switched, hasLength(1));
      expect(session.switched.single.address, _solOtherAddr);
    },
  );

  testWidgets(
    'Solana: no switch when the source already IS the active selection',
    (tester) async {
      final token = _token(Chain.solana);
      await setUpSheet(
        sourceAddress: _solActive,
        chain: Chain.solana,
        token: token,
      );
      await pumpSheet(tester, token);

      expect(session.switched, isEmpty);
    },
  );
}
