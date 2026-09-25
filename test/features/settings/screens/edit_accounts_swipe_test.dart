import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/edit_accounts_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockSession extends Mock implements SessionManager {}

class _MockAuth extends Mock implements AuthService {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockAvatars extends Mock implements AvatarService {}

/// A swipe on this list dismisses the row *before* the removal is attempted.
/// Anything that then stops the removal leaves the account in the list with its
/// `Dismissible` already dismissed — which the framework treats as an error on
/// the next build ("a dismissed Dismissible widget is still part of the tree"),
/// taking the whole screen down. So every refusal has to put the row back.
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
  const otherWallet = WalletInfo(
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
    wallets: [solanaWallet],
  );
  const otherAccount = Account(
    id: 'acct-2',
    name: 'Account 02',
    seedPhraseId: 'sp-1',
    derivationIndex: 1,
    wallets: [otherWallet],
  );

  late _MockRepo repo;
  late _MockSession session;
  late _MockAuth auth;
  late _MockWalletManager walletManager;
  late _MockAuthNotifier authNotifier;
  late _MockAvatars avatars;

  setUp(() {
    repo = _MockRepo();
    session = _MockSession();
    auth = _MockAuth();
    walletManager = _MockWalletManager();
    authNotifier = _MockAuthNotifier();
    avatars = _MockAvatars();

    for (final register in <void Function()>[
      () => sl.registerSingleton<WalletRepository>(repo),
      () => sl.registerSingleton<SessionManager>(session),
      () => sl.registerSingleton<AuthService>(auth),
      () => sl.registerSingleton<WalletManager>(walletManager),
      () => sl.registerSingleton<AuthStateNotifier>(authNotifier),
      () => sl.registerSingleton<AvatarService>(avatars),
    ]) {
      register();
    }

    when(
      () => repo.getAccountViews(),
    ).thenAnswer((_) async => [account, otherAccount]);
    when(() => repo.getActiveWallet()).thenAnswer((_) async => otherWallet);
    when(
      () => repo.getWalletsForSeedPhrase('sp-1'),
    ).thenAnswer((_) async => [solanaWallet, otherWallet]);
    when(() => repo.getAllSeedPhrases()).thenAnswer(
      (_) async => const [SeedPhraseInfo(id: 'sp-1', name: 'Main phrase')],
    );
    when(() => repo.removeAccount(any())).thenAnswer((_) async => 'sol-2');
    when(
      () => walletManager.notifyWalletDataChanged(),
    ).thenAnswer((_) async {});
    when(() => walletManager.clearWalletSelection()).thenAnswer((_) async {});
    when(() => session.reconcileAfterRemoval(any())).thenAnswer((_) async {});
    when(() => authNotifier.onLogout()).thenAnswer((_) async {});
    // No avatar art in a widget test — the rows fall back to their
    // placeholder, which is all these swipes need.
    when(() => avatars.cachedFile(any())).thenReturn(null);
    when(() => avatars.avatarFile(any())).thenAnswer((_) async => null);
  });

  tearDown(() {
    sl.unregister<WalletRepository>();
    sl.unregister<SessionManager>();
    sl.unregister<AuthService>();
    sl.unregister<WalletManager>();
    sl.unregister<AuthStateNotifier>();
    sl.unregister<AvatarService>();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const EditAccountsScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
    expect(find.text('Account 01'), findsOneWidget);
  }

  /// Swipes the first row away and confirms the sheet it raises.
  Future<void> swipeAndConfirm(WidgetTester tester) async {
    await tester.drag(find.text('Account 01'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    // The sheet swallows taps for a beat after its slide-in finishes, and
    // pumpAndSettle returns while that timer is still pending.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Remove account?'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
  }

  testWidgets('a confirmed swipe removes the row', (tester) async {
    await pumpScreen(tester);
    await swipeAndConfirm(tester);

    verify(() => repo.removeAccount('acct-1')).called(1);
    expect(find.text('Account 01'), findsNothing);
    expect(find.text('Account 02'), findsOneWidget);
  });

  testWidgets('a removal that throws puts the dismissed row back and says '
      'why', (tester) async {
    // Not a GraphSyncException — this is the arm every *other* failure takes.
    // Before it existed the throw escaped the swipe callback entirely, and the
    // row stayed dismissed over an account that was never removed.
    when(() => repo.removeAccount('acct-1')).thenThrow(StateError('db closed'));

    await pumpScreen(tester);
    await swipeAndConfirm(tester);

    expect(find.text('Account 01'), findsOneWidget);
    expect(find.textContaining('Could not remove the account'), findsOneWidget);

    // Let the error snack bar's own timer expire before the test ends.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a read taken before the removal can fail too, and the row '
      'still comes back', (tester) async {
    // `getActiveWallet` runs after the swipe has already dismissed the row, so
    // it has to be inside the same guard as the removal itself.
    when(() => repo.getActiveWallet()).thenThrow(StateError('db closed'));

    await pumpScreen(tester);
    await swipeAndConfirm(tester);

    expect(find.text('Account 01'), findsOneWidget);
    verifyNever(() => repo.removeAccount(any()));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
