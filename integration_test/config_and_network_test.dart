// E2E: remote config (kill switch + force upgrade) and network failure
// handling, driven on a real Android emulator against the sandboxed mock
// backend (test/e2e/mock_backend.py).
//
// This is the bucket the mock's fault-injection surface was built for: every
// case here is "what does the app do when the backend answers wrong, slowly,
// or not at all". Nothing here needs a captured fixture — the config payloads
// are served through `MockControl.fault(status: 200, body: ...)`, which lets a
// test compose the body in Dart instead of pinning it in a scenario file. That
// matters for CFG-009, whose whole point is "minimumVersion EQUALS the running
// build": a hardcoded fixture would silently stop testing that the moment
// somebody bumps `pubspec.yaml`.
//
// Case map — case ID -> test:
//
// | Case      | Test                                                       | Tier    |
// | --------- | ---------------------------------------------------------- | ------- |
// | (infra)   | mock control surface answers from inside the app process     | smoke   |
// | `CFG-007` | force-upgrade wall goes up below the minimum and only there  | smoke   |
// | `CFG-009` | force-upgrade wall goes up below the minimum and only there  | smoke   |
// | `CFG-010` | force-upgrade wall goes up below the minimum and only there  | smoke   |
// | `CFG-001` | kill switch closes one mint cell, leaves its neighbour open  | smoke   |
// | `CFG-005` | kill switch closes one mint cell, leaves its neighbour open  | smoke   |
// | `NET-001` | cold launch with the backend unreachable                     | smoke   |
// | `NET-008` | cold launch with the backend unreachable                     | smoke   |
// | `NET-005` | a 5xx backend lands on the error view and recovers on retry  | smoke   |
// | `NET-006` | a 5xx backend lands on the error view and recovers on retry  | smoke   |
// | `NET-004` | a slow session login shows the skeleton, not a blank screen  | smoke   |
// | `NET-002` | going offline mid-session keeps the shell up                 | smoke   |
// | `ONB-113` | onboarding completes with the backend unreachable            | smoke   |
// | `CFG-002` | a kill delivered mid-session closes the flow                 | nightly |
// | `CFG-006` | a kill delivered mid-session closes the flow                 | nightly |
// | `CFG-008` | the force-upgrade wall appears on a foreground               | nightly |
//
// Twelve smoke case IDs across seven `testWidgets` (plus the harness guard),
// which is this bucket's whole quota. The two nightly tests are nightly for
// one reason only: each has to sit out
// [_kConfigRefreshFloor] of real wall clock, which no fixture can shorten.
//
// Not automated here, and why:
//   * `ONB-114` — private-key import offline. `support/test_wallet.dart`
//     carries only the mnemonic, so there is no key to type into the import
//     field. Belongs with `onboarding_import_test.dart`, which owns that
//     screen and would have to add the constant.
//   * `CFG-003`, `NET-003`, `NET-007` — deferred to Phase 3.
//     All three need a real signing flow (the `authorize()` backstop, an
//     interrupted broadcast, an RPC outage mid-send), which needs the
//     portfolio fixtures the send buckets own.
//   * `CFG-004` — un-killing a flow. Not reachable in-process: see
//     [_kConfigRefreshFloor]. A second SUCCESSFUL fetch is five minutes behind
//     the first, and `RemoteConfigService` exposes no seam for the cooldown.
//   * `SET-066`, `SET-086` — offline Settings. Assigned to this bucket, but
//     they drive the Settings tree that `settings_test.dart`
//     owns; putting them here duplicates that file's navigation helpers.
//
// The store-button tap in `CFG-007` and the hardware-back dismiss attempt are
// native, so they stay with Patrol (Phase 4). What is asserted here is the
// half observable from the Dart tree: the wall is up, it carries the
// operator's copy verbatim, and nothing underneath it is reachable.
//
// TEST ORDER IS LOAD-BEARING. The three cases that drive a FAILING session
// initialisation (`ONB-113`, `NET-001`, `NET-005`) run last. An offline login
// can surface as an unhandled `AuthException` in the test zone, and
// `LiveTestWidgetsFlutterBinding` does not recover from that: the aborted test
// leaves `_pendingFrame` set and every subsequent test in the file fails with
// `'!inTest': is not true`. Keeping them last bounds the blast radius to
// themselves. Do not interleave them with the CFG cases.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/features/home/widgets/home_screen_skeleton.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';
import 'package:mallow_wallet/shared/widgets/force_upgrade_overlay.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';
import 'package:mallow_wallet/shared/widgets/shared_header.dart';
import 'package:mallow_wallet/shared/widgets/tappable.dart';

import 'support/e2e.dart';

/// Shortest affordable wall-clock gap between two `GET /v2/config/mobile`
/// fetches.
///
/// `RemoteConfigService` guards a refresh twice: a 5-minute freshness TTL after
/// a SUCCESS, and a 30-second cooldown after ANY attempt. So the only cheap
/// mid-session transition is `failed launch fetch -> 30 s -> successful
/// refresh`; a success-to-success transition costs the full TTL and is not
/// affordable in a test. Every mid-session config case here is built on the
/// cheap one. Padded past 30 s because the clock starts when the service
/// ATTEMPTS the launch fetch, a beat before the test can observe anything.
const Duration _kConfigRefreshFloor = Duration(seconds: 33);

/// Operator copy for the killed cell. Asserted verbatim — `CFG-001`'s point is
/// that incident-specific copy reaches the user unedited, because it is the
/// only thing that can tell them whether their assets are safe.
const String _kKillMessage =
    'Minting is paused while we ship a fix. Your artworks are safe.';

/// Operator copy for the force-upgrade wall. Same reasoning as [_kKillMessage]:
/// the fallback string is what shows when the server sent nothing, so asserting
/// the fallback would not prove the operator's message renders at all.
const String _kUpgradeMessage =
    'This build can no longer reach mallow. Please update.';

/// The app's `/v2` DATA reads, deliberately NOT `/v2/config/mobile`.
///
/// Counting "any `/v2` request" would let a remote-config refresh stand in for
/// a user-visible read, which is the opposite of what a network case is trying
/// to prove. These three are the reads this fixture set provably makes: the
/// portfolio tab's artwork query, and the EVM/Tezos balance reads that a
/// foreground refresh issues.
const String _kV2Read = r'/v2/(evm|tezos|portfolio)';

/// The one `/v2` read a tab change issues, and issues EXACTLY once.
///
/// `PortfolioBloc._onLoad` -> `_fetchAndEmitAll` sends a single
/// `POST /v2/portfolio/artworks` per load, so a counter that advances by two
/// over one tab open can only mean "sent, failed, re-sent" — which is what
/// makes it usable as the subject of a retry assertion.
///
/// 🛑 The EVM/Tezos balance reads are NOT interchangeable with it here.
/// `TokenBalanceBloc` is built once by `TabNavigator`'s `MultiBlocProvider` at
/// launch and only refetches on a `resumed` lifecycle event or a pull-to-
/// refresh; `TokensTabContent` reuses that same instance. So no tab tap — not
/// even onto the tokens tab — issues `/v2/evm/balances` or
/// `/v2/tezos/balances`.
const String _kArtworkRead = r'/v2/portfolio/artworks';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Not just once per file. A fault left armed by a failing case is the
    // classic cross-case contaminant, and this file arms one in almost every
    // test.
    await MockControl.reset();
  });

  // -------------------------------------------------------------------------
  // Harness guard. Runs first, deliberately: this file is the first consumer of
  // `MockControl` from inside the app process (Wave 0 verified the control
  // endpoints by curl from the host only). If the client call path is broken,
  // every test below fails in a way that reads like an app bug. This one fails
  // first and names the harness.
  // -------------------------------------------------------------------------
  testWidgets('mock control surface answers from inside the app process', (
    tester,
  ) async {
    // `reset()` already ran in setUp; if it had thrown we would not be here.
    await MockControl.scenario('default');

    // An unknown scenario must be a loud 400, not a silent fallthrough to the
    // default fixtures — a green test that asserts nothing is the exact failure
    // this suite exists to prevent.
    await expectLater(
      MockControl.scenario('cfgnet_no_such_scenario'),
      throwsA(isA<MockControlException>()),
    );

    await MockControl.fault(
      path: r'/__never_requested__',
      status: 500,
      times: 1,
    );
    await MockControl.clearFaults();
    await MockControl.state({'blockhash_valid': true});

    final logged = await MockControl.requests();
    expect(
      logged.where((r) => r.path.startsWith('/__test__')),
      isEmpty,
      reason: 'control-surface calls must never be recorded',
    );
  });

  // -------------------------------------------------------------------------
  // CFG — force upgrade
  // -------------------------------------------------------------------------

  testWidgets('force-upgrade wall goes up below the minimum and only there', (
    tester,
  ) async {
    // The wall is mounted above the router in `app.dart`, so it needs neither a
    // wallet nor a session — three cold boots to Welcome are far cheaper than
    // one onboarding.
    final localVersion = await readLocalAppVersion();
    expect(
      localVersion,
      isNotNull,
      reason: 'PackageInfo must resolve, or the wall can never be raised',
    );

    // --- CFG-007: below the minimum -> wall, carrying the operator's copy.
    await _serveConfig(
      minimumVersion: '999.0.0',
      updateRequired: true,
      updateMessage: _kUpgradeMessage,
    );
    await restartApp(tester);
    await pumpUntil(
      tester,
      find.text('Update required'),
      label: 'force-upgrade wall',
      rounds: 200,
    );
    expect(
      find.text(_kUpgradeMessage),
      findsOneWidget,
      reason: 'the operator message must render verbatim, not the fallback',
    );
    expect(
      find.text(forceUpgradeFallbackMessage),
      findsNothing,
      reason: 'the fallback is only for a server that sent no message',
    );
    // Non-dismissable, from the Dart side: the wall is an opaque Material over
    // the whole viewport, so the Welcome CTA underneath is still IN the tree
    // but must not be reachable by a tap. (The hardware-back and store-button
    // halves of CFG-007 are native — Patrol.)
    expect(
      find.text('Create a new wallet'),
      findsOneWidget,
      reason: 'the router is still mounted underneath the wall',
    );
    expect(
      find.text('Create a new wallet').hitTestable(),
      findsNothing,
      reason: 'the wall must absorb taps meant for the screen beneath it',
    );

    // --- CFG-009: minimumVersion EQUALS the running build -> no wall. A
    // server-side mistake here would lock out every installed client, which is
    // why the client AND-s the server verdict with its own comparison.
    await MockControl.clearFaults();
    await _serveConfig(
      minimumVersion: localVersion,
      updateRequired: true,
      updateMessage: _kUpgradeMessage,
    );
    await restartApp(tester);
    await _expectNoWallAfterConfigLands(tester);

    // --- CFG-010: unparseable minimumVersion -> fail open, no wall.
    await MockControl.clearFaults();
    await _serveConfig(
      minimumVersion: 'latest',
      updateRequired: true,
      updateMessage: _kUpgradeMessage,
    );
    await restartApp(tester);
    await _expectNoWallAfterConfigLands(tester);
  });

  // -------------------------------------------------------------------------
  // CFG — kill switch
  // -------------------------------------------------------------------------

  testWidgets(
    'kill switch closes one mint cell and leaves its neighbour open',
    (tester) async {
      await _serveConfig(disabledFlows: [_killedMint]);
      await completeOnboardingWithTestWallet(tester);

      // --- CFG-001 steps 1-4: the entry point is closed and explains itself.
      await _openMintChooser(tester);
      await tapAndSettle(tester, find.text('1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('Temporarily unavailable'),
        label: 'flow-unavailable sheet',
      );
      expect(
        find.text(_kKillMessage),
        findsOneWidget,
        reason: 'the operator message must render verbatim',
      );
      await tapAndSettle(tester, find.text('OK'));
      await pumpUntilGone(
        tester,
        find.text('Temporarily unavailable'),
        label: 'flow-unavailable sheet',
      );
      // Dismissing returns the user to where they tapped, with no side effects:
      // FlowUnavailableScreen pops itself once acknowledged.
      await pumpUntil(
        tester,
        find.text('Choose artwork type'),
        label: 'mint type chooser (back where we started)',
      );
      expect(find.text('New 1/1 artwork'), findsNothing);

      // --- CFG-001 step 5: the kill is scoped to ONE cell. `edition-mint` is a
      // separate builder and a separate cell, one row down the same screen.
      await tapAndSettle(tester, find.text('Editions'));
      await pumpUntil(
        tester,
        find.text('New editions'),
        label: 'editions mint form (neighbouring cell still live)',
      );

      // --- CFG-005: with the config fetch failing, nothing is killed. The same
      // kill is still configured server-side; the app just never learns it.
      // Fail-open is deliberate — a backend outage must not brick the app.
      await MockControl.clearFaults();
      await _failConfigFetch();
      await restartApp(tester, wipe: false);
      await unlockApp(tester);
      await _openMintChooser(tester);
      await tapAndSettle(tester, find.text('1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('New 1/1 artwork'),
        label: '1/1 mint form (fail-open after a failed config fetch)',
      );
      expect(find.text('Temporarily unavailable'), findsNothing);
    },
  );

  testWidgets(
    'a kill delivered mid-session closes the flow and a failed refresh does '
    'not re-open it',
    (tester) async {
      // The launch fetch must FAIL, for two reasons: it is CFG-002's
      // precondition (the flow is usable when the session starts), and it is
      // the only way to earn a second fetch in 30 s rather than 5 minutes.
      await _failConfigFetch();
      await completeOnboardingWithTestWallet(tester);

      // Step 1: the flow works — reach its entry screen, then back out.
      await _openMintChooser(tester);
      await tapAndSettle(tester, find.text('1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('New 1/1 artwork'),
        label: '1/1 mint form (flow live at session start)',
      );
      // The whole MallowHeader title row is the back affordance.
      await tapAndSettle(tester, find.text('New 1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('Choose artwork type'),
        label: 'mint type chooser',
      );

      // Step 2: the operator disables the flow.
      await MockControl.clearFaults();
      await _serveConfig(disabledFlows: [_killedMint]);

      // Step 3: background and return. The refresh is cooldown-guarded, which
      // is where this case's wall-clock cost comes from.
      //
      // Counted relative to *now*, not from zero: `FlowGatedScreen.initState`
      // also calls `refreshIfStale`, so entering the mint form above may
      // already have spent an attempt. An absolute "at least 2" could
      // therefore be satisfied by that earlier failure and let the test tap
      // before the kill has landed.
      final fetchesBefore = await _countRequests(r'/v2/config/mobile');
      await _waitOutConfigCooldown(tester);
      await foregroundApp(tester);
      await _pumpUntilConfigFetches(tester, atLeast: fetchesBefore + 1);

      // The kill applies on the first tap after the foreground.
      await tapAndSettle(tester, find.text('1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('Temporarily unavailable'),
        label: 'flow-unavailable sheet after a mid-session kill',
      );
      expect(find.text(_kKillMessage), findsOneWidget);
      await tapAndSettle(tester, find.text('OK'));
      await pumpUntilGone(tester, find.text('Temporarily unavailable'));

      // CFG-006: refreshes now fail. A flapping backend must never re-open a
      // path just closed.
      //
      // Honest scope note: the successful fetch above reset the 5-minute
      // freshness TTL, so the foregrounds below are unlikely to issue a request
      // at all. This asserts the user-visible invariant (the kill survives
      // foregrounding while the backend is failing), NOT specifically the
      // last-known-good branch of `RemoteConfigService._fetch`'s catch. That
      // branch has unit cover; reaching it here would cost a five-minute wait.
      await MockControl.clearFaults();
      await _failConfigFetch();
      await foregroundApp(tester);
      await foregroundApp(tester);
      await pumpUntil(
        tester,
        find.text('Choose artwork type'),
        label: 'mint type chooser after foregrounding',
      );
      await tapAndSettle(tester, find.text('1/1 artwork'));
      await pumpUntil(
        tester,
        find.text('Temporarily unavailable'),
        label: 'flow-unavailable sheet (kill retained across failed refresh)',
      );
    },
    tags: 'nightly',
  );

  testWidgets(
    'the force-upgrade wall appears on a foreground, with no relaunch',
    (tester) async {
      // Same cooldown trick as CFG-002: fail the launch fetch so the second
      // fetch is 30 s away instead of 5 minutes.
      await _failConfigFetch();
      await restartApp(tester);
      await pumpUntil(
        tester,
        find.text('Create a new wallet'),
        label: 'Welcome screen',
      );
      // Wait for the launch fetch to be ON THE WIRE before disarming the
      // fault. The Welcome screen renders while that request is still in
      // flight (measured: ~700 ms on this emulator), so clearing the fault
      // first lets the launch fetch SUCCEED — which sets the 5-minute
      // freshness TTL and silently suppresses every later refresh. The test
      // then times out on a wall that was never going to be raised.
      // Absolute count, not a delta: `setUp` emptied the log, so the launch
      // fetch is the only one that can have happened.
      await _pumpUntilConfigFetches(tester, atLeast: 1);
      expect(find.text('Update required'), findsNothing);

      await MockControl.clearFaults();
      await _serveConfig(
        minimumVersion: '999.0.0',
        updateRequired: true,
        updateMessage: _kUpgradeMessage,
      );
      await _waitOutConfigCooldown(tester);
      await foregroundApp(tester);

      await pumpUntil(
        tester,
        find.text('Update required'),
        label: 'force-upgrade wall raised by a foreground refresh',
        rounds: 200,
      );
      expect(find.text(_kUpgradeMessage), findsOneWidget);
    },
    tags: 'nightly',
  );

  // -------------------------------------------------------------------------
  // NET — network failure handling
  // -------------------------------------------------------------------------

  // NET-004
  testWidgets('a slow session login shows the skeleton, not a blank screen', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await waitForHome(tester);

    // Slow, NOT broken: no `status`, so the mock still answers this request
    // from the `default` fixture — just 6 s late. (Stating a status here is
    // what turns the case into a duplicate of NET-005; `fault` used to do
    // that by itself, which is why the parameter now defaults to null.)
    //
    // 6 s is long enough that the skeleton cannot fall between two pumps, and
    // short enough not to matter against the job budget.
    await MockControl.fault(path: r'/v0/login', delayMs: 6000);
    await restartApp(tester, wipe: false);
    await unlockApp(tester);

    await pumpUntil(
      tester,
      find.byType(HomeScreenSkeleton),
      label: 'session loading skeleton',
    );
    expect(
      find.text('Connection Error'),
      findsNothing,
      reason: 'slow is not failed',
    );

    // Nothing hangs indefinitely: content arrives once the delay expires.
    await MockControl.clearFaults();
    await waitForHome(tester);
  });

  // NET-002
  testWidgets(
    'going offline mid-session keeps the shell up and recovers when back',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await waitForHome(tester);

      final readsBeforeOffline = await _countRequests(_kV2Read);

      await MockControl.fault(path: r'.*', refuse: true);
      // Drive the reads through the tab bar rather than a pull-to-refresh
      // gesture: what must survive is the shell, and a drag on an empty list
      // fixture is a no-op.
      await _tapNavTab(tester, 1);
      // Wait for a read to have REACHED the mock and been refused, rather than
      // sleeping three seconds and hoping. The mock logs a request before it
      // decides to drop the connection, so the counter advancing is proof the
      // app really tried and really failed — without it, "no Connection Error"
      // below would also pass on an app that issued no read at all.
      await _pumpUntilRequestCount(
        tester,
        _kV2Read,
        atLeast: readsBeforeOffline + 1,
        label: 'a read refused by the dead network',
      );
      expect(
        find.byType(SharedHeader),
        findsOneWidget,
        reason: 'going offline must not wipe the shell',
      );
      expect(
        find.text('Connection Error'),
        findsNothing,
        reason: 'an established session must not be torn down by a failed read',
      );

      await _tapNavTab(tester, 0);
      await waitForHome(tester);
      expect(find.byType(HomeScreen), findsOneWidget);

      // Recovers without a restart — and the proof is a request that round
      // trips AFTER the fault is cleared. Re-asserting `HomeScreen` is not
      // that proof: it already held while the refuse-all fault was armed, so
      // an app that permanently stopped retrying after a refused connection
      // would pass it.
      await MockControl.clearFaults();
      final readsBeforeRecovery = await _countRequests(_kV2Read);
      await _tapNavTab(tester, 1);
      // A tab the session has already visited stays mounted behind an
      // `Offstage` and need not re-fetch on return, so the tab tap alone is
      // not a guaranteed request. The foreground is: `TabNavigator`'s
      // `didChangeAppLifecycleState` fires `TokenBalanceEvent.refresh` and
      // `AccountWalletEvent.refreshBalances` on every resume, and both are
      // `/v2` balance reads.
      await foregroundApp(tester);
      await _pumpUntilRequestCount(
        tester,
        _kV2Read,
        atLeast: readsBeforeRecovery + 1,
        label: 'a read that reached the mock after the fault cleared',
      );

      await _tapNavTab(tester, 0);
      await waitForHome(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Connection Error'), findsNothing);
    },
  );

  testWidgets('onboarding completes with the backend unreachable', (
    tester,
  ) async {
    await MockControl.fault(path: r'.*', refuse: true);
    await restartApp(tester);

    // Key generation, the vault write and PIN setup are all on-device, so the
    // whole create-wallet path must complete with no network at all.
    final createBtn = find.text('Create a new wallet');
    await pumpUntil(tester, createBtn, label: 'Welcome screen');
    await tapAndSettle(tester, createBtn);
    final recoveryBtn = find.text('Use a recovery phrase');
    await pumpUntil(tester, recoveryBtn, label: 'Create-wallet menu');
    await tapAndSettle(tester, recoveryBtn);
    final generateBtn = find.text('Generate recovery phrase');
    await pumpUntil(tester, generateBtn, label: 'Wallet intro screen');
    await tapAndSettle(tester, generateBtn);
    final savedCheckbox = find.text(
      "I've saved my recovery phrase in a secure location",
    );
    await pumpUntil(tester, savedCheckbox, label: 'Seed phrase screen');
    await tapAndSettle(tester, savedCheckbox);
    await tapAndSettle(tester, find.text('Continue'));
    await completePinSetup(tester);

    // The wallet exists and the app is past onboarding; only the network data
    // is missing, which is exactly what the case expects.
    await pumpUntil(
      tester,
      find.text('Connection Error'),
      label: 'offline session error inside the shell',
      rounds: 250,
    );
    // Not `find.byType(MallowBottomNavBar)`: that overlay is mounted on every
    // screen including Welcome, so it would pass without the app having left
    // onboarding at all. With the session in its error view there is no
    // `SharedHeader` either, so the falsifiable pair is "the tab route is on
    // top" plus "Welcome is gone".
    expect(NavBarState.visible.value, isTrue, reason: 'inside the tab shell');
    expect(find.text('Create a new wallet'), findsNothing);

    await MockControl.clearFaults();
    await tapAndSettle(tester, find.text('Retry'));
    await waitForHome(tester);
  });
  // NET-001, NET-008
  testWidgets(
    'cold launch with the backend unreachable shows Connection Error, and '
    'unlocking still works',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await waitForHome(tester);

      // Airplane mode, modelled as "every socket is dropped". The mock answers
      // /__test__ before fault matching, so the test can still drive it while
      // the app sees a dead network.
      await MockControl.fault(path: r'.*', refuse: true);
      await restartApp(tester, wipe: false);
      await pumpUntil(tester, find.byType(LockScreen), label: 'lock screen');

      // 🛑 Let the under-lock login attempt FINISH before unlocking.
      // `SessionInitializer` starts its login while the lock screen is still
      // up (the routed content is built underneath it), and unlocking swaps
      // `app.dart`'s locked branch for the unlocked one. Unlocking on top of
      // an in-flight login puts the failing future and a tree rebuild in the
      // same window, and the resulting `AuthException` intermittently lands
      // in the test zone unhandled — which aborts this test mid-`pump` AND
      // leaves `LiveTestWidgetsFlutterBinding._pendingFrame` set, so every
      // later test in the file dies with `'!inTest': is not true`. One
      // mistimed unlock costs the whole file. See the report: the same
      // unhandled error is reachable by a real user and is an app bug.
      await _settleFailedLogin(tester);

      // NET-008: unlocking is entirely local — Argon2id against a stored hash.
      // Being offline must never keep a user out of their own wallet.
      await unlockApp(tester);

      // NET-001: not an infinite skeleton, not a blank screen, not a crash.
      await pumpUntil(
        tester,
        find.text('Connection Error'),
        label: 'session Connection Error view',
        rounds: 250,
      );
      expect(find.text('Retry'), findsOneWidget);

      // Back online: Retry proceeds into the app, with no relaunch.
      //
      // The case's step 4 ("retry while still offline, see the same
      // screen") is deliberately NOT driven: a second offline login is a
      // second chance at the unhandled-error abort above, for an assertion
      // the first failure already made.
      await MockControl.clearFaults();
      await tapAndSettle(tester, find.text('Retry'));
      await waitForHome(tester);
      expect(find.text('Connection Error'), findsNothing);
    },
  );

  // NET-005, NET-006
  testWidgets('a 5xx backend lands on the error view and recovers on retry', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await waitForHome(tester);

    // --- NET-005. Everything 500s, including /v2/config/mobile — a failed
    // remote-config fetch must not block anything, it fails open.
    await MockControl.fault(path: r'.*', status: 500);
    await restartApp(tester, wipe: false);
    await pumpUntil(tester, find.byType(LockScreen), label: 'lock screen');
    // Same reason as NET-001: never unlock on top of an in-flight login.
    await _settleFailedLogin(tester);
    await unlockApp(tester);

    await pumpUntil(
      tester,
      find.text('Connection Error'),
      label: 'session error view under a 5xx backend',
      rounds: 250,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.text('Update required'),
      findsNothing,
      reason: 'a failed config fetch must never raise the upgrade wall',
    );

    await MockControl.clearFaults();
    await tapAndSettle(tester, find.text('Retry'));
    await waitForHome(tester);

    // --- NET-006. The login token expires: the backend answers 401 "Please log
    // in" once. The app must coalesce it, re-login under the UI and retry the
    // original request — no logout, no error wall. Asserted on the wire,
    // because a silent refresh is by definition invisible on screen.
    final loginsBefore = await _countRequests(r'/v0/login');
    final readsBefore = await _countRequests(_kArtworkRead);
    // Scoped to the portfolio tab's artwork query rather than all of `/v2/`:
    // it is the one read the tap below provably issues, and issues exactly
    // once (see [_kArtworkRead]). Keeping `/v2/config/mobile` out of it also
    // stops the case from accidentally measuring the remote-config path
    // instead of a user-visible read.
    await MockControl.fault(
      path: _kArtworkRead,
      status: 401,
      times: 1,
      body: {
        'error': {'message': 'Please log in'},
      },
    );
    await _tapNavTab(tester, 1);
    await _pumpUntilRequestCount(
      tester,
      r'/v0/login',
      atLeast: loginsBefore + 1,
      label: 'a silent re-login triggered by the 401',
    );
    // The refresh is only half of it: the interceptor must also re-send the
    // request that got the 401, or the screen the user tapped stays empty
    // while the session quietly heals behind it.
    await _pumpUntilRequestCount(
      tester,
      _kArtworkRead,
      atLeast: readsBefore + 2,
      label: 'the original read retried after the refresh',
    );

    // Back to Home. The tab shell drops the previous tab's subtree, so
    // [HomeScreen] is a signal about the CURRENT tab, not about the session —
    // asserting it while the portfolio tab is up would fail for the wrong
    // reason.
    await _tapNavTab(tester, 0);
    await waitForHome(tester);
    expect(
      find.text('Create a new wallet'),
      findsNothing,
      reason:
          'a 401 must be refreshed under the UI, never surfaced as a logout',
    );
    expect(find.text('Connection Error'), findsNothing);
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The one killed cell used across the CFG cases: Solana 1/1 minting.
///
/// Picked because its neighbour on the same screen (`edition-mint`) is a
/// different cell, so one tap proves the kill and the next proves its scope.
const Map<String, String> _killedMint = {
  'chain': 'solana',
  'flow': 'nft-mint',
  'message': _kKillMessage,
};

/// Serves a `GET /v2/config/mobile` body composed in Dart.
///
/// A fault rather than a fixture directory on purpose: the interesting configs
/// here are relative to a value only known at runtime (the running build's
/// version), or differ by one field between three consecutive relaunches in
/// one test. Faults are matched before scenario routes, so this wins over the
/// `default` scenario's permissive body without touching it.
Future<void> _serveConfig({
  String? minimumVersion,
  bool updateRequired = false,
  String? updateMessage,
  List<Map<String, String>> disabledFlows = const [],
}) {
  return MockControl.fault(
    path: r'/v2/config/mobile',
    method: 'GET',
    status: 200,
    body: {
      'result': {
        'minimumVersion': minimumVersion,
        'updateRequired': updateRequired,
        'updateMessage': updateMessage,
        'disabledFlows': disabledFlows,
      },
    },
  );
}

/// Makes the config endpoint — and only the config endpoint — fail 500.
Future<void> _failConfigFetch() =>
    MockControl.fault(path: r'/v2/config/mobile', method: 'GET', status: 500);

/// Asserts the wall stays DOWN, after proving the config actually arrived.
///
/// A bare `findsNothing` right after a relaunch would also pass if the app
/// never fetched the config at all, which is the false-confidence failure this
/// suite exists to prevent. So: wait for the fetch on the wire, give the
/// overlay's async `PackageInfo` lookup room to land, then assert.
Future<void> _expectNoWallAfterConfigLands(WidgetTester tester) async {
  await pumpUntil(
    tester,
    find.text('Create a new wallet'),
    label: 'Welcome screen',
  );
  await _pumpUntilConfigFetches(tester, atLeast: 1);
  await tester.pump(const Duration(seconds: 2));
  expect(
    find.text('Update required'),
    findsNothing,
    reason:
        'the client must fail open unless it is genuinely below the minimum',
  );
}

/// Number of logged requests whose path matches [pattern].
Future<int> _countRequests(String pattern) async {
  final regex = RegExp(pattern);
  final logged = await MockControl.requests();
  return logged.where((r) => regex.hasMatch(r.path)).length;
}

/// Pumps until the mock has logged [atLeast] requests matching [pattern].
///
/// Each round costs an HTTP round trip to the control surface, so it pumps
/// five frames between polls rather than one — on this emulator a `pump` plus
/// a `GET /__test__/requests` is ~250 ms, and polling every frame turned a
/// 15-second budget into a minute of wall clock.
Future<void> _pumpUntilRequestCount(
  WidgetTester tester,
  String pattern, {
  required int atLeast,
  String? label,
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (await _countRequests(pattern) >= atLeast) return;
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  fail('Timed out waiting for ${label ?? '$atLeast x $pattern'}');
}

Future<void> _pumpUntilConfigFetches(
  WidgetTester tester, {
  required int atLeast,
}) => _pumpUntilRequestCount(
  tester,
  r'/v2/config/mobile',
  atLeast: atLeast,
  label: '$atLeast x GET /v2/config/mobile',
);

/// Keeps the app running for [seconds] of real wall clock.
///
/// One-second steps, not 100 ms ones: each `pump` also renders a frame on a
/// software-GL emulator, so a fine-grained wait costs far more wall clock than
/// the duration it is supposed to represent. Nothing that calls this needs
/// frame resolution — it is a stopwatch, not an animation.
Future<void> _pumpSeconds(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Burns the `RemoteConfigService` retry cooldown while keeping the app alive.
Future<void> _waitOutConfigCooldown(WidgetTester tester) =>
    _pumpSeconds(tester, _kConfigRefreshFloor.inSeconds);

/// Waits for the boot-time `POST /v0/login` to be attempted AND to have
/// finished failing.
///
/// The request log is written when a request ARRIVES, so counting it only
/// proves the login started. The extra seconds are what prove it ended: the
/// mock's refusal / 500 comes back in ~300-950 ms on this emulator, and every
/// later step in an offline case depends on `SessionInitializer` having
/// settled into its error state rather than still being in flight.
Future<void> _settleFailedLogin(WidgetTester tester) async {
  await _pumpUntilRequestCount(
    tester,
    r'/v0/login',
    atLeast: 1,
    label: 'the boot login attempt',
  );
  await _pumpSeconds(tester, 3);
}

/// Home -> quick-actions FAB -> "Mint" -> the mint type chooser.
///
/// The FAB is the only [Tappable] inside [MallowBottomNavBar] (the three tab
/// items are bare `GestureDetector`s under a `Semantics`), so this finder does
/// not depend on the semantics tree being enabled.
Future<void> _openMintChooser(WidgetTester tester) async {
  await waitForHome(tester);
  await tapAndSettle(
    tester,
    find.descendant(
      of: find.byType(MallowBottomNavBar),
      matching: find.byType(Tappable),
    ),
  );
  final mintItem = find.text('Mint').last;
  await pumpUntil(tester, mintItem, label: 'quick-actions menu');
  await tapAndSettle(tester, mintItem);
  await pumpUntil(
    tester,
    find.text('Choose artwork type'),
    label: 'mint type chooser',
  );
}

/// Taps one of the three bottom-nav tabs by index (0 home, 1 portfolio,
/// 2 tokens).
Future<void> _tapNavTab(WidgetTester tester, int index) async {
  final tabs = find.descendant(
    of: find.byType(MallowBottomNavBar),
    matching: find.byType(GestureDetector),
  );
  await settleAt(tester, tabs);
  await tester.tap(tabs.at(index));
  await tester.pump(const Duration(milliseconds: 600));
}
