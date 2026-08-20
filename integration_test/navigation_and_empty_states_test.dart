// E2E: navigation graph + empty-wallet rendering.
//
// Bucket `navigation-and-empty-states`: tab switching, back-stack behaviour,
// drawer gestures, the quick-actions FAB, the unknown-route error screen, and
// what each main surface looks like on a wallet that holds nothing.
//
// It runs on the `default` fixtures, which ARE the empty-wallet baseline: a
// signed-in wallet that holds nothing, with every body in the shape its wire
// contract specifies. This file used to need a `nav_empty_wallet` scenario on
// top, because `default` answered the portfolio and activity reads with bodies
// that were empty but the WRONG SHAPE — so those screens rendered an ERROR
// view that reads, to a careless assertion, exactly like an empty state. Those
// four routes now live in `default` itself and the scenario directory is
// gone.
//
// | Case       | Test name                                                     | Subset  |
// | ---------- | ------------------------------------------------------------- | ------- |
// | `PLAT-010` | fresh launch is crash-free and every relaunch unlocks           | smoke   |
// | `NAV-001`  | three tabs are present and switch content                       | smoke   |
// | `NAV-002`  | tab state survives switching                                    | smoke   |
// | `NAV-003`  | rapid tab tapping lands on the last tap                         | smoke   |
// | `NAV-004`  | quick-actions FAB opens and closes the action menu              | smoke   |
// | `NAV-005`  | FAB is hidden for a watch-only wallet                           | nightly |
// | `NAV-006`  | drawer opens by chevron and edge swipe                          | smoke   |
// | `NAV-008`  | drawer closes on tab switch                                     | smoke   |
// | `NAV-009`  | back from a pushed route pops it, drawer stays shut             | smoke   |
// | `NAV-011`  | unknown route renders the error screen                          | smoke   |
// | `BUY-001`  | portfolio action row holds exactly the shipped buttons          | nightly |
// | `BUY-002`  | empty Tokens tab prompts to fund and opens Receive              | smoke   |
//
// 10 smoke + 2 nightly, which is this bucket's whole quota.
//
// Cases in this bucket that are NOT here, and why:
//   * `NAV-007` (iOS drawer momentum) and `ONB-115` — MANUAL.
//   * `NAV-010`, `ONB-116`, `ONB-117`, `A11Y-002/003/006/007` — WIDGET.
//   * `A11Y-005` — MANUAL (screen-reader output is a human judgement).
//   * The hardware-back half of `NAV-006` (steps 4-5: back closes the drawer,
//     back on a closed tab root OPENS it) is `PLAT-003` in the Patrol phase.
//     It is deliberately NOT faked with a widget tap here.
//
// Two deviations from the case text, both called out at the test:
//   * `PLAT-010` waits 3 s rather than 30 s on the first screen, and relaunches
//     3 times rather than 5. `integration_test` cannot restart the process, so
//     a "relaunch" is `restartApp(wipe: false)` over persisted storage.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/features/home/widgets/account_menu_drawer.dart';
import 'package:mallow_wallet/features/portfolio/screens/tokens_tab_content.dart';
import 'package:mallow_wallet/features/portfolio/screens/your_art_screen.dart';
import 'package:mallow_wallet/features/portfolio/widgets/portfolio_action_buttons.dart';
import 'package:mallow_wallet/features/portfolio/widgets/portfolio_value_section.dart';
import 'package:mallow_wallet/features/portfolio/widgets/tokens_empty_state.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';
import 'package:mallow_wallet/shared/widgets/tappable.dart';

import 'support/e2e.dart';

// ---------------------------------------------------------------------------
// Finders
// ---------------------------------------------------------------------------

/// One of the three nav-bar tabs, by its accessibility label.
///
/// The tabs are icon-only `_NavItem`s (private), so there is no text to find
/// and no exported key. The `Semantics` wrapper each one carries is the only
/// stable public handle. Matched on the WIDGET's properties rather than through
/// `find.bySemanticsLabel`, which needs the semantics tree switched on.
Finder _navTab(String label) => find.descendant(
  of: find.byType(MallowBottomNavBar),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
    description: 'nav tab "$label"',
  ),
);

/// The centre lightning-bolt quick-actions button.
Finder _fab() => find.descendant(
  of: find.byType(MallowBottomNavBar),
  matching: find.byWidgetPredicate(
    (w) => w is Tappable && w.semanticLabel == 'Quick actions',
    description: 'quick-actions FAB',
  ),
);

/// The account chevron in the shared header — the drawer's tap affordance.
Finder _accountChevron() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Open account menu',
  description: 'account chevron',
);

// ---------------------------------------------------------------------------
// Assertions on things that move
// ---------------------------------------------------------------------------

/// Left edge of the drawer panel in logical pixels: `0` when fully open,
/// `-panelWidth` when fully closed.
///
/// The drawer is always mounted — `TabNavigator` slides it with a
/// `Transform.translate` rather than adding/removing it — so its presence
/// proves nothing and its POSITION is the only real assertion available.
double _drawerLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byType(AccountMenuDrawer)).dx;

/// Pumps until the drawer has finished settling [open] (or fails).
///
/// The closed target is derived from the panel's own measured width instead of
/// the private `_menuWidth` constant, so a design change to the drawer width
/// does not silently turn this into a no-op.
Future<void> _expectDrawer(WidgetTester tester, {required bool open}) async {
  final panel = find.byType(AccountMenuDrawer);
  if (panel.evaluate().isEmpty) fail('Drawer panel is not in the tree');
  final target = open ? 0.0 : -tester.getSize(panel).width;
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if ((_drawerLeft(tester) - target).abs() < 0.5) return;
  }
  fail(
    'Drawer never settled ${open ? "open" : "closed"} '
    '(left=${_drawerLeft(tester)}, expected $target)',
  );
}

/// Top edge of the nav bar once it has stopped animating.
///
/// The bar is never unmounted: `_PersistentNavBar` hides it with an
/// `AnimatedSlide` of one full height plus an `IgnorePointer`. So "is the nav
/// bar showing" is a question about geometry, and comparing the settled top
/// against the on-a-tab-root value is what makes a hide/show regression fail.
Future<double> _settledNavBarTop(WidgetTester tester) async {
  final bar = find.byType(MallowBottomNavBar);
  double? previous;
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (bar.evaluate().isEmpty) {
      previous = null;
      continue;
    }
    final top = tester.getTopLeft(bar).dy;
    if (previous != null && (top - previous).abs() < 0.5) return top;
    previous = top;
  }
  fail('Nav bar never stopped moving');
}

/// The live nav bar widget, for reading `currentTab` / `showFab`.
MallowBottomNavBar _navBar(WidgetTester tester) =>
    tester.widget<MallowBottomNavBar>(find.byType(MallowBottomNavBar));

/// Asserts exactly one tab's screen is on stage, and names the highlight the
/// bar is drawing. `skipOffstage` (default) is doing the work: visited tabs
/// stay mounted behind an `Offstage`, so a plain presence check would match all
/// three and prove nothing.
void _expectOnStage(WidgetTester tester, Type screen, MallowNavTab tab) {
  const screens = [HomeScreen, YourArtScreen, TokensTabContent];
  for (final candidate in screens) {
    expect(
      find.byType(candidate),
      candidate == screen ? findsOneWidget : findsNothing,
      reason: '$candidate on-stage expectation while showing $screen',
    );
  }
  expect(_navBar(tester).currentTab, tab, reason: 'nav bar highlight');
}

// ---------------------------------------------------------------------------
// Flow helpers
// ---------------------------------------------------------------------------

/// Cold app -> imported deterministic wallet -> Home, with the feed settled.
///
/// Every `testWidgets` starts here. Re-onboarding per case costs ~10 s but
/// keeps the file order-independent: a case that leaves the app three routes
/// deep, or holding a watch-only wallet, cannot poison the next one.
Future<void> _bootToHome(WidgetTester tester) async {
  await completeOnboardingWithTestWallet(tester);
  await pumpUntil(tester, find.byType(HomeScreen), label: 'Home feed');
}

/// Logical screen size, for taps that must land at a screen-relative point
/// (the pushed-aside content beside an open drawer, the left edge strip).
Size _screenSize(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

/// Switches to [tab] through the nav bar and waits for its screen to be on
/// stage.
Future<void> _tapTab(
  WidgetTester tester,
  String label,
  Type screen, {
  String? waitFor,
}) async {
  await tapAndSettle(tester, _navTab(label));
  await pumpUntil(tester, find.byType(screen), label: '$label tab');
  if (waitFor != null) {
    await pumpUntil(tester, find.text(waitFor), label: '$label tab content');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // A fault or scenario left armed by a failing case is the classic
    // cross-case contaminant.
    await MockControl.reset();
    // The `NavBarState` statics that a real process restart would clear are
    // reset by `restartApp` (see `resetAppStatics` in the harness) — every
    // case here starts with one, so there is nothing to do per-case. Two
    // distinct failures were traced to those leaks on this file: a
    // `ValueNotifier` does not notify on an unchanged write, so the first tap
    // on a leaked `selectedTab` was silently swallowed (NAV-002's Portfolio
    // tap issued no `/v2/portfolio/*` request at all after NAV-001); and a
    // stale `activeTab` makes `_TabNavigatorState.initState` write a CHANGED
    // value while the router is mid-build, tripping `setState() during build`
    // in the persistent nav bar. The second one is a real app bug — see the
    // report — reset rather than absorbed so it cannot masquerade as a
    // failure of whichever case runs next.
  });

  // PLAT-010 — fresh install, crash-free launch.
  //
  // Deviations from the case text, both forced by the harness rather than
  // chosen: the 30 s soak is 3 s (the case is a crash gate, and 30 s of idle
  // pumping buys nothing a mounted-and-still-rendering assertion does not), and
  // "force-quit and relaunch five times" is three `restartApp(wipe: false)`
  // cycles. `integration_test` cannot restart the process; a relaunch here is a
  // torn-down widget tree plus a rebuilt DI graph over the SAME persisted
  // stores, which is what the case is really checking. A genuine process kill
  // stays with Patrol.
  testWidgets(
    'PLAT-010 fresh launch is crash-free and every relaunch unlocks',
    (tester) async {
      await restartApp(tester);

      // 1. First launch reaches the welcome screen.
      await pumpUntil(
        tester,
        find.text('Create a new wallet'),
        label: 'Welcome screen',
      );
      expect(find.text('I already have a wallet'), findsOneWidget);

      // 2. Let it sit. The welcome screen animates forever, so "still there
      //    after N frames with nothing thrown" is the crash assertion.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Create a new wallet'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 3. Complete onboarding.
      await importTestWallet(tester);
      await pumpUntil(tester, find.byType(HomeScreen), label: 'Home feed');

      // 4. Relaunch repeatedly. Each one must land on the PIN lock and unlock
      //    back to Home — never the welcome screen (that would mean the wallet
      //    did not survive) and never Home unlocked (that would mean the lock
      //    did not arm).
      for (var launch = 1; launch <= 3; launch++) {
        // The shared relaunch never samples once: AppLockEvent.init reads the
        // database asynchronously, so the routed Home renders first and
        // LockScreen drops over it a frame or two later.
        await relaunchIntoLockScreen(
          tester,
          label: 'lock screen on relaunch $launch',
        );
        expect(
          find.text('Enter your PIN to unlock'),
          findsOneWidget,
          reason: 'relaunch $launch',
        );

        await unlockApp(tester);
        await waitForHome(tester);
        expect(find.text('Create a new wallet'), findsNothing);
        expect(tester.takeException(), isNull, reason: 'relaunch $launch');
      }
    },
  );

  // NAV-001 — three tabs are present and switch content.
  testWidgets('NAV-001 three tabs are present and switch content', (
    tester,
  ) async {
    await _bootToHome(tester);

    // Exactly three tabs plus the centre FAB.
    expect(_navTab('Home'), findsOneWidget);
    expect(_navTab('Portfolio'), findsOneWidget);
    expect(_navTab('Tokens'), findsOneWidget);
    expect(_fab(), findsOneWidget);
    expect(_navBar(tester).showFab, isTrue);

    // Only the initial tab is built; the other two are not in the tree at all
    // until first visited.
    _expectOnStage(tester, HomeScreen, MallowNavTab.home);

    // Portfolio: assert the empty-wallet copy, not merely "the screen is
    // there" — a blank Portfolio would satisfy the latter for the wrong
    // reason.
    await _tapTab(tester, 'Portfolio', YourArtScreen, waitFor: 'No art yet');
    _expectOnStage(tester, YourArtScreen, MallowNavTab.portfolio);
    expect(find.text('Start collecting art to see it here'), findsOneWidget);

    await _tapTab(tester, 'Tokens', TokensTabContent);
    await pumpUntil(
      tester,
      find.byType(TokensEmptyState),
      label: 'Tokens empty state',
    );
    _expectOnStage(tester, TokensTabContent, MallowNavTab.tokens);

    await _tapTab(tester, 'Home', HomeScreen);
    _expectOnStage(tester, HomeScreen, MallowNavTab.home);
    expect(tester.takeException(), isNull);
  });

  // NAV-002 — tab state survives switching.
  //
  // The case phrases this as scroll position, which an empty wallet has
  // none of. The mechanism underneath is what actually matters and IS
  // assertable here: `TabNavigator` keeps every visited tab mounted behind an
  // `Offstage`, so returning repaints the existing State instead of
  // reconstructing the screen and re-running its load from a skeleton. A
  // regression that drops the keep-alive shows up as a NEW State object and a
  // re-run of the loading path — both fail below.
  testWidgets('NAV-002 tab state survives switching', (tester) async {
    await _bootToHome(tester);

    await _tapTab(tester, 'Portfolio', YourArtScreen, waitFor: 'No art yet');
    final firstState = tester.state<State<YourArtScreen>>(
      find.byType(YourArtScreen),
    );

    await _tapTab(tester, 'Home', HomeScreen);
    // Still mounted, just off stage.
    expect(find.byType(YourArtScreen), findsNothing);
    expect(find.byType(YourArtScreen, skipOffstage: false), findsOneWidget);

    await tapAndSettle(tester, _navTab('Portfolio'));
    await tester.pump(const Duration(milliseconds: 200));

    // Back immediately, with no loading pass in between: the loaded content is
    // on screen on the first frames after the switch.
    expect(find.text('No art yet'), findsOneWidget);
    expect(
      tester.state<State<YourArtScreen>>(find.byType(YourArtScreen)),
      same(firstState),
      reason: 'Portfolio tab was rebuilt from scratch instead of restored',
    );
    _expectOnStage(tester, YourArtScreen, MallowNavTab.portfolio);
  });

  // NAV-003 — rapid tab tapping.
  testWidgets('NAV-003 rapid tab tapping lands on the last tap', (
    tester,
  ) async {
    await _bootToHome(tester);

    // Deliberately NOT `tapAndSettle`: settling between taps is the opposite
    // of what this case exercises. The bar itself does not move while tabs
    // switch, so a bare tap is safe here.
    const sequence = ['Portfolio', 'Tokens', 'Home', 'Portfolio', 'Tokens'];
    for (final label in sequence) {
      await tester.tap(_navTab(label).first);
      await tester.pump(const Duration(milliseconds: 40));
    }

    await pumpUntil(
      tester,
      find.byType(TokensTabContent),
      label: 'Tokens tab after rapid switching',
    );
    // Let the cross-fade finish before judging what is on stage.
    await tester.pump(const Duration(milliseconds: 400));

    _expectOnStage(tester, TokensTabContent, MallowNavTab.tokens);
    expect(tester.takeException(), isNull);
  });

  // NAV-004 — quick-actions FAB.
  testWidgets('NAV-004 quick-actions FAB opens and closes the action menu', (
    tester,
  ) async {
    await _bootToHome(tester);

    expect(find.text('Mint'), findsNothing);

    // Open on the first tap.
    await tapAndSettle(tester, _fab());
    await pumpUntil(tester, find.text('Mint'), label: 'action menu');
    expect(find.text('Sell'), findsOneWidget);
    expect(find.text('Receive'), findsOneWidget);
    // The menu is a NavBarTransparentRoute, so the bar it is anchored to must
    // NOT flicker away underneath it. Presence is not that assertion — the bar
    // is mounted on every screen — the visibility refcount is: a route that
    // was not transparent would fire `didPushNext` on the TabNavigator below
    // and release it.
    expect(NavBarState.visible.value, isTrue, reason: 'bar stays shown');

    // Close on the second tap.
    await tapAndSettle(tester, _fab());
    await pumpUntilGone(tester, find.text('Mint'), label: 'action menu');

    // Re-open, then dismiss by tapping outside it (the menu is anchored
    // bottom-right; the top-left corner is barrier).
    await tapAndSettle(tester, _fab());
    await pumpUntil(tester, find.text('Mint'), label: 'action menu reopened');
    await tester.tapAt(const Offset(24, 120));
    await pumpUntilGone(
      tester,
      find.text('Mint'),
      label: 'action menu after outside tap',
    );

    // ActionMenu tracks open/closed in a static, and `restartApp` disposes the
    // tree rather than popping routes — leaving it open would strand that flag
    // and break the next case's first FAB tap.
    expect(tester.takeException(), isNull);
  });

  // NAV-005 — FAB hidden for watch-only wallets.
  //
  // Nightly: the only way to get a watch-only wallet is to drive the real
  // add-wallet flow (onboarding offers no watch path), which is four extra
  // screens on top of the shared onboarding cost.
  testWidgets('NAV-005 FAB is hidden for a watch-only wallet', (tester) async {
    await _bootToHome(tester);
    expect(_navBar(tester).showFab, isTrue, reason: 'signable wallet');

    // The drawer is a means to the add-wallet flow here, not the subject: the
    // shared opener re-taps a swallowed toggle. NAV-006 below is where the
    // chevron itself is under test, so it keeps the raw tap.
    await openAccountDrawer(tester);
    await _expectDrawer(tester, open: true);

    await tapAndSettle(tester, find.text('Add wallet'));
    await pumpUntil(
      tester,
      find.text('Watch address'),
      label: 'Add-wallet menu',
    );
    await tapAndSettle(tester, find.text('Watch address'));

    await pumpUntil(
      tester,
      find.text('Enter the wallet you want to watch'),
      label: 'Watch-address screen',
    );
    // A third-party address, so nothing here collides with the imported
    // deterministic wallet's own rows.
    await enterTextInto(
      tester,
      find.byType(TextField).last,
      'So11111111111111111111111111111111111111112',
    );

    await tapAndSettle(tester, find.text('Continue'));

    // The watch wallet becomes the active session, which re-reads the active
    // wallet type behind the nav bar.
    await pumpUntil(
      tester,
      find.byWidgetPredicate(
        (w) => w is MallowBottomNavBar && !w.showFab,
        description: 'nav bar without the FAB',
      ),
      label: 'watch-only nav bar',
      rounds: 150,
    );

    // The three tabs stay, and re-space themselves without the FAB's slot.
    expect(_fab(), findsNothing);
    expect(_navTab('Home'), findsOneWidget);
    expect(_navTab('Portfolio'), findsOneWidget);
    expect(_navTab('Tokens'), findsOneWidget);
  }, tags: 'nightly');

  // NAV-006 — drawer opens by chevron and edge swipe, closes on the content
  // tap. Steps 4-5 (Android hardware back closes it, then re-opens it from a
  // closed tab root) are PLAT-003 in the Patrol phase: the back key is a native
  // input, and a widget tap standing in for it would assert nothing about the
  // gesture that actually ships.
  testWidgets('NAV-006 drawer opens by chevron and edge swipe', (tester) async {
    await _bootToHome(tester);
    await _expectDrawer(tester, open: false);

    final screen = _screenSize(tester);
    // A point in the tab content that is still content once the drawer has
    // pushed it right, and clear of the nav bar at the bottom.
    final onContent = Offset(screen.width - 24, screen.height / 2);

    // 1. Chevron opens it.
    await tapAndSettle(tester, _accountChevron());
    await _expectDrawer(tester, open: true);
    expect(find.text('Add wallet'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // 2. Tapping the pushed-aside content closes it.
    await tester.tapAt(onContent);
    await _expectDrawer(tester, open: false);

    // 3. A swipe from the very left edge opens it. `flingFrom` carries a
    //    velocity, which is what `_onDrawerDragEnd` reads to decide the
    //    settle direction (a rightward flick opens).
    await tester.flingFrom(
      Offset(4, screen.height / 2),
      const Offset(280, 0),
      900,
    );
    await _expectDrawer(tester, open: true);

    // Leave it closed so nothing leaks into the next case.
    await tester.tapAt(onContent);
    await _expectDrawer(tester, open: false);
    expect(tester.takeException(), isNull);
  });

  // NAV-008 — drawer closes on tab switch.
  //
  // The case step is "with the drawer open, tap the Portfolio tab". On a
  // compact phone that tap is not performable, and the assertion below pins
  // why: an open drawer slides the WHOLE shell — nav bar included — 300 dp
  // right, which on the 411 dp emulator carries the nav pill past the right
  // edge. So the selection is delivered through `NavBarState.selectedTab`, the
  // public notifier `MallowBottomNavBar.onTabSelected` writes and the one the
  // header's wallet-value shortcut already uses (`shared_header.dart`
  // `_WalletValue`). Everything downstream — closing the drawer, swapping the
  // tab, moving the highlight — is the app's real code path.
  //
  // The geometry expectation is deliberate, not defensive: if the drawer is
  // narrowed or the bar stops sliding, the tab becomes tappable, this fails,
  // and someone re-decides whether to go back to the literal tap.
  testWidgets('NAV-008 drawer closes on tab switch', (tester) async {
    await _bootToHome(tester);

    await tapAndSettle(tester, _accountChevron());
    await _expectDrawer(tester, open: true);

    expect(
      tester.getCenter(_navTab('Portfolio')).dx,
      greaterThan(_screenSize(tester).width),
      reason:
          'nav tabs are expected to be pushed off-screen by the open drawer; '
          'if they are reachable again, tap the tab instead of the notifier',
    );

    NavBarState.selectedTab.value = MallowNavTab.portfolio;

    await _expectDrawer(tester, open: false);
    await pumpUntil(tester, find.text('No art yet'), label: 'Portfolio tab');
    _expectOnStage(tester, YourArtScreen, MallowNavTab.portfolio);
  });

  // NAV-009 — back navigation from pushed screens is unaffected.
  //
  // The case opens a profile from an artist avatar; an empty-wallet Home
  // renders no artist rows, so the pushed route here is the Activity sheet from
  // the header — a `ModalRoute` on the ROOT navigator, which is the same stack
  // position and the same `navBarRouteObserver` subscription a pushed screen
  // gets. The load-bearing part is the back press: `TabNavigator` wraps a tab
  // root in `PopScope(canPop: false)` and repurposes back to toggle the drawer,
  // and that must not leak to a route pushed on top.
  //
  // `handlePopRoute()` is not a stand-in tap: it is the exact Dart entry point
  // the Android embedder's `flutter/navigation` `popRoute` call reaches, for
  // both the legacy back button and the predictive-back callback. What it does
  // NOT cover is the native layer above it (callback registration, the
  // predictive-back animation) — that stays with Patrol.
  testWidgets('NAV-009 back from a pushed route pops it, drawer stays shut', (
    tester,
  ) async {
    await _bootToHome(tester);
    await _expectDrawer(tester, open: false);
    final rootTop = await _settledNavBarTop(tester);

    await tapAndSettle(
      tester,
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Activity',
        description: 'header activity button',
      ),
    );
    await pumpUntil(
      tester,
      find.text('Recent activity'),
      label: 'activity sheet',
    );
    // Empty wallet, so the sheet's own empty state is the correct content —
    // asserted so a sheet that opened onto an error view cannot pass here.
    await pumpUntil(
      tester,
      find.text('No activity yet'),
      label: 'activity empty state',
    );

    // The nav bar retracts while a route sits on top of the tab root.
    final pushedTop = await _settledNavBarTop(tester);
    expect(
      pushedTop,
      greaterThan(rootTop + 10),
      reason: 'nav bar did not hide under the pushed route',
    );

    await tester.binding.handlePopRoute();
    await pumpUntilGone(
      tester,
      find.text('Recent activity'),
      label: 'activity sheet after back',
    );

    // Back popped the route. It did NOT fall through to the tab root's
    // back-opens-drawer handler, and the bar came back where it was.
    await _expectDrawer(tester, open: false);
    _expectOnStage(tester, HomeScreen, MallowNavTab.home);
    expect(await _settledNavBarTop(tester), closeTo(rootTop, 1.0));
  });

  // NAV-011 — unknown route error screen.
  //
  // Router-level: delivery of a real bad deep link is LINK-005/006 (Patrol).
  testWidgets('NAV-011 unknown route renders the error screen', (tester) async {
    await _bootToHome(tester);

    // Navigate from a context BELOW the router's Navigator — the nav bar and
    // the lock overlay sit above it and carry no InheritedGoRouter.
    GoRouter.of(
      tester.element(find.byType(HomeScreen)),
    ).go('/does-not-exist/x');

    await pumpUntil(
      tester,
      find.text('Something went wrong'),
      label: 'unknown-route error screen',
    );
    // The error text itself is rendered, not just the headline.
    expect(find.textContaining('/does-not-exist/x'), findsOneWidget);

    // The back arrow falls back to Home when there is nothing to pop.
    await tapAndSettle(
      tester,
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(IconButton),
      ),
    );
    await waitForHome(tester);
    // The bar is mounted everywhere, so presence proves nothing; that it is
    // SHOWN (the refcount TabNavigator raises while it is topmost) does.
    expect(NavBarState.visible.value, isTrue, reason: 'nav bar after back');
    expect(find.text('Something went wrong'), findsNothing);
  });

  // BUY-001 — no Buy button in the portfolio action row.
  //
  // Nightly. The fiat on-ramp was removed, so absence is now unconditional —
  // there is no build that draws a Buy control. The invariants asserted are the
  // ones the case exists to protect: the exact shipped set in the exact order,
  // even spacing (no gap left by the removed control), and no resurrected
  // "Coming soon" affordance.
  testWidgets(
    'BUY-001 portfolio action row holds exactly the shipped buttons',
    (tester) async {
      await _bootToHome(tester);
      await _tapTab(tester, 'Tokens', TokensTabContent);
      await pumpUntil(
        tester,
        find.byType(PortfolioActionButtonsRow),
        label: 'portfolio action row',
      );

      final row = find.byType(PortfolioActionButtonsRow);
      final labels = tester
          .widgetList<Text>(
            find.descendant(of: row, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .whereType<String>()
          .toList();

      expect(labels, <String>['Swap', 'Send', 'Receive', 'Stake']);

      // "no gap or empty slot where one used to be". Each `_ActionButton`
      // wraps its column in exactly one `Opacity` (the disabled dim), so those
      // rects ARE the button boxes. The buttons have different widths, so the
      // even distribution `spaceBetween` produces shows up in the EDGE gaps,
      // not in the centre strides — an orphaned `SizedBox` left behind by a
      // removed control is one unequal gap.
      final boxes = tester
          .widgetList<Opacity>(
            find.descendant(of: row, matching: find.byType(Opacity)),
          )
          .toList();
      expect(
        boxes.length,
        labels.length,
        reason: 'one Opacity-wrapped button box per label',
      );
      final rects = [
        for (var i = 0; i < boxes.length; i++)
          tester.getRect(
            find.descendant(of: row, matching: find.byType(Opacity)).at(i),
          ),
      ];
      final gaps = [
        for (var i = 1; i < rects.length; i++)
          rects[i].left - rects[i - 1].right,
      ];
      for (final gap in gaps) {
        expect(
          gap,
          closeTo(gaps.first, 1.0),
          reason: 'action row is not evenly spread: $gaps',
        );
      }

      expect(find.textContaining('Coming soon'), findsNothing);
    },
    tags: 'nightly',
  );

  // BUY-002 — empty-state prompt card offers only "Transfer crypto".
  //
  // The empty-wallet Tokens tab is the headline empty state of this bucket, and
  // every assertion below is on the empty state's own copy, so it cannot
  // pass on a blank screen. The absent buy CTA is asserted unconditionally —
  // see BUY-001.
  testWidgets('BUY-002 empty Tokens tab prompts to fund and opens Receive', (
    tester,
  ) async {
    await _bootToHome(tester);
    await _tapTab(tester, 'Tokens', TokensTabContent);

    final card = find.byType(TokensEmptyState);
    await pumpUntil(tester, card, label: 'Tokens empty state');

    // $0.00 on the prompt card. Scoped to the card's own value section: the
    // header carries a total too, and each 0-balance gas-token row below the
    // card renders its own $0.00.
    expect(
      find.descendant(
        of: find.descendant(
          of: card,
          matching: find.byType(PortfolioValueSection),
        ),
        matching: find.text(r'$0.00'),
      ),
      findsOneWidget,
    );
    // The session's first chain is Solana — the imported phrase derives
    // Solana + Ethereum + Tezos at index 0, ordered SOL -> ETH -> XTZ.
    expect(
      find.text('To get started, transfer Solana to your wallet'),
      findsOneWidget,
    );

    expect(
      find.descendant(of: card, matching: find.text('Transfer crypto')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('with cash')),
      findsNothing,
      reason: 'the fiat on-ramp CTA was removed and must not come back',
    );

    // Transfer crypto opens the Receive sheet, carrying the real session
    // wallets — asserted against the deterministic wallet's own address so a
    // sheet listing the wrong session cannot pass.
    await tapAndSettle(
      tester,
      find.descendant(of: card, matching: find.text('Transfer crypto')),
    );
    await pumpUntil(
      tester,
      find.text(truncateAddress(kTestWalletSolana)),
      label: 'receive sheet',
    );
    expect(find.text(truncateAddress(kTestWalletEvm)), findsOneWidget);
    expect(find.text(truncateAddress(kTestWalletTezos)), findsOneWidget);

    // Leave the sheet closed.
    await tester.binding.handlePopRoute();
    await pumpUntilGone(
      tester,
      find.text(truncateAddress(kTestWalletSolana)),
      label: 'receive sheet after back',
    );
  });
}
