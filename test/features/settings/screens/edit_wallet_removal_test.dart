import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/services/account_wallet_bloc.dart';
import 'package:mallow_wallet/features/settings/screens/edit_wallet_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuth extends Mock implements AuthService {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockAccountWalletBloc
    extends MockBloc<AccountWalletEvent, AccountWalletState>
    implements AccountWalletBloc {}

/// Removing a wallet here can destroy key material that exists nowhere else on
/// the device: an imported wallet's private key goes with it, and so does the
/// seed phrase itself once the last wallet derived from it is removed. Neither
/// can be recovered from the app, so the confirmation has to say which one the
/// user is about to lose — the generic "back up your recovery phrase" line is
/// wrong for an imported key and silent about a phrase being deleted.
///
/// The removal also has to be un-repeatable while it runs. `removeWallet`
/// returns the replacement wallet id, or null when nothing is left, and this
/// screen turns null into a logout — so a second call, which finds no row and
/// returns null, would sign the user out of a device that still holds wallets.
void main() {
  const hdWallet = WalletInfo(
    id: 'w-1',
    address: 'So1anaAddress1111111111111111111111111111111',
    name: 'Solana',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-1',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
  );
  const sibling = WalletInfo(
    id: 'w-2',
    address: '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed',
    name: 'Ethereum',
    walletType: WalletType.hd,
    chain: 'ethereum',
    accountId: 'acct-1',
    seedPhraseId: 'sp-1',
    derivationIndex: 0,
  );
  const importedWallet = WalletInfo(
    id: 'w-1',
    address: 'So1anaAddress2222222222222222222222222222222',
    name: 'Imported',
    walletType: WalletType.importedKey,
    chain: 'solana',
    accountId: 'acct-2',
  );
  const socialWallet = WalletInfo(
    id: 'w-1',
    address: 'So1anaAddress4444444444444444444444444444444',
    name: 'Social',
    walletType: WalletType.social,
    chain: 'solana',
    accountId: 'acct-3',
  );
  const ledgerWallet = WalletInfo(
    id: 'w-1',
    address: 'So1anaAddress5555555555555555555555555555555',
    name: 'Ledger',
    walletType: WalletType.ledger,
    chain: 'solana',
    accountId: 'acct-4',
  );
  const viewOnlyWallet = WalletInfo(
    id: 'w-1',
    address: 'So1anaAddress6666666666666666666666666666666',
    name: 'Watching',
    walletType: WalletType.viewOnly,
    chain: 'solana',
    accountId: 'acct-5',
  );

  late _MockRepo repo;
  late _MockWalletManager walletManager;
  late _MockAuth auth;
  late _MockAuthNotifier authNotifier;
  late _MockAccountWalletBloc accountWalletBloc;

  setUp(() {
    repo = _MockRepo();
    walletManager = _MockWalletManager();
    auth = _MockAuth();
    authNotifier = _MockAuthNotifier();
    accountWalletBloc = _MockAccountWalletBloc();

    for (final register in <void Function()>[
      () => sl.registerSingleton<WalletRepository>(repo),
      () => sl.registerSingleton<WalletManager>(walletManager),
      () => sl.registerSingleton<AuthService>(auth),
      () => sl.registerSingleton<AuthStateNotifier>(authNotifier),
      () => sl.registerSingleton<AccountWalletBloc>(accountWalletBloc),
    ]) {
      register();
    }

    when(() => repo.getWalletById('w-1')).thenAnswer((_) async => hdWallet);
    when(
      () => repo.getWalletsForSeedPhrase('sp-1'),
    ).thenAnswer((_) async => [hdWallet, sibling]);
    when(() => repo.getAllSeedPhrases()).thenAnswer(
      (_) async => const [SeedPhraseInfo(id: 'sp-1', name: 'Main phrase')],
    );
    when(
      () => walletManager.removeWallet(any()),
    ).thenAnswer((_) async => 'w-2');
    when(() => walletManager.switchWalletById(any())).thenAnswer((_) async {});
    when(() => walletManager.clearWalletSelection()).thenAnswer((_) async {});
    when(() => authNotifier.onLogout()).thenAnswer((_) async {});
  });

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<WalletManager>();
    sl.unregister<AuthService>();
    sl.unregister<AuthStateNotifier>();
    sl.unregister<AccountWalletBloc>();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1000);
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
          builder: (context, state) => const EditWalletScreen(walletId: 'w-1'),
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
    expect(find.text('Edit wallet'), findsOneWidget);
  }

  /// Opens the confirmation sheet and waits out its entrance tap guard, which
  /// swallows taps for a beat after the slide-in finishes. `pumpAndSettle`
  /// returns while that timer is still pending, so without the extra pump the
  /// first tap on the sheet's own button goes nowhere.
  Future<void> openRemoveSheet(WidgetTester tester) async {
    await tester.tap(find.text('Remove wallet'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Remove wallet?'), findsOneWidget);
  }

  testWidgets('an imported wallet is warned about its private key, not a '
      'recovery phrase it does not have', (tester) async {
    when(
      () => repo.getWalletById('w-1'),
    ).thenAnswer((_) async => importedWallet);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('Make sure you have a copy of the private key'),
      findsOneWidget,
    );
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('the last wallet of a seed phrase says the phrase itself is '
      'deleted, and names it', (tester) async {
    when(
      () => repo.getWalletsForSeedPhrase('sp-1'),
    ).thenAnswer((_) async => const [hdWallet]);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('deletes that recovery phrase from this device'),
      findsOneWidget,
    );
    expect(find.textContaining('"Main phrase"'), findsOneWidget);
  });

  testWidgets('a wallet whose seed phrase keeps another wallet gets the '
      'plain warning', (tester) async {
    await pumpScreen(tester);
    await openRemoveSheet(tester);

    // Nothing irreversible happens to the phrase here — the sibling still
    // holds it — so the sheet must not claim it is being deleted.
    expect(
      find.textContaining('backed up your recovery phrase'),
      findsOneWidget,
    );
    expect(find.textContaining('deletes that recovery phrase'), findsNothing);
  });

  testWidgets('a second Remove tap during an in-flight removal cannot log the '
      'user out', (tester) async {
    final removal = Completer<String?>();
    when(
      () => walletManager.removeWallet('w-1'),
    ).thenAnswer((_) => removal.future);

    await pumpScreen(tester);
    await openRemoveSheet(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    // The sheet is gone, so the tap below really does land on the screen's
    // own Remove button.
    expect(find.text('Remove wallet?'), findsNothing);

    // The repository has not answered yet. A second tap here used to re-enter
    // it; the retry finds no row, returns null, and the screen reads null as
    // "no wallets remain".
    await tester.tap(find.text('Remove wallet'));
    await tester.pumpAndSettle();
    verify(() => walletManager.removeWallet('w-1')).called(1);
    verifyNever(() => authNotifier.onLogout());
    // Nor may it re-ask: a second sheet over an in-flight removal is the same
    // re-entry one confirm tap later.
    expect(find.text('Remove wallet?'), findsNothing);

    removal.complete('w-2');
    await tester.pumpAndSettle();

    verify(() => walletManager.switchWalletById('w-2')).called(1);
    verifyNever(() => authNotifier.onLogout());
    verifyNever(() => walletManager.clearWalletSelection());
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a social wallet is told it can be signed back in, not to back '
      'up a phrase it never had', (tester) async {
    when(() => repo.getWalletById('w-1')).thenAnswer((_) async => socialWallet);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(
      find.textContaining('signing in with the same account'),
      findsOneWidget,
    );
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('a Ledger wallet says the key stays on the device that holds '
      'it', (tester) async {
    when(() => repo.getWalletById('w-1')).thenAnswer((_) async => ledgerWallet);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    // Nothing signable is stored here, so telling this user to back up a
    // recovery phrase before removing the row is simply wrong.
    expect(find.textContaining('stays on your Ledger'), findsOneWidget);
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('a watch-only wallet says no key is stored for it', (
    tester,
  ) async {
    when(
      () => repo.getWalletById('w-1'),
    ).thenAnswer((_) async => viewOnlyWallet);

    await pumpScreen(tester);
    await openRemoveSheet(tester);

    expect(find.textContaining('No key is stored for it'), findsOneWidget);
    expect(find.textContaining('backed up your recovery phrase'), findsNothing);
  });

  testWidgets('a wallet already removed elsewhere leaves the screen instead '
      'of sitting on a dead button', (tester) async {
    WalletInfo? stored = hdWallet;
    when(() => repo.getWalletById('w-1')).thenAnswer((_) async => stored);

    await pumpScreen(tester);
    // Removed from the accounts list while this screen was open.
    stored = null;

    await tester.tap(find.text('Remove wallet'));
    await tester.pumpAndSettle();

    // There is nothing left to confirm and nothing left to edit, so the
    // screen leaves rather than swallowing the tap.
    expect(find.text('Remove wallet?'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    verifyNever(() => walletManager.removeWallet(any()));
  });

  testWidgets('a refused recovery-graph write re-arms the button so the '
      'removal can be retried', (tester) async {
    var attempts = 0;
    when(() => walletManager.removeWallet('w-1')).thenAnswer((_) async {
      if (attempts++ == 0) throw GraphSyncException('graph write refused');
      return 'w-2';
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
    // set would leave the user a dead button and no way to remove the wallet
    // at all.
    await openRemoveSheet(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    verify(() => walletManager.switchWalletById('w-2')).called(1);
    expect(find.text('home'), findsOneWidget);

    // Let the error snack bar's own timer expire before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
