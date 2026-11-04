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
import 'package:mallow_wallet/features/send/models/recipient_address.dart';
import 'package:mallow_wallet/features/send/models/recipient_suggestion.dart';
import 'package:mallow_wallet/features/send/services/recipient_search_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_amount_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_recipient_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A send whose recipient is known before the token: a wallet address
/// scanned from the account menu.
///
/// The token step must list only what that address can receive, and the
/// address must reach the field and the bloc once a token is picked. Solana
/// is the case that needs its own path: picking a Solana token moves no chain,
/// so the re-validation a chain change triggers never runs for it.
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

class _FakeRecipientSearchService extends Fake
    implements RecipientSearchService {
  @override
  Future<List<RecipientSuggestion>> search(String query, Chain chain) async =>
      const [];
}

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _ethSelf = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
const _tezSelf = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
const _solOther = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _ethOther = '0x2222222222222222222222222222222222222222';
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

  setUp(() async {
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

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pumpSheet(
    WidgetTester tester,
    RecipientAddress recipient,
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
            child: SendSheet(recipient: recipient),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  testWidgets('a Solana address lists Solana tokens and fills the field', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      const RecipientAddress(address: _solOther, chain: Chain.solana),
    );

    expect(find.text('USD Coin'), findsOneWidget);
    expect(find.text('Bonk'), findsOneWidget);
    expect(find.text('Ethereum'), findsNothing);

    await tester.tap(find.text('USD Coin'));
    await flush(tester);

    final step = tester.widget<SendRecipientStep>(
      find.byType(SendRecipientStep),
    );
    expect(step.chain, Chain.solana);
    expect(step.errorText, isNull);
    expect(fieldText(tester), _solOther);
    // No chain moved, so only the preset path can have told the bloc.
    verify(
      () => sendBloc.add(const SendEvent.setRecipient(_solOther)),
    ).called(1);
    expect(
      find.byType(SendAmountStep),
      findsNothing,
      reason: 'the user reviews the address before going on',
    );

    await tester.tap(find.text('Next'));
    await flush(tester);
    expect(find.byType(SendAmountStep), findsOneWidget);
  });

  testWidgets('an Ethereum address lists Ethereum tokens and fills the field', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      const RecipientAddress(address: _ethOther, chain: Chain.ethereum),
    );

    expect(find.text('USD Coin'), findsNothing);
    expect(find.text('Bonk'), findsNothing);

    await tester.tap(find.text('Ethereum'));
    await flush(tester);

    final step = tester.widget<SendRecipientStep>(
      find.byType(SendRecipientStep),
    );
    expect(step.chain, Chain.ethereum);
    expect(step.errorText, isNull);
    expect(fieldText(tester), _ethOther);
    verify(
      () => sendBloc.add(const SendEvent.setRecipient(_ethOther)),
    ).called(1);
  });

  testWidgets('a chain with nothing to send says so by name', (tester) async {
    await pumpSheet(
      tester,
      const RecipientAddress(address: _tezSelf, chain: Chain.tezos),
    );

    expect(find.text('No Tezos tokens to send'), findsOneWidget);
  });
}
