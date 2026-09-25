import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/avatar_pool_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/services/account_wallet_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/settings/screens/edit_account_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_toggle.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockAvatarPool extends Mock implements AvatarPoolService {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockSession extends Mock implements SessionManager {}

class _MockAuth extends Mock implements AuthService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAccountWalletBloc
    extends MockBloc<AccountWalletEvent, AccountWalletState>
    implements AccountWalletBloc {}

/// Turning a chain off on this screen deletes a wallet, and the deletion can
/// be refused: the recovery-graph write is the commit point of a removal and
/// it can fail. What the user must never get is the refusal message next to a
/// screen that closed as if the edit had been saved — the toggles would then
/// read as applied on the next open, and the account would be one wallet
/// different from what the screen last showed.
///
/// Turning a chain *on* can be refused for the same reason: the import
/// supersedes any view-only wallet already watching that address, and pruning
/// that wallet from the graph is the commit point of its removal. So an
/// addition is not the "always safe" half of the diff — it can throw, and the
/// screen has to survive it rather than dying with an unhandled exception on
/// the Done callback.
void main() {
  const solanaWallet = WalletInfo(
    id: 'sol-1',
    address: 'So1anaAddress1111111111111111111111111111111',
    name: 'Solana',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-1',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
  );
  const ethWallet = WalletInfo(
    id: 'eth-1',
    address: '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed',
    name: 'Ethereum',
    walletType: WalletType.hd,
    chain: 'ethereum',
    accountId: 'acct-1',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
  );
  const account = Account(
    id: 'acct-1',
    name: 'Account 01',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
    wallets: [solanaWallet, ethWallet],
  );

  late _MockRepo repo;
  late _MockAvatarPool pool;
  late _MockTokens tokens;
  late _MockPortfolio portfolio;
  late _MockSession session;
  late _MockAuth auth;
  late _MockWalletManager walletManager;
  late _MockAccountWalletBloc accountWalletBloc;

  const tezosAddress = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  setUpAll(() {
    registerFallbackValue(const <String>[]);
    registerFallbackValue(const <WalletImportSelection>[]);
  });

  setUp(() {
    repo = _MockRepo();
    pool = _MockAvatarPool();
    tokens = _MockTokens();
    portfolio = _MockPortfolio();
    session = _MockSession();
    auth = _MockAuth();
    walletManager = _MockWalletManager();
    accountWalletBloc = _MockAccountWalletBloc();

    for (final register in <void Function()>[
      () => sl.registerSingleton<WalletRepository>(repo),
      () => sl.registerSingleton<AvatarPoolService>(pool),
      () => sl.registerSingleton<TokenRepository>(tokens),
      () => sl.registerSingleton<PortfolioRepository>(portfolio),
      () => sl.registerSingleton<SessionManager>(session),
      () => sl.registerSingleton<AuthService>(auth),
      () => sl.registerSingleton<WalletManager>(walletManager),
      () => sl.registerSingleton<AccountWalletBloc>(accountWalletBloc),
    ]) {
      register();
    }

    when(() => repo.getAccountViews()).thenAnswer((_) async => [account]);
    when(() => repo.getActiveWallet()).thenAnswer((_) async => solanaWallet);
    // The picker derivation only feeds the "off" rows; failing it leaves the
    // two chains the account already holds, which is all this test toggles.
    when(
      () => repo.deriveAccountsForPicker(
        any(),
        startIndex: any(named: 'startIndex'),
        count: any(named: 'count'),
      ),
    ).thenAnswer((_) => Future.error(Exception('no derivation in tests')));
    when(
      () => pool.candidates(inUse: any(named: 'inUse')),
    ).thenAnswer((_) async => const <String>[]);
    // Future.error, not `async => throw`: the screen enriches the Solana row
    // with `.catchError`, and a Future<Never> makes that handler impossible to
    // satisfy. These stubs stand in for "the network is not here".
    when(
      () => tokens.getTokenBalances(any()),
    ).thenAnswer((_) => Future.error(Exception('no prices in tests')));
    when(
      () => portfolio.artworkCountForOwner(any()),
    ).thenAnswer((_) => Future.error(Exception('no indexer in tests')));
    when(() => session.refreshActiveAccount()).thenAnswer((_) async {});
  });

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<AvatarPoolService>();
    sl.unregister<TokenRepository>();
    sl.unregister<PortfolioRepository>();
    sl.unregister<SessionManager>();
    sl.unregister<AuthService>();
    sl.unregister<WalletManager>();
    sl.unregister<AccountWalletBloc>();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('home'))),
        ),
        GoRoute(
          path: '/edit',
          builder: (context, state) =>
              const EditAccountScreen(accountId: 'acct-1'),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
    router.push('/edit');
    await tester.pumpAndSettle();
    expect(find.text('Edit Account'), findsOneWidget);
  }

  /// Turns the Ethereum row off (row order is Solana, then Ethereum — Tezos
  /// has no wallet and no derived address, so it has no row) and saves.
  Future<void> disableEthereumAndSave(WidgetTester tester) async {
    expect(find.byType(MallowToggle), findsNWidgets(2));
    await tester.tap(find.byType(MallowToggle).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MallowButton, 'Done'));
    await tester.pumpAndSettle();
  }

  testWidgets('a refused removal keeps the screen open and the toggle on', (
    tester,
  ) async {
    when(
      () => repo.removeWallets(any()),
    ).thenThrow(GraphSyncException(Exception('keystore')));

    await pumpScreen(tester);
    await disableEthereumAndSave(tester);

    // The message is only true because the removal is all-or-nothing, so it
    // has to be one call for the whole set rather than one per wallet.
    verify(() => repo.removeWallets(any())).called(1);
    verifyNever(() => repo.removeWallet(any()));
    expect(
      find.text('Could not update recovery data. Nothing was removed.'),
      findsOneWidget,
    );
    // Not a save: the screen stays, and the toggle is re-read from the account
    // rather than left showing the edit the user did not get.
    expect(find.text('Edit Account'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(
      tester.widget<MallowToggle>(find.byType(MallowToggle).at(1)).value,
      isTrue,
    );
    // Nothing was removed, so no ownership proof may be dropped either.
    verifyNever(() => auth.forgetWalletSig(any()));
  });

  testWidgets('a successful removal drops the wallet sig and closes the '
      'screen', (tester) async {
    when(() => repo.removeWallets(any())).thenAnswer((_) async => 'sol-1');

    await pumpScreen(tester);
    await disableEthereumAndSave(tester);

    final removed =
        verify(() => repo.removeWallets(captureAny())).captured.single
            as Iterable<String>;
    expect(removed.toList(), [ethWallet.id]);
    verify(() => auth.forgetWalletSig(ethWallet.address)).called(1);
    // The active wallet survived the edit, so no re-auth is provoked.
    verifyNever(() => walletManager.switchWalletById(any()));
    expect(find.text('Edit Account'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a refused addition keeps the screen open and never reaches the '
      'removals', (tester) async {
    // Derivation has to succeed here: the Tezos row only exists — as an "off"
    // row the user can turn on — once its address is derived.
    when(
      () => repo.deriveAccountsForPicker(
        any(),
        startIndex: any(named: 'startIndex'),
        count: any(named: 'count'),
      ),
    ).thenAnswer(
      (_) async => AccountPickerInfo(
        accounts: [
          AccountAddresses(
            index: 0,
            solanaStandard: solanaWallet.address,
            ethereum: ethWallet.address,
            tezos: tezosAddress,
          ),
        ],
        alreadyImported: {solanaWallet.address, ethWallet.address},
      ),
    );
    when(
      () => repo.importAccountsFromPhrase(any(), any()),
    ).thenThrow(GraphSyncException(Exception('keystore')));

    await pumpScreen(tester);
    expect(find.byType(MallowToggle), findsNWidgets(3));

    // Tezos on (the addition that fails), then Ethereum off (a removal that
    // must not happen because of it).
    await tester.tap(find.byType(MallowToggle).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MallowToggle).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MallowButton, 'Done'));
    await tester.pumpAndSettle();

    final selections =
        verify(
              () => repo.importAccountsFromPhrase(any(), captureAny()),
            ).captured.single
            as List<WalletImportSelection>;
    expect(selections.single.address, tezosAddress);
    expect(
      find.text('Could not update recovery data. The address was not added.'),
      findsOneWidget,
    );
    // The refusal stops the whole diff: deleting the Ethereum wallet on top of
    // an addition that did not land would leave the account in a shape the
    // user never asked for.
    verifyNever(() => repo.removeWallets(any()));
    verifyNever(() => auth.forgetWalletSig(any()));
    // Not a save: the screen stays, and both toggles are re-read from the
    // account rather than left showing the edit the user did not get.
    expect(find.text('Edit Account'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(
      tester.widget<MallowToggle>(find.byType(MallowToggle).at(1)).value,
      isFalse,
    );
    expect(
      tester.widget<MallowToggle>(find.byType(MallowToggle).at(2)).value,
      isTrue,
    );
  });
}
