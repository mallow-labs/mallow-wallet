import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/session_portfolio_aggregator.dart';
import 'package:mallow_wallet/features/portfolio/data/tezos_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/core/network/solana_pay_tags.dart';
import 'package:mallow_wallet/features/send/models/payment_request.dart';
import 'package:mallow_wallet/features/send/models/recipient_address.dart';
import 'package:mallow_wallet/features/send/models/recipient_advisory.dart';
import 'package:mallow_wallet/features/send/services/recipient_advisory_service.dart';
import 'package:mallow_wallet/features/send/models/recipient_suggestion.dart';
import 'package:mallow_wallet/features/send/services/recipient_search_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_amount_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_confirm_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A send opened from a scanned payment request.
///
/// The request fixes the token and the recipient, and usually the amount, so
/// the sheet picks and fills them itself and goes on to the review. It does
/// so through each step's own handler, so a value that fails a step's check
/// stops the sheet there instead of being carried past it.
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
  /// Holds the background network refresh back until completed, so a test
  /// can land it after the sheet has reached the review.
  Completer<void>? refreshGate;

  @override
  Future<List<SendSourceCandidate>> sendSourcesForMint({
    required Chain chain,
    required String mint,
    bool refresh = false,
  }) async {
    if (refresh) await refreshGate?.future;
    return [
      SendSourceCandidate(
        wallet: _wallet(chain),
        rawBalance: 1000000000,
        uiBalance: 1.0,
      ),
    ];
  }
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
const _ethUsdc = TokenBalance(
  mint: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  symbol: 'USDC',
  name: 'USD Coin (Ethereum)',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
  isVerified: true,
  chain: Chain.ethereum,
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
  late _FakeAggregator aggregator;
  late StreamController<SendState> sendStates;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late ValueNotifier<RemoteConfig> config;

  setUpAll(() => registerFallbackValue(const SendEvent.reset()));

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
    aggregator = _FakeAggregator();
    register<SessionPortfolioAggregator>(aggregator);
    register<TokenPriceService>(_FakeTokenPriceService());
    register<RecipientAdvisoryService>(_FakeRecipientAdvisoryService());

    sendBloc = _MockSendBloc();
    tokenBalanceBloc = _MockTokenBalanceBloc();
    sendStates = StreamController<SendState>.broadcast();
    whenListen(
      sendBloc,
      sendStates.stream,
      initialState: const SendState.input(),
    );
    // The sheet's provider owns this bloc and closes it with the sheet.
    when(() => sendBloc.close()).thenAnswer((_) async {});
    register<SendBloc>(sendBloc);
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.loaded(
        tokens: [_usdc, _bonk, _eth, _ethUsdc],
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
      () => sl.unregister<SendBloc>(),
      () => sl.unregister<TokenPriceService>(),
      () => sl.unregister<RecipientAdvisoryService>(),
    ]) {
      drop();
    }
    config.dispose();
    unawaited(sendStates.close());
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> open(WidgetTester tester, PaymentRequest payment) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSendSheet(
                context,
                payment: payment,
                tokenBalanceBloc: tokenBalanceBloc,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
  }

  /// What the bloc says once it has checked [amount].
  Future<void> checked(
    WidgetTester tester, {
    required String amount,
    required String recipient,
    TokenBalance? token,
    String? amountError,
  }) async {
    sendStates.add(
      SendState.input(
        recipient: recipient,
        amount: amount,
        token: token,
        amountError: amountError,
      ),
    );
    await flush(tester);
  }

  TextField amountField(WidgetTester tester) => tester.widget<TextField>(
    find.descendant(
      of: find.byType(SendAmountStep),
      matching: find.byType(TextField),
    ),
  );

  const tags = SolanaPayTags(references: [_tezSelf], memo: 'order 42');
  // A Tezos address is no Solana key; the tags are only compared here.
  const solanaPay = PaymentRequest(
    recipient: RecipientAddress(address: _solOther, chain: Chain.solana),
    token: _splMint,
    amount: DecimalAmount('1.50'),
    tags: tags,
    label: 'Coffee Shop',
  );

  testWidgets('a Solana Pay request fills the sheet and goes to review', (
    tester,
  ) async {
    await open(tester, solanaPay);

    expect(find.byType(SendAmountStep), findsOneWidget);
    expect(amountField(tester).controller!.text, '1.5');
    expect(amountField(tester).enabled, isFalse);
    expect(find.text('Max'), findsNothing);
    expect(find.text('Payment request from Coffee Shop'), findsOneWidget);
    verifyInOrder([
      () => sendBloc.add(const SendEvent.setPaymentTags(tags)),
      () => sendBloc.add(const SendEvent.setToken(_usdc)),
      () => sendBloc.add(const SendEvent.setRecipient(_solOther)),
      () => sendBloc.add(const SendEvent.setAmount('1.5')),
    ]);
    verifyNever(() => sendBloc.add(const SendEvent.validateAndProceed()));

    await checked(tester, amount: '1.5', recipient: _solOther, token: _usdc);

    verify(() => sendBloc.add(const SendEvent.validateAndProceed())).called(1);
  });

  testWidgets('the source refresh landing after review keeps the review', (
    tester,
  ) async {
    // The refresh resolves the wallet already in use. Treating that as a
    // switch reset the bloc and dropped the sheet back a step, and the review
    // still in flight then pushed it forward again.
    // The sheet also lays the confirm step out to measure it, so count the
    // ones with a Send handler, and expect at least one.
    final liveConfirm = find.byWidgetPredicate(
      (w) => w is SendConfirmStep && w.onSend != null,
    );
    final gate = aggregator.refreshGate = Completer<void>();
    await open(tester, solanaPay);
    await checked(tester, amount: '1.5', recipient: _solOther, token: _usdc);
    sendStates.add(
      const SendState.ready(
        recipient: _solOther,
        amountString: '1.5',
        amount: 1.5,
        token: _usdc,
        estimatedFeeLamports: 5000,
        totalCost: 1.5,
      ),
    );
    await flush(tester);
    expect(liveConfirm, findsWidgets);

    gate.complete();
    await flush(tester);

    expect(liveConfirm, findsWidgets);
    expect(find.byType(SendAmountStep), findsNothing);
    verifyNever(() => sendBloc.add(const SendEvent.reset()));
  });

  testWidgets('an amount that fails its check stays on the amount step', (
    tester,
  ) async {
    await open(tester, solanaPay);

    await checked(
      tester,
      amount: '1.5',
      recipient: _solOther,
      token: _usdc,
      amountError: 'Insufficient balance',
    );

    verifyNever(() => sendBloc.add(const SendEvent.validateAndProceed()));
    expect(find.byType(SendAmountStep), findsOneWidget);
  });

  testWidgets('an EIP-681 transfer is read in the token\'s decimals', (
    tester,
  ) async {
    await open(
      tester,
      PaymentRequest(
        recipient: const RecipientAddress(
          address: _ethOther,
          chain: Chain.ethereum,
        ),
        token: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
        amount: AtomicAmount(BigInt.from(2500000)),
      ),
    );

    verify(() => sendBloc.add(const SendEvent.setToken(_ethUsdc))).called(1);
    verify(
      () => sendBloc.add(const SendEvent.setRecipient(_ethOther)),
    ).called(1);
    verify(() => sendBloc.add(const SendEvent.setAmount('2.5'))).called(1);
    expect(find.text('Payment request'), findsOneWidget);
  });

  testWidgets('without an amount the payer types one', (tester) async {
    await open(
      tester,
      const PaymentRequest(
        recipient: RecipientAddress(address: _solOther, chain: Chain.solana),
        token: _splMint,
      ),
    );

    expect(find.byType(SendAmountStep), findsOneWidget);
    expect(amountField(tester).enabled, isTrue);
    expect(amountField(tester).controller!.text, isEmpty);
    expect(find.text('Max'), findsOneWidget);
    verifyNever(() => sendBloc.add(any(that: isA<SendSetAmount>())));
  });

  testWidgets('a token the wallet does not hold closes with the reason', (
    tester,
  ) async {
    await open(
      tester,
      const PaymentRequest(
        recipient: RecipientAddress(address: _solOther, chain: Chain.solana),
        token: '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
        amount: DecimalAmount('1'),
      ),
    );

    expect(find.text("This request is for a token you don't hold"), findsOne);
    expect(find.byType(SendSheet), findsNothing);
  });

  testWidgets('an amount finer than the token holds closes with the reason', (
    tester,
  ) async {
    await open(
      tester,
      const PaymentRequest(
        recipient: RecipientAddress(address: _solOther, chain: Chain.solana),
        token: _splMint,
        amount: DecimalAmount('0.0000001'),
      ),
    );

    expect(find.textContaining('more precise than USDC'), findsOneWidget);
    expect(find.byType(SendSheet), findsNothing);
  });
}
