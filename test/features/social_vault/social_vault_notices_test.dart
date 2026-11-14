import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_api.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/onboarding/widgets/social_vault_prompts.dart';
import 'package:mallow_wallet/features/social_vault/services/social_sign_in_routing.dart';
import 'package:mallow_wallet/features/social_vault/widgets/social_vault_notices.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/social_wallet_copy.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

class _MockVaults extends Mock implements SocialVaultService {}

class _MockStorage extends Mock implements SecureWalletStorage {}

class _MockSocialAuth extends Mock implements SocialAuthService {}

/// The app's sign-in state, with only what the notices read: whether the
/// app-lock setup of onboarding is behind the user.
class _FakeAuthState extends ChangeNotifier implements AuthStateNotifier {
  bool _done = false;

  @override
  bool get hasCompletedOnboarding => _done;

  void finishOnboarding() {
    _done = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _vaultId = 'vault-1';

// Midday UTC, so the date reads the same in any time zone the tests run in.
const _pending = api.SocialVaultPendingDeletion(
  requestedAt: '2026-11-10T12:00:00Z',
  appliesAt: '2026-11-17T12:00:00Z',
);

api.SocialVaultSlot _slot(String id, String label) => api.SocialVaultSlot(
  createdAt: '2026-11-10T12:00:00Z',
  slotId: id,
  kind: api.SocialVaultSlotKind.passkeyPrf,
  nonce: 'AAAA',
  wrappedKey: 'AAAA',
  label: label,
);

/// What the app shows for a vault after a status read or a sign-in: the
/// blocking warning while a deletion of the wallet backup is pending, and the
/// one-time notice for a sign-in key this device has not seen — and the
/// questions a sign-in asks before it creates a wallet or adds a key.
void main() {
  late _MockVaults vaults;
  late GoRouter router;
  final signInKeysExtras = <Object?>[];
  final secretsExtras = <Object?>[];
  const prompts = AppSocialVaultPrompts();

  setUp(() {
    vaults = _MockVaults();
    sl.registerSingleton<SocialVaultService>(vaults);
    when(
      () => vaults.unacknowledgedDeletion(any()),
    ).thenAnswer((_) async => null);
    when(() => vaults.unseenSlots(any())).thenAnswer((_) async => const []);
    when(() => vaults.acknowledgeSlots(any(), any())).thenAnswer((_) async {});
    when(
      () => vaults.acknowledgeDeletion(any(), any()),
    ).thenAnswer((_) async {});
    signInKeysExtras.clear();
    secretsExtras.clear();
    router = GoRouter(
      navigatorKey: AppRoutes.rootNavigatorKey,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        // Any other page of the app: where a navigation takes the user.
        GoRoute(
          path: '/elsewhere',
          builder: (_, _) => const Scaffold(body: Text('elsewhere')),
        ),
        GoRoute(
          path: AppRoutes.signInKeys,
          builder: (_, state) {
            signInKeysExtras.add(state.extra);
            return const Scaffold(body: Text('sign-in keys'));
          },
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
    SocialSignInRouting.instance.reset();
    await sl.reset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();
  }

  /// Starts [run] and settles on whatever it shows. It ends only once its
  /// sheets are answered, so the future comes back unawaited.
  Future<Future<T>> start<T>(
    WidgetTester tester,
    Future<T> Function() run,
  ) async {
    final done = run();
    await tester.pumpAndSettle();
    // A sheet swallows taps until shortly after its entrance has settled.
    await tester.pump(const Duration(milliseconds: 200));
    return done;
  }

  /// Lets a snack bar run out, so no timer outlives the test.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('a pending deletion', () {
    setUp(() {
      when(
        () => vaults.unacknowledgedDeletion(_vaultId),
      ).thenAnswer((_) async => _pending);
    });

    testWidgets('is a full-screen warning that cannot be backed out of', (
      tester,
    ) async {
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      expect(
        find.text(
          'Your wallet backup is scheduled for deletion on November 17, '
          '2026. If you did not ask for this, keep it.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(MallowButton, 'Keep my backup'), findsOne);
      expect(
        find.widgetWithText(MallowButton, 'It was me, continue'),
        findsOne,
      );
      expect(find.text('home'), findsNothing, reason: 'it covers the app');

      // The system back gesture does not dismiss it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      verifyNever(() => vaults.cancelDeletion(any()));
      verifyNever(() => vaults.acknowledgeDeletion(any(), any()));
    });

    testWidgets('"Keep my backup" cancels the request with a signed write', (
      tester,
    ) async {
      when(() => vaults.cancelDeletion(_vaultId)).thenAnswer(
        (_) async => const api.SocialVault(
          vaultId: _vaultId,
          revision: 5,
          payloadNonce: '',
          payloadCiphertext: '',
          vaultPublicKey: 'PK',
          slots: [],
          pendingDeletion: null,
          createdAt: '',
          updatedAt: '',
        ),
      );
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Keep my backup'));
      await tester.pumpAndSettle();
      await done;

      verify(() => vaults.cancelDeletion(_vaultId)).called(1);
      verifyNever(() => vaults.acknowledgeDeletion(any(), any()));
      expect(find.byType(PendingDeletionWarningScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('"It was me, continue" is remembered for that request', (
      tester,
    ) async {
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('It was me, continue'));
      await tester.pumpAndSettle();
      await done;

      verify(
        () => vaults.acknowledgeDeletion(_vaultId, _pending.requestedAt),
      ).called(1);
      verifyNever(() => vaults.cancelDeletion(any()));
      expect(find.byType(PendingDeletionWarningScreen), findsNothing);
    });

    testWidgets('an "It was me, continue" that cannot be saved says so and '
        'leaves both buttons working', (tester) async {
      var storeFails = true;
      when(() => vaults.acknowledgeDeletion(any(), any())).thenAnswer((
        _,
      ) async {
        if (storeFails) throw StateError('keystore');
      });
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('It was me, continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Could not save your answer. Try again.'),
        findsOneWidget,
      );
      // Still up, and not stuck: the screen has no other way out.
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      final keep = tester.widget<MallowButton>(
        find.widgetWithText(MallowButton, 'Keep my backup'),
      );
      final itWasMe = tester.widget<MallowButton>(
        find.widgetWithText(MallowButton, 'It was me, continue'),
      );
      expect(keep.isLoading, isFalse);
      expect(itWasMe.enabled, isTrue);

      storeFails = false;
      await tester.tap(find.text('It was me, continue'));
      await tester.pumpAndSettle();
      await done;
      expect(find.byType(PendingDeletionWarningScreen), findsNothing);
      await drain(tester);
    });

    testWidgets('a cancel refused for the clock says so and keeps the '
        'warning up', (tester) async {
      when(() => vaults.cancelDeletion(_vaultId)).thenThrow(
        const SocialVaultApiException(
          SocialVaultApiError.staleTimestamp,
          status: 401,
        ),
      );
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Keep my backup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(socialVaultClockMessage), findsOneWidget);
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a cancel that cannot be sent keeps the warning up', (
      tester,
    ) async {
      when(() => vaults.cancelDeletion(_vaultId)).thenThrow(
        const SocialVaultApiException(SocialVaultApiError.unavailable),
      );
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Keep my backup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Could not keep your backup'), findsOneWidget);
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a device that cannot sign for the vault says to sign in '
        'again', (tester) async {
      when(
        () => vaults.cancelDeletion(_vaultId),
      ).thenThrow(const SocialVaultStaleKeyException(_vaultId));
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Keep my backup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Sign in to the wallet again'), findsOne);
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      await drain(tester);
    });
  });

  group('a sign-in key this device has not seen', () {
    setUp(() {
      when(
        () => vaults.unseenSlots(_vaultId),
      ).thenAnswer((_) async => [_slot('k9', 'Passkey · Pixel')]);
    });

    testWidgets('is announced with its date and label', (tester) async {
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      expect(find.text('New sign-in key'), findsOneWidget);
      expect(
        find.text(
          'A sign-in key was added on November 10, 2026: Passkey · Pixel',
        ),
        findsOneWidget,
      );
      expect(find.text('Review sign-in keys'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      // Not seen until the user answers.
      verifyNever(() => vaults.acknowledgeSlots(any(), any()));
    });

    testWidgets('"Dismiss" marks it seen and goes nowhere', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;

      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9'])).called(1);
      expect(find.text('home'), findsOneWidget);
      expect(signInKeysExtras, isEmpty);
    });

    testWidgets('"Review sign-in keys" marks it seen and opens the screen, '
        'which gates itself', (tester) async {
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tap(find.text('Review sign-in keys'));
      await tester.pumpAndSettle();

      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9'])).called(1);
      expect(find.text('sign-in keys'), findsOneWidget);
      // `extra == true` is what the screen trusts as "already authenticated".
      expect(signInKeysExtras, [null]);
    });

    testWidgets('several keys are one notice, a line each', (tester) async {
      when(() => vaults.unseenSlots(_vaultId)).thenAnswer(
        (_) async => [_slot('k9', 'Passkey · Pixel'), _slot('k10', '')],
      );
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      expect(find.text('New sign-in keys'), findsOneWidget);
      expect(
        find.text(
          'A sign-in key was added on November 10, 2026: Passkey · Pixel',
        ),
        findsOneWidget,
      );
      expect(
        find.text('A sign-in key was added on November 10, 2026: Passkey'),
        findsOneWidget,
      );
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;
      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9', 'k10'])).called(1);
    });

    testWidgets('a tap outside the sheet is a dismissal: seen', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await done;

      expect(find.text('New sign-in key'), findsNothing);
      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9'])).called(1);
      expect(signInKeysExtras, isEmpty);
    });

    testWidgets('the back gesture is a dismissal: seen', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await done;

      expect(find.text('New sign-in key'), findsNothing);
      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9'])).called(1);
    });

    // What used to happen after every sign-in: the notice went up on the
    // screen the sign-in started from, the app replaced that screen about a
    // second later, and the notice it took down was recorded as seen.
    testWidgets('a notice the app takes down with the page under it is not '
        'seen', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));
      expect(find.text('New sign-in key'), findsOneWidget);

      router.go('/elsewhere');
      await tester.pumpAndSettle();
      await done;

      expect(find.text('elsewhere'), findsOneWidget);
      expect(find.text('New sign-in key'), findsNothing);
      verifyNever(() => vaults.acknowledgeSlots(any(), any()));
      expect(signInKeysExtras, isEmpty);
    });

    testWidgets('a deletion warning the app takes down is not answered, and '
        'the keys after it stay unseen', (tester) async {
      when(
        () => vaults.unacknowledgedDeletion(_vaultId),
      ).thenAnswer((_) async => _pending);
      await pumpApp(tester);
      final done = await start(tester, () => prompts.reviewVault(_vaultId));
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);

      router.go('/elsewhere');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(PendingDeletionWarningScreen), findsNothing);
      verifyNever(() => vaults.acknowledgeDeletion(any(), any()));
      verifyNever(() => vaults.cancelDeletion(any()));
      // The key notice that follows is on a page that stays: answer it.
      expect(find.text('New sign-in key'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;
    });

    testWidgets('a name with line breaks and direction controls is drawn as '
        'one plain line', (tester) async {
      when(() => vaults.unseenSlots(_vaultId)).thenAnswer(
        (_) async => [_slot('k9', 'Work\n\u202Ephone\u2066\t laptop\u0007')],
      );
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      expect(
        find.text(
          'A sign-in key was added on November 10, 2026: Work phone laptop',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a long name is cut, so the notice keeps its buttons', (
      tester,
    ) async {
      when(
        () => vaults.unseenSlots(_vaultId),
      ).thenAnswer((_) async => [_slot('k9', 'x' * 64)]);
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      expect(
        find.text('A sign-in key was added on November 10, 2026: ${'x' * 40}…'),
        findsOneWidget,
      );
      final line = tester.widget<Text>(find.textContaining('A sign-in key'));
      expect(line.maxLines, 2);
      expect(line.overflow, TextOverflow.ellipsis);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('comes after the deletion warning, not instead of it', (
      tester,
    ) async {
      when(
        () => vaults.unacknowledgedDeletion(_vaultId),
      ).thenAnswer((_) async => _pending);
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));

      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
      expect(find.text('New sign-in key'), findsNothing);
      await tester.tap(find.text('It was me, continue'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New sign-in key'), findsOneWidget);
    });
  });

  // A sign-in ends by taking the user somewhere: Home, or the app-lock setup
  // of onboarding. The app shell says when it starts on that and when the
  // navigation has been issued; the notices wait in between.
  group('after a sign-in', () {
    setUp(() {
      when(
        () => vaults.unseenSlots(_vaultId),
      ).thenAnswer((_) async => [_slot('k9', 'Passkey · Pixel')]);
    });

    testWidgets('the notices wait for the navigation, and go up on the page '
        'it lands on', (tester) async {
      await pumpApp(tester);
      final routed = SocialSignInRouting.instance.begin();
      final done = prompts.reviewVault(_vaultId);

      // The wallet switch and the login: about a second.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('New sign-in key'), findsNothing);

      router.go('/elsewhere');
      routed();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('elsewhere'), findsOneWidget);
      expect(find.text('New sign-in key'), findsOneWidget);
      verifyNever(() => vaults.acknowledgeSlots(any(), any()));

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;
      verify(() => vaults.acknowledgeSlots(_vaultId, ['k9'])).called(1);
    });

    testWidgets('a result published a moment before the notice asks is '
        'still waited for', (tester) async {
      await pumpApp(tester);
      // As the sign-in does it: the result goes out on a stream, whose
      // listener (the app shell) runs on a later microtask, and the notice
      // is asked for straight away.
      final results = StreamController<int>.broadcast();
      addTearDown(results.close);
      VoidCallback? routed;
      results.stream.listen(
        (_) => routed = SocialSignInRouting.instance.begin(),
      );
      results.add(1);
      final done = prompts.reviewVault(_vaultId);

      await tester.pump(const Duration(seconds: 1));
      expect(routed, isNotNull);
      expect(find.text('New sign-in key'), findsNothing);

      routed!();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New sign-in key'), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;
    });

    testWidgets('a routing that fails still lets the notices through', (
      tester,
    ) async {
      await pumpApp(tester);
      final routed = SocialSignInRouting.instance.begin();
      await start(tester, () => prompts.reviewVault(_vaultId));
      expect(find.text('New sign-in key'), findsNothing);

      // What the app shell does in its `finally`, with no navigation issued.
      routed();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New sign-in key'), findsOneWidget);
    });

    testWidgets('a routing that never ends does not hold a notice for '
        'good', (tester) async {
      await pumpApp(tester);
      SocialSignInRouting.instance.begin();
      final done = prompts.reviewVault(_vaultId);

      await tester.pump(
        SocialSignInRouting.settleTimeout - const Duration(seconds: 1),
      );
      expect(find.text('New sign-in key'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('New sign-in key'), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await done;
    });

    testWidgets('with no sign-in being routed for, nothing is waited for', (
      tester,
    ) async {
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));
      expect(find.text('New sign-in key'), findsOneWidget);
    });
  });

  // Onboarding ends with the app-lock setup, which the user must finish.
  // Nothing is put in its way, and nothing offers a way round it.
  group('while the app-lock setup of onboarding is still ahead', () {
    late _FakeAuthState auth;
    late _MockSocialAuth socialAuth;

    setUp(() {
      auth = _FakeAuthState();
      socialAuth = _MockSocialAuth();
      when(() => socialAuth.checkVaults()).thenAnswer((_) async {});
      sl
        ..registerSingleton<AuthStateNotifier>(auth)
        ..registerSingleton<SocialAuthService>(socialAuth);
      when(
        () => vaults.unacknowledgedDeletion(_vaultId),
      ).thenAnswer((_) async => _pending);
      when(
        () => vaults.unseenSlots(_vaultId),
      ).thenAnswer((_) async => [_slot('k9', 'Passkey · Pixel')]);
    });

    testWidgets('no notice is shown and nothing is recorded as seen', (
      tester,
    ) async {
      await pumpApp(tester);
      // Standing in for the app-lock setup.
      router.go('/elsewhere');
      await tester.pumpAndSettle();

      await (await start(tester, () => prompts.reviewVault(_vaultId)));

      expect(find.text('elsewhere'), findsOneWidget);
      expect(find.byType(PendingDeletionWarningScreen), findsNothing);
      expect(find.text('New sign-in key'), findsNothing);
      verifyNever(() => vaults.acknowledgeSlots(any(), any()));
      verifyNever(() => vaults.acknowledgeDeletion(any(), any()));
      expect(signInKeysExtras, isEmpty);
      verifyNever(() => socialAuth.checkVaults());
    });

    testWidgets('the check runs again, once, when onboarding is done and '
        'Home is on screen', (tester) async {
      await pumpApp(tester);
      router.go('/elsewhere');
      await tester.pumpAndSettle();
      // Asked twice during onboarding (a sign-in, then a status check).
      await (await start(tester, () => prompts.reviewVault(_vaultId)));
      await (await start(tester, () => prompts.reviewVault(_vaultId)));

      // The lock is set, but the user is still on the last onboarding step.
      auth.finishOnboarding();
      await tester.pumpAndSettle();
      verifyNever(() => socialAuth.checkVaults());

      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      verify(() => socialAuth.checkVaults()).called(1);

      // Only that once: later visits to Home ask nothing.
      router.go('/elsewhere');
      await tester.pumpAndSettle();
      router.go(AppRoutes.home);
      await tester.pumpAndSettle();
      verifyNever(() => socialAuth.checkVaults());
    });

    testWidgets('once onboarding is done, the notices are shown as usual', (
      tester,
    ) async {
      auth.finishOnboarding();
      await pumpApp(tester);
      await start(tester, () => prompts.reviewVault(_vaultId));
      expect(find.byType(PendingDeletionWarningScreen), findsOneWidget);
    });
  });

  testWidgets('a backup step that failed after sign-in says what finishes '
      'it: the sign-in, again', (tester) async {
    await pumpApp(tester);
    await prompts.backupIncomplete(provider: 'apple');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text(
        'Your Apple wallet is ready, but its backup did not finish. Sign in '
        'with the same Apple account again to finish it.',
      ),
      findsOneWidget,
    );
    // The Sign-in keys screen has no retry for a wallet in this state.
    expect(find.textContaining('Sign-in keys'), findsNothing);
    await drain(tester);
  });

  // Said once to a device whose sign-in key was replaced from another one.
  group('a sign-in key replaced on another device', () {
    testWidgets('is said with what still works and what to do', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.signInKeyReplaced(provider: 'google'),
      );

      expect(find.text('Sign in again to manage your backup'), findsOneWidget);
      expect(find.text(signInKeyReplacedMessage('Google')), findsOneWidget);
      // One button: there is nothing to choose.
      expect(find.byType(MallowButton), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await done, isTrue, reason: 'seen');
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('a tap outside it counts as seen', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.signInKeyReplaced(provider: 'apple'),
      );
      expect(find.textContaining('your Apple wallet'), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(await done, isTrue);
    });

    testWidgets('taken down by the app, it is not seen', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.signInKeyReplaced(provider: 'google'),
      );

      router.go('/elsewhere');
      await tester.pumpAndSettle();
      expect(await done, isFalse);
    });

    testWidgets('with no screen to show it on, it is not seen', (tester) async {
      // No app pumped: the root navigator has no context.
      expect(await prompts.signInKeyReplaced(provider: 'google'), isFalse);
    });
  });

  // Shown once, after the backend has said twice, a day apart, that a
  // wallet's vault does not exist and the wallet was unlinked from it.
  group('a wallet whose backup is no longer stored', () {
    testWidgets('is told so, with what that means', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.backupNoLongerStored(provider: 'google'),
      );

      expect(find.text('About your Google wallet'), findsOneWidget);
      expect(
        find.text(
          'This wallet’s backup is no longer stored with mallow. The wallet '
          'stays on this phone: its recovery phrase is now the only backup.',
        ),
        findsOneWidget,
      );
      expect(find.text('View recovery phrase'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(await done, isTrue, reason: 'seen');
      expect(find.text('home'), findsOneWidget);
      expect(secretsExtras, isEmpty);
    });

    testWidgets('"View recovery phrase" opens Show secrets without the '
        'pre-authenticated flag, so it gates itself', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.backupNoLongerStored(provider: 'apple'),
      );

      expect(find.text('About your Apple wallet'), findsOneWidget);
      await tester.tap(find.text('View recovery phrase'));
      await tester.pumpAndSettle();

      expect(await done, isTrue);
      expect(find.text('secrets'), findsOneWidget);
      // `extra == true` is what the screen trusts as "already authenticated".
      expect(secretsExtras, [null]);
    });

    testWidgets('a dismissed sheet still counts as seen', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.backupNoLongerStored(provider: 'google'),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await done, isTrue);
    });

    testWidgets('with no screen to show it on, it is not seen', (tester) async {
      // No app pumped: the root navigator has no context.
      expect(await prompts.backupNoLongerStored(provider: 'google'), isFalse);
    });

    testWidgets('taken down by the app, it is not seen: it is said again', (
      tester,
    ) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.backupNoLongerStored(provider: 'google'),
      );
      expect(find.text('About your Google wallet'), findsOneWidget);

      router.go('/elsewhere');
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      expect(secretsExtras, isEmpty);
    });
  });

  // Offered once after this phone's backup held a sign-in key without
  // end-to-end encryption. "Dismiss" drops the advice for good.
  group('the offer to replace sign-in keys', () {
    testWidgets('"Replace sign-in keys" opens the screen, which gates '
        'itself', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, prompts.offerKeyReplacement);
      expect(find.text(backupWasUnprotectedTitle), findsOneWidget);
      expect(find.text(backupWasUnprotectedMessage), findsOneWidget);

      await tester.tap(find.text(replaceSignInKeysLabel));
      await tester.pumpAndSettle();
      expect(await done, isTrue);
      expect(signInKeysExtras, [null]);
    });

    testWidgets('"Dismiss", a tap outside and the back gesture are the '
        'user’s no', (tester) async {
      await pumpApp(tester);
      var done = await start(tester, prompts.offerKeyReplacement);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(await done, isFalse);

      done = await start(tester, prompts.offerKeyReplacement);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(await done, isFalse);

      done = await start(tester, prompts.offerKeyReplacement);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      expect(signInKeysExtras, isEmpty);
    });

    testWidgets('taken down by the app, it was not answered: it is offered '
        'again', (tester) async {
      await pumpApp(tester);
      final done = await start(tester, prompts.offerKeyReplacement);
      expect(find.text(backupWasUnprotectedTitle), findsOneWidget);

      router.go('/elsewhere');
      await tester.pumpAndSettle();
      expect(await done, isNull);
      expect(signInKeysExtras, isEmpty);
    });

    testWidgets('with no screen to show it on, it was not offered', (
      tester,
    ) async {
      expect(await prompts.offerKeyReplacement(), isNull);
    });
  });

  testWidgets('a vault with nothing pending and nothing new shows nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    await (await start(tester, () => prompts.reviewVault(_vaultId)));
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(PendingDeletionWarningScreen), findsNothing);
    verifyNever(() => vaults.acknowledgeSlots(any(), any()));
  });

  test('a timestamp that does not parse is shown as it came', () {
    expect(socialVaultDate('soon'), 'soon');
    expect(socialVaultDate('2026-11-17T12:00:00Z'), 'November 17, 2026');
  });

  group('before a wallet is created', () {
    testWidgets('the question names the account', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.confirmCreate(
          provider: 'google',
          emailHint: 'new@example.test',
        ),
      );

      expect(
        find.text('No mallow wallet found for new@example.test. Create one?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      expect(await done, SocialVaultCreateChoice.create);
    });

    testWidgets('names the provider when the account shares no email', (
      tester,
    ) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.confirmCreate(provider: 'apple'),
      );

      expect(
        find.text('No mallow wallet found for your Apple account. Create one?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await done, SocialVaultCreateChoice.cancel);
    });

    testWidgets('a dismissed sheet is a no', (tester) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.confirmCreate(provider: 'google'),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await done, SocialVaultCreateChoice.cancel);
    });

    testWidgets('warns instead when this device already holds a vault wallet '
        'for the provider, and leads with "Use another account"', (
      tester,
    ) async {
      await pumpApp(tester);
      final done = await start(
        tester,
        () => prompts.confirmCreate(
          provider: 'google',
          emailHint: 'other@example.test',
          hasWalletHere: true,
          walletAccountEmail: 'owner@example.test',
        ),
      );

      expect(find.text('This account has no wallet'), findsOneWidget);
      expect(
        find.textContaining(
          'other@example.test has no mallow wallet. The Google wallet on '
          'this phone belongs to owner@example.test.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Create one?'), findsNothing);
      final buttons = tester
          .widgetList<MallowButton>(find.byType(MallowButton))
          .toList();
      expect(buttons.first.label, 'Use another account');
      expect(buttons.first.variant, MallowButtonVariant.primary);
      expect(buttons.map((b) => b.label), contains('Create a new wallet'));

      await tester.tap(find.text('Use another account'));
      await tester.pumpAndSettle();
      expect(await done, SocialVaultCreateChoice.useAnotherAccount);
    });
  });

  testWidgets('the wrong-account question names the account the wallet '
      'needs', (tester) async {
    await pumpApp(tester);
    final done = await start(
      tester,
      () => prompts.wrongAccount(
        provider: 'google',
        expectedEmail: 'owner@example.test',
        signedInEmail: 'other@example.test',
      ),
    );

    expect(
      find.text(
        'This wallet belongs to owner@example.test. You signed in as '
        'other@example.test. Sign in with that account to use it. Nothing '
        'was changed.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Use another account'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);
  });

  group('re-authentication before a key is added', () {
    late _MockStorage storage;

    setUp(() {
      storage = _MockStorage();
      sl.registerSingleton<SecureWalletStorage>(storage);
    });

    testWidgets('is the app\'s own gate: an unreadable lock is a no', (
      tester,
    ) async {
      when(() => storage.loadAuthFactors()).thenThrow(StateError('keystore'));
      await pumpApp(tester);
      expect(await prompts.reauthenticate(), isFalse);
    });

    testWidgets('passes where the gate passes', (tester) async {
      when(
        () => storage.loadAuthFactors(),
      ).thenAnswer((_) async => (hasPin: false, biometricEnabled: false));
      await pumpApp(tester);
      expect(await prompts.reauthenticate(), isTrue);
    });

    testWidgets('with no screen to ask on, it is a no', (tester) async {
      // No app pumped: the root navigator has no context.
      expect(await prompts.reauthenticate(), isFalse);
      expect(
        await prompts.confirmCreate(provider: 'google'),
        SocialVaultCreateChoice.cancel,
      );
    });
  });
}
