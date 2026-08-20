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
import 'package:mallow_wallet/features/send/models/recipient_suggestion.dart';
import 'package:mallow_wallet/features/send/services/recipient_search_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/recipient_search_dropdown.dart';
import 'package:mallow_wallet/features/send/widgets/send_amount_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_recipient_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Re-picking the token mid-flow can move the send onto another **chain**, and
/// the recipient already entered does not move with it.
///
/// A recipient picked from the username dropdown is held as
/// `_pickedProfile` + `_resolvedAddress` rather than as field text — the field
/// shows `@handle` — and that pair is what the recipient step's Next gate
/// trusts in place of re-parsing the field. Nothing between there and signing
/// re-validates it: the amount step doesn't, and the confirm step renders
/// whatever address the bloc was handed. So a Solana address carried into an
/// Ethereum send passed the only gate that could have caught it and failed at
/// prepare/simulate instead, as a raw-exception snackbar plus a bloc reset.
class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _MockRemoteConfigService extends Mock implements RemoteConfigService {}

class _FakeWalletManager extends Fake implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _solSelf;
}

/// One qualifying wallet on whichever chain is asked about — enough to adopt a
/// source without tripping the 2+ wallet picker.
class _FakeAggregator extends Fake implements SessionPortfolioAggregator {
  @override
  Future<List<SendSourceCandidate>> sendSourcesForMint({
    required Chain chain,
    required String mint,
    bool refresh = false,
  }) async => [
    SendSourceCandidate(
      wallet: _wallet(chain),
      rawBalance: 1000000000,
      uiBalance: 1.0,
    ),
  ];
}

class _FakeSessionManager extends Fake implements SessionManager {
  /// Signable on every chain, so `guardCannotSend` lets the Ethereum row
  /// through — the gate under test is the recipient one, not the signer one.
  @override
  WalletInfo? sessionWalletForChain(Chain chain) => _wallet(chain);

  @override
  Future<void> selectSourceWallet(WalletInfo wallet) async {}
}

class _FakeTokenRepository extends Fake implements TokenRepository {
  @override
  Future<List<TokenBalance>> getCachedBalances(String walletAddress) async =>
      const [];

  @override
  Future<List<TokenBalance>> getTokenBalances(String walletAddress) async =>
      const [];
}

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

  @override
  Future<WalletInfo?> getActiveWallet() async => _wallet(Chain.solana);
}

class _FakeProfileLookupService extends Fake implements ProfileLookupService {
  @override
  Future<Map<String, UserPreview>> profilesForAddresses(
    List<String> addresses,
  ) async => const {};
}

/// Alice holds a Solana wallet only — the real service filters results to
/// addresses that can receive on the chain being sent on, so an Ethereum
/// search for her finds nothing.
class _FakeRecipientSearchService extends Fake
    implements RecipientSearchService {
  @override
  Future<List<RecipientSuggestion>> search(String query, Chain chain) async =>
      chain == Chain.solana
      ? const [RecipientSuggestion(address: _aliceSol, username: 'alice')]
      : const [];
}

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _ethSelf = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
const _tezSelf = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
const _aliceSol = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _splMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

WalletInfo _wallet(Chain chain) => WalletInfo(
  id: 'wallet-${chain.toDbString()}',
  address: switch (chain) {
    Chain.solana => _solSelf,
    Chain.ethereum => _ethSelf,
    Chain.tezos => _tezSelf,
  },
  name: 'Wallet',
  walletType: WalletType.hd,
  chain: chain.toDbString(),
);

const _usdc = TokenBalance(
  mint: _splMint,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
  isVerified: true,
);

/// A second Solana token, so the same-chain control can re-pick without the
/// chain moving. Named unlike the chain itself: the rows carry the network
/// name too, so `Solana` is not a unique finder on this step.
const _bonk = TokenBalance(
  mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
  symbol: 'BONK',
  name: 'Bonk',
  decimals: 5,
  rawBalance: 1000000000,
  uiBalance: 10000.0,
  isVerified: true,
);
const _eth = TokenBalance(
  mint: TokenBalance.evmNativeSentinel,
  symbol: 'ETH',
  name: 'Ethereum',
  decimals: 18,
  rawBalance: 1000000000,
  uiBalance: 1.0,
  isNative: true,
  isVerified: true,
  chain: Chain.ethereum,
);

void main() {
  late _MockSendBloc sendBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<void> setUpSheet() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();

    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    config = ValueNotifier(RemoteConfig.permissive);
    final remoteConfig = _MockRemoteConfigService();
    when(() => remoteConfig.config).thenReturn(config);
    when(remoteConfig.refreshIfStale).thenAnswer((_) async {});

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<RemoteConfigService>(remoteConfig);
    register<WalletManager>(_FakeWalletManager());
    register<WalletRepository>(_FakeWalletRepository());
    register<ProfileLookupService>(_FakeProfileLookupService());
    register<SessionManager>(_FakeSessionManager());
    register<TokenRepository>(_FakeTokenRepository());
    register<EthereumTokenService>(_FakeEthereumTokenService());
    register<TezosTokenService>(_FakeTezosTokenService());
    register<RecipientSearchService>(_FakeRecipientSearchService());
    register<SessionPortfolioAggregator>(_FakeAggregator());
  }

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
        tokens: [_usdc, _bonk, _eth],
        totalUsdValue: 0,
      ),
    );
  });

  tearDown(() {
    for (final drop in [
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<WalletRepository>(),
      () => sl.unregister<ProfileLookupService>(),
      () => sl.unregister<SessionManager>(),
      () => sl.unregister<TokenRepository>(),
      () => sl.unregister<EthereumTokenService>(),
      () => sl.unregister<TezosTokenService>(),
      () => sl.unregister<RecipientSearchService>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
    ]) {
      drop();
    }
    config.dispose();
  });

  /// Pumps past the 500 ms search debounce and lets the response settle.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pumpSheet(WidgetTester tester) async {
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
            // Entering on an SPL token puts the sheet straight on the recipient
            // step, on Solana.
            child: const SendSheet(initialToken: _usdc),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  /// Searches for `alice` and taps her row, leaving the field holding the
  /// handle and the sheet holding her Solana address.
  Future<void> pickAlice(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, 'alice');
    await flush(tester);
    await tester.tap(find.byKey(recipientSuggestionKey(_aliceSol)));
    await flush(tester);

    final step = tester.widget<SendRecipientStep>(
      find.byType(SendRecipientStep),
    );
    expect(step.resolvedAddress, _aliceSol, reason: 'precondition');
  }

  /// Back to the token step, then pick the row named [tokenName].
  Future<void> reselectToken(WidgetTester tester, String tokenName) async {
    await tester.tap(
      find.descendant(
        of: find.byType(SendRecipientStep),
        matching: find.byWidgetPredicate(
          (w) =>
              w is MallowSvgIcon &&
              w.assetPath == 'assets/icons/arrow_left.svg',
        ),
      ),
    );
    await flush(tester);
    await tester.tap(find.text(tokenName));
    await flush(tester);
  }

  testWidgets(
    'a recipient picked on Solana does not satisfy Next after the send moves '
    'to Ethereum',
    (tester) async {
      await setUpSheet();
      await pumpSheet(tester);
      await pickAlice(tester);

      await reselectToken(tester, 'Ethereum');

      final step = tester.widget<SendRecipientStep>(
        find.byType(SendRecipientStep),
      );
      expect(step.chain, Chain.ethereum);
      expect(
        step.resolvedAddress,
        isNull,
        reason: 'her Solana address cannot receive an Ethereum send',
      );

      await tester.tap(find.text('Next'));
      await flush(tester);

      // The whole point: the gate holds. Advancing here reached the confirm
      // step on a wrong-chain recipient, which only failed at prepare/simulate.
      expect(find.byType(SendAmountStep), findsNothing);
      expect(find.byType(SendRecipientStep), findsOneWidget);
    },
  );

  testWidgets(
    'a recipient picked on Solana survives re-picking another Solana token',
    (tester) async {
      // The clearing is keyed on the chain, not on the token: swapping USDC for
      // another SPL token changes nothing about who may receive it, and wiping
      // the recipient there would cost the user their choice for no reason.
      await setUpSheet();
      await pumpSheet(tester);
      await pickAlice(tester);

      await reselectToken(tester, 'Bonk');

      final step = tester.widget<SendRecipientStep>(
        find.byType(SendRecipientStep),
      );
      expect(step.chain, Chain.solana);
      expect(step.resolvedAddress, _aliceSol);

      await tester.tap(find.text('Next'));
      await flush(tester);

      expect(find.byType(SendAmountStep), findsOneWidget);
    },
  );
}
