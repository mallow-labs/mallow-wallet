// Shared shell navigation: the account drawer and the Settings root.
//
// Import the barrel instead of this file directly:
//
//     import 'support/e2e.dart';
//
// This lives in `support/` for one reason: four flow files had grown four
// different ways into Settings, each with its own readiness heuristic and only
// one of them idempotent — so a case that reached Settings through the weakest
// copy could fail on a screen it never mentions, and a fix to one copy left the
// other three broken. What follows is the union of the four, not a new fifth
// way: the idempotence check from `settings_test.dart`, the geometry read of
// "the drawer is open" from `onboarding_import_test.dart` and
// `navigation_and_empty_states_test.dart`, the accounts-panel collapse from the
// import file, the push-preference pre-empt every settings case needs, and the
// "Preferences" settle from `pin_and_lock_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/home/widgets/account_menu_drawer.dart';
import 'package:mallow_wallet/features/settings/screens/settings_screen.dart';

import 'harness.dart';

// ---------------------------------------------------------------------------
// Finders
// ---------------------------------------------------------------------------

/// The account-menu button in the persistent header — the drawer's tap
/// affordance, and a TOGGLE rather than an open.
///
/// Matched on the `Semantics` widget rather than `find.bySemanticsLabel`,
/// which needs the semantics tree switched on; the widget carries the label
/// either way.
Finder get accountMenuButton => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Open account menu',
  description: 'account menu button',
);

/// The account drawer panel.
///
/// ALWAYS mounted — `TabNavigator` parks it off the left edge and slides it in
/// with a `Transform.translate` rather than adding and removing it — so its
/// presence proves nothing and its POSITION is the only real read of
/// open/closed. See [accountDrawerIsOpen].
Finder get accountDrawer => find.byType(AccountMenuDrawer);

/// The drawer's "Settings" row.
///
/// Scoped to the panel: a pushed settings route leaves the drawer, the home
/// shell and the parent screen alive underneath it, so a bare
/// `find.text('Settings')` also matches the settings header.
Finder get drawerSettingsRow =>
    find.descendant(of: accountDrawer, matching: find.text('Settings'));

/// The pill in the drawer header while the accounts panel is on top of the
/// menu rows. Present == the menu rows are covered.
Finder get _drawerClosePill =>
    find.descendant(of: accountDrawer, matching: find.text('Close'));

/// The settings identity row, once `SettingsScreen._loadData` has resolved.
///
/// The row renders the ACTIVE ACCOUNT'S NAME, which only arrives with that
/// future — so waiting for it is what separates "the route is mounted" from
/// "the screen loaded". Matched on the default name shape rather than a fixed
/// index, because the active account is not always the first one; pass
/// `identity:` to [openSettings] for a session whose account has been renamed.
Finder get _settingsIdentityRow => find.descendant(
  of: find.byType(SettingsScreen),
  matching: find.textContaining(RegExp(r'^Account \d+$')),
);

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------

/// True once the drawer panel has slid fully into the viewport.
bool accountDrawerIsOpen(WidgetTester tester) {
  final panel = accountDrawer;
  if (panel.evaluate().isEmpty) return false;
  return tester.getTopLeft(panel.first).dx > -0.5;
}

/// Slides the account drawer open, or returns straight away when it is already
/// open.
///
/// IDEMPOTENT, and that is not a nicety: the header tap is a toggle, and
/// pushing a route from the drawer leaves it open BEHIND that route — so
/// popping back and tapping the header again closes it instead of opening it.
///
/// Bounded re-taps rather than a fixed grace period. An import that ends in
/// `DrawerSignal.showAccountsOnNextOpen` opens the drawer from a post-frame
/// callback, and a tap that races that callback closes it again; waiting the
/// callback out on every call would spend a second on each of the ~30 settings
/// entries in this suite that can never trigger it. Re-tapping only while the
/// drawer is still shut costs nothing in the common case and converges either
/// way round the race.
///
/// [roundsPerAttempt] is 50 (5 s), the most generous of the per-tap waits the
/// four copies had picked — a re-tap that lands on a drawer still sliding open
/// closes it again, so the wait has to be longer than the worst slide this
/// emulator produces, not merely longer than the animation.
Future<void> openAccountDrawer(
  WidgetTester tester, {
  int attempts = 3,
  int roundsPerAttempt = 50,
}) async {
  await pumpUntil(tester, accountMenuButton, label: 'app header');
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (accountDrawerIsOpen(tester)) break;
    await tapAndSettle(tester, accountMenuButton);
    for (var round = 0; round < roundsPerAttempt; round++) {
      if (accountDrawerIsOpen(tester)) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  if (!accountDrawerIsOpen(tester)) {
    fail('The account drawer did not slide open');
  }
  // Position-stable == the slide really finished. Tapping a row mid-slide
  // computes a hit point the row has already left, and the gesture lands on
  // nothing.
  await settleAt(tester, accountDrawer);
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Turns the push preference off before the Settings root is opened.
///
/// NOT a convenience. `SettingsScreen._loadData` computes the push toggle as
/// `prefs.pushNotificationsEnabled && await pushService.isAuthorized()`, and
/// `isAuthorized()` resolves `FirebaseMessaging.instance`, which throws
/// `[core/no-app]` in a harness that deliberately skips
/// `Firebase.initializeApp()` (see `harness.dart#bootstrapApp`). The throw
/// escapes `_loadData` before its `setState`, so the screen would render "—"
/// for the account name and never update the Active Networks badge, and the
/// unawaited failure would fail whichever test the framework pins it on.
///
/// The `&&` short-circuits, so turning the stored preference off keeps the
/// Firebase call from ever being made. Public preference API only; no DI
/// surgery, no change to `lib/`. The stored preference defaults to `true` and
/// is wiped by `resetAppState()`, so this runs on every entry into Settings,
/// not once per file.
Future<void> pushOffForFirebaselessSandbox() =>
    sl<PreferencesService>().setPushNotificationsEnabled(false);

/// Home -> account drawer -> Settings, and returns once the settings root has
/// LOADED, not merely mounted.
///
/// Readiness is the union of what the file-local copies each waited for:
///
///  * the [SettingsScreen] route is mounted;
///  * the identity row has resolved (`_loadData` finished — see
///    [_settingsIdentityRow]), which is also what makes the Active Networks
///    badge trustworthy;
///  * the "Preferences" row is on screen, which several cases assert on
///    immediately afterwards;
///  * and the push transition has settled, because until it does the home
///    route is still on stage and owns the first `Scrollable` in the tree —
///    which is what a `scrollUntil` on this screen would grab.
///
/// [identity] overrides the row waited for, for a session whose active account
/// has been renamed away from the default "Account NN".
Future<void> openSettings(
  WidgetTester tester, {
  Finder? identity,
  int rounds = 300,
}) async {
  await pushOffForFirebaselessSandbox();
  await openAccountDrawer(tester);

  if (_drawerClosePill.evaluate().isNotEmpty) {
    // The accounts panel covers the menu rows and, being an IgnorePointer
    // sibling, swallows the tap that would otherwise reach them.
    await tapAndSettle(tester, _drawerClosePill);
    await pumpUntilGone(tester, _drawerClosePill, label: 'accounts panel');
  }

  // The drawer is built even while closed, parked off-screen, so waiting for
  // the row to exist is not enough — wait for it to be tappable.
  await pumpUntil(
    tester,
    drawerSettingsRow.hitTestable(),
    label: 'account menu -> Settings row',
  );
  await tapAndSettle(tester, drawerSettingsRow.hitTestable());

  await pumpUntilDrained(
    tester,
    find.byType(SettingsScreen),
    label: 'Settings root',
    rounds: rounds,
  );
  await pumpUntilDrained(
    tester,
    identity ?? _settingsIdentityRow,
    label: 'settings identity row',
    rounds: rounds,
  );
  final preferences = find.descendant(
    of: find.byType(SettingsScreen),
    matching: find.text('Preferences'),
  );
  await pumpUntilDrained(
    tester,
    preferences,
    label: 'Settings screen (Preferences row)',
    rounds: rounds,
  );
  await settleAt(tester, preferences);
}
