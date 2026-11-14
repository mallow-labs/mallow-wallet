import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/social_vault/widgets/legacy_social_notice.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockRepo extends Mock implements WalletRepository {}

Account _social(
  String id, {
  bool legacy = false,
  String? vaultId,
  String provider = 'google',
}) => Account(
  id: id,
  name: 'Account $id',
  kind: AccountKind.social,
  wallets: [
    WalletInfo(
      id: 'w-$id',
      address: 'addr-$id',
      name: 'Wallet',
      walletType: WalletType.social,
      chain: 'solana',
      socialProvider: provider,
      socialVaultId: vaultId,
      legacySocial: legacy,
      accountId: id,
    ),
  ],
);

/// Each wallet from the older Google or Apple sign-in is told once what the
/// mark on it means and how it is recovered now. The notice must reach every
/// such wallet, never a vault wallet, and never come back — and its shortcut
/// to the keys must not be a way past the gate in front of them.
void main() {
  group('legacySocialNoticesDue', () {
    final older = _social('older', legacy: true);
    final vault = _social('vault', vaultId: 'vault-1');
    final backupDeleted = _social('deleted');
    const seed = Account(id: 'seed', name: 'Account 01');

    test('lists only accounts from the older sign-in', () {
      expect(
        legacySocialNoticesDue([seed, vault, backupDeleted, older], const {}),
        [older],
      );
    });

    test('skips an account that was already told', () {
      final second = _social('second', legacy: true, provider: 'apple');
      expect(legacySocialNoticesDue([older, second], {'older'}), [second]);
      expect(
        legacySocialNoticesDue([older, second], {'older', 'second'}),
        isEmpty,
      );
    });

    test('a vault wallet is never due, told or not', () {
      expect(legacySocialNoticesDue([vault, backupDeleted], const {}), isEmpty);
    });
  });

  test('the message is the sentence, the recovery path and what to do', () {
    final message = legacySocialNoticeMessage('Google');
    expect(
      message,
      startsWith(
        'Older sign-in, run by Web3Auth: your Google account alone can open '
        'this wallet.',
      ),
    );
    expect(message, contains('older sign-in on the mallow website'));
    expect(message, contains('Save the wallet’s keys now'));
    // It never promises what only a vault wallet has.
    expect(message, isNot(contains('can never open')));
    expect(message, isNot(contains('backed up')));
    expect(message, isNot(contains('passkey')));
    expect(legacySocialNoticeMessage('Apple'), contains('your Apple account'));
  });

  group('maybeShowLegacySocialNotice', () {
    late _MockRepo repo;
    late PreferencesService prefs;
    late GoRouter router;
    final secretsExtras = <Object?>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await PreferencesService.create();
      repo = _MockRepo();
      sl
        ..registerSingleton<PreferencesService>(prefs)
        ..registerSingleton<WalletRepository>(repo);
      secretsExtras.clear();
      router = GoRouter(
        navigatorKey: AppRoutes.rootNavigatorKey,
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: AppRoutes.recoveryPhrase,
            builder: (_, state) {
              secretsExtras.add(state.extra);
              return const Scaffold(body: Text('secrets'));
            },
          ),
        ],
      );
    });

    tearDown(() async {
      router.dispose();
      await sl.reset();
    });

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
      );
      await tester.pumpAndSettle();
    }

    /// Starts the notice and settles on whatever it shows. The run itself
    /// ends only once its sheets are answered, so it comes back unawaited.
    Future<({Future<void> done})> start(WidgetTester tester) async {
      final done = maybeShowLegacySocialNotice();
      await tester.pumpAndSettle();
      // A sheet swallows taps until shortly after its entrance has settled.
      await tester.pump(const Duration(milliseconds: 200));
      return (done: done);
    }

    testWidgets('shows one sheet for a wallet from the older sign-in, and '
        'never again', (tester) async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _social('vault', vaultId: 'vault-1'),
          _social('older', legacy: true),
        ],
      );
      await pumpApp(tester);

      final first = (await start(tester)).done;
      expect(find.text('About your Google wallet'), findsOneWidget);
      expect(
        find.textContaining(
          'Older sign-in, run by Web3Auth: your Google account alone can '
          'open this wallet.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('mallow website'), findsOneWidget);
      // Recorded before the answer, so a killed app does not ask twice.
      expect(prefs.legacySocialNoticeShown, {'older'});

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await first;
      expect(find.text('About your Google wallet'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(secretsExtras, isEmpty);

      // The next unlock, or the next launch: nothing.
      await (await start(tester)).done;
      expect(find.text('About your Google wallet'), findsNothing);
    });

    testWidgets('a device with only vault wallets is shown nothing', (
      tester,
    ) async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [_social('vault', vaultId: 'vault-1'), _social('deleted')],
      );
      await pumpApp(tester);

      await (await start(tester)).done;
      expect(find.textContaining('Older sign-in'), findsNothing);
      expect(prefs.legacySocialNoticeShown, isEmpty);
    });

    testWidgets('Show secrets opens the secrets screen without the '
        'pre-authenticated flag, so it gates itself', (tester) async {
      when(
        () => repo.getAccountViews(),
      ).thenAnswer((_) async => [_social('older', legacy: true)]);
      await pumpApp(tester);

      await start(tester);
      await tester.tap(find.text('Show secrets'));
      await tester.pumpAndSettle();

      expect(find.text('secrets'), findsOneWidget);
      // `extra == true` is what the screen trusts as "already authenticated".
      expect(secretsExtras, [null]);
    });

    testWidgets('two such wallets are each told once, one after the other', (
      tester,
    ) async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _social('g', legacy: true),
          _social('a', legacy: true, provider: 'apple'),
        ],
      );
      await pumpApp(tester);

      final done = (await start(tester)).done;
      expect(find.text('About your Google wallet'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('About your Apple wallet'), findsOneWidget);
      expect(find.textContaining('your Apple account alone'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await done;

      expect(prefs.legacySocialNoticeShown, {'g', 'a'});
    });

    testWidgets('a failed lookup shows nothing and records nothing', (
      tester,
    ) async {
      when(() => repo.getAccountViews()).thenThrow(StateError('db'));
      await pumpApp(tester);

      await (await start(tester)).done;
      expect(find.textContaining('Older sign-in'), findsNothing);
      expect(prefs.legacySocialNoticeShown, isEmpty);
    });
  });
}
