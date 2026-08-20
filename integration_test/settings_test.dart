// E2E: the Settings tree — identity, preferences, the security gate, secret
// reveal, and the two destructive paths — driven on a real Android emulator
// against the sandboxed mock backend (test/e2e/mock_backend.py).
//
// This is the `settings` bucket: 53 E2E-eligible cases, 17 of them the CI
// smoke subset. Most of the bucket is the "inert control audit": rows that
// must exist, must navigate somewhere, and must NOT quietly acquire
// behaviour. A widget being on screen is NOT the assertion
// here — every case below pins an observable consequence: a route that opened,
// a value that survived a relaunch, a stored flag a later screen re-read, or a
// request that reached the wire.
//
// Measured on the local headless emulator (19 `testWidgets`, 33 cases):
// 7 min 35 s of test time plus 35 s of per-file overhead (Gradle
// assembleDebug + install + cold boot) = 8 min 10 s for the whole file. The
// CI smoke subset was 11 tests / 20 cases at 4 min 18 s; the factory reset
// (41 s — it re-onboards) and the PIN change (35 s — it relaunches to prove
// the new PIN unlocks) have since been demoted to nightly, leaving 9 tests /
// 17 cases at ~3 min 2 s, so ~3 min 37 s per run. Neither demoted case can be
// made cheaper without dropping what it asserts, and both are relaunch-heavy —
// which is what makes them the right two to move when the smoke suite has to
// fit the job's fixed 45-minute budget. The most expensive smoke case left is
// the gate (44 s — three Argon2id rejections); it stays because ONB-099 is the
// security gate itself.
//
// ---------------------------------------------------------------------------
// Case map — case -> test -> smoke|nightly|TODO
// ---------------------------------------------------------------------------
// SET-001  | account identity on the settings root              | smoke
// SET-004  | Active Networks badge + relaunch                   | smoke
// SET-009  | app theme applies instantly and persists           | smoke
// SET-011  | app theme defaults to Dark, not System             | smoke
// ONB-099  | re-auth gate on Security & Privacy                 | smoke
// SET-023  | cancelling the gate does not open the screen       | smoke
// SET-024  | wrong PIN does not open the screen                 | smoke
// SET-045  | Show secrets does not re-prompt                    | smoke
// SET-033  | biometric row hidden without enrolment             | smoke
// PERM-010 | no biometrics enrolled at the OS level             | smoke
// SET-080  | no route into the five unfinished screens          | smoke
// SET-003  | identity row navigates and refreshes on return     | smoke
// SET-069  | rename an account and see it everywhere            | smoke
// SET-038  | threshold row Off by default, sheet opens disabled | smoke
// SET-039  | enable the gate and set a threshold                | smoke
// SET-040  | cancel writes nothing                              | smoke
// SET-064  | report a bug submits successfully                  | smoke
// SET-058  | reset app wipes wallets, returns to onboarding     | nightly
// SET-059  | reset app is a true factory reset                  | nightly
// SET-028  | change PIN happy path                              | nightly
// SET-012  | preferred explorer (Solana) selection persists     | nightly
// SET-013  | preferred explorer (Ethereum) is independent       | nightly
// SET-029  | wrong current PIN / mismatched confirmation        | nightly
// SET-031  | turn off PIN is blocked without biometrics         | nightly
// SET-042  | Your secrets: one row per distinct phrase          | nightly
// SET-049  | word grid content is correct                       | nightly
// SET-054  | secret is not retained after leaving the screen    | nightly
// SET-055  | analytics toggle persists                          | nightly
// SET-072  | toggling a chain on adds a real wallet             | nightly
// SET-073  | toggling a chain off deletes a wallet              | nightly
// SET-074  | staged toggles are discarded on back-out           | nightly
// SET-085  | back navigation from every settings screen         | nightly
// SET-021  | network toggles reach the import picker            | nightly
//
// TODO(SET-002): needs the `profile` scenario fixture (Phase 2).
// TODO(SET-005): needs a wallet-multi bootstrap (>=2 accounts) in the shared
//   harness; it is scoped to the `wallet-multi` fixture.
// TODO(SET-006): unreachable in this sandbox. `SettingsScreen._loadData` reads
//   `PushNotificationService.isAuthorized()`, which throws `[core/no-app]`
//   because the harness boots without `Firebase.initializeApp()`. See
//   `pushOffForFirebaselessSandbox` in `support/navigation.dart` — the whole
//   bucket depends on short-circuiting that call, so the push toggle itself
//   cannot be exercised.
// TODO(SET-015): needs the `art-roles` artwork fixture (Phase 2).
// TODO(SET-017): needs the `port-funded` portfolio fixture.
// TODO(SET-019, SET-020): need the `profile` scenario fixture (Phase 2).
// TODO(SET-027): the app refuses to reach "no biometrics AND no PIN" — the PIN
//   screen only offers "Skip for now" when biometrics are already enabled, and
//   Turn off PIN is refused without them (SET-031 pins that). Producing the
//   state needs enrolled biometrics, i.e. Patrol.
// TODO(SET-030): same reason — "Change PIN with no PIN set" needs the no-PIN
//   state, which requires enrolled biometrics.
// TODO(SET-043, SET-053): need the `key-fixed` fixture — a throwaway private
//   key constant alongside the mnemonic in `support/test_wallet.dart`.
// TODO(SET-044): needs the `watch-addr` fixture (a device whose only account is
//   watch-only), which means a multi-account bootstrap plus an account removal.
// TODO(SET-068, SET-076, SET-077): need the `wallet-multi` bootstrap.
// TODO(SET-078, SET-088, SET-089, SET-090, SET-091): need the `profile` /
//   `net-fail` scenario fixtures (Phase 2).
//
// Cases this file deliberately does NOT claim: SET-012/013 also
// ask that the opened URL changes. That needs a completed transaction to open
// an explorer link from, i.e. a Phase-3 activity fixture; only the stored
// selection is asserted here.
//
// SECURITY: the reveal cases below assert word-by-word against the throwaway
// phrase already committed in `support/test_wallet.dart`. Nothing here prints,
// joins or logs a phrase or a private key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/features/accounts/screens/add_account_screen.dart';
import 'package:mallow_wallet/features/accounts/screens/import_wallets_from_phrase_screen.dart';
import 'package:mallow_wallet/features/settings/screens/about_screen.dart';
import 'package:mallow_wallet/features/settings/screens/active_networks_screen.dart';
import 'package:mallow_wallet/features/settings/screens/app_theme_screen.dart';
import 'package:mallow_wallet/features/settings/screens/change_pin_screen.dart';
import 'package:mallow_wallet/features/settings/screens/edit_account_screen.dart';
import 'package:mallow_wallet/features/settings/screens/preferences_screen.dart';
import 'package:mallow_wallet/features/settings/screens/preferred_explorer_screen.dart';
import 'package:mallow_wallet/features/settings/screens/recovery_phrase_warning_screen.dart';
import 'package:mallow_wallet/features/settings/screens/recovery_phrase_words_screen.dart';
import 'package:mallow_wallet/features/settings/screens/report_bug_screen.dart';
import 'package:mallow_wallet/features/settings/screens/reset_app_screen.dart';
import 'package:mallow_wallet/features/settings/screens/security_privacy_screen.dart';
import 'package:mallow_wallet/features/settings/screens/settings_screen.dart';
import 'package:mallow_wallet/features/settings/screens/show_secrets_screen.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';
import 'package:mallow_wallet/shared/widgets/mallow_header.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mallow_wallet/shared/widgets/mallow_toggle.dart';
import 'package:mallow_wallet/shared/widgets/seed_phrase_grid.dart';
import 'package:mallow_wallet/shared/widgets/shared_header.dart';

import 'support/e2e.dart';

// ---------------------------------------------------------------------------
// Finders
// ---------------------------------------------------------------------------

/// Everything matching [matching] inside the currently-mounted [screen].
///
/// Scoping matters more here than anywhere else in the suite: a pushed settings
/// route leaves the drawer, the home shell and the parent settings screen alive
/// underneath it, so a bare `find.text('Settings')` matches the drawer row as
/// well as the header.
Finder _on(Type screen, Finder matching) =>
    find.descendant(of: find.byType(screen), matching: matching);

/// The [MallowToggle] sitting in the same row as [label].
Finder _rowToggle(Finder label) => find.descendant(
  of: find.ancestor(of: label, matching: find.byType(Row)).first,
  matching: find.byType(MallowToggle),
);

bool _toggleValue(WidgetTester tester, Finder label) =>
    tester.widget<MallowToggle>(_rowToggle(label)).value;

/// Number of [MallowSvgIcon]s in the row containing [label].
///
/// The single-select settings pickers mark their selection with a trailing
/// checkmark and nothing else, so this counts the selection. Explorer rows draw
/// their leading glyph with a bare `SvgPicture`, so 1 == selected; theme rows
/// use a `MallowSvgIcon` for the glyph too, so 2 == selected.
int _rowIcons(String label) => find
    .descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byType(MallowSvgIcon),
    )
    .evaluate()
    .length;

/// The five screens that are registered as routes but must stay unreachable.
/// `Edit wallet` is the dangerous one — it carries a working destructive
/// "Remove wallet" button.
const _unreachableScreenTitles = [
  'Connected apps',
  'Account privacy',
  'Currency',
  'Display Language',
  'Edit wallet',
];

void _expectNoUnreachableScreens(String where) {
  for (final title in _unreachableScreenTitles) {
    expect(
      find.text(title),
      findsNothing,
      reason: '"$title" must have no route in the settings tree (at: $where)',
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------------------

Future<void> _tapSettingsRow(WidgetTester tester, String label) =>
    tapAndSettle(tester, _on(SettingsScreen, find.text(label)));

/// Taps the back arrow of [screen]'s header and waits for it to pop.
Future<void> _back(WidgetTester tester, Type screen) async {
  await tapAndSettle(
    tester,
    find.descendant(
      of: find.byType(screen),
      matching: find.byType(MallowHeader),
    ),
  );
  await pumpUntilGone(tester, find.byType(screen), label: '$screen to pop');
}

/// Settings -> Security & Privacy, clearing the re-auth gate with the PIN.
///
/// The emulator has no biometric enrolment, so `requireReauth` falls straight
/// through to the PIN sheet — that is the path ONB-099 describes for this
/// device class.
Future<void> _openSecurityPrivacy(WidgetTester tester) async {
  await _tapSettingsRow(tester, 'Security & Privacy');
  await pumpUntil(tester, find.text('Enter your PIN'), label: 'PIN gate sheet');
  // The sheet swallows taps until its entrance animation plus a short settle
  // buffer have elapsed (`_SheetEntranceTapGuard`); `enterPin` waits that out
  // and re-taps any digit the guard still ate.
  await enterPin(tester);
  await pumpUntil(
    tester,
    find.byType(SecurityPrivacyScreen),
    label: 'Security & Privacy',
  );
  // The route mounts before its body exists: the screen renders an empty box
  // until `_load()` returns from secure storage and the biometric probes. A
  // caller that asserts on the frame the route arrives sees no rows at all —
  // which fails a `findsOneWidget` and, worse, silently passes a
  // `findsNothing`. "Change PIN" is the one row rendered unconditionally, so
  // it marks the loaded body.
  await pumpUntil(
    tester,
    _on(SecurityPrivacyScreen, find.text('Change PIN')),
    label: 'Security & Privacy body',
  );
}

/// Dismisses the modal sheet marked by [sheetMarker] the way a user cancels
/// one, and waits for it to be gone.
///
/// Tries the scrim first and falls back to the system back gesture. Both are
/// cancels; the case being pinned is the *outcome* (no access), not which
/// gesture produced it.
Future<void> _dismissSheet(WidgetTester tester, Finder sheetMarker) async {
  await tester.tapAt(const Offset(200, 80));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (sheetMarker.evaluate().isEmpty) return;
  }
  await tester.binding.handlePopRoute();
  await pumpUntilGone(tester, sheetMarker, label: 'sheet after a back gesture');
}

ThemeMode _themeMode(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode ??
    ThemeMode.system;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await MockControl.reset();
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Root
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('settings root renders the Account identity, not a Profile one', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    expect(
      _on(SettingsScreen, find.text(formatAccountName(1))),
      findsOneWidget,
    );
    expect(_on(SettingsScreen, find.text('Edit account')), findsOneWidget);
    expect(_on(SettingsScreen, find.text('Edit profile')), findsNothing);
    // The truncated address line is Profile-only; an Account session must not
    // print the wallet address under the name.
    expect(
      _on(SettingsScreen, find.text(truncateAddress(kTestWalletSolana))),
      findsNothing,
    );
    // Every network on -> the badge collapses to "All".
    expect(_on(SettingsScreen, find.text('All')), findsOneWidget);
  });

  testWidgets('Active Networks badge follows the toggles and survives a '
      'relaunch', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    expect(_on(SettingsScreen, find.text('All')), findsOneWidget);

    await _tapSettingsRow(tester, 'Active Networks');
    await pumpUntil(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
      label: 'Active networks screen',
    );
    expect(
      _toggleValue(tester, _on(ActiveNetworksScreen, find.text('Solana'))),
      isTrue,
    );
    expect(
      _toggleValue(tester, _on(ActiveNetworksScreen, find.text('Ethereum'))),
      isTrue,
    );
    await tapAndSettle(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
    );
    expect(
      _toggleValue(tester, _on(ActiveNetworksScreen, find.text('Ethereum'))),
      isFalse,
    );
    await _back(tester, ActiveNetworksScreen);
    await pumpUntil(
      tester,
      _on(SettingsScreen, find.text('Solana, Tezos')),
      label: 'badge after switching Ethereum off',
    );

    await _tapSettingsRow(tester, 'Active Networks');
    await pumpUntil(
      tester,
      _on(ActiveNetworksScreen, find.text('Tezos')),
      label: 'Active networks screen',
    );
    await tapAndSettle(tester, _on(ActiveNetworksScreen, find.text('Tezos')));
    await _back(tester, ActiveNetworksScreen);
    await pumpUntil(
      tester,
      _on(SettingsScreen, find.text('Solana')),
      label: 'badge after switching Tezos off',
    );

    // Persisted, not just held in the screen's state.
    await relaunchAndUnlock(tester);
    await openSettings(tester);
    expect(_on(SettingsScreen, find.text('Solana')), findsOneWidget);
    expect(_on(SettingsScreen, find.text('All')), findsNothing);
  });

  testWidgets('renaming from the identity row updates Settings and the home '
      'header without a restart', (tester) async {
    const newName = 'Renamed E2E';
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    await tapAndSettle(tester, _on(SettingsScreen, find.text('Edit account')));
    await pumpUntil(
      tester,
      find.byType(EditAccountScreen),
      label: 'Edit Account',
    );
    await enterTextInto(
      tester,
      _on(EditAccountScreen, find.byType(TextField)),
      newName,
    );
    await tapAndSettle(tester, _on(EditAccountScreen, find.text('Done')));
    await pumpUntilGone(
      tester,
      find.byType(EditAccountScreen),
      label: 'Edit Account to pop',
    );

    // SET-003: the settings header re-reads on return, no restart.
    await pumpUntil(
      tester,
      _on(SettingsScreen, find.text(newName)),
      label: 'renamed identity row',
    );
    expect(_on(SettingsScreen, find.text(formatAccountName(1))), findsNothing);

    // SET-069: and so does the persistent home header.
    await _back(tester, SettingsScreen);
    await pumpUntil(
      tester,
      _on(SharedHeader, find.text(newName)),
      label: 'renamed home header',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Preferences
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('app theme defaults to Dark, applies instantly and survives a '
      'relaunch', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    // SET-011: the default is ThemeMode.dark, NOT ThemeMode.system.
    expect(_themeMode(tester), ThemeMode.dark);

    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    await tapAndSettle(tester, _on(PreferencesScreen, find.text('App Theme')));
    await pumpUntil(tester, find.byType(AppThemeScreen), label: 'App Theme');
    // Leading glyph + trailing checkmark on the selected row; glyph only on the
    // others.
    expect(_rowIcons('Dark mode'), 2);
    expect(_rowIcons('Light mode'), 1);

    await tapAndSettle(tester, find.text('Light mode'));
    await pumpUntil(
      tester,
      find.byType(AppThemeScreen),
      label: 'App Theme after select',
    );
    // SET-009: applied app-wide immediately, not on the next launch.
    expect(_themeMode(tester), ThemeMode.light);
    expect(_rowIcons('Light mode'), 2);
    expect(_rowIcons('Dark mode'), 1);
    expect(
      Theme.of(tester.element(find.byType(AppThemeScreen))).brightness,
      Brightness.light,
    );

    await relaunchAndUnlock(tester);
    expect(_themeMode(tester), ThemeMode.light);
  });

  testWidgets('preferred explorer persists per chain and the two chains are '
      'independent', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    await tapAndSettle(
      tester,
      _on(PreferencesScreen, find.text('Preferred Explorer')),
    );
    await pumpUntil(
      tester,
      find.byType(PreferredExplorerScreen),
      label: 'Preferred Explorer',
    );

    // Defaults: Solscan for Solana, Etherscan for Ethereum.
    expect(_rowIcons('Solscan'), 1);
    expect(_rowIcons('Solana Beach'), 0);
    expect(_rowIcons('Etherscan'), 1);
    expect(_rowIcons('Blockscout'), 0);

    await tapAndSettle(tester, find.text('Solana Beach'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_rowIcons('Solana Beach'), 1);
    expect(_rowIcons('Solscan'), 0);
    // SET-013: the Ethereum selection did not move with it.
    expect(_rowIcons('Etherscan'), 1);

    await tapAndSettle(tester, find.text('Blockscout'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_rowIcons('Blockscout'), 1);
    expect(_rowIcons('Etherscan'), 0);
    expect(_rowIcons('Solana Beach'), 1);

    // Both selections are read back from storage on re-entry.
    await _back(tester, PreferredExplorerScreen);
    await tapAndSettle(
      tester,
      _on(PreferencesScreen, find.text('Preferred Explorer')),
    );
    await pumpUntil(
      tester,
      find.byType(PreferredExplorerScreen),
      label: 'Preferred Explorer re-entry',
    );
    expect(_rowIcons('Solana Beach'), 1);
    expect(_rowIcons('Blockscout'), 1);
  }, tags: 'nightly');

  // ─────────────────────────────────────────────────────────────────────────
  // The Security & Privacy gate
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('the Security & Privacy gate refuses a cancel and a wrong PIN, '
      'and challenges exactly once', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    // ONB-099: no enrolment on this device, so the gate falls through to the
    // PIN sheet rather than a biometric prompt.
    await _tapSettingsRow(tester, 'Security & Privacy');
    await pumpUntil(
      tester,
      find.text('Enter your PIN'),
      label: 'PIN gate sheet',
    );

    // SET-023: dismissing the sheet keeps you out. No error toast — the tap
    // simply does nothing, which is the documented (and slightly unfriendly)
    // behaviour.
    await _dismissSheet(tester, find.text('Enter your PIN'));
    expect(find.byType(SecurityPrivacyScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);

    // SET-024: three wrong entries are each rejected and the screen never opens.
    await _tapSettingsRow(tester, 'Security & Privacy');
    await pumpUntil(
      tester,
      find.text('Enter your PIN'),
      label: 'PIN gate sheet',
    );
    await tester.pump(const Duration(milliseconds: 500));
    for (var attempt = 0; attempt < 3; attempt++) {
      await enterRejectedPin(tester, digits: '999999');
      expect(find.byType(SecurityPrivacyScreen), findsNothing);
    }
    await pumpUntilGone(
      tester,
      find.text('Enter your PIN'),
      label: 'PIN sheet after 3 failures',
    );
    expect(find.byType(SecurityPrivacyScreen), findsNothing);

    // The correct PIN opens it, and Show secrets does NOT challenge again.
    await _openSecurityPrivacy(tester);
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Show secrets')),
    );
    await pumpUntil(
      tester,
      find.byType(ShowSecretsScreen),
      label: 'Your secrets',
    );
    // SET-045: exactly one authentication for the whole journey.
    expect(find.text('Enter your PIN'), findsNothing);
    expect(
      _on(ShowSecretsScreen, find.text('Recovery phrase 01')),
      findsOneWidget,
    );
  });

  testWidgets('no biometric row is offered when nothing is enrolled', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);

    // Not greyed out — absent. A control the user could not turn back on is
    // never rendered.
    expect(find.text('Biometric authentication'), findsNothing);
    // PERM-010: and the PIN really is the path in, which _openSecurityPrivacy
    // just proved by getting here through the PIN sheet.
    expect(_on(SecurityPrivacyScreen, find.text('Change PIN')), findsOneWidget);
  });

  testWidgets('the transaction auth threshold is Off by default, saves when '
      'enabled, and discards a cancel', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);

    // SET-038: trailing value reads Off, and the sheet opens with the checkbox
    // clear and the slider inert.
    expect(_on(SecurityPrivacyScreen, find.text('Off')), findsOneWidget);
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Require auth over')),
    );
    await pumpUntil(tester, find.byType(Slider), label: 'threshold sheet');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<Slider>(find.byType(Slider)).onChanged,
      isNull,
      reason: 'the slider must be disabled until the gate is enabled',
    );

    // SET-040 (first half): cancel writes nothing.
    await tapAndSettle(tester, find.text('Cancel'));
    await pumpUntilGone(tester, find.byType(Slider), label: 'threshold sheet');
    expect(_on(SecurityPrivacyScreen, find.text('Off')), findsOneWidget);

    // SET-039: enable, drag to the top of the range, save.
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Require auth over')),
    );
    await pumpUntil(tester, find.byType(Slider), label: 'threshold sheet');
    await tester.pump(const Duration(milliseconds: 500));
    await tapAndSettle(tester, find.text('Require authentication'));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await tapAndSettle(tester, find.text('Save'));
    await pumpUntilGone(tester, find.byType(Slider), label: 'threshold sheet');
    expect(_on(SecurityPrivacyScreen, find.text('Off')), findsNothing);
    expect(_on(SecurityPrivacyScreen, find.text('\$1000')), findsOneWidget);

    // Re-opening shows the saved state, not the defaults.
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Require auth over')),
    );
    await pumpUntil(tester, find.byType(Slider), label: 'threshold sheet');
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1000);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);

    // SET-040 (second half): a cancelled edit leaves both the flag and the
    // amount alone.
    await tester.drag(find.byType(Slider), const Offset(-600, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await tapAndSettle(tester, find.text('Require authentication'));
    await tapAndSettle(tester, find.text('Cancel'));
    await pumpUntilGone(tester, find.byType(Slider), label: 'threshold sheet');
    expect(_on(SecurityPrivacyScreen, find.text('\$1000')), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // PIN management
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('changing the PIN retires the old one and the new one unlocks '
      'the app', (tester) async {
    const newPin = '222222';
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);

    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Change PIN')),
    );
    await pumpUntil(
      tester,
      find.text('Enter your current PIN'),
      label: 'Change PIN step 1',
    );
    await enterPin(tester);
    await pumpUntil(
      tester,
      find.text('Enter a new PIN'),
      label: 'Change PIN step 2',
    );
    await enterPin(tester, digits: newPin);
    await pumpUntil(
      tester,
      find.text('Confirm your new PIN'),
      label: 'Change PIN step 3',
    );
    await enterPin(tester, digits: newPin);
    await pumpUntil(
      tester,
      find.text('PIN changed successfully.'),
      label: 'change-PIN snackbar',
    );
    await pumpUntilGone(
      tester,
      find.byType(ChangePinScreen),
      label: 'Change PIN to pop',
    );

    // The assertion that matters: the credential really moved.
    await relaunchIntoLockScreen(tester);
    // `enterPin`'s default is the PIN onboarding set — the one this test just
    // retired. It must no longer unlock.
    await enterRejectedPin(tester);
    expect(
      find.byType(LockScreen),
      findsOneWidget,
      reason: 'the retired PIN must not unlock the app',
    );
    await unlockApp(tester, pin: newPin);
  }, tags: 'nightly');

  testWidgets('a wrong current PIN and a mismatched confirmation both leave '
      'the stored PIN untouched', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);

    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Change PIN')),
    );
    await pumpUntil(
      tester,
      find.text('Enter your current PIN'),
      label: 'Change PIN step 1',
    );
    await enterRejectedPin(tester, digits: '999999');
    expect(find.text('Enter your current PIN'), findsOneWidget);
    expect(find.text('Enter a new PIN'), findsNothing);

    await enterPin(tester);
    await pumpUntil(
      tester,
      find.text('Enter a new PIN'),
      label: 'Change PIN step 2',
    );
    await enterPin(tester, digits: '222222');
    await pumpUntil(
      tester,
      find.text('Confirm your new PIN'),
      label: 'Change PIN step 3',
    );
    await enterRejectedPin(tester, digits: '333333');
    expect(find.text('Confirm your new PIN'), findsOneWidget);
    expect(find.text('PIN changed successfully.'), findsNothing);

    // Nothing was written: the original PIN still clears the gate. Backing out
    // of the confirm step returns to the new-PIN step first (SET-085), so the
    // flow needs two backs, not one.
    await tapAndSettle(
      tester,
      find.descendant(
        of: find.byType(ChangePinScreen),
        matching: find.byType(MallowHeader),
      ),
    );
    await pumpUntil(
      tester,
      find.text('Enter a new PIN'),
      label: 'back to the new-PIN step',
    );
    await _back(tester, ChangePinScreen);
    await _back(tester, SecurityPrivacyScreen);
    await _openSecurityPrivacy(tester);
    expect(find.byType(SecurityPrivacyScreen), findsOneWidget);
  }, tags: 'nightly');

  testWidgets('Turn off PIN is refused while biometrics are unavailable', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);

    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Change PIN')),
    );
    await pumpUntil(
      tester,
      find.text('Enter your current PIN'),
      label: 'Change PIN step 1',
    );
    await enterPin(tester);
    await pumpUntil(
      tester,
      find.text('Turn off PIN'),
      label: 'Turn off PIN action',
    );
    await tapAndSettle(tester, find.text('Turn off PIN'));
    await pumpUntil(
      tester,
      find.text('Enable biometrics first'),
      label: 'refusal sheet',
    );
    await tester.pump(const Duration(milliseconds: 500));
    // A single acknowledge action — no way to proceed.
    expect(find.text('Turn off'), findsNothing);
    await tapAndSettle(tester, find.text('Got it'));
    await pumpUntilGone(
      tester,
      find.text('Enable biometrics first'),
      label: 'refusal sheet',
    );

    // The PIN is still set: the gate still demands it and still accepts it.
    await _back(tester, ChangePinScreen);
    await _back(tester, SecurityPrivacyScreen);
    await _openSecurityPrivacy(tester);
    expect(find.byType(SecurityPrivacyScreen), findsOneWidget);
  }, tags: 'nightly');

  // ─────────────────────────────────────────────────────────────────────────
  // Secrets
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('Your secrets lists one row per phrase, reveals the imported '
      'words, and forgets them on the way out', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _openSecurityPrivacy(tester);
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Show secrets')),
    );
    await pumpUntil(
      tester,
      find.byType(ShowSecretsScreen),
      label: 'Your secrets',
    );

    // SET-042: one row per DISTINCT phrase, labelled positionally, with every
    // wallet derived from it listed underneath.
    expect(
      _on(ShowSecretsScreen, find.text('Recovery phrase 01')),
      findsOneWidget,
    );
    expect(
      _on(ShowSecretsScreen, find.text('Recovery phrase 02')),
      findsNothing,
    );
    for (final address in [
      kTestWalletSolana,
      kTestWalletEvm,
      kTestWalletTezos,
    ]) {
      expect(
        _on(ShowSecretsScreen, find.text(truncateAddress(address))),
        findsOneWidget,
      );
    }
    // No private-key section on a seed-only device.
    expect(_on(ShowSecretsScreen, find.text('Private keys')), findsNothing);

    await tapAndSettle(tester, find.text('Recovery phrase 01'));
    await pumpUntil(
      tester,
      find.byType(RecoveryPhraseWarningScreen),
      label: 'phrase warning',
    );
    expect(find.byType(SeedPhraseGrid), findsNothing);
    await tapAndSettle(
      tester,
      find.text('I understand the dangers of sharing my phrase'),
    );
    await tapAndSettle(tester, find.text('Continue'));
    await pumpUntil(
      tester,
      find.byType(RecoveryPhraseWordsScreen),
      label: 'word grid',
    );

    // SET-049: a secure-storage round trip of the phrase the import wrote.
    for (final word in kTestWalletMnemonic.split(' ')) {
      expect(find.text(word), findsAtLeastNWidgets(1));
    }
    expect(find.text('12.'), findsOneWidget);
    expect(find.text('13.'), findsNothing);

    // Back skips the warning it replaced.
    await _back(tester, RecoveryPhraseWordsScreen);
    await pumpUntil(
      tester,
      find.byType(ShowSecretsScreen),
      label: 'back to Your secrets',
    );
    expect(find.byType(RecoveryPhraseWarningScreen), findsNothing);

    // SET-054: nothing is cached — re-entry starts at the warning again.
    await tapAndSettle(tester, find.text('Recovery phrase 01'));
    await pumpUntil(
      tester,
      find.byType(RecoveryPhraseWarningScreen),
      label: 'phrase warning on re-entry',
    );
    expect(find.byType(SeedPhraseGrid), findsNothing);
  }, tags: 'nightly');

  // ─────────────────────────────────────────────────────────────────────────
  // Privacy + destructive paths
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets(
    'the analytics toggle persists across re-entry and a relaunch',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await openSettings(tester);
      await _openSecurityPrivacy(tester);

      final analytics = _on(
        SecurityPrivacyScreen,
        find.text('Share usage analytics'),
      );
      expect(_toggleValue(tester, analytics), isTrue);
      await tapAndSettle(tester, analytics);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_toggleValue(tester, analytics), isFalse);

      await _back(tester, SecurityPrivacyScreen);
      await _openSecurityPrivacy(tester);
      expect(_toggleValue(tester, analytics), isFalse);

      await relaunchAndUnlock(tester);
      await openSettings(tester);
      await _openSecurityPrivacy(tester);
      expect(_toggleValue(tester, analytics), isFalse);
    },
    tags: 'nightly',
  );

  testWidgets('reset app wipes the wallet, drops every preference, and returns '
      'to onboarding', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    // SET-059 preconditions: move several settings off their defaults first.
    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    await tapAndSettle(tester, _on(PreferencesScreen, find.text('App Theme')));
    await pumpUntil(tester, find.byType(AppThemeScreen), label: 'App Theme');
    await tapAndSettle(tester, find.text('Light mode'));
    await tester.pump(const Duration(milliseconds: 300));
    await _back(tester, AppThemeScreen);
    await tapAndSettle(
      tester,
      _on(PreferencesScreen, find.text('Preferred Explorer')),
    );
    await pumpUntil(
      tester,
      find.byType(PreferredExplorerScreen),
      label: 'Preferred Explorer',
    );
    await tapAndSettle(tester, find.text('Orb'));
    await tester.pump(const Duration(milliseconds: 200));
    await _back(tester, PreferredExplorerScreen);
    await _back(tester, PreferencesScreen);

    await _tapSettingsRow(tester, 'Active Networks');
    await pumpUntil(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
      label: 'Active networks',
    );
    await tapAndSettle(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
    );
    await _back(tester, ActiveNetworksScreen);
    await pumpUntil(
      tester,
      _on(SettingsScreen, find.text('Solana, Tezos')),
      label: 'badge before reset',
    );

    await _openSecurityPrivacy(tester);
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Share usage analytics')),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // SET-058: the reset itself.
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Reset app')),
    );
    await pumpUntil(tester, find.byType(ResetAppScreen), label: 'Reset app');
    await tapAndSettle(tester, find.text('I have my recovery phrase saved'));
    await tapAndSettle(
      tester,
      find.descendant(
        of: find.byType(AnimatedContainer),
        matching: find.text('Reset app'),
      ),
    );
    await pumpUntil(
      tester,
      find.text('I already have a wallet'),
      label: 'welcome screen after reset',
      rounds: 200,
    );

    // No PIN and no biometric flag survive: a relaunch lands on Welcome with
    // no lock overlay at all.
    await restartApp(tester, wipe: false);
    await pumpUntil(
      tester,
      find.text('I already have a wallet'),
      label: 'welcome screen after relaunch',
      rounds: 200,
    );
    expect(find.byType(LockScreen), findsNothing);
    expect(
      _themeMode(tester),
      ThemeMode.dark,
      reason: 'theme must be back at its default',
    );

    // SET-059: re-onboarding starts from factory defaults.
    await importTestWallet(tester);
    await openSettings(tester);
    expect(
      _on(SettingsScreen, find.text(formatAccountName(1))),
      findsOneWidget,
    );
    expect(_on(SettingsScreen, find.text('All')), findsOneWidget);

    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    await tapAndSettle(
      tester,
      _on(PreferencesScreen, find.text('Preferred Explorer')),
    );
    await pumpUntil(
      tester,
      find.byType(PreferredExplorerScreen),
      label: 'Preferred Explorer',
    );
    expect(_rowIcons('Solscan'), 1);
    expect(_rowIcons('Orb'), 0);
    await _back(tester, PreferredExplorerScreen);
    await _back(tester, PreferencesScreen);

    await _openSecurityPrivacy(tester);
    expect(
      _toggleValue(
        tester,
        _on(SecurityPrivacyScreen, find.text('Share usage analytics')),
      ),
      isTrue,
    );
  }, tags: 'nightly');

  testWidgets('a bug report reaches the backend with its report ID', (
    tester,
  ) async {
    const description = 'e2e settings smoke report';
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _tapSettingsRow(tester, 'Report a bug');
    await pumpUntil(
      tester,
      find.byType(ReportBugScreen),
      label: 'Report a bug',
    );

    final reportId = tester
        .widgetList<Text>(_on(ReportBugScreen, find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .firstWhere(
          (s) => RegExp(r'^RPT-[A-Z0-9]{6}-\d{8}$').hasMatch(s),
          orElse: () => '',
        );
    expect(
      reportId,
      isNotEmpty,
      reason: 'the screen must show an RPT-XXXXXX-YYYYMMDD report id',
    );

    await tapAndSettle(tester, find.text(reportId));
    await pumpUntil(
      tester,
      find.text('Report ID copied'),
      label: 'copy snackbar',
    );

    await enterTextInto(
      tester,
      _on(ReportBugScreen, find.byType(TextField)),
      description,
    );
    await tapAndSettle(tester, _on(ReportBugScreen, find.text('Report')));
    await pumpUntil(
      tester,
      find.text('Bug report submitted. Thank you!'),
      label: 'submitted snackbar',
      rounds: 150,
    );
    await pumpUntilGone(
      tester,
      find.byType(ReportBugScreen),
      label: 'Report a bug to pop',
    );

    // The wire, not just the UI.
    final posts = (await MockControl.requests())
        .where((r) => r.method == 'POST' && r.path.contains('/v1/bugReport'))
        .toList();
    expect(posts, hasLength(1));
    final body = posts.single.body as Map<String, dynamic>;
    expect(body['reportId'], reportId);
    expect(body['message'], description);
    expect(body['platform'], 'Android');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Per-account chain toggles
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('per-chain toggles are staged until Done, then really add and '
      'remove wallets', (tester) async {
    final tezosRow = _on(
      EditAccountScreen,
      find.text(truncateAddress(kTestWalletTezos)),
    );
    final ethRow = _on(
      EditAccountScreen,
      find.text(truncateAddress(kTestWalletEvm)),
    );

    Future<void> openEditAccount() async {
      await tapAndSettle(
        tester,
        _on(SettingsScreen, find.text('Edit account')),
      );
      await pumpUntil(
        tester,
        find.byType(EditAccountScreen),
        label: 'Edit Account',
      );
      await pumpUntil(tester, tezosRow, label: 'derived chain rows');
    }

    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await openEditAccount();
    expect(_toggleValue(tester, tezosRow), isTrue);
    expect(_toggleValue(tester, ethRow), isTrue);

    // SET-074: staged, not live — backing out discards both flips.
    await tapAndSettle(tester, tezosRow);
    await tapAndSettle(tester, ethRow);
    expect(_toggleValue(tester, tezosRow), isFalse);
    expect(_toggleValue(tester, ethRow), isFalse);
    await _back(tester, EditAccountScreen);
    await openEditAccount();
    expect(_toggleValue(tester, tezosRow), isTrue);
    expect(_toggleValue(tester, ethRow), isTrue);

    // SET-073: off + Done really deletes the wallet. The toggle state on
    // re-entry is read from the account's wallet rows, so it is the deletion
    // that is being asserted, not the staged flag.
    await tapAndSettle(tester, tezosRow);
    await tapAndSettle(tester, _on(EditAccountScreen, find.text('Done')));
    await pumpUntilGone(
      tester,
      find.byType(EditAccountScreen),
      label: 'Edit Account to pop',
    );
    await openEditAccount();
    expect(_toggleValue(tester, tezosRow), isFalse);

    // SET-072: on + Done re-derives the wallet at the account's index — the
    // same tz1 address the import picker would produce.
    await tapAndSettle(tester, tezosRow);
    await tapAndSettle(tester, _on(EditAccountScreen, find.text('Done')));
    await pumpUntilGone(
      tester,
      find.byType(EditAccountScreen),
      label: 'Edit Account to pop',
    );
    await openEditAccount();
    expect(_toggleValue(tester, tezosRow), isTrue);
    expect(tezosRow, findsOneWidget);
  }, tags: 'nightly');

  testWidgets('a network switched off is not offered by the import picker', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    await _tapSettingsRow(tester, 'Active Networks');
    await pumpUntil(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
      label: 'Active networks',
    );
    await tapAndSettle(
      tester,
      _on(ActiveNetworksScreen, find.text('Ethereum')),
    );
    await _back(tester, ActiveNetworksScreen);
    await _back(tester, SettingsScreen);

    await openAccountDrawer(tester);
    await pumpUntil(
      tester,
      find.text('Add wallet').hitTestable(),
      label: 'drawer Add wallet row',
    );
    await tapAndSettle(tester, find.text('Add wallet').hitTestable());
    await pumpUntil(
      tester,
      find.byType(AddAccountScreen),
      label: 'Add account',
    );
    // The row only renders once the screen has found a seed-backed account,
    // which is an async DB read.
    final fromPhrase = _on(
      AddAccountScreen,
      find.text('Import wallets from recovery phrase'),
    );
    await pumpUntil(tester, fromPhrase, label: 'import-from-phrase row');
    await tapAndSettle(tester, fromPhrase);
    // The phrase list auto-forwards when the device holds exactly one recovery
    // phrase (`RecoveryPhraseScreen._loadAccounts`: `if (distinct.length == 1)`
    // it selects it and navigates), so there is no row to tap here — the picker
    // is the next screen.
    await pumpUntil(
      tester,
      find.byType(ImportWalletsFromPhraseScreen),
      label: 'import picker',
      rounds: 300,
    );
    // Deriving the first batch of five accounts across three curves takes
    // seconds in a debug build on this emulator.
    await pumpUntil(
      tester,
      find.text(truncateAddress(kTestWalletSolana)),
      label: 'derived Solana row',
      rounds: 400,
    );
    expect(
      find.text(truncateAddress(kTestWalletEvm)),
      findsNothing,
      reason: 'Ethereum is switched off, so no EVM address may be offered',
    );
  }, tags: 'nightly');

  // ─────────────────────────────────────────────────────────────────────────
  // Structure of the tree
  // ─────────────────────────────────────────────────────────────────────────

  testWidgets('no row anywhere in the settings tree reaches an unfinished '
      'screen', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);
    _expectNoUnreachableScreens('settings root');

    // Long-press the identity row and the section labels — SET-080 calls those
    // out specifically as the places a hidden route could hide. The row carries
    // only an onTap, so a long press resolves to that same tap: it opens Edit
    // Account, and nothing else.
    await tester.longPress(_on(SettingsScreen, find.text('Edit account')));
    await tester.pump(const Duration(milliseconds: 600));
    _expectNoUnreachableScreens('identity row long-press');
    if (find.byType(EditAccountScreen).evaluate().isNotEmpty) {
      await _back(tester, EditAccountScreen);
    }
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    _expectNoUnreachableScreens('Preferences');
    // The Currency and Display Language rows are deliberately not rendered.
    expect(
      _on(PreferencesScreen, find.text('Preferred Explorer')),
      findsOneWidget,
    );
    expect(_on(PreferencesScreen, find.text('App Theme')), findsOneWidget);
    expect(_on(PreferencesScreen, find.text('NSFW blur')), findsOneWidget);
    await _back(tester, PreferencesScreen);

    await _tapSettingsRow(tester, 'About mallow');
    await pumpUntil(tester, find.byType(AboutScreen), label: 'About');
    _expectNoUnreachableScreens('About');
    await _back(tester, AboutScreen);

    await _openSecurityPrivacy(tester);
    _expectNoUnreachableScreens('Security & Privacy');
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Show secrets')),
    );
    await pumpUntil(
      tester,
      find.byType(ShowSecretsScreen),
      label: 'Your secrets',
    );
    _expectNoUnreachableScreens('Your secrets');
    await tester.longPress(
      _on(ShowSecretsScreen, find.text('Recovery phrases')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    _expectNoUnreachableScreens('Your secrets section long-press');
    expect(find.byType(ShowSecretsScreen), findsOneWidget);
  });

  testWidgets('every settings screen backs out to its immediate parent', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await openSettings(tester);

    await _tapSettingsRow(tester, 'Preferences');
    await pumpUntil(
      tester,
      find.byType(PreferencesScreen),
      label: 'Preferences',
    );
    await tapAndSettle(tester, _on(PreferencesScreen, find.text('App Theme')));
    await pumpUntil(tester, find.byType(AppThemeScreen), label: 'App Theme');
    await _back(tester, AppThemeScreen);
    expect(find.byType(PreferencesScreen), findsOneWidget);
    await _back(tester, PreferencesScreen);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _tapSettingsRow(tester, 'Active Networks');
    await pumpUntil(
      tester,
      find.byType(ActiveNetworksScreen),
      label: 'Active networks',
    );
    await _back(tester, ActiveNetworksScreen);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _tapSettingsRow(tester, 'About mallow');
    await pumpUntil(tester, find.byType(AboutScreen), label: 'About');
    await _back(tester, AboutScreen);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await _tapSettingsRow(tester, 'Report a bug');
    await pumpUntil(
      tester,
      find.byType(ReportBugScreen),
      label: 'Report a bug',
    );
    await _back(tester, ReportBugScreen);
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Change PIN's confirm step backs up one STEP, not out of the flow.
    await _openSecurityPrivacy(tester);
    await tapAndSettle(
      tester,
      _on(SecurityPrivacyScreen, find.text('Change PIN')),
    );
    await pumpUntil(
      tester,
      find.text('Enter your current PIN'),
      label: 'Change PIN step 1',
    );
    await enterPin(tester);
    await pumpUntil(
      tester,
      find.text('Enter a new PIN'),
      label: 'Change PIN step 2',
    );
    await enterPin(tester, digits: '222222');
    await pumpUntil(
      tester,
      find.text('Confirm your new PIN'),
      label: 'Change PIN step 3',
    );
    await tapAndSettle(
      tester,
      find.descendant(
        of: find.byType(ChangePinScreen),
        matching: find.byType(MallowHeader),
      ),
    );
    await pumpUntil(
      tester,
      find.text('Enter a new PIN'),
      label: 'back to the new-PIN step',
    );
    expect(find.byType(ChangePinScreen), findsOneWidget);

    await _back(tester, ChangePinScreen);
    expect(find.byType(SecurityPrivacyScreen), findsOneWidget);
    await _back(tester, SecurityPrivacyScreen);
    expect(find.byType(SettingsScreen), findsOneWidget);
    await _back(tester, SettingsScreen);
    await waitForHome(tester);
  }, tags: 'nightly');
}
