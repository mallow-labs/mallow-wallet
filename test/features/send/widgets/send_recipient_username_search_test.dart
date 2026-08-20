import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
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
import 'package:mallow_wallet/features/send/widgets/send_sheet.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Username search in the fungible-send recipient step.
///
/// Two behaviours only exist once the whole sheet is wired, so neither the
/// service nor the controller unit tests can cover them:
///
///  * `_onAddressChanged` has to consult the search gate **before** validating
///    the text as an address. `alice` is not a Solana address, so without the
///    early return the field paints "Invalid Solana address" in red directly
///    underneath an open dropdown of matching users.
///  * `_onRecipientNext` has to trust the picked profile's resolved address
///    rather than re-parsing the field, which by then holds `@alice`. Without
///    that branch, picking a user and tapping Next refuses to advance.

class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _FakeWalletManager extends Fake implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _solSelf;
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

/// Returns [results] for any query, immediately.
class _FakeRecipientSearchService extends Fake
    implements RecipientSearchService {
  _FakeRecipientSearchService(this.results);

  final List<RecipientSuggestion> results;
  final queries = <String>[];

  @override
  Future<List<RecipientSuggestion>> search(String query, Chain chain) async {
    queries.add(query);
    return results;
  }
}

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _aliceMain = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _aliceSecond = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const _splMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

TokenBalance _solToken() => const TokenBalance(
  mint: _splMint,
  symbol: 'USDC',
  name: 'USD Coin',
  decimals: 6,
  rawBalance: 5000000,
  uiBalance: 5.0,
);

/// Address of the nth generated suggestion — distinct per row, so each gets its
/// own [recipientSuggestionKey].
String _aliceAt(int i) => '${_aliceMain.substring(0, _aliceMain.length - 1)}$i';

/// Enough suggestions to overflow the dropdown's 240px cap (rows are 44px).
List<RecipientSuggestion> _manyAlices(int count) => [
  for (var i = 0; i < count; i++)
    RecipientSuggestion(address: _aliceAt(i), username: 'alice$i'),
];

WalletInfo _wallet(String address) => WalletInfo(
  id: 'wallet-1',
  address: address,
  name: 'Wallet 1',
  walletType: WalletType.hd,
  chain: Chain.solana.toDbString(),
);

void main() {
  late _MockSendBloc sendBloc;
  late _MockTokenBalanceBloc tokenBalanceBloc;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  Future<void> setUpSheet(_FakeRecipientSearchService searchService) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();

    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(_FakeWalletManager());
    register<WalletRepository>(_FakeWalletRepository());
    register<ProfileLookupService>(_FakeProfileLookupService());
    register<SessionManager>(_FakeSessionManager());
    register<TokenRepository>(_FakeTokenRepository());
    register<EthereumTokenService>(_FakeEthereumTokenService());
    register<TezosTokenService>(_FakeTezosTokenService());
    register<RecipientSearchService>(searchService);
    register<SessionPortfolioAggregator>(
      _FakeAggregator(
        SendSourceCandidate(
          wallet: _wallet(_solSelf),
          rawBalance: 5000000,
          uiBalance: 5.0,
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
      () => sl.unregister<RecipientSearchService>(),
      () => sl.unregister<SessionPortfolioAggregator>(),
    ]) {
      drop();
    }
  });

  /// Pumps past the 500ms search debounce and lets the response settle.
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
            child: SendSheet(initialToken: _solToken()),
          ),
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await flush(tester);
  }

  testWidgets('a typed username shows suggestions, not an address error', (
    tester,
  ) async {
    // The regression this exists for: `alice` fails every address validator, so
    // without the search gate short-circuiting validation the user sees a red
    // "Invalid Solana address" under a dropdown that is offering them users.
    final service = _FakeRecipientSearchService([
      const RecipientSuggestion(address: _aliceMain, username: 'alice'),
    ]);
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, 'alice');

    expect(find.text('Invalid Solana address'), findsNothing);
    expect(find.byKey(recipientSuggestionKey(_aliceMain)), findsOneWidget);
    expect(service.queries, ['alice']);
  });

  testWidgets('an address is validated, never searched', (tester) async {
    // The gate must not swallow address validation wholesale — a mistyped
    // address still has to report itself.
    final service = _FakeRecipientSearchService(const []);
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, _aliceMain);
    expect(find.text('Invalid Solana address'), findsNothing);
    expect(service.queries, isEmpty);

    // Long enough to clear the 32-char search ceiling, so it reaches the
    // address validator rather than the search gate.
    await type(tester, 'not-a-real-address-but-quite-long-indeed');
    expect(find.text('Invalid Solana address'), findsOneWidget);
    expect(service.queries, isEmpty);
  });

  testWidgets('one profile with two wallets on the chain offers both', (
    tester,
  ) async {
    // The deliberate divergence from the webapp. Both rows carry the same
    // handle, so the truncated address is the only thing distinguishing them —
    // if it were dropped the user could not tell which wallet they picked.
    final service = _FakeRecipientSearchService(const [
      RecipientSuggestion(address: _aliceMain, username: 'alice'),
      RecipientSuggestion(address: _aliceSecond, username: 'alice'),
    ]);
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, 'alice');

    expect(find.byKey(recipientSuggestionKey(_aliceMain)), findsOneWidget);
    expect(find.byKey(recipientSuggestionKey(_aliceSecond)), findsOneWidget);
    expect(find.textContaining('9WzD'), findsOneWidget);
    expect(find.textContaining('EPjF'), findsOneWidget);
  });

  testWidgets('picking a suggestion fills the handle and advances on Next', (
    tester,
  ) async {
    // `@alice` is in the field by design, so Next has to advance on the picked
    // profile's resolved address instead of re-parsing the text.
    final service = _FakeRecipientSearchService(const [
      RecipientSuggestion(address: _aliceMain, username: 'alice'),
    ]);
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, 'alice');
    await tester.tap(find.byKey(recipientSuggestionKey(_aliceMain)));
    await flush(tester);

    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      '@alice',
    );
    // The resolved address stays visible under the field — with two rows for
    // one profile, this is how the user confirms which wallet they landed on.
    expect(find.text(_aliceMain), findsOneWidget);

    await tester.tap(find.text('Next'));
    await flush(tester);

    expect(find.byType(SendAmountStep), findsOneWidget);
  });

  testWidgets('dragging the results list scrolls it and keeps it open', (
    tester,
  ) async {
    // The dropdown is capped at 240px — about five rows — so anything past that
    // is only reachable by dragging. `MallowScrollBehavior` makes `onDrag`
    // keyboard dismissal the app-wide default, which unfocuses the field, and
    // losing focus closes the dropdown: the card would vanish under the finger
    // the moment the user reached for a row below the cut-off.
    final service = _FakeRecipientSearchService(_manyAlices(8));
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, 'alice');

    final focusNode = tester
        .widget<TextField>(find.byType(TextField).first)
        .focusNode;
    expect(focusNode?.hasFocus, isTrue);

    // The tail row starts past the cut-off, so it is the one the user has to
    // drag for. Row 2 is on screen, so drag from there.
    final tailRow = find.byKey(recipientSuggestionKey(_aliceAt(7)));
    expect(tailRow, findsNothing);

    await tester.drag(
      find.byKey(recipientSuggestionKey(_aliceAt(2))),
      const Offset(0, -100),
    );
    await flush(tester);

    // The field keeps focus — losing it is what used to close the dropdown.
    expect(focusNode?.hasFocus, isTrue);
    // The list scrolled, so the row past the cut-off is now reachable. A closed
    // dropdown would have taken every row with it instead.
    expect(tailRow, findsOneWidget);
  });

  testWidgets('the empty state names the chain being sent on', (tester) async {
    // Results are filtered to addresses that can receive on this chain, so a
    // real username with no Solana wallet finds nothing. A bare "No users
    // found" would read as a broken search.
    final service = _FakeRecipientSearchService(const []);
    await setUpSheet(service);
    await pumpSheet(tester);

    await type(tester, 'alice');

    expect(find.text('No Solana users found'), findsOneWidget);
  });
}
