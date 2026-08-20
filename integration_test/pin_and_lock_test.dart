// E2E: PIN setup, the app-lock overlay, and the failed-PIN lockout ladder.
//
// Bucket `pin-and-lock`: 10 E2E-eligible cases, 8 of them the CI smoke
// subset. Everything that needs a real biometric prompt or a true OS
// backgrounding is dispositioned PATROL and is NOT here.
//
// Case map (case ID -> test):
//
// | Case      | Test name                                              | Suite   |
// | --------- | ------------------------------------------------------ | ------- |
// | `ONB-024` | skipping biometrics lands on a mandatory PIN screen    | smoke   |
// | `ONB-025` | creating a PIN fills dots, confirms, and reaches home  | smoke   |
// | `ONB-085` | the correct PIN unlocks back to the screen behind      | smoke   |
// | `ONB-086` | wrong-PIN messaging counts the attempts down           | smoke   |
// | `ONB-087` | five wrong PINs arm a cooldown that freezes the pad    | smoke   |
// | `ONB-088` | the cooldown survives a relaunch                       | nightly |
// | `ONB-089` | the cooldown escalates 30s -> 60s -> 5m                | nightly |
// | `ONB-095` | the lock is armed in the session that set the PIN      | smoke   |
// | `ONB-100` | the PIN sheet rejects after three wrong attempts       | smoke   |
// | `ONB-101` | dismissing the PIN sheet cancels the gated action      | smoke   |
//
// THREE THINGS THIS FILE DOES DELIBERATELY, EACH FOR A REASON
//
// 1. It locks the app with the shared `lockApp(tester)`, which dispatches
//    `AppLockEvent.lock()` on the app's own bloc rather than backgrounding.
//    The real trigger is a 60-second background threshold read off the wall
//    clock (`_backgroundLockThreshold`, `lib/app.dart`), so a faithful drive
//    costs 60 s per case and cannot be shortened from inside the process. The
//    real threshold is a Patrol case (`LIFE-002`), so `ONB-095` is
//    dispositioned to force the state in-process here, which is what this
//    does. `_onLock` only transitions out of `unlocked`, so this still
//    exercises the regression `ONB-095` exists for: an app that boots into
//    `noPinSet` never locks, and the dispatch would be inert.
//
// 2. It never waits out a cooldown in real time. The tiers are a private
//    `const` list in `AppLockBloc` with no seam, so the only lever is the
//    PERSISTED lockout state that `AppLockEvent.init` rehydrates from
//    `SecureWalletStorage`. Past-dating the stored deadline and relaunching
//    is exactly the "countdown elapsed while the app was closed" branch of
//    `_onInit`, and seeding the stored counter is how the ladder is reached
//    without 2.5 minutes of real cooldowns (see `ONB-089`). Both write
//    through the app's own storage API, never around it.
//
// 3. It synchronises on `AppLockBloc.failedAttempts` between wrong PINs on the
//    LOCK SCREEN, where the counter is the strongest available signal.
//    `verifyPin` runs Argon2id (64 MiB, 3 passes) in a `compute` isolate, so
//    a rejected PIN takes a while to clear the dots -- and `_onNumberTap`
//    drops every tap while six digits are still buffered. Typing the next
//    PIN blind therefore loses digits. The counter is the sync signal only;
//    every assertion below is on visible text or a rendered widget. The modal
//    PIN sheet has no such counter, so its cases use the shared
//    `enterRejectedPin`, which waits on the dots instead.
//
// Run: `test/e2e/run_one.sh integration_test/pin_and_lock_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/core/security/app_lock_bloc.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/features/onboarding/screens/pin_setup_screen.dart';
import 'package:mallow_wallet/features/settings/screens/settings_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/custom_number_pad.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';
import 'package:mallow_wallet/shared/widgets/pin_prompt_sheet.dart';

import 'support/e2e.dart';

/// A PIN that is never the wallet's, so every entry of it is rejected.
const String _wrongPin = '222222';

// ---------------------------------------------------------------------------
// Finders and probes
// ---------------------------------------------------------------------------

Finder get _lockScreen => find.byType(LockScreen);

Finder get _numberPad => find.byType(CustomNumberPad);

Finder get _cooldownMessage => find.textContaining('Too many failed attempts.');

/// Fill colours of the six PIN dots, in order.
///
/// Both PIN surfaces draw their dots as circular [Container]s sized to
/// [MallowTheme.pinDotSize], which is what separates them from the number
/// pad's 72 px circular keys. Comparing the colours to each other -- rather
/// than to a token -- keeps the assertion theme-agnostic: a filled dot simply
/// has to differ from an empty one.
List<Color?> _pinDotColours(WidgetTester tester, {required Finder within}) =>
    tester
        .widgetList<Container>(
          find.descendant(of: within, matching: find.byType(Container)),
        )
        .where((c) {
          final decoration = c.decoration;
          return decoration is BoxDecoration &&
              decoration.shape == BoxShape.circle &&
              c.constraints?.maxWidth == MallowTheme.pinDotSize;
        })
        .map((c) => (c.decoration! as BoxDecoration).color)
        .toList();

/// Fill colours of the lock screen's six dots, in order.
///
/// The lock screen animates its dots, so they are [AnimatedContainer]s rather
/// than the plain [Container]s [_pinDotColours] looks for, and they are the
/// only ones it draws.
List<Color?> _lockDotColours(WidgetTester tester) => tester
    .widgetList<AnimatedContainer>(
      find.descendant(
        of: _lockScreen,
        matching: find.byType(AnimatedContainer),
      ),
    )
    .map((c) => (c.decoration! as BoxDecoration).color)
    .toList();

/// Whether the lock screen currently refuses number-pad input.
bool _padIsFrozen(WidgetTester tester) => tester
    .widget<IgnorePointer>(
      find.ancestor(of: _numberPad, matching: find.byType(IgnorePointer)).first,
    )
    .ignoring;

/// The lock screen's number-pad opacity (0.4 while dimmed by a cooldown).
double _padOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.ancestor(of: _numberPad, matching: find.byType(Opacity)).first,
    )
    .opacity;

/// Seconds left on the displayed cooldown, parsed out of the countdown copy.
///
/// The tier is asserted as a range, not an exact value: the message is
/// rendered from `cooldownUntil.difference(DateTime.now())`, which has already
/// lost a fraction of a second by the time it is built, and it truncates. A
/// freshly armed 30 s tier therefore reads "29s", not "30s".
int _cooldownSecondsLeft(WidgetTester tester) {
  final texts = tester.widgetList<Text>(_cooldownMessage);
  expect(texts, isNotEmpty, reason: 'no cooldown countdown on screen');
  final copy = texts.first.data ?? '';
  final match = RegExp(r'Try again in (?:(\d+)m )?(\d+)s').firstMatch(copy);
  expect(match, isNotNull, reason: 'unparseable cooldown copy: "$copy"');
  final minutes = int.tryParse(match!.group(1) ?? '0') ?? 0;
  return minutes * 60 + int.parse(match.group(2)!);
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

/// Taps a key that is expected to be inert, without the hit-test warning.
///
/// A frozen pad sits under an `IgnorePointer`, so the tap lands on the lock
/// screen behind it. That is the point of the call, not a mistake.
Future<void> _tapFrozenPadKey(WidgetTester tester, String digit) async {
  await tester.tap(
    find.descendant(of: _numberPad, matching: find.text(digit)).first,
    warnIfMissed: false,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

/// Pumps until the lock bloc has counted at least [expected] failed attempts.
Future<AppLockStateLocked> _pumpUntilFailedAttempts(
  WidgetTester tester,
  int expected, {
  int rounds = 300,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final state = appLockBloc(tester).state;
    if (state is AppLockStateLocked && state.failedAttempts >= expected) {
      // One more frame so the rebuild driven by that emission is on screen
      // before the caller asserts on its copy.
      await tester.pump(const Duration(milliseconds: 100));
      return state;
    }
  }
  fail('Timed out waiting for failedAttempts >= $expected');
}

/// Enters [_wrongPin] on the lock screen and waits for rejection number
/// [attempt] to land.
Future<AppLockStateLocked> _enterWrongPin(
  WidgetTester tester,
  int attempt,
) async {
  await enterPin(tester, digits: _wrongPin);
  return _pumpUntilFailedAttempts(tester, attempt);
}

/// Settings -> Security & Privacy, which is gated by `requireReauth`. With no
/// biometric enrolled the gate falls straight through to the modal PIN sheet,
/// which is the surface both sheet cases need.
Future<void> _openPinSheetFromSettings(WidgetTester tester) async {
  await openSettings(tester);

  final securityRow = find.text('Security & Privacy');
  await scrollUntil(
    tester,
    securityRow,
    scrollable: find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first,
    label: 'Security & Privacy row',
  );
  await tapAndSettle(tester, securityRow);

  await pumpUntil(
    tester,
    find.byType(PinPromptSheet),
    label: 'PIN prompt sheet',
    rounds: 150,
  );
  await settleAt(tester, find.byType(PinPromptSheet));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await MockControl.reset();
  });

  // ONB-024 -- biometrics skipped, so a PIN is mandatory: the create-PIN
  // screen offers no way past it.
  testWidgets('skipping biometrics lands on a mandatory PIN screen', (
    tester,
  ) async {
    await restartApp(tester);
    await importTestWalletToPinSetup(tester);

    expect(find.text('Create a PIN'), findsOneWidget);
    expect(
      find.text('Create a 6-digit PIN to keep your wallet safe'),
      findsOneWidget,
    );
    expect(
      find.text('You can change this anytime in settings'),
      findsOneWidget,
    );
    expect(_numberPad, findsOneWidget);

    final dots = _pinDotColours(tester, within: find.byType(PinSetupScreen));
    expect(dots, hasLength(6), reason: 'six PIN dots');
    expect(dots.toSet(), hasLength(1), reason: 'all six start empty');

    // The load-bearing half of the case: no escape hatch, because biometrics
    // were not enabled.
    expect(find.text('Skip for now'), findsNothing);
  });

  // ONB-025 -- create a PIN, confirm it, land on home.
  testWidgets('creating a PIN fills dots, confirms, and reaches home', (
    tester,
  ) async {
    await restartApp(tester);
    await importTestWalletToPinSetup(tester);

    final screen = find.byType(PinSetupScreen);
    // Half a PIN, through the harness's verified pad driver: it re-resolves
    // the key against the topmost pad immediately before each tap and then
    // waits for the dots to move, retrying a tap the pad swallowed. A local
    // one-shot `tapAndSettle` per digit is exactly the dropped-digit flake
    // that driver exists to remove, and it would land on the very screen this
    // case is about.
    await enterPin(tester, digits: '111');
    final partial = _pinDotColours(tester, within: screen);
    expect(partial, hasLength(6));
    expect(partial.take(3).toSet(), hasLength(1), reason: 'three dots filled');
    expect(partial.skip(3).toSet(), hasLength(1), reason: 'three dots empty');
    expect(
      partial.first,
      isNot(partial.last),
      reason: 'a filled dot must read differently from an empty one',
    );

    // The other half. `enterPin` re-samples the dots before typing, so the
    // three already-filled ones are its baseline and each further digit is
    // still verified against it.
    await enterPin(tester, digits: '111');

    await pumpUntil(
      tester,
      find.text('Confirm your PIN'),
      label: 'PIN confirm step',
    );
    expect(find.text('Enter your PIN again to confirm'), findsOneWidget);
    expect(find.text('Create a PIN'), findsNothing);
    // Every dot back to the EMPTY colour sampled above -- "all six alike" on
    // its own would also be satisfied by six filled dots.
    expect(
      _pinDotColours(tester, within: screen),
      everyElement(partial.last),
      reason: 'dots clear for the confirmation entry',
    );

    await enterPin(tester);
    await waitForHome(tester);
  });

  // ONB-095 -- the lock is armed by the session that set the PIN, and stays
  // armed after a relaunch. The regression: the app used to boot into
  // `noPinSet` and only arm the lock on the second launch.
  testWidgets('the lock is armed in the session that set the PIN', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    // Onboarding must not interrupt itself with a lock screen on the way out.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(_lockScreen, findsNothing);

    // Step 2: same session, no relaunch in between.
    await lockApp(tester);
    expect(_lockScreen, findsOneWidget);
    await unlockApp(tester);

    // Steps 3-4: relaunch, unlock, and the lock is armed again.
    await relaunchIntoLockScreen(tester);
    await unlockApp(tester);
    await waitForHome(tester);
    await lockApp(tester);
    expect(_lockScreen, findsOneWidget);
  });

  // ONB-085 -- the correct PIN unlocks, revealing the screen that was already
  // there rather than a fresh home.
  testWidgets('the correct PIN unlocks back to the screen behind', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    // Step off the default screen first, or "the screen you were on" is not
    // falsifiable: an unlock that reset the app to a fresh home would look
    // identical to one that restored it.
    await openSettings(tester);
    expect(find.text('Preferences'), findsOneWidget);

    await lockApp(tester);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Enter your PIN to unlock'), findsOneWidget);
    expect(_numberPad, findsOneWidget);
    final dots = _lockDotColours(tester);
    expect(dots, hasLength(6), reason: 'six PIN dots');
    expect(dots.toSet(), hasLength(1), reason: 'all six start empty');

    await unlockApp(tester);

    // Still on the pushed Settings route, not bounced back to home. A fresh
    // home screen carries no "Preferences" row, so this is falsifiable.
    //
    // Element identity is NOT the assertion here, and measuring it was wrong:
    // the lock overlay swaps the routed app between two different parent
    // widgets (`Stack` while locked, `CastErrorToastListener` while not), so
    // the whole routed subtree really is torn down and rebuilt. What survives
    // is the router's location, which is what the case is actually about.
    await pumpUntil(
      tester,
      find.text('Preferences'),
      label: 'Settings still on screen after unlock',
    );
    expect(find.text('Preferences'), findsOneWidget);
  });

  // ONB-086 -- wrong-PIN copy: generic for the first two, then a countdown.
  testWidgets('wrong-PIN messaging counts the attempts down', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await lockApp(tester);

    await _enterWrongPin(tester, 1);
    expect(find.text('Wrong PIN. Please try again.'), findsOneWidget);

    await _enterWrongPin(tester, 2);
    expect(find.text('Wrong PIN. Please try again.'), findsOneWidget);

    await _enterWrongPin(tester, 3);
    expect(find.text('Wrong PIN. 2 attempts remaining.'), findsOneWidget);

    await _enterWrongPin(tester, 4);
    expect(find.text('Wrong PIN. 1 attempts remaining.'), findsOneWidget);

    // Four failures is not a lockout -- the correct PIN still works.
    expect(_padIsFrozen(tester), isFalse);
    await unlockApp(tester);
    await waitForHome(tester);
  });

  // ONB-087 -- the fifth wrong PIN arms a cooldown: the pad dims, stops
  // accepting input (the correct PIN included), and nothing is wiped. The
  // expiry half is driven through the persisted deadline rather than 30 s of
  // wall clock; see the header note.
  testWidgets('five wrong PINs arm a cooldown that freezes the pad', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await lockApp(tester);

    for (var attempt = 1; attempt <= 5; attempt++) {
      await _enterWrongPin(tester, attempt);
    }

    await pumpUntil(tester, _cooldownMessage, label: 'cooldown countdown');
    expect(
      _cooldownSecondsLeft(tester),
      inInclusiveRange(20, 30),
      reason: 'the first tier is 30 s',
    );
    expect(_padIsFrozen(tester), isTrue);
    expect(_padOpacity(tester), lessThan(1.0), reason: 'the pad is dimmed');

    // Even the CORRECT PIN is refused while the cooldown runs.
    for (var i = 0; i < 6; i++) {
      await _tapFrozenPadKey(tester, '1');
    }
    expect(_lockScreen, findsOneWidget);
    expect(_cooldownMessage, findsOneWidget);

    // Model the countdown elapsing while the app was closed: `_onInit` drops
    // a persisted deadline that is already in the past and re-enables entry.
    await sl<SecureWalletStorage>().storePinCooldownUntil(
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await relaunchIntoLockScreen(tester);

    expect(_cooldownMessage, findsNothing);
    expect(_padIsFrozen(tester), isFalse);
    await unlockApp(tester);

    // Nothing was wiped.
    await waitForHome(tester);
    expect(await sl<SecureWalletStorage>().hasPin(), isTrue);
  });

  // ONB-088 -- force-quitting during a cooldown must not clear it, and must
  // not reset the attempt counter that decides the next tier.
  testWidgets('the cooldown survives a relaunch', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await lockApp(tester);

    for (var attempt = 1; attempt <= 5; attempt++) {
      await _enterWrongPin(tester, attempt);
    }
    await pumpUntil(tester, _cooldownMessage, label: 'cooldown countdown');

    // The ladder is persisted, not just held in memory.
    final storage = sl<SecureWalletStorage>();
    expect(await storage.loadFailedPinAttempts(), 5);
    expect(await storage.loadPinCooldownUntil(), isNotNull);

    await relaunchIntoLockScreen(tester);

    await pumpUntil(
      tester,
      _cooldownMessage,
      label: 'cooldown countdown after relaunch',
    );
    expect(_padIsFrozen(tester), isTrue);
    expect(
      await sl<SecureWalletStorage>().loadFailedPinAttempts(),
      5,
      reason: 'force-quitting must not reset the attempt counter',
    );
  }, tags: 'nightly');

  // ONB-089 -- the cooldown escalates every five failures: 30s, 60s, 5m. The
  // counter is seeded through the app's own storage between tiers, because
  // every failure at or above five arms its own cooldown -- reaching the
  // tenth failure by typing costs five real 30 s waits.
  testWidgets('the cooldown escalates 30s -> 60s -> 5m', (tester) async {
    await completeOnboardingWithTestWallet(tester);

    Future<int> tierAfterSeeding(int priorFailures) async {
      final storage = sl<SecureWalletStorage>();
      await storage.storeFailedPinAttempts(priorFailures);
      await storage.deletePinCooldownUntil();

      await relaunchIntoLockScreen(tester);
      await _enterWrongPin(tester, priorFailures + 1);
      await pumpUntil(tester, _cooldownMessage, label: 'cooldown countdown');
      return _cooldownSecondsLeft(tester);
    }

    expect(
      await tierAfterSeeding(4),
      inInclusiveRange(20, 30),
      reason: 'failure 5 -> 30 s',
    );
    expect(
      await tierAfterSeeding(9),
      inInclusiveRange(45, 60),
      reason: 'failure 10 -> 60 s',
    );
    expect(
      await tierAfterSeeding(14),
      inInclusiveRange(270, 300),
      reason: 'failure 15 -> 5 min',
    );
    // Above a minute the copy switches to the "Xm Ys" form.
    expect(
      find.textContaining(RegExp(r'Try again in \d+m \d+s')),
      findsOneWidget,
    );
  }, tags: 'nightly');

  // ONB-100 -- three wrong entries close the modal PIN sheet, and the gated
  // screen is not entered.
  testWidgets('the PIN sheet rejects after three wrong attempts', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await _openPinSheetFromSettings(tester);

    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(
      find.text('Confirm your PIN to authorize this transaction.'),
      findsOneWidget,
    );

    // First two rejections keep the sheet open and clear the dots.
    // `enterRejectedPin` is what makes attempt 2 real: verification is
    // Argon2id on a `compute` isolate, and until it resolves the buffer is
    // still full and every further tap is dropped -- so typing the second
    // wrong PIN straight after the first would enter nothing at all.
    for (var attempt = 1; attempt <= 2; attempt++) {
      await enterRejectedPin(tester, digits: _wrongPin);
      expect(find.byType(PinPromptSheet), findsOneWidget);
    }

    await enterPin(tester, digits: _wrongPin);
    await pumpUntilGone(
      tester,
      find.byType(PinPromptSheet),
      label: 'PIN prompt sheet',
      rounds: 200,
    );

    // The gate denied the action: Security & Privacy was never pushed.
    expect(find.text('Change PIN'), findsNothing);
    expect(find.text('Show secrets'), findsNothing);
    expect(find.text('Preferences'), findsOneWidget);
  });

  // ONB-101 -- swiping the sheet away cancels the gated action.
  testWidgets('dismissing the PIN sheet cancels the gated action', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await _openPinSheetFromSettings(tester);
    expect(find.text('Enter your PIN'), findsOneWidget);

    await tester.drag(find.byType(PinPromptSheet), const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntilGone(
      tester,
      find.byType(PinPromptSheet),
      label: 'PIN prompt sheet',
      rounds: 200,
    );

    expect(find.text('Change PIN'), findsNothing);
    expect(find.text('Show secrets'), findsNothing);
    expect(find.text('Preferences'), findsOneWidget);
  });
}
