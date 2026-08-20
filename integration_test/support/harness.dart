// Shared E2E harness: app bootstrap, state reset, in-process restart, and
// the bounded-pump driving primitives every flow file uses.
//
// Import the barrel instead of this file directly:
//
//     import 'support/e2e.dart';
//
// Two rules that are not style preferences, they are why this file exists:
//
//  1. NEVER call `pumpAndSettle`. The welcome screen runs a perpetual
//     three_js ring animation, so the frame scheduler never goes idle and
//     `pumpAndSettle` blocks until the test times out. Everything here drives
//     with bounded `pump()` loops instead.
//  2. Bundle many cases into ONE file. `flutter test
//     integration_test/` does NOT amortize the build across the directory: it
//     re-runs `assembleDebug`, uninstalls the app, reinstalls it and cold-boots
//     it FOR EVERY FILE. Measured on this emulator: ~34 s of pure overhead per
//     file, against ~2-13 s of actual test work. The CI job has a fixed
//     45-minute timeout and cannot be sharded, so a file-per-case layout spends
//     the whole budget on process startup. Use `restartApp` to isolate cases
//     inside one file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import 'package:mallow_wallet/app.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/router/menu_drawer_controller.dart';
import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/features/home/widgets/drawer_signal.dart';
import 'package:mallow_wallet/features/onboarding/screens/biometric_setup_screen.dart';
import 'package:mallow_wallet/features/onboarding/screens/pin_setup_screen.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';
import 'package:mallow_wallet/shared/widgets/custom_number_pad.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

/// Boots the app graph the way `main()` does, minus everything an offline E2E
/// run must not touch: Firebase (no real google-services.json in the sandbox),
/// Sentry, analytics init, and the push side effects. Backend URLs arrive via
/// `--dart-define`, so there is no config to load from disk.
///
/// Idempotent. Calling it twice is a no-op, because `configureDependencies()`
/// throws on a second registration and several `testWidgets` in one file share
/// one process. Use [restartApp] when you want a genuinely fresh graph.
Future<void> bootstrapApp() async {
  if (sl.isRegistered<WalletRepository>()) return;

  GoogleFonts.config.allowRuntimeFetching = false;

  // `main()` resolves the device zone over a method channel; here we only
  // load the database and leave `tz.local` at UTC. Deterministic, and it stops
  // any date formatter that reaches for `tz.local` from throwing
  // LocationNotFoundException mid-flow.
  tz_data.initializeTimeZones();

  await configureDependencies();
}

/// Wipes every trace of a previous test from the device, so the next boot
/// lands on the Welcome screen regardless of what ran before.
///
/// This is what makes a file order-independent, and what keeps case 2 in a
/// file from inheriting case 1's wallet, PIN and session.
///
/// Measured note on the cross-FILE half of that: `flutter test` currently
/// uninstalls the app after each file (`--uninstall` defaults to true in
/// `IntegrationTestDevice.kill()`), so files already start from a fresh
/// install today. That is a flutter_tools default, not a guarantee —
/// `--no-uninstall` flips it — and it does nothing for case-to-case isolation
/// inside one file. Call this anyway.
///
/// Four stores persist, and all four must go:
///   * `flutter_secure_storage` (EncryptedSharedPreferences on Android) —
///     PIN hash, tokens, selected wallet, onboarding flag, account graph;
///   * the native mnemonic vault (`art.mallow.wallet/mnemonic_vault`,
///     AndroidKeystore-encrypted) — mnemonics and imported private keys;
///   * `SharedPreferences` — every user preference plus the account counter;
///   * the encrypted Drift database at `<appDocs>/mallow.sqlite` — seed
///     phrases, accounts, wallets, and every cache table.
///
/// It runs AFTER `configureDependencies()`, not before, and delegates to the
/// app's own factory reset (`WalletRepository.resetAll`, which backs
/// Settings -> "Reset app"). Doing it pre-DI from raw plugin APIs is not
/// safe: a bare `FlutterSecureStorage.deleteAll()` also drops
/// `mallow_db_encryption_key`, and the *existing* `mallow.sqlite` file is then
/// unopenable with the freshly generated key. Going through `resetAll` also
/// means the per-seed vault entries are deleted by id — ids that only the
/// database can enumerate.
///
/// The DB encryption key and the sqlite file itself survive on purpose; every
/// row inside is deleted, which is what "fresh install" means to the app.
Future<void> resetAppState() async {
  await bootstrapApp();
  await sl<WalletRepository>().resetAll();
}

/// Puts the app's TOP-LEVEL STATICS back where a cold process would start
/// them.
///
/// [restartApp] disposes a widget tree; it does not restart a process. Every
/// `static` in `lib/` therefore survives from case to case, and three of them
/// are load-bearing for navigation:
///
///  * `NavBarState.selectedTab` / `.activeTab` — a `ValueNotifier` does not
///    notify on an unchanged write, so a leaked `selectedTab` makes the first
///    tap on that tab a silent no-op; and a leaked `activeTab` makes
///    `_TabNavigatorState.initState` write a CHANGED value while the router is
///    mid-build, tripping "setState() during build" in the persistent nav bar.
///  * `NavBarState.visible` + its private `_showRefCount` — driven by
///    `requestShow`/`releaseShow` from `TabNavigator`'s RouteAware callbacks.
///    The refcount is private, so it is wound down through the public
///    [NavBarState.releaseShow] rather than assigned; the bounded loop is a
///    deliberate over-release (the count can only ever be a small number of
///    mounted TabNavigators).
///  * `DrawerSignal.*` — one-shot flags consumed by `TabNavigator`. A case
///    that sets one and never reaches the tab shell leaves the NEXT case's
///    Home opening the account drawer on its own.
///
/// NOT reset, because it cannot be: `ActionMenu._isOpen` is library-private
/// and has no reset seam. [restartApp] instead pops the menu's route through
/// the real navigator before the tree goes away, which is what clears the flag
/// (`whenComplete` on the popped route). See the note there.
void resetAppStatics() {
  NavBarState.selectedTab.value = MallowNavTab.home;
  NavBarState.activeTab.value = MallowNavTab.home;
  NavBarState.offset.value = 0.0;
  for (var i = 0; i < 8; i++) {
    NavBarState.releaseShow();
  }
  NavBarState.visible.value = false;
  DrawerSignal.showAccountsOnNextOpen = false;
  DrawerSignal.reloadDrawerOnReturn = false;
}

/// Pops every transient overlay route (action menu, sheets, dialogs) through
/// the REAL navigator, so their completion callbacks run before the tree is
/// disposed.
///
/// `Route.dispose()` completes the route's *dispose* completer, never its
/// *popped* one (`navigator.dart`), so a `push(...).whenComplete(...)` handler
/// never fires when the tree is torn down underneath it. Two app statics are
/// stranded that way, and neither is reachable from a test:
///
///  * `ActionMenu._isOpen` stays true, and the next case's first FAB tap then
///    takes the "already open" branch and pops a page instead of opening the
///    menu;
///  * `LedgerConnectListener._isShowing` stays true, so the next Ledger
///    request is swallowed.
///
/// Popping only [PopupRoute]s is what makes this safe: go_router's pages are
/// `PageRoute`s and are left alone, while the action menu (a `PopupRoute`),
/// modal sheets (`ModalBottomSheetRoute`) and dialogs (`RawDialogRoute`) all
/// unwind the way a user dismissal would.
Future<void> _popTransientRoutes(WidgetTester tester) async {
  final navigator = AppRoutes.rootNavigatorKey.currentState;
  if (navigator == null) return;
  navigator.popUntil((route) => route is! PopupRoute);
  // Long enough for the exit transition to finish: the popped-future (and so
  // the `whenComplete` this exists for) is completed by the navigator when the
  // route's animation ends, not when `pop` is called. The menu's reverse
  // transition is 160 ms and a sheet's is ~250 ms.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Slides the account drawer shut and waits for the nav-bar offset it drives
/// to settle back at 0. A no-op when no drawer is open.
///
/// Driven through `MenuDrawerController.close`, the same callback the drawer's
/// own scrim tap uses, so the animation and every listener on it run exactly
/// as they would for a user.
Future<void> _closeAccountDrawer(WidgetTester tester) async {
  if (NavBarState.offset.value == 0.0) return;
  final controller = find.byType(MenuDrawerController);
  if (controller.evaluate().isNotEmpty) {
    tester.widget<MenuDrawerController>(controller.first).close();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (NavBarState.offset.value == 0.0) return;
    }
  }
  // No drawer in the tree, or it never settled: fall back to zeroing the
  // notifier while the tree is still live, which is at least safe to notify.
  NavBarState.offset.value = 0.0;
  await tester.pump(const Duration(milliseconds: 50));
}

/// The app-side errors this suite provokes that are NOT the behaviour under
/// test. Both are real, reported app bugs with no seam a test can reach, and
/// both land on whichever case the framework happens to be running rather than
/// on the one that caused them.
///
///  1. **Unguarded Firebase call.** `SettingsScreen._loadData` awaits
///     `PushNotificationService.isAuthorized()`, which resolves
///     `FirebaseMessaging.instance` with no try/catch. This suite deliberately
///     never calls `Firebase.initializeApp()` (see [bootstrapApp]), so the
///     future rejects with `[core/no-app]` and nothing catches it. Every
///     settings surface pre-empts it by turning the push preference off first
///     (`&&` short-circuits), so this entry covers the frames where that has
///     not happened yet.
///  2. **setState from dispose.** `_TabNavigatorState.dispose` assigns
///     `NavBarState.offset.value = 0.0`, and that `ValueNotifier` notifies the
///     persistent nav bar's `ValueListenableBuilder` synchronously while the
///     element tree is locked for unmount — "setState() or markNeedsBuild()
///     called when widget tree was locked". It fires on every `context.go`
///     that tears the tab shell down, and on a [restartApp] whose drawer was
///     left open UNDERNEATH a pushed route (a muted ticker, so the close
///     animation never completes and the offset is still non-zero when dispose
///     runs). Debug-only; it never reaches release.
const List<String> _knownAppLeaks = <String>[
  'No Firebase App',
  'widget tree was locked',
];

/// Takes the pending framework exception, swallowing it when it is one of the
/// [_knownAppLeaks] and RETHROWING anything else.
///
/// One allowlist, one drain: a per-file copy is how a suite ends up swallowing
/// a different set of errors on each screen, and the drain is the one helper
/// where being too permissive turns a red test green.
void drainKnownAppLeaks(WidgetTester tester) {
  final Object? leaked = tester.takeException();
  if (leaked == null) return;
  final text = '$leaked';
  if (_knownAppLeaks.any(text.contains)) return;
  throw leaked;
}

/// Tears the widget tree down, optionally wipes app state, rebuilds the DI
/// graph, and relaunches [MallowApp] — the closest thing to a process restart
/// available from inside a single `flutter test` invocation.
///
/// Call this at the top of EVERY `testWidgets` in a file. It is what makes the
/// "many cases per file" rule workable: `configureDependencies()` cannot be
/// called twice, and singletons such as `AuthStateNotifier` cache
/// wallet/onboarding state read at boot, so without a rebuilt graph case 2
/// inherits case 1's session.
///
/// Pass `wipe: false` to relaunch against the data the previous case left
/// behind — that is the "kill and reopen the app" scenario (PIN lock on
/// relaunch, session restore, persisted selections).
///
/// Returns once the first frame of the relaunched app has been pumped; the
/// caller still has to `pumpUntil` whatever screen it expects. Do not assume
/// the first screen you see is the final one: the app-lock overlay is driven
/// by an async `AppLockEvent.init` that reads the database, so a `wipe: false`
/// relaunch of a PIN-protected wallet renders Home first and drops
/// `LockScreen` over it a frame or two later. Always
/// `pumpUntil(tester, find.byType(LockScreen))` rather than sampling once.
Future<void> restartApp(WidgetTester tester, {bool wipe = true}) async {
  // Unwind sheets/menus through the real navigator BEFORE the tree goes, so
  // their `whenComplete` handlers run and the statics they own are released.
  await _popTransientRoutes(tester);

  // Also BEFORE the teardown, and for a different reason: close the account
  // drawer if one is open.
  //
  // `_TabNavigatorState.dispose` assigns `NavBarState.offset.value = 0.0`
  // (`tab_navigator.dart`), and a `ValueNotifier` only notifies on a CHANGED
  // value. So a case that ends with the drawer open — every case that reached
  // Settings through it, since pushing a route leaves the drawer open behind
  // it — makes that assignment mark the persistent nav bar's
  // `ValueListenableBuilder` dirty in the middle of the unmount walk, and the
  // framework throws "setState() or markNeedsBuild() called when widget tree
  // was locked", failing whichever case happens to be tearing down.
  //
  // Closing the drawer through the app's own `MenuDrawerController.close`
  // leaves the offset at 0 legitimately, so BOTH the animation listener and
  // `dispose` then write an unchanged value and neither notifies. Zeroing the
  // notifier directly is not enough — the drawer animation's listener writes
  // it straight back.
  //
  // The bug itself — a widget writing global state from `dispose` — is an APP
  // bug, reported and not fixed here.
  await _closeAccountDrawer(tester);

  // Dispose the old tree first: MallowApp's state holds a
  // WidgetsBindingObserver, several stream subscriptions and the deep-link
  // service, and leaving two live copies makes the next case's router race
  // the previous one's redirects.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 50));

  // Drain the known app leaks the teardown itself can raise — leak 2, the
  // setState-from-dispose one, is reachable from right here — and rethrow
  // anything else. The bargain is stated once, on [_knownAppLeaks].
  drainKnownAppLeaks(tester);

  // After the teardown, not before: `_TabNavigatorState.dispose` writes
  // `NavBarState` on its way out.
  resetAppStatics();

  if (wipe) await resetAppState();

  // Let any in-flight repository write reach the database before the
  // connection goes. Several caches are written from an UNAWAITED future
  // (`HomeFeedRepository.cacheAllHomeSections` off `HomeBloc._revalidate` is
  // the one seen here), and drift throws
  // "Tried to send Request ... but the connection was closed!" into the zone
  // when the channel closes under one — an error that lands on whichever test
  // the framework is running at the time, not on the case that caused it.
  // App bug (a fire-and-forget write with no closed-check); reported, not
  // fixed. These frames only make the harness stop attributing it to an
  // innocent case.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  if (sl.isRegistered<MallowDatabase>()) {
    // get_it registers no disposer for the database, so a bare `sl.reset()`
    // would leak the open sqlite connection and the next graph would open a
    // second one against the same encrypted file.
    await sl<MallowDatabase>().close();
  }
  await sl.reset();
  await bootstrapApp();

  await tester.pumpWidget(const MallowApp());
  await tester.pump(const Duration(milliseconds: 100));
}

/// Backgrounds the app and brings it straight back, the way a user switching
/// away and returning does.
///
/// This is what fires every `didChangeAppLifecycleState` observer — the
/// foreground token-balance refresh in `TabNavigator`, `RemoteConfigService`'s
/// `refreshIfStale`, and the app-lock's background timer.
///
/// Driven through the real `flutter/lifecycle` channel rather than
/// `handleAppLifecycleStateChanged`, which is `@protected`: calling it is an
/// analyzer warning, and warnings are fatal in CI. `ServicesBinding` expands
/// each message into the legal transition chain, so `paused` then `resumed`
/// produces the same observer sequence a real backgrounding does.
///
/// 🛑 **Never `pump` between the two.** `SchedulerBinding` calls
/// `_setFramesEnabledState(false)` for `hidden`/`paused`/`detached`, so
/// `LiveTestWidgetsFlutterBinding.pump` awaits a frame that is never
/// scheduled: the test hangs FOREVER with the app still alive and answering
/// its own timers, which reads like a stuck network rather than a stuck
/// driver. The wait between the two messages is a real `Future.delayed` —
/// timers keep running while frames are off — and the first pump happens only
/// once frames are back on.
///
/// The whole cycle is well under the 60-second background-lock threshold, so
/// the app does not lock underneath the caller.
Future<void> foregroundApp(WidgetTester tester) async {
  for (final state in [AppLifecycleState.paused, AppLifecycleState.resumed]) {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      const StringCodec().encodeMessage(state.toString()),
      (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 500));
}

// ---------------------------------------------------------------------------
// Pump primitives
// ---------------------------------------------------------------------------

/// Pumps in bounded steps until [finder] matches or the budget runs out.
/// Replaces `pumpAndSettle`, which hangs on the welcome screen's perpetual
/// three_js animation. Throws with a clear message on timeout so a broken
/// step names the screen it was stuck on.
///
/// The default budget is 8 s (80 x 100 ms). Raise [rounds] for a step that
/// waits on the mock, not on an animation.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  String? label,
  int rounds = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for ${label ?? finder.toString()}');
}

/// [pumpUntil] that runs [drainKnownAppLeaks] on every round.
///
/// Use it for any wait that spans a surface known to leak — the settings tree
/// and the tab-shell teardown are the two here. One undrained async error
/// aborts the whole FILE rather than the case that caused it, and the abort
/// leaves `LiveTestWidgetsFlutterBinding._pendingFrame` set, so every later
/// case in the file dies with `'!inTest': is not true`.
///
/// It is NOT the default: draining is only safe where the leak is a known,
/// reported app bug, and everywhere else an unexpected exception should fail
/// the case that provoked it.
Future<void> pumpUntilDrained(
  WidgetTester tester,
  Finder finder, {
  String? label,
  int rounds = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    drainKnownAppLeaks(tester);
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for ${label ?? finder.toString()}');
}

/// The inverse of [pumpUntil]: waits for [finder] to stop matching.
///
/// Use it for the disappearance half of a flow — a sheet closing, a spinner
/// clearing, a toast expiring. Asserting the NEXT screen appeared is not the
/// same assertion: routes overlap during a transition, so both can match at
/// once and a test that only waits for the arrival can pass while the old
/// screen is still mounted on top of it.
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  String? label,
  int rounds = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    if (finder.evaluate().isEmpty) return;
  }
  fail('Timed out waiting for ${label ?? finder.toString()} to disappear');
}

/// Pumps until [finder] matches EXACTLY [matches] widgets.
///
/// The reason this is not "wait for it to appear, then count": `context.go`
/// keeps both the outgoing and the incoming route mounted for the length of
/// the transition, so a screen that shares any copy with its predecessor
/// matches TWICE for a few frames. A `pumpUntil` + `findsOneWidget` pair then
/// fails on a screen the case never mentions, and the fix is not a longer
/// sleep — it is waiting for the count itself to settle.
///
/// Also the right tool for "the transition finished": pass `matches: 1` for
/// the arriving screen, or `matches: 0` (same as [pumpUntilGone]) for the
/// outgoing one.
Future<void> pumpUntilCount(
  WidgetTester tester,
  Finder finder,
  int matches, {
  String? label,
  int rounds = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  var last = -1;
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    last = finder.evaluate().length;
    if (last == matches) return;
  }
  fail(
    'Timed out waiting for exactly $matches x ${label ?? finder.toString()} '
    '(last count: $last)',
  );
}

/// Pumps until [finder]'s centre stops moving between frames.
///
/// [pumpUntil] returns on the first frame the target *exists*, which for
/// anything arriving on a route/sheet transition is the frame where it is
/// still parked off-screen. Tapping then computes a hit point outside the
/// view, the gesture lands on nothing, and the handler never runs — the test
/// later times out on the *next* screen with the previous one still up, which
/// reads like a broken app rather than a mistimed tap. Waiting for a stable
/// position is self-tuning: it costs one extra frame on a widget that is
/// already static, and tracks the sheet/route transition duration without
/// hard-coding it.
///
/// Returns quietly if the finder never matches — it is a stabiliser, not an
/// assertion. Put a [pumpUntil] in front when the widget's presence matters.
Future<void> settleAt(
  WidgetTester tester,
  Finder finder, {
  int rounds = 30,
  Duration step = const Duration(milliseconds: 50),
}) async {
  Offset? previous;
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    if (finder.evaluate().isEmpty) continue;
    final centre = tester.getCenter(finder.first);
    if (previous != null && (centre - previous).distance < 0.5) return;
    previous = centre;
  }
}

/// Waits for [finder] to stop moving, taps its first match, then pumps once
/// more so the handler's first frame is on screen. The default tap in this
/// suite — plain `tester.tap` skips the settle and hits empty space during a
/// transition (see [settleAt]).
Future<void> tapAndSettle(
  WidgetTester tester,
  Finder finder, {
  Duration after = const Duration(milliseconds: 300),
}) async {
  await settleAt(tester, finder);
  await tester.tap(finder.first);
  await tester.pump(after);
}

/// Focuses the field [finder] points at, types [text] into it, and then hides
/// the soft keyboard again.
///
/// Taps first, like a user would, so any onTap/focus side effect the field
/// carries actually fires before the text lands.
///
/// [hideKeyboard] defaults to true, and turning it off is a trap. This runs on
/// a real device, so the Android IME really does come up and really does eat
/// ~310 dp of the viewport. It retracts asynchronously, over several frames,
/// and a `tapAndSettle('Continue')` right after typing outruns it — the NEXT
/// screen then lays out inside the shrunken viewport. That is how a
/// seed-phrase entry produced `A RenderFlex overflowed by 121 pixels` from
/// `pin_setup_screen.dart` two screens later, failing the test with an error
/// that names a screen the test never typed into.
Future<void> enterTextInto(
  WidgetTester tester,
  Finder finder,
  String text, {
  bool hideKeyboard = true,
}) async {
  await settleAt(tester, finder);
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.enterText(finder.first, text);
  await tester.pump(const Duration(milliseconds: 300));
  if (hideKeyboard) await dismissKeyboard(tester);
}

/// Drops focus, tells the platform to hide the IME, then pumps until the view
/// insets are actually back to zero (or the budget runs out).
///
/// `unfocus()` alone is NOT enough here. `IntegrationTestWidgetsFlutterBinding`
/// sets `registerTestTextInput => false`, so this suite talks to the REAL
/// Android IME rather than `TestTextInput` — which is why tapping a field
/// raises a real keyboard that really shrinks the viewport, and why the
/// explicit `TextInput.hide` below is what actually retracts it.
///
/// Self-verifying rather than a fixed sleep: one frame when no keyboard is up,
/// and it tracks the real retract animation otherwise. It does NOT fail on
/// timeout — a device that never reports zero insets should not turn every
/// text-entry step red.
Future<void> dismissKeyboard(
  WidgetTester tester, {
  int rounds = 60,
  Duration step = const Duration(milliseconds: 50),
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    if (tester.view.viewInsets.bottom == 0) return;
  }
}

/// Drags [scrollable] until [target] is actually hit-testable, or fails.
///
/// `WidgetTester.scrollUntilVisible` and `dragUntilVisible` both call
/// `pumpAndSettle` between drags, so neither can be used here.
///
/// [delta] is the drag applied per step: negative Y scrolls DOWN the list
/// (content moves up), which is the common case. [scrollable] defaults to the
/// first `Scrollable` in the tree — pass an explicit finder on a screen with
/// nested or horizontal scroll views.
Future<void> scrollUntil(
  WidgetTester tester,
  Finder target, {
  Finder? scrollable,
  Offset delta = const Offset(0, -200),
  int maxScrolls = 30,
  String? label,
}) async {
  final view = scrollable ?? find.byType(Scrollable).first;
  for (var i = 0; i < maxScrolls; i++) {
    if (target.hitTestable().evaluate().isNotEmpty) {
      await settleAt(tester, target);
      return;
    }
    if (view.evaluate().isEmpty) {
      fail('No scrollable found while looking for ${label ?? target}');
    }
    await tester.drag(view.first, delta);
    await tester.pump(const Duration(milliseconds: 150));
  }
  fail('Scrolled $maxScrolls times without reaching ${label ?? target}');
}

// ---------------------------------------------------------------------------
// Screen helpers
// ---------------------------------------------------------------------------

/// The PIN every E2E flow sets. Fixed so a relaunch/lock-screen case can
/// unlock without threading the value through the test.
const String kTestWalletPin = '111111';

/// Every number pad in the tree. Deliberately UNCHAINED: `.first` / `.last`
/// throw `Bad state: No element` the moment nothing matches, and every caller
/// here has to cope with the pad going away mid-entry (the sheet pops on the
/// sixth digit). Callers take `.evaluate().last` after an emptiness check
/// instead — last, because when a PIN sheet is presented over a screen that
/// has its own pad, the topmost route's widgets come last in tree order.
Finder get _numberPad => find.byType(CustomNumberPad);

/// The element of the pad the user is looking at, or null when there is none.
Element? _topNumberPad() {
  final pads = _numberPad.evaluate();
  return pads.isEmpty ? null : pads.last;
}

/// Fill colours of every circular [Container] inside the active PIN surface,
/// in tree order.
///
/// The scope is the innermost [Column] above the pad: all three surfaces
/// (`PinSetupScreen`, `LockScreen`, `PinPromptSheet`) lay their dots row and
/// their [CustomNumberPad] out as siblings in one Column, so this reads the
/// dots of the surface being typed into without the harness having to know
/// which one it is.
///
/// Deliberately NOT "the six dots": the three surfaces size their dots
/// differently (12 dp for the two `Container` ones, 16 dp for the lock
/// screen's `AnimatedContainer`, whose animated inner `Container` is what is
/// read here). The number pad's own 72 dp circular keys are included and are
/// harmless — their colour never changes, so they never register as a change
/// against the baseline in [_filledCount].
///
/// Walks elements rather than composing finders because a finder chain is not
/// null-safe: `find.ancestor(of: pad.last, ...)` throws rather than matching
/// nothing once the surface has gone.
List<Color?> _pinSurfaceCircles(WidgetTester tester) {
  final pad = _topNumberPad();
  if (pad == null) return const [];
  Element? scope;
  pad.visitAncestorElements((element) {
    if (element.widget is Column) {
      scope = element;
      return false;
    }
    return true;
  });
  if (scope == null) return const [];

  final colours = <Color?>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is Container) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.shape == BoxShape.circle) {
        colours.add(decoration.color);
      }
    }
    element.visitChildren(visit);
  }

  scope!.visitChildren(visit);
  return colours;
}

/// How many dots have changed away from [baseline] (sampled with the buffer
/// empty), or `-1` when the surface itself changed shape.
///
/// This is the only observable the PIN buffer has: `_pin` is private on all
/// three surfaces and the dots are the app's own render of its length.
int _filledCount(WidgetTester tester, List<Color?> baseline) {
  final now = _pinSurfaceCircles(tester);
  if (now.length != baseline.length) return -1;
  var changed = 0;
  for (var i = 0; i < now.length; i++) {
    if (now[i] != baseline[i]) changed++;
  }
  return changed;
}

/// Taps one pad key, re-resolving the finder immediately before the tap.
///
/// Re-resolving matters: a `Finder` caches its matches, so a finder evaluated
/// before a settle and tapped after it can point at an element that has since
/// been unmounted — which is the `Bad state: No element` a sheet popping on
/// the sixth digit produces. `warnIfMissed` is off because a swallowed tap is
/// an expected outcome here (see [enterPin]); the caller verifies the effect
/// rather than the delivery.
Future<bool> _tapPadKey(WidgetTester tester, String digit) async {
  final pad = _topNumberPad();
  if (pad == null) return false;
  final key = find.descendant(
    of: find.byElementPredicate(
      (element) => identical(element, pad),
      description: 'the number pad on top',
    ),
    matching: find.text(digit),
  );
  final matches = key.evaluate();
  if (matches.isEmpty) return false;
  await tester.tap(key.first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 60));
  return true;
}

/// Types [digits] on whichever number pad is on screen (PIN create, PIN
/// confirm, lock screen, or the modal PIN sheet), verifying each digit lands.
///
/// Scoped to [CustomNumberPad] on purpose: a bare `find.text('1')` also
/// matches the seed-phrase grid's "1." index label and any balance containing
/// the digit.
///
/// EVERY TAP IS VERIFIED, and that is the point of this helper. Two real
/// situations silently drop taps, and both produce a five-digit buffer that
/// looks like the app ignoring a correct PIN:
///
///  1. `PinPromptSheet` arrives behind `_SheetEntranceTapGuard`, which
///     swallows taps until the route's entrance animation has finished plus a
///     100 ms settle buffer. The wait below covers the usual case; the
///     re-tap covers a slow frame.
///  2. All three surfaces drop a tap while the buffer is already full
///     (`if (_pin.length >= _pinLength) return`), and PIN VERIFICATION is
///     Argon2id (64 MiB, 3 passes) on a `compute` isolate — seconds on this
///     emulator. Typing a second PIN before the first has been rejected
///     therefore loses its leading digits. Use [enterRejectedPin] between
///     wrong attempts rather than relying on the re-tap here.
///
/// The per-digit budget is deliberately long (2 s): a duplicated digit is a
/// far worse failure than a slow one, so this waits well past any plausible
/// frame hitch before deciding a tap was swallowed.
Future<void> enterPin(
  WidgetTester tester, {
  String digits = kTestWalletPin,
}) async {
  final baseline = await _readyPinSurface(tester);
  await _typePin(tester, digits, baseline);
}

/// Waits for the PIN surface to be tappable and samples its empty-dot
/// baseline.
Future<List<Color?>> _readyPinSurface(WidgetTester tester) async {
  await pumpUntil(tester, _numberPad, label: 'number pad');
  // Position-stable == route/sheet entrance finished; the extra pump covers
  // `_sheetSettleBuffer` (100 ms) before the sheet accepts taps.
  await settleAt(tester, _numberPad);
  await tester.pump(const Duration(milliseconds: 150));
  final baseline = _pinSurfaceCircles(tester);
  if (baseline.isEmpty) fail('No PIN surface on screen to type into');
  return baseline;
}

Future<void> _typePin(
  WidgetTester tester,
  String digits,
  List<Color?> baseline,
) async {
  for (var index = 0; index < digits.length; index++) {
    final digit = digits[index];
    var landed = false;
    for (var attempt = 0; attempt < 3 && !landed; attempt++) {
      if (!await _tapPadKey(tester, digit)) {
        fail('The number pad went away while typing digit ${index + 1}');
      }
      for (var round = 0; round < 20 && !landed; round++) {
        await tester.pump(const Duration(milliseconds: 100));
        // "Moved off the pre-tap count" rather than "== index + 1": the last
        // digit of a PIN also clears the dots (confirm step, rejection) or
        // replaces the surface entirely, and both are proof it landed.
        landed = _filledCount(tester, baseline) != index;
      }
    }
    if (!landed) {
      fail(
        'Digit ${index + 1} of the PIN never registered — the pad swallowed '
        '3 taps (a tap guard still up, or the buffer never drained)',
      );
    }
  }
}

/// Types a PIN that is expected to be REJECTED, and waits for the surface to
/// finish rejecting it.
///
/// The wait is the whole helper. Verification runs Argon2id on a `compute`
/// isolate, and until it resolves the buffer is still full and every further
/// tap is dropped — so a case that enters a second wrong PIN straight after
/// the first silently types into nothing and then asserts against the
/// PREVIOUS attempt's copy.
///
/// Returns once the dots are back to empty (the app's own "try again" state)
/// or the surface has gone (three strikes closes `PinPromptSheet`). The
/// budget is 30 s because Argon2id on this emulator really can take seconds
/// per attempt.
Future<void> enterRejectedPin(
  WidgetTester tester, {
  String digits = kTestWalletPin,
}) async {
  final baseline = await _readyPinSurface(tester);
  await _typePin(tester, digits, baseline);
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (_numberPad.evaluate().isEmpty) return;
    if (_filledCount(tester, baseline) == 0) return;
  }
  fail('Timed out waiting for the rejected PIN to clear the dots');
}

/// Walks the optional biometric-setup screen and stops ON the "Create a PIN"
/// screen.
///
/// On an emulator with no enrolled biometrics the biometric screen
/// auto-forwards straight to PIN setup; when biometrics ARE available it shows
/// a "Skip for now" link. Both PIN screens also carry a "Skip for now", so the
/// PIN title is checked first every round — skipping the PIN would leave the
/// app unlockable and silently break every lock-screen case downstream.
///
/// Returns only once the biometric screen is GONE, not merely once the PIN
/// screen exists: `context.go` keeps both routes mounted for the length of the
/// transition, and the two screens share a "You can change this anytime in
/// settings" footer — so an assertion made on arrival finds two of it and
/// fails naming a screen the case never mentions.
Future<void> waitForPinSetup(WidgetTester tester) async {
  final pinTitle = find.text('Create a PIN');
  final skipBiometrics = find.text('Skip for now');
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (pinTitle.evaluate().isNotEmpty) break;
    if (skipBiometrics.evaluate().isNotEmpty) {
      await tapAndSettle(tester, skipBiometrics);
    }
  }
  await pumpUntil(tester, pinTitle, label: 'PIN create');
  await pumpUntilGone(
    tester,
    find.byType(BiometricSetupScreen),
    label: 'biometric setup screen',
  );
}

/// Walks the optional biometric-setup screen and both PIN steps, and returns
/// once onboarding is over and THE PIN ACTUALLY EXISTS. Shared by the
/// create-wallet and import-wallet paths, which converge here.
///
/// The lock wait is not belt-and-braces. `AppLockEvent.setPin` hashes with
/// Argon2id before it emits `unlocked`, and `PinSetupScreen._savePin`
/// navigates home WITHOUT awaiting the bloc — so "the redirect fired" does not
/// mean the PIN exists yet. For a beat the app still reports `noPinSet`, an
/// `AppLockEvent.lock()` (which only fires from `unlocked`) is inert, and a
/// relaunch reads `hasPin() == false` and boots straight past the lock screen.
/// Every lock case would then fail for a reason that has nothing to do with
/// what it tests.
///
/// It stops short of [waitForHome] on purpose: onboarding can legitimately
/// complete with no backend at all (key generation, the vault write and the
/// PIN are on-device), and in that case `SessionInitializer` lands on its
/// error view and Home never renders. Callers that expect a live session say
/// so — [importTestWallet] does.
Future<void> completePinSetup(WidgetTester tester) async {
  await waitForPinSetup(tester);
  await enterPin(tester);
  await pumpUntil(tester, find.text('Confirm your PIN'), label: 'PIN confirm');
  await enterPin(tester);

  await pumpUntilGone(
    tester,
    find.byType(PinSetupScreen),
    label: 'PIN setup screen',
    rounds: 150,
  );
  await waitForLockArmed(tester);
}

/// Waits until the app is on Home with its session initialised.
///
/// 🛑 `find.byType(MallowBottomNavBar)` is NOT this signal, however much it
/// reads like it. `app.dart` mounts `_PersistentNavBar` as a Stack SIBLING of
/// the routed content, so the bar is in the tree on EVERY screen — measured: 1
/// match on a wiped install's Welcome screen, 1 while `SessionInitializer` is
/// still loading, and 1 while it is showing its error view. A `pumpUntil` on
/// it returns on the first frame from anywhere and proves nothing.
///
/// [HomeScreen] is the real signal, and it was verified on device rather than
/// reasoned about. It is instantiated in exactly one place
/// (`TabNavigator._screens`), which sits under `SessionInitializer`'s resolved
/// child, and `find.byType` skips offstage widgets — so it matches when, and
/// only when, the Home tab is on stage with a live session. On the same
/// device run: Welcome 0, PIN screen 0, session-loading 0, Home 1, and 0 again
/// once the Portfolio tab is on stage.
///
/// For "the shell is up on SOME tab", use `find.byType(SharedHeader)` instead;
/// `NavBarState.visible` on its own is not it either — the refcount is raised
/// from `TabNavigator`'s RouteAware `didPush`, which fires before the session
/// resolves (measured true at frame 0, six frames before Home appeared).
Future<void> waitForHome(WidgetTester tester, {int rounds = 250}) => pumpUntil(
  tester,
  find.byType(HomeScreen),
  label: 'Home (session initialised)',
  rounds: rounds,
);

// ---------------------------------------------------------------------------
// App lock
// ---------------------------------------------------------------------------

/// The app's LIVE [AppLockBloc] — the one `MallowApp` created and provided.
///
/// Never `sl<AppLockBloc>()`: it is registered as a FACTORY, so the locator
/// hands back a brand-new bloc that no widget listens to. Events dispatched to
/// that one change nothing on screen, and its state is not the app's.
AppLockBloc appLockBloc(WidgetTester tester) => BlocProvider.of<AppLockBloc>(
  tester.element(find.byType(MaterialApp).first),
);

/// Pumps until the PIN written by [completePinSetup] has actually been stored
/// and the lock is armed.
Future<void> waitForLockArmed(WidgetTester tester, {int rounds = 200}) async {
  for (var i = 0; i < rounds; i++) {
    if (appLockBloc(tester).state is AppLockStateUnlocked) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for the app lock to arm after PIN setup');
}

/// Locks the app in place, the way a 60-second backgrounding would, and waits
/// for the lock overlay.
///
/// The real trigger is a background threshold read off the wall clock
/// (`_backgroundLockThreshold`, `lib/app.dart`), so a faithful drive costs
/// 60 s per case and cannot be shortened from inside the process; the real
/// threshold is a Patrol case. `_onLock` only transitions out of `unlocked`,
/// so the assertion below is load-bearing: an app that booted into `noPinSet`
/// would swallow the event and this would otherwise pass by doing nothing.
Future<void> lockApp(WidgetTester tester) async {
  final bloc = appLockBloc(tester);
  expect(
    bloc.state,
    isA<AppLockStateUnlocked>(),
    reason: 'the lock must be armed before it can be exercised',
  );
  bloc.add(const AppLockEvent.lock());
  await pumpUntil(tester, find.byType(LockScreen), label: 'lock screen');
}

/// The budget every lock-screen wait below runs on: 25 s.
///
/// It is one constant rather than a per-call-site number because the four
/// flow files had picked four (80 / 150 / 200 / 250 rounds) for the same two
/// waits, and the shortest of them is not enough on a contended emulator —
/// both sides of a lock cycle are gated by Argon2id (64 MiB, 3 passes) on a
/// `compute` isolate, and the `wipe: false` relaunch in front of it rebuilds
/// the DI graph and re-reads the database first. The generous value costs
/// nothing when the screen arrives on time; the short one flakes.
const int kLockScreenRounds = 250;

/// Kill-and-reopen over the data the previous step left behind, and wait for
/// the lock overlay.
///
/// 🛑 Never sample once after the relaunch. `AppLockEvent.init` reads the
/// database asynchronously, so the relaunched app renders Home FIRST and drops
/// [LockScreen] over it a frame or two later — a single `expect` here reads
/// "home" and is wrong.
Future<void> relaunchIntoLockScreen(
  WidgetTester tester, {
  int rounds = kLockScreenRounds,
  String? label,
}) async {
  await restartApp(tester, wipe: false);
  await pumpUntil(
    tester,
    find.byType(LockScreen),
    label: label ?? 'lock screen after relaunch',
    rounds: rounds,
  );
}

/// Enters [pin] on the lock screen and waits for the overlay to go.
///
/// Waits for [LockScreen] first, so it is safe to call straight after a
/// relaunch as well as on a lock raised in-session by [lockApp].
Future<void> unlockApp(
  WidgetTester tester, {
  String pin = kTestWalletPin,
  int rounds = kLockScreenRounds,
}) async {
  await pumpUntil(
    tester,
    find.byType(LockScreen),
    label: 'lock screen',
    rounds: rounds,
  );
  await enterPin(tester, digits: pin);
  await pumpUntilGone(
    tester,
    find.byType(LockScreen),
    label: 'lock screen',
    rounds: rounds,
  );
}

/// [relaunchIntoLockScreen] + [unlockApp] + [waitForHome]: the whole
/// "force-quit and reopen" round trip, for a case that only wants to be back
/// where it was.
///
/// Use the two halves separately when something has to be asserted while the
/// lock is up (a retired PIN being refused, the welcome screen after a reset).
Future<void> relaunchAndUnlock(
  WidgetTester tester, {
  String pin = kTestWalletPin,
  int rounds = kLockScreenRounds,
}) async {
  await relaunchIntoLockScreen(tester, rounds: rounds);
  await unlockApp(tester, pin: pin, rounds: rounds);
  await waitForHome(tester);
}
