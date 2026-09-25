import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/services/avatar_pool_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/services/account_wallet_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/settings/screens/edit_account_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockAvatarPool extends Mock implements AvatarPoolService {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockSession extends Mock implements SessionManager {}

class _MockAuth extends Mock implements AuthService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockAccountWalletBloc
    extends MockBloc<AccountWalletEvent, AccountWalletState>
    implements AccountWalletBloc {}

/// Removing an account removes every wallet under it, and with them key
/// material that exists nowhere else on the device: an imported wallet's
/// private key, and the seed phrase itself once the account holds the last
/// wallets derived from it. Neither can be recovered from the app, so the
/// confirmation has to name the one the user is about to lose — the generic
/// "back up your recovery phrase" line is wrong for an imported key and silent
/// about a phrase being deleted.
///
/// The removal also has to be un-repeatable while it runs. `removeAccount`
/// returns the replacement wallet id, or null when nothing is left, and this
/// screen turns null into a logout — so a second call, which matches no rows
/// and returns null, would sign the user out of a device that still holds
/// wallets.
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
  const otherSeedWallet = WalletInfo(
    id: 'sol-2',
    address: 'So1anaAddress3333333333333333333333333333333',
    name: 'Solana',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-2',
    seedPhraseId: 'sp-1',
    derivationIndex: 1,
  );
  const account = Account(
    id: 'acct-1',
    name: 'Account 01',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
    wallets: [solanaWallet, ethWallet],
  );
  const otherAccount = Account(
    id: 'acct-2',
    name: 'Account 02',
    seedPhraseId: 'sp-1',
    derivationIndex: 1,
    wallets: [otherSeedWallet],
  );
  const importedAccount = Account(
    id: 'acct-1',
    name: 'Imported',
    kind: AccountKind.privateKey,
    wallets: [
      WalletInfo(
        id: 'pk-1',
        address: 'So1anaAddress2222222222222222222222222222222',
        name: 'Imported',
        walletType: WalletType.importedKey,
        chain: 'solana',
        accountId: 'acct-1',
      ),
    ],
  );

  const socialAccount = Account(
    id: 'acct-1',
    name: 'Social',
    kind: AccountKind.social,
    wallets: [
      WalletInfo(
        id: 'soc-1',
        address: 'So1anaAddress4444444444444444444444444444444',
        name: 'Social',
        walletType: WalletType.social,
        chain: 'solana',
        accountId: 'acct-1',
      ),
    ],
  );
  const ledgerAccount = Account(
    id: 'acct-1',
    name: 'Ledger',
    kind: AccountKind.hardware,
    wallets: [
      WalletInfo(
        id: 'led-1',
        address: 'So1anaAddress5555555555555555555555555555555',
        name: 'Ledger',
        walletType: WalletType.ledger,
        chain: 'solana',
        accountId: 'acct-1',
      ),
    ],
  );
  const viewOnlyAccount = Account(
    id: 'acct-1',
    name: 'Watching',
    kind: AccountKind.viewOnly,
    wallets: [
      WalletInfo(
        id: 'vo-1',
        address: 'So1anaAddress6666666666666666666666666666666',
        name: 'Watching',
        walletType: WalletType.viewOnly,
        chain: 'solana',
        accountId: 'acct-1',
      ),
    ],
  );

  late _MockRepo repo;
  late _MockAvatarPool pool;
  late _MockTokens tokens;
  late _MockPortfolio portfolio;
  late _MockSession session;
  late _MockAuth auth;
  late _MockWalletManager walletManager;
  late _MockAuthNotifier authNotifier;
  late _MockAccountWalletBloc accountWalletBloc;

  setUp(() {
    repo = _MockRepo();
    pool = _MockAvatarPool();
    tokens = _MockTokens();
    portfolio = _MockPortfolio();
    session = _MockSession();
    auth = _MockAuth();
    walletManager = _MockWalletManager();
    authNotifier = _MockAuthNotifier();
    accountWalletBloc = _MockAccountWalletBloc();

    for (final register in <void Function()>[
      () => sl.registerSingleton<WalletRepository>(repo),
      () => sl.registerSingleton<AvatarPoolService>(pool),
      () => sl.registerSingleton<TokenRepository>(tokens),
      () => sl.registerSingleton<PortfolioRepository>(portfolio),
      () => sl.registerSingleton<SessionManager>(session),
      () => sl.registerSingleton<AuthService>(auth),
      () => sl.registerSingleton<WalletManager>(walletManager),
      () => sl.registerSingleton<AuthStateNotifier>(authNotifier),
      () => sl.registerSingleton<AccountWalletBloc>(accountWalletBloc),
    ]) {
      register();
    }

    // Two accounts: the device keeps at least one, so a screen showing the
    // only account refuses the removal before it ever asks.
    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [account, otherAccount]);
    when(() => repo.getActiveWallet()).thenAnswer((_) async => solanaWallet);
    // The seed phrase keeps a wallet under the other account, so removing this
    // one does not delete it.
    when(
      () => repo.getWalletsForSeedPhrase('sp-1'),
    ).thenAnswer((_) async => [solanaWallet, ethWallet, otherSeedWallet]);
    when(() => repo.getAllSeedPhrases()).thenAnswer(
      (_) async => const [SeedPhraseInfo(id: 'sp-1', name: 'Main phrase')],
    );
    when(() => repo.removeAccount(any())).thenAnswer((_) async => 'sol-2');
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
    when(
      () => tokens.getTokenBalances(any()),
    ).thenAnswer((_) => Future.error(Exception('no prices in tests')));
    when(
      () => portfolio.artworkCountForOwner(any()),
    ).thenAnswer((_) => Future.error(Exception('no indexer in tests')));
    when(() => session.refreshActiveAccount()).thenAnswer((_) async {});
    when(() => session.reconcileAfterRemoval(any())).thenAnswer((_) async {});
    when(() => walletManager.clearWalletSelection()).thenAnswer((_) async {});
    when(
      () => walletManager.notifyWalletDataChanged(),
    ).thenAnswer((_) async {});
    when(() => authNotifier.onLogout()).thenAnswer((_) async {});
  });

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<AvatarPoolService>();
    sl.unregister<TokenRepository>();
    sl.unregister<PortfolioRepository>();
    sl.unregister<SessionManager>();
    sl.unregister<AuthService>();
    sl.unregister<WalletManager>();
    sl.unregister<AuthStateNotifier>();
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
    // Fire-and-forget by design: the route's own future completes only
    // when the screen pops, which several of these tests never do.
    unawaited(router.push('/edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Account'), findsOneWidget);
  }

  /// Opens the confirmation sheet and waits out its entrance tap guard, which
  /// swallows taps for a beat after the slide-in finishes. `pumpAndSettle`
  /// returns while that timer is still pending, so without the extra pump the
  /// first tap on the sheet's own button goes nowhere.
  Future<void> openRemoveSheet(WidgetTester tester) async {
    await tester.tap(find.text('Remove account'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Remove account?'), findsOneWidget);
  }

  testWidgets('an imported account is warned about its private key, not a '
      'recovery phrase it does not have', (tester) async {
    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [importedAccount, otherAccount]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('Make sure you have a copy of the private key'),
      findsOneWidget,
    );
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('an account holding the last wallets of a seed phrase says the '
      'phrase itself is deleted, and names it', (tester) async {
    when(
      () => repo.getWalletsForSeedPhrase('sp-1'),
    ).thenAnswer((_) async => const [solanaWallet, ethWallet]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('deletes that recovery phrase from this device'),
      findsOneWidget,
    );
    expect(find.textContaining('"Main phrase"'), findsOneWidget);
  });

  testWidgets('an account whose seed phrase survives it gets the plain '
      'warning', (tester) async {
    await pumpScreen(tester);
    await openRemoveSheet(tester);

    // The other account still holds the phrase, so nothing irreversible
    // happens to it here and the sheet must not claim otherwise.
    expect(
      find.textContaining('backed up your recovery phrase'),
      findsOneWidget,
    );
    expect(find.textContaining('deletes that recovery phrase'), findsNothing);
  });

  testWidgets('a second Remove tap during an in-flight removal cannot log the '
      'user out', (tester) async {
    final removal = Completer<String?>();
    when(() => repo.removeAccount('acct-1')).thenAnswer((_) => removal.future);

    await pumpScreen(tester);
    await openRemoveSheet(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    // The sheet is gone, so the tap below really does land on the screen's
    // own Remove button.
    expect(find.text('Remove account?'), findsNothing);

    // The repository has not answered yet. A second tap here used to re-enter
    // it; the retry matches no rows, returns null, and the screen reads null
    // as "no wallets remain".
    await tester.tap(find.text('Remove account'));
    await tester.pumpAndSettle();
    verify(() => repo.removeAccount('acct-1')).called(1);
    verifyNever(() => authNotifier.onLogout());
    // Nor may it re-ask: a second sheet over an in-flight removal is the same
    // re-entry one confirm tap later.
    expect(find.text('Remove account?'), findsNothing);

    removal.complete('sol-2');
    await tester.pumpAndSettle();

    verify(() => session.reconcileAfterRemoval('sol-2')).called(1);
    verifyNever(() => authNotifier.onLogout());
    verifyNever(() => walletManager.clearWalletSelection());
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a social account is told it can be signed back in, not to back '
      'up a phrase it never had', (tester) async {
    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [socialAccount, otherAccount]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('signing in with the same account'),
      findsOneWidget,
    );
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('an all-Ledger account says the keys stay on the device that '
      'holds them', (tester) async {
    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [ledgerAccount, otherAccount]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    // Nothing signable is stored here, so telling this user to back up a
    // recovery phrase before removing the rows is simply wrong.
    expect(find.textContaining('stay on your Ledger'), findsOneWidget);
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('a watch-only account says no keys are stored for it', (
    tester,
  ) async {
    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [viewOnlyAccount, otherAccount]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(find.textContaining('No keys are stored for it'), findsOneWidget);
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('an account already removed elsewhere leaves the screen instead '
      'of sitting on a dead button', (tester) async {
    var views = <Account>[account, otherAccount];
    when(() => repo.getAccountViews()).thenAnswer((_) async => views);

    await pumpScreen(tester);
    // Removed from the accounts list while this screen was open. Two accounts
    // remain, so the "keep at least one" refusal is not what is under test.
    const survivor = Account(
      id: 'acct-3',
      name: 'Account 03',
      seedPhraseId: 'sp-1',
      derivationIndex: 2,
    );
    views = <Account>[otherAccount, survivor];

    await tester.tap(find.text('Remove account'));
    await tester.pumpAndSettle();

    expect(find.text('Remove account?'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    verifyNever(() => repo.removeAccount(any()));
  });

  testWidgets('a refused recovery-graph write re-arms the button so the '
      'removal can be retried', (tester) async {
    var attempts = 0;
    when(() => repo.removeAccount('acct-1')).thenAnswer((_) async {
      if (attempts++ == 0) throw GraphSyncException('graph write refused');
      return 'sol-2';
    });

    await pumpScreen(tester);
    await openRemoveSheet(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not update recovery data'),
      findsOneWidget,
    );

    // Nothing was deleted, so this is a retryable failure. A busy flag left
    // set would leave the user a dead button and no way to remove the account
    // at all.
    await openRemoveSheet(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    verify(() => session.reconcileAfterRemoval('sol-2')).called(1);
    expect(find.text('home'), findsOneWidget);

    // Let the error snack bar's own timer expire before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
