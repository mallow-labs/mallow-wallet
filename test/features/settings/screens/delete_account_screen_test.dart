import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/delete_account_screen.dart';
import 'package:mallow_wallet/shared/utils/social_wallet_copy.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockApiV2 extends Mock implements api.MallowApiV2Client {}

class _MockRepository extends Mock implements WalletRepository {}

// The Delete profile row is always shown (App Store 5.1.1(v) discoverability),
// so the screen owns every state the row can open into. The load-bearing one:
// every `/v0/login` upserts a `users` document for the signed-in address, so a
// signed-in user with no username still has a server record — addresses,
// sign-in history, push registrations — and the delete must run for real. The
// screen once told those users there was "nothing to delete on our servers",
// which is the 5.1.1(v) gap this suite guards.

void main() {
  late _MockAuth auth;

  setUp(() {
    auth = _MockAuth();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    sl.registerSingleton<AuthService>(auth);
  });
  tearDown(() => sl.unregister<AuthService>());

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeleteAccountScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('signed in with a username names the profile it deletes', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));

    await pumpScreen(tester);

    expect(find.text('Delete @ada'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsOneWidget);
  });

  // A missing username is not a missing record, so this is the same real
  // delete — only the heading changes.
  testWidgets('signed in without a username still offers the real delete', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(const api.User());

    await pumpScreen(tester);

    expect(find.text('Delete your mallow profile'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsOneWidget);
    // The itemised copy is what tells the user what a delete costs; it must
    // not be dropped just because there is no username to print. "What stays"
    // sits below the fold in the test viewport, so scroll to it.
    expect(find.text('What gets removed'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('What stays'), 200);
    expect(find.text('What stays'), findsOneWidget);
    // The old, false variant.
    expect(find.text('No mallow profile to delete'), findsNothing);
    expect(
      find.textContaining('nothing to delete on our servers'),
      findsNothing,
    );
    expect(find.widgetWithText(MallowButton, 'Reset app'), findsNothing);
  });

  // Deleting a profile never deletes a Google or Apple wallet's encrypted
  // backup (its social vault): that backup is the only thing that brings the
  // wallet back on a new device. It is server-side data that outlives the
  // profile, so the screen must say it is kept and where it is deleted —
  // otherwise the deletion path it describes is incomplete.
  group('a wallet backup that outlives the profile', () {
    late _MockRepository repository;
    const keepsBackup = ValueKey('profile-deletion-keeps-backup');

    WalletInfo wallet({String? vaultId, bool legacy = false}) => WalletInfo(
      id: 'w',
      address: 'SocialSol',
      name: 'Google Wallet',
      walletType: WalletType.social,
      chain: 'solana',
      socialProvider: 'google',
      socialVaultId: vaultId,
      legacySocial: legacy,
    );

    setUp(() {
      repository = _MockRepository();
      sl.registerSingleton<WalletRepository>(repository);
      when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));
      when(() => auth.currentAddress).thenReturn('SocialSol');
    });

    tearDown(() => sl.unregister<WalletRepository>());

    testWidgets('is said to stay, with where to delete it', (tester) async {
      when(
        () => repository.getAllWallets(),
      ).thenAnswer((_) async => [wallet(vaultId: 'vault-1')]);
      await pumpScreen(tester);

      await tester.scrollUntilVisible(find.byKey(keepsBackup), 200);
      expect(
        find.text(
          'Your encrypted wallet backup stays with mallow, so you can still '
          'sign in to this wallet. To delete it too, use Delete wallet backup '
          'in Sign-in keys.',
        ),
        findsOneWidget,
      );
      expect(
        profileDeletionKeepsBackupMessage,
        contains('Delete wallet backup in Sign-in keys'),
      );
      // Nothing lists the backup among what the delete removes.
      expect(find.textContaining('its encrypted backup'), findsNothing);
    });

    testWidgets('is not mentioned for a wallet from the older sign-in, '
        'which has none', (tester) async {
      when(
        () => repository.getAllWallets(),
      ).thenAnswer((_) async => [wallet(legacy: true)]);
      await pumpScreen(tester);
      expect(find.byKey(keepsBackup), findsNothing);
      expect(find.textContaining('wallet backup'), findsNothing);
    });

    testWidgets('a failed lookup still offers the delete', (tester) async {
      when(() => repository.getAllWallets()).thenThrow(StateError('db'));
      await pumpScreen(tester);
      expect(find.byKey(keepsBackup), findsNothing);
      expect(
        find.widgetWithText(MallowButton, 'Delete profile'),
        findsOneWidget,
      );
    });
  });

  // Signed out there is no `login-token`, so the call would 401 and leave the
  // profile in place. Ask for a sign-in rather than offering a delete that
  // cannot run — and never claim the server holds nothing.
  testWidgets('signed out asks for a sign-in instead of deleting', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(null);

    await pumpScreen(tester);

    expect(find.text('Sign in to delete your profile'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsNothing);
    expect(find.textContaining('nothing to delete'), findsNothing);
    // Reset app wipes the wallets and touches no server record: it is never
    // presented as the way to delete the profile.
    expect(find.widgetWithText(MallowButton, 'Reset app'), findsNothing);
    expect(find.byType(MallowButton), findsNothing);
  });

  // `POST /v2/user/delete` takes a signed login. A social wallet whose key is
  // missing is skipped by the 401 re-sign, so the delete only failed with
  // "Couldn’t delete your profile". The tap proves the wallet first, which is
  // where that wallet gets its re-login.
  group('the wallet proof before the delete', () {
    const viewer = 'SOCIAL_VIEWER';
    late _MockSession session;
    late _MockApiV2 apiV2;

    setUp(() {
      session = _MockSession();
      apiV2 = _MockApiV2();
      if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
      if (sl.isRegistered<api.MallowApiV2Client>()) {
        sl.unregister<api.MallowApiV2Client>();
      }
      sl.registerSingleton<SessionManager>(session);
      sl.registerSingleton<api.MallowApiV2Client>(apiV2);

      when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));
      when(() => auth.currentAddress).thenReturn(viewer);
      when(
        () => auth.hasValidWalletSigForAny(any()),
      ).thenAnswer((_) async => false);
      when(() => session.sessionWalletForAddress(viewer)).thenReturn(
        const WalletInfo(
          id: 'w-social',
          address: viewer,
          name: 'Google Wallet',
          walletType: WalletType.social,
          chain: 'solana',
        ),
      );
    });

    tearDown(() {
      sl.unregister<SessionManager>();
      sl.unregister<api.MallowApiV2Client>();
    });

    setUpAll(() => registerFallbackValue(const <String>[]));

    testWidgets('a cancelled re-login deletes nothing and says why', (
      tester,
    ) async {
      when(() => auth.signAndVerifyForWallet(any(), any())).thenThrow(
        TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        ),
      );

      await pumpScreen(tester);
      await tester.tap(find.widgetWithText(MallowButton, 'Delete profile'));
      await tester.pump();
      await tester.pump();

      verify(() => auth.signAndVerifyForWallet('w-social', viewer)).called(1);
      verifyNever(() => apiV2.deleteUser());
      expect(find.text('Sign-in was cancelled'), findsOneWidget);
      expect(
        find.text('Couldn’t delete your profile. Try again.'),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
