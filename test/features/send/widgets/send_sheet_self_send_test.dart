import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
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
import 'package:mallow_wallet/features/send/widgets/send_amount_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_recipient_step.dart';
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fungible-send twin of the artwork transfer's self-send defect.
///
/// The recipient step's "You can't send to your own wallet" guard, and the
/// filter that drops your own wallet out of Recent recipients, both compared
/// addresses with a raw `==`. On EVM one address exists in two forms — EIP-55
/// checksummed (how `derivation.dart` derives it, and how a wallet row stores
/// it) and lowercased (how the backend stores/returns it, and what a user
/// pastes off a block explorer). `'0xAb…' == '0xab…'` is false, so on Ethereum
/// the guard was silently disarmed and the user's own address stayed in
/// Recents — one tap away from an irreversible send-to-self on mainnet.
///
/// Both comparisons now route through `apiOwnerAddress`, the repo's canonical
/// owner-key normaliser (EVM lowercased; Solana/Tezos untouched).
///
/// Each test below fails if its half of the fix is reverted:
///
///  * the EVM tests fail with a raw `==` — that is the bug;
///  * the **Solana** tests are the control. Solana addresses are base58 and
///    case-SENSITIVE: two strings differing only in case are two different
///    wallets holding different funds. They fail if the normalisation were
///    done with a blanket `toLowerCase()` instead — which is exactly the naive
///    fix that would otherwise look correct.

class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

/// `getAddress()` answers the globally selected wallet, which is Solana's
/// signer. The sheet seeds `_selfAddress` from it only for a Solana send (a
/// Tezos/Ethereum send seeds from `SessionManager.sessionWalletForChain`), and
/// in both cases replaces it with the resolved source wallet's address — which
/// is what the guard actually compares against. See
/// `send_source_switch_test.dart` for the seeding rules themselves.
class _FakeWalletManager extends Fake implements WalletManager {
  _FakeWalletManager(this.solana);

  final String solana;

  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => solana;
}

/// Returns exactly one candidate, so the sheet adopts it as the source wallet
/// without opening the 2+-wallet picker.
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
  @override
  WalletInfo? sessionWalletForChain(Chain chain) => null;

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

// ── Addresses ────────────────────────────────────────────────────────────────

/// A real EIP-55 checksummed address — built with the same helper the wallet
/// derives with, so the form's checksum gate accepts it verbatim (a hand-typed
/// mixed-case constant with a wrong checksum would be rejected before the
/// self-send guard ever ran, and the test would pass for the wrong reason).
final _ethChecksummed = MultiChainDerivation.checksumEthereumAddress(
  '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed',
);
const _ethLowercased = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
const _ethOther = '0x2222222222222222222222222222222222222222';

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

/// [_solSelf] with a single character's case flipped. Still valid base58 that
/// decodes to 32 bytes — i.e. a *different, real* Solana wallet, not another
/// spelling of the same one. Lowercasing base58 would collapse the two.
const _solCaseVariant = 'HN7cAbqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

const _solOther = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

const _erc20 = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
const _splMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

TokenBalance _ethToken() => const TokenBalance(
  mint: _erc20,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
  chain: Chain.ethereum,
);

TokenBalance _solToken() => const TokenBalance(
  mint: _splMint,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
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

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  /// Registers the sheet's dependencies. [walletAddress] is the address the
  /// resolved source wallet is *stored* as — the casing the guard compares
  /// from.
  Future<void> setUpSheet({
    required String walletAddress,
    required Chain chain,
    required TokenBalance token,
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

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(_FakeWalletManager(_solSelf));
    register<WalletRepository>(_FakeWalletRepository());
    register<ProfileLookupService>(_FakeProfileLookupService());
    register<SessionManager>(_FakeSessionManager());
    register<TokenRepository>(_FakeTokenRepository());
    register<EthereumTokenService>(_FakeEthereumTokenService());
    register<TezosTokenService>(_FakeTezosTokenService());
    register<SessionPortfolioAggregator>(
      _FakeAggregator(
        SendSourceCandidate(
          wallet: _wallet(walletAddress, chain),
          rawBalance: token.rawBalance,
          uiBalance: token.uiBalance,
        ),
      ),
    );
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

  /// Types [recipient] into the recipient field and taps Next.
  Future<void> tapNextWith(WidgetTester tester, String recipient) async {
    await tester.enterText(find.byType(TextField).first, recipient);
    await flush(tester);
    await tester.tap(find.text('Next'));
    await flush(tester);
  }

  /// The recents the recipient step is actually offering.
  List<String> offeredRecents(WidgetTester tester) => tester
      .widget<SendRecipientStep>(find.byType(SendRecipientStep))
      .recents
      .map((r) => r.address)
      .toList();

  const guardMessage = "You can't send to your own wallet";

  // ── EVM: the bug ───────────────────────────────────────────────────────────

  testWidgets(
    'ETH send: a lowercased paste of the checksummed source wallet is refused',
    (tester) async {
      // The wallet row holds the EIP-55 form; the user pastes the address off
      // an explorer, which serves it lowercased. A raw `==` says "different
      // wallet" and waves an irreversible self-send through.
      await setUpSheet(
        walletAddress: _ethChecksummed,
        chain: Chain.ethereum,
        token: _ethToken(),
      );
      await pumpSheet(tester, _ethToken());

      await tapNextWith(tester, _ethLowercased);

      expect(find.text(guardMessage), findsOneWidget);
      expect(find.byType(SendAmountStep), findsNothing);
    },
  );

  testWidgets(
    'ETH send: the checksummed form of a lowercased source wallet is refused',
    (tester) async {
      // The mirror image — a wallet row stored lowercased (imported/Ledger,
      // or written by a backend read) against a checksummed recipient. Both
      // directions have to normalise, not just one.
      await setUpSheet(
        walletAddress: _ethLowercased,
        chain: Chain.ethereum,
        token: _ethToken(),
      );
      await pumpSheet(tester, _ethToken());

      await tapNextWith(tester, _ethChecksummed);

      expect(find.text(guardMessage), findsOneWidget);
      expect(find.byType(SendAmountStep), findsNothing);
    },
  );

  testWidgets('ETH send: a genuinely different recipient still advances', (
    tester,
  ) async {
    // The guard must not become a blanket block — refusing a real recipient is
    // the same class of bug pointing the other way.
    await setUpSheet(
      walletAddress: _ethChecksummed,
      chain: Chain.ethereum,
      token: _ethToken(),
    );
    await pumpSheet(tester, _ethToken());

    await tapNextWith(tester, _ethOther);

    expect(find.text(guardMessage), findsNothing);
    expect(find.byType(SendAmountStep), findsOneWidget);
  });

  testWidgets(
    'ETH send: the source wallet is dropped from Recents across a casing '
    'mismatch',
    (tester) async {
      // Recents is the one-tap path into the guard. Leaving your own wallet in
      // the list is how a user reaches a self-send without ever typing one.
      await setUpSheet(
        walletAddress: _ethChecksummed,
        chain: Chain.ethereum,
        token: _ethToken(),
        recents: [_ethLowercased, _ethOther],
      );
      await pumpSheet(tester, _ethToken());

      expect(offeredRecents(tester), [_ethOther]);
    },
  );

  // ── Solana: the control ────────────────────────────────────────────────────

  testWidgets('Solana send: the source wallet is still refused', (
    tester,
  ) async {
    await setUpSheet(
      walletAddress: _solSelf,
      chain: Chain.solana,
      token: _solToken(),
    );
    await pumpSheet(tester, _solToken());

    await tapNextWith(tester, _solSelf);

    expect(find.text(guardMessage), findsOneWidget);
    expect(find.byType(SendAmountStep), findsNothing);
  });

  testWidgets(
    'Solana send: an address differing from the source only in case is a '
    'DIFFERENT wallet and must still advance',
    (tester) async {
      // Base58 is case-sensitive. A blanket `toLowerCase()` normalisation
      // would collapse these two distinct wallets into one and refuse a
      // perfectly legitimate send — the naive fix that otherwise looks right.
      await setUpSheet(
        walletAddress: _solSelf,
        chain: Chain.solana,
        token: _solToken(),
      );
      await pumpSheet(tester, _solToken());

      await tapNextWith(tester, _solCaseVariant);

      expect(find.text(guardMessage), findsNothing);
      expect(find.byType(SendAmountStep), findsOneWidget);
    },
  );

  testWidgets(
    'Solana send: Recents keeps an address that differs from the source only '
    'in case',
    (tester) async {
      // Same control on the recents filter: lowercasing base58 would silently
      // delete a real recipient from the user's history.
      await setUpSheet(
        walletAddress: _solSelf,
        chain: Chain.solana,
        token: _solToken(),
        recents: [_solSelf, _solCaseVariant, _solOther],
      );
      await pumpSheet(tester, _solToken());

      expect(offeredRecents(tester), [_solCaseVariant, _solOther]);
    },
  );
}
