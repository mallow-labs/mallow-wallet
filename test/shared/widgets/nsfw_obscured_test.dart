import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_toggle.dart';
import 'package:mallow_wallet/shared/widgets/nsfw_obscured.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockSessionManager extends Mock implements SessionManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAuthService authService;
  late PreferencesService prefs;

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  /// [warningShown] pre-acknowledges the one-time sheet so reveal tests
  /// don't trip over it; the sheet test flips it off explicitly.
  Future<void> setUpServices({
    bool showNsfw = false,
    bool warningShown = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref_show_nsfw': showNsfw,
      'pref_nsfw_warning_shown': warningShown,
    });
    prefs = await PreferencesService.create();
    authService = _MockAuthService();
    when(() => authService.currentUser).thenReturn(null);
    // Account session: the setting stays device-local (no /v1/showNsfw push).
    final sessionManager = _MockSessionManager();
    when(() => sessionManager.isProfileMode).thenReturn(false);
    register<PreferencesService>(prefs);
    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
  }

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<PreferencesService>();
    drop<AuthService>();
    drop<SessionManager>();
  });

  Widget host({required bool nsfw, double width = 100, String? contentId}) {
    return MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: width,
            child: NsfwObscured(
              nsfw: nsfw,
              contentId: contentId,
              child: const ColoredBox(color: Colors.green),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('unflagged artwork renders without any overlay', (tester) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: false));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('unflagged artwork builds without PreferencesService — call '
      'sites wrap unconditionally, so an unflagged one must not depend on '
      'the service locator', (tester) async {
    // Deliberately no setUpServices(): nothing is registered.
    expect(sl.isRegistered<PreferencesService>(), isFalse);
    await tester.pumpWidget(host(nsfw: false));
    expect(tester.takeException(), isNull);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('a widget whose flag flips false → true blurs on the flip — '
      'the deferred lookup must not strand the overlay', (tester) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: false, contentId: 'artwork-a'));
    expect(find.byType(BackdropFilter), findsNothing);

    // Same slot, same artwork, now flagged (e.g. a moderation update landed).
    await tester.pumpWidget(host(nsfw: true, contentId: 'artwork-a'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);

    // The prefs subscription must be live too: flipping the setting on
    // un-blurs without a parent rebuild.
    await prefs.setShowNsfw(true);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('flagged artwork is blurred until revealed; a compact tile '
      'reveals on tap', (tester) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: true));
    expect(find.byType(BackdropFilter), findsOneWidget);

    // Tap anywhere on the compact overlay = reveal (one-off peek).
    await tester.tap(find.byType(NsfwObscured));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('flagged artwork is not blurred when show-NSFW is on, and '
      're-blurs when the setting turns off', (tester) async {
    await setUpServices(showNsfw: true);
    await tester.pumpWidget(host(nsfw: true));
    expect(find.byType(BackdropFilter), findsNothing);

    // Switching the setting off must re-blur — otherwise flipping the
    // preference would leave already-visible NSFW artwork exposed.
    await prefs.setShowNsfw(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('wide overlay reveals via the button, not the scrim — a '
      'blurred surface must not be tappable-through', (tester) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: true, width: 320));
    expect(find.text('NSFW'), findsOneWidget);

    // Tapping the scrim (not the button) is absorbed and does NOT reveal.
    await tester.tapAt(tester.getTopLeft(find.byType(NsfwObscured)));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.tap(find.text('Reveal artwork'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('a recycled slot re-blurs when contentId swaps — a prior '
      'reveal must not leak onto a different artwork', (tester) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: true, contentId: 'artwork-a'));
    expect(find.byType(BackdropFilter), findsOneWidget);

    // Reveal artwork A (compact tile: tap anywhere).
    await tester.tap(find.byType(NsfwObscured));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);

    // The keyless slot now hosts a *different* NSFW artwork (e.g. after a
    // refresh/filter/pagination). Widget.canUpdate reuses the same State, so
    // without the contentId reset artwork B would render unblurred.
    await tester.pumpWidget(host(nsfw: true, contentId: 'artwork-b'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('a plain rebuild with the same contentId keeps the reveal — '
      'in-place updates must not re-blur the artwork the user peeked', (
    tester,
  ) async {
    await setUpServices();
    await tester.pumpWidget(host(nsfw: true, contentId: 'artwork-a'));

    await tester.tap(find.byType(NsfwObscured));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);

    // Same artwork, rebuilt (e.g. parent setState). The peek must survive.
    await tester.pumpWidget(host(nsfw: true, contentId: 'artwork-a'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('moderation-locked account cannot reveal', (tester) async {
    await setUpServices();
    when(
      () => authService.currentUser,
    ).thenReturn(const api.User(disableNsfwSetting: true));
    await tester.pumpWidget(host(nsfw: true));

    await tester.tap(find.byType(NsfwObscured));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('first reveal opens the one-time warning sheet and marks it '
      'acknowledged', (tester) async {
    await setUpServices(warningShown: false);
    await tester.pumpWidget(host(nsfw: true));

    await tester.tap(find.byType(NsfwObscured));
    await tester.pumpAndSettle();
    expect(find.text('NSFW settings'), findsOneWidget);
    expect(prefs.nsfwWarningShown, isTrue);

    // The sheet's toggle flips the global setting (device-local here — no
    // profile session is registered). Let the sheet's entrance tap guard
    // disarm before tapping.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byType(MallowToggle));
    await tester.pumpAndSettle();
    expect(prefs.showNsfw, isTrue);
  });
}
