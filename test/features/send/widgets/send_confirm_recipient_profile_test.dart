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
import 'package:mallow_wallet/core/crypto/derivation.dart';
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
import 'package:mallow_wallet/features/send/models/recipient_advisory.dart';
import 'package:mallow_wallet/features/send/services/recipient_advisory_service.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_confirm_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/address_utils.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mallow_wallet/shared/widgets/account_avatar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who the confirm step says you are sending to.
///
/// The step resolves the recipient's mallow profile through
/// `ProfileLookupService.profilesForAddresses` and renders its username + pfp
/// in the Recipient pill, falling back to the truncated address. That map was
/// keyed on the address the **backend** echoes, which serves EVM addresses
/// lowercase, while the sheet indexed it with the address the **user** supplied
/// — EIP-55 checksummed when copied out of their own account list. The two
/// forms never compared equal, so on Ethereum the lookup always missed: sending
/// to another account on the device reviewed as a bare hash while the identical
/// Solana send showed the profile.
///
/// The Solana test is the control, not duplication. Base58 is case-SENSITIVE —
/// two Solana strings differing only in case are two different wallets holding
/// different funds — so it fails if the normalisation is ever done with a
/// blanket `toLowerCase()` instead of `apiOwnerAddress`.

class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

class _FakeWalletManager extends Fake implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _solSource;
}

class _FakeAggregator extends Fake implements SessionPortfolioAggregator {
  _FakeAggregator(this.candidate);

  final SendSourceCandidate candidate;

  @override
  Future<List<SendSourceCandidate>> sendSourcesForMint({
    required Chain chain,
    required String mint,
    bool refresh = false,
  }) async => [candidate];
}

class _FakeSessionManager extends Fake implements SessionManager {
  _FakeSessionManager(this.wallet);

  final WalletInfo? wallet;

  @override
  WalletInfo? sessionWalletForChain(Chain chain) => wallet;

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

/// Stands in for the wallets table. [byAddress] holds the accounts this device
/// owns; the match is case-insensitive because that is what the real
/// `accountsForAddresses` does — a checksummed EVM recipient still finds the
/// row stored for it.
class _FakeWalletRepository extends Fake implements WalletRepository {
  _FakeWalletRepository([this.byAddress = const {}]);

  final Map<String, ({String name, String avatarSeed})> byAddress;

  @override
  Future<Map<String, ({String name, String avatarSeed})>> accountsForAddresses(
    List<String> addresses,
  ) async {
    final rows = {
      for (final e in byAddress.entries) e.key.toLowerCase(): e.value,
    };
    return {
      for (final address in addresses)
        if (rows[address.toLowerCase()] case final row?) address: row,
    };
  }
}

/// Answers the way the backend does: keyed on the address it stores, which for
/// EVM is always lowercase — never the checksummed form the caller submitted.
class _FakeProfileLookupService extends Fake implements ProfileLookupService {
  _FakeProfileLookupService(this.byBackendAddress);

  /// Backend-form address → username.
  final Map<String, String> byBackendAddress;

  /// Addresses the sheet actually asked about, in call order.
  final List<String> queried = [];

  @override
  Future<Map<String, UserPreview>> profilesForAddresses(
    List<String> addresses,
  ) async {
    queried.addAll(addresses);
    return {
      for (final submitted in addresses)
        if (byBackendAddress[apiOwnerAddress(submitted)] case final name?)
          // The real service normalises its keys for exactly this reason; a
          // fake that echoed the submitted string would hide the bug.
          apiOwnerAddress(submitted): UserPreview(
            username: name,
            addresses: [apiOwnerAddress(submitted)],
          ),
    };
  }
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

const _solSource = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solRecipient = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

const _ethSource = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';

/// The other account on this device, in the two forms one EVM address has: the
/// EIP-55 form a wallet row stores and the account list copies out, and the
/// lowercase form the backend keeps. Built with the wallet's own checksummer so
/// the form gate accepts it verbatim.
///
/// 🛑 It must contain hex **letters** (a–f). An all-digit address checksums to
/// itself, so the two forms would be the same string and the test would pass
/// against the very bug it exists to catch.
final _ethRecipientChecksummed = MultiChainDerivation.checksumEthereumAddress(
  _ethRecipientLower,
);
const _ethRecipientLower = '0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359';

const _eth = TokenBalance(
  mint: TokenBalance.evmNativeSentinel,
  symbol: 'ETH',
  name: 'Ethereum',
  decimals: 18,
  rawBalance: 1000000000000000000,
  uiBalance: 1.0,
  isNative: true,
  chain: Chain.ethereum,
);

const _sol = TokenBalance(
  mint: TokenBalance.solMint,
  symbol: 'SOL',
  name: 'Solana',
  decimals: 9,
  rawBalance: 5000000000,
  uiBalance: 5.0,
  isNative: true,
);

WalletInfo _wallet(String address, Chain chain) => WalletInfo(
  id: 'wallet-1',
  address: address,
  name: 'Wallet 1',
  walletType: WalletType.hd,
  chain: chain.toDbString(),
);

void main() {
  late _MockSendBloc sendBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;
  late StreamController<SendState> sendStates;
  late ValueNotifier<RemoteConfig> config;
  late _FakeProfileLookupService profiles;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<void> setUpSheet({
    required Chain chain,
    required String sourceAddress,
    required TokenBalance token,
    required Map<String, String> backendProfiles,
    Map<String, ({String name, String avatarSeed})> localAccounts = const {},
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();

    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    profiles = _FakeProfileLookupService(backendProfiles);
    final wallet = _wallet(sourceAddress, chain);

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(_FakeWalletManager());
    register<WalletRepository>(_FakeWalletRepository(localAccounts));
    register<ProfileLookupService>(profiles);
    register<TokenPriceService>(_FakeTokenPriceService());
    register<RecipientAdvisoryService>(_FakeRecipientAdvisoryService());
    register<SessionManager>(_FakeSessionManager(wallet));
    register<TokenRepository>(_FakeTokenRepository());
    register<EthereumTokenService>(_FakeEthereumTokenService());
    register<TezosTokenService>(_FakeTezosTokenService());
    register<SessionPortfolioAggregator>(
      _FakeAggregator(
        SendSourceCandidate(
          wallet: wallet,
          rawBalance: token.rawBalance,
          uiBalance: token.uiBalance,
        ),
      ),
    );
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
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.loaded(
        tokens: [],
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

  testWidgets('Ethereum: the recipient reviews as the profile behind the '
      'address, not a truncated hash', (tester) async {
    // Sending to another account on this device: the address is copied out of
    // the account list in its stored EIP-55 form, while the backend knows it
    // lowercase. Both forms are the same wallet and must resolve the same
    // profile.
    await setUpSheet(
      chain: Chain.ethereum,
      sourceAddress: _ethSource,
      token: _eth,
      backendProfiles: {_ethRecipientLower: 'alice'},
    );
    await pumpToConfirm(
      tester,
      _eth,
      SendState.ready(
        recipient: _ethRecipientChecksummed,
        amountString: '0.1',
        amount: 0.1,
        token: null, // native ETH collapses to a null token
        estimatedFeeLamports: 0,
        totalCost: 0.1,
      ),
    );

    expect(
      _ethRecipientChecksummed,
      isNot(_ethRecipientLower),
      reason: 'the fixture must actually have two distinct forms',
    );
    expect(
      profiles.queried,
      contains(_ethRecipientChecksummed),
      reason: 'the confirm step must look the recipient up at all',
    );
    expect(find.text('alice'), findsWidgets);
    expect(
      find.text(truncateAddress(_ethRecipientChecksummed)),
      findsNothing,
      reason:
          'falling back to the truncation is the bug — it means the profile '
          'the backend returned was never matched to the recipient',
    );
  });

  testWidgets('Solana: an unlinked recipient still falls back to the '
      'truncated address', (tester) async {
    // The fallback itself is correct behaviour and must survive the fix — an
    // address with no mallow profile has no name to show.
    await setUpSheet(
      chain: Chain.solana,
      sourceAddress: _solSource,
      token: _sol,
      backendProfiles: const {},
    );
    await pumpToConfirm(
      tester,
      _sol,
      const SendState.ready(
        recipient: _solRecipient,
        amountString: '1',
        amount: 1,
        token: null,
        estimatedFeeLamports: 5000,
        totalCost: 1,
      ),
    );

    expect(find.text(truncateAddress(_solRecipient)), findsWidgets);
  });

  // ── Another account on this device ─────────────────────────────────────────

  testWidgets('Solana: another account on this device reviews under its '
      'account name, not a bare hash', (tester) async {
    // The chain-independent half of the defect. The pill was fed only by the
    // mallow-profile lookup, and most local accounts have no profile — so
    // sending between your own accounts reviewed as a truncated address with
    // an avatar seeded off that address, on Solana just as much as on
    // Ethereum. Base58 has exactly one form, which is what ruled casing out as
    // the whole story.
    await setUpSheet(
      chain: Chain.solana,
      sourceAddress: _solSource,
      token: _sol,
      backendProfiles: const {},
      localAccounts: const {
        _solRecipient: (name: 'Account 2', avatarSeed: 'seed-account-2'),
      },
    );
    await pumpToConfirm(
      tester,
      _sol,
      const SendState.ready(
        recipient: _solRecipient,
        amountString: '1',
        amount: 1,
        token: null,
        estimatedFeeLamports: 5000,
        totalCost: 1,
      ),
    );

    expect(find.text('Account 2'), findsWidgets);
    expect(
      find.text(truncateAddress(_solRecipient)),
      findsNothing,
      reason: 'the account name replaces the truncation, it does not join it',
    );
    // The identicon is keyed by the account's persisted seed, so it matches the
    // one the accounts list draws — seeding off the address would render a
    // different picture for the same account on the next screen.
    expect(
      tester
          .widgetList<AccountAvatar>(find.byType(AccountAvatar))
          .map((a) => a.seed),
      contains('seed-account-2'),
    );
  });

  testWidgets('Ethereum: a checksummed recipient still finds the account row '
      'stored for it', (tester) async {
    // The two halves together: the recipient arrives EIP-55 checksummed, and
    // the account lookup must match it case-insensitively the way the wallets
    // table does.
    await setUpSheet(
      chain: Chain.ethereum,
      sourceAddress: _ethSource,
      token: _eth,
      backendProfiles: const {},
      localAccounts: {
        _ethRecipientLower: (name: 'Account 3', avatarSeed: 'seed-account-3'),
      },
    );
    await pumpToConfirm(
      tester,
      _eth,
      SendState.ready(
        recipient: _ethRecipientChecksummed,
        amountString: '0.1',
        amount: 0.1,
        token: null,
        estimatedFeeLamports: 0,
        totalCost: 0.1,
      ),
    );

    expect(find.text('Account 3'), findsWidgets);
  });

  testWidgets('the mallow profile outranks the local account behind the same '
      'address', (tester) async {
    // The precedence [RecentRecipient.displayName] applies one step earlier,
    // kept in lockstep here: the username is the recipient's public identity,
    // while `Account NN` is a local label that names nobody. A recipient must
    // not read as one thing in the recents list and another on the review.
    await setUpSheet(
      chain: Chain.solana,
      sourceAddress: _solSource,
      token: _sol,
      backendProfiles: const {_solRecipient: 'alice'},
      localAccounts: const {
        _solRecipient: (name: 'Account 2', avatarSeed: 'seed-account-2'),
      },
    );
    await pumpToConfirm(
      tester,
      _sol,
      const SendState.ready(
        recipient: _solRecipient,
        amountString: '1',
        amount: 1,
        token: null,
        estimatedFeeLamports: 5000,
        totalCost: 1,
      ),
    );

    expect(find.text('alice'), findsWidgets);
    expect(find.text('Account 2'), findsNothing);
    // The picture follows the name: a profile with no pfp is seeded by its
    // username, never by the account's `avatarSeed`, so the pill never pairs
    // one identity's name with another's face.
    expect(
      tester
          .widgetList<AccountAvatar>(find.byType(AccountAvatar))
          .map((a) => a.seed),
      isNot(contains('seed-account-2')),
    );
  });

  testWidgets('Solana: the profile key keeps its case — base58 is '
      'case-SENSITIVE', (tester) async {
    // The control. Lowercasing a Solana address would key the map on a string
    // that decodes to a *different* wallet, so the recipient would review under
    // no profile (or, worse, someone else's).
    await setUpSheet(
      chain: Chain.solana,
      sourceAddress: _solSource,
      token: _sol,
      backendProfiles: const {_solRecipient: 'bob'},
    );
    await pumpToConfirm(
      tester,
      _sol,
      const SendState.ready(
        recipient: _solRecipient,
        amountString: '1',
        amount: 1,
        token: null,
        estimatedFeeLamports: 5000,
        totalCost: 1,
      ),
    );

    expect(find.text('bob'), findsWidgets);
  });
}
