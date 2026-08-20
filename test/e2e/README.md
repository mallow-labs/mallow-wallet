# E2E testing — headless Android emulator + sandboxed backend

Automated end-to-end tests that drive real user flows through the app on a
headless Android emulator, against a local mock backend. Deterministic and
fully offline: no Firebase, no real backend, no chain, and no third-party host.
That last one is enforced rather than assumed — `dart_defines.sh` points every
outbound base URL at the mock, including the price, RPC and gateway hosts whose
Dart defaults are live services. Adding a `Config` getter with a live default
and not adding it there silently re-opens a hole. The intent is a
regression gate — if a flow's navigation, a screen's widget, or a
create→home redirect breaks, the test fails.

## What runs

```
┌─────────────────┐   --dart-define API_BASE_URL=http://10.0.2.2:8091
│ flutter test    │──────────────────────────────────────────────┐
│ integration_test│                                                │
└────────┬────────┘                                                ▼
         │ builds + installs debug APK             ┌──────────────────────────┐
         ▼                                          │ mock_backend.py (host)   │
┌─────────────────────────┐   HTTP via 10.0.2.2    │ canned JSON for v1/v2/RPC │
│ headless emulator        │───────────────────────▶│ :8091                    │
│ (KVM-accelerated x86_64) │                        └──────────────────────────┘
│ app under test + driver  │
└─────────────────────────┘
```

## Quick start

```bash
test/e2e/run_e2e.sh                                   # whole suite (every tag, nightly included)
test/e2e/run_one.sh integration_test/some_flow_test.dart   # one file, while iterating
test/e2e/run_one.sh --uninstall integration_test/some_flow_test.dart
```

Both runners boot the emulator (if needed), start a **fresh** mock backend, and
run the test with the app pointed at the mock. Shared plumbing — emulator boot
and mock lifecycle — lives in `test/e2e/lib.sh`, so the two runners cannot drift
apart. The `--dart-define` set is one level further out in
`test/e2e/dart_defines.sh`, which `lib.sh` sources and any CI job you add should
source too: add or change a define there and nowhere else, or you get a test
that passes locally and fails in CI. It is POSIX `sh` so a plain `/bin/sh` step
can source it.

**They serialize.** A host has one emulator and one Gradle build dir, so each
runner takes an exclusive `flock` on `/tmp/mallow-e2e.lock` for its whole
invocation. Concurrent runs queue; they do not collide. Just wait.

On failure the runner prints the tail of that run's `mock.log` (per-run files
under `/tmp/mallow-e2e/`). Every request is logged with its path, so an
unexpected empty default response is visible without re-running anything.

`--uninstall` (`run_one.sh` only) does `adb uninstall` first, for a genuine
fresh-install case. It is **local-only**: a whole-directory run invokes `flutter
test integration_test/` as a single shell line and has no between-file hook,
which is exactly why `resetAppState()` exists as the in-process substitute.

## What the host needs

- **KVM** (`/dev/kvm`) — hardware acceleration; without it the x86_64 emulator
  is unusably slow.
- **Android SDK** at `/opt/android-sdk` with: `emulator`, `platform-tools`,
  `system-images;android-35;google_apis;x86_64`, `cmake;3.31.4` (needed by the
  `flutter_angle` native plugin), NDK.
- **AVD** named `e2e_pixel` (`avdmanager create avd -n e2e_pixel -k
  "system-images;android-35;google_apis;x86_64" -d pixel_6`).
- **JDK 17** at `/usr/lib/jvm/java-17-openjdk-amd64` — Gradle needs a full JDK
  with `javac`; the system `java-21` is a JRE only. `~/.gradle/gradle.properties`
  pins Gradle to it (`org.gradle.java.home` + auto-detect off).

## Sandbox files

- `android/app/google-services.json` — gitignored, and a **placeholder** under
  test. The `com.google.gms.google-services` Gradle plugin requires the file at
  build time; the app never calls `Firebase.initializeApp` under test, so the
  values are inert. Copy the **committed**
  `test/e2e/google-services.placeholder.json` into place before a run; a CI job
  should do the same rather than writing the file by hand, so there is one
  placeholder and its `package_name` always matches the app id.

## Two behaviors changed for headless E2E (both scoped, no prod impact)

1. **3D artwork ring** (`lib/features/onboarding/widgets/artwork_ring_3d.dart`)
   — `flutter_angle` hard-crashes on the emulator's software GL. Gated behind
   `--dart-define=E2E_DISABLE_GL=true`, which routes the decorative ring to its
   existing non-GL fallback. No effect without the define.
2. **Impeller disabled for debug builds**
   (`android/app/src/debug/AndroidManifest.xml`) — Impeller on swiftshader
   crashes the emulator under image-heavy screens; Skia is stable. Debug-only,
   so release/profile keep Impeller.

## Fixtures

The mock owns no hardcoded route table. Everything it serves comes from

```
test/e2e/fixtures/<scenario>/routes.json
```

**Add a scenario by adding a directory — never by editing `mock_backend.py`.**
That is the rule that lets many people write fixtures at once without merge
conflicts. Scenarios are discovered by directory listing at startup *and*
re-read on every scenario switch, so a new directory needs no server restart.

`default` is not a stub — it is the **empty-wallet baseline**: a signed-in
wallet that holds nothing, with every body in the shape its wire contract
specifies. Write a scenario only for the diffs from that.

🛑 **Bind every body to the type that parses it, and say which in a `_note`.**
An "empty" body of the wrong shape is worse than no fixture at all: the
generated `fromJson` throws on a missing non-nullable field, the screen renders
its **error** view, and a test that only checks "no artwork is listed" reads
that as an empty state and passes. `PortfolioArtworksResponse` needs `total`
as well as `result`; `ActivityListResponse` needs `pagination`; the Uniswap
list and the balances reads are both nested under `result`. Check
`packages/mallow_api/openapi/openapi.yaml` (or the hand-written model) before
you invent a body, never the other way round.

The same trap has a quieter form: a body the app parses successfully but reads
as "nothing here". `searchAssets` answering `result: null` degrades to zero
tokens **without erroring**, so the Tokens tab looks empty because the mock
said nothing, not because the wallet holds nothing. `default` answers it with
a real empty-portfolio body for exactly that reason.

```jsonc
{
  "routes": [
    // Plain HTTP: method + a path regex (searched, not anchored).
    { "method": "GET",  "path": "/v2/.*balances", "body": { "tokens": [] } },
    // Big captures live in a sibling file.
    { "method": "POST", "path": "/v2/.*portfolio", "bodyFile": "portfolio.json" },
    // JSON-RPC: match on the verb. `body` is the `result` value; the mock
    // wraps it in the envelope. Use "error" instead of "body" for an RPC error.
    { "method": "POST", "rpc": "getBalance",
      "body": { "context": { "slot": 1 }, "value": 777 } },
    // Optional non-200 for a route that must fail in this scenario.
    { "method": "GET",  "path": "/v2/gone", "status": 404, "body": {} }
  ]
}
```

A JSON-RPC request only ever matches a route that declares `rpc`, and a plain
HTTP request only ever matches one that does not — so a broad path regex cannot
swallow every RPC verb.

Resolution order, most specific first:

1. fault rules (below)
2. the active scenario's routes, in file order
3. the `default` scenario's routes — so a scenario states only its **diffs**
4. built-in handlers: the Solana JSON-RPC verbs, and `POST /v2/tx/*`
5. `DEFAULTS` — an empty `[]`/`{}` keyed by HTTP method

Every request logs one stderr line naming the rule that answered it:

```
[mock] POST /?network=devnet rpc=sendTransaction -> 200 (builtin:sendTransaction)
[mock] GET /v2/config/mobile rpc=- -> 200 (scenario:default#5)
[mock] GET /v2/artwork/xyz rpc=- -> 200 (DEFAULT)        <-- missing fixture
```

A `DEFAULT` tag is how a missing fixture gets found. That is what `mock.log` is
for on a CI failure.

### Solana RPC

Every Solana verb POSTs to the same proxy-root path, so JSON-RPC requests are
dispatched on the body's **`method`** field, not on the path. Batch bodies (a
JSON array) are answered with an array of envelopes, ids echoed. Confirmation is
plain HTTP polling of `getSignatureStatuses` — there is no websocket path, so
the mock never needs a websocket server.

Built-in verbs: `getLatestBlockhash`, `isBlockhashValid`, `getAccountInfo`,
`getMultipleAccounts`, `getBalance`, `getTokenAccountsByOwner`,
`simulateTransaction`, `sendTransaction`, `getSignatureStatuses`,
`getTransaction`, `getMinimumBalanceForRentExemption`, `getFeeForMessage`,
`getEpochInfo`, `getSlot`, `getHealth`, `getRecentPrioritizationFees`,
`getSignaturesForAddress`, `getPriorityFeeEstimate`. Anything else answers
`result: null` and logs `DEFAULT`.

They are mutually coherent: `sendTransaction` returns a deterministic base58
signature derived from the tx bytes and remembers it; `getSignatureStatuses`
then progresses that signature to `confirmed` and `finalized`; `getTransaction`
returns a non-null result for it and null for any other. `simulateTransaction`
returns `unitsConsumed` plus one account entry per requested inspect-address,
whose lamports sit `sim_cost_lamports` below what `getBalance` reports — so the
net-SOL delta the confirmation sheets read (`simulateWithDelta`) is a small,
plausible cost.

`isBlockhashValid` is load-bearing: `awaitConfirmationOrThrow`
(`lib/core/network/solana_rpc_service.dart`) probes it after ~15 s to decide
whether a blockhash expired. Set `blockhash_valid: false` for unconfirmed-path
tests, or they eat the full 90 s `maxWait`.

`POST /v2/tx/*` is answered with a generated, deserializable transaction whose
fee payer is `fee_payer` (see `txfixture.py`).

## Scenario control

The mock exposes a control surface at `/__test__/*`. It exists **only in
`mock_backend.py`** — no client, define, or route for it exists in the app, so
it cannot be reached in any release build. The test code runs on the device,
which already reaches the mock at `10.0.2.2:8091`, so a test drives it directly
over HTTP (`MockControl` in `integration_test/support/`) and CI needs no new
`--dart-define`.

| Endpoint | Body | Response |
| --- | --- | --- |
| `POST /__test__/reset` | `{}` or `{"scenario":"funded_wallet"}` | `{"ok":true,"name":...}`, or **400** on an unknown scenario |
| `POST /__test__/scenario` | `{"name":"funded_wallet"}` | `{"ok":true,"name":...}`, or **400** `{"ok":false,"error":"unknown scenario: ..."}` |
| `POST /__test__/fault` | see below | `{"ok":true,"count":N}` |
| `POST /__test__/faults/clear` | `{}` | `{"ok":true}` |
| `GET /__test__/requests` | — | `[{"method","path","rpc","body"}]` since the last reset |
| `POST /__test__/state` | a subset of the tunable keys below | `{"ok":true,"state":{...}}`, or **400** on an unknown key |

`reset` restores everything: scenario back to `default`, faults cleared, the
recorded-request log emptied, all broadcast-tx state dropped, and every
`/__test__/state` tunable back to its initial value. Pass `scenario` to reset
**and** select in one round trip: a bare reset followed by a separate
`/__test__/scenario` call leaves a window in which the mock is back on
`default` while the previous case's app is still running, and any request it
lands in that window is answered from the wrong fixture set.

An unknown scenario name is a **400, not a fallthrough** — a silent fallthrough
to empty defaults is exactly the false-confidence failure this suite exists to
prevent.

In `/__test__/requests`, `rpc` is the verb name for a single JSON-RPC call, a
comma-joined list of verb names for a batch, and `null` for a plain HTTP
request — always a string or null, never an array. Control endpoints are never
recorded.

An entry records a request's **arrival**, not its completion: the log is
appended before faults, delays and `refuse` are applied. A count proves the app
sent something and says nothing about whether it got an answer.

### Fault injection

```jsonc
POST /__test__/fault
{
  "path": "/v2/.*portfolio",   // regex, optional
  "method": "GET",             // optional
  "rpc": "sendTransaction",    // optional; matches the JSON-RPC verb
  "status": null,              // null => DO NOT BREAK IT (see below)
  "delay_ms": 0,               // sleep before responding
  "refuse": false,             // true => close the connection, no response
  "times": null,               // null = unlimited, else N matches then expire
  "body": null                 // with a status: the error body. Alone: a 200.
}
```

**`status` defaults to null, and null means "answer it normally".** A fault
with only `delay_ms` is a *slow* request that still gets its real fixture — the
thing a loading-state case actually needs. It used to default to 500, so every
"slow" fault was silently also a "broken" one, and a case written to prove the
skeleton appears was really proving the error view appears. State a status to
fail a request; give a `body` with no status to serve that body with a 200.

Rules are appended and matched in insertion order; only the fields you set are
tested. A fault is an HTTP-level thing, so an `rpc` fault against a **batch**
body fires when any member names that verb, and it faults the whole response.

### State tunables

`POST /__test__/state` merges its body into the mock's state. **The key set is
closed**: every key is validated against the table below (the mock's
`INITIAL_STATE`), and an unknown one is a **400** naming the offender plus the
full valid list, with **no partial update** — the whole payload is rejected. A
typo'd key (`blockhashValid`, `tx_eror`) used to merge silently while the real
tunable kept its default, which turns a failure-path case into a green
happy-path pass, or spends a 90 s confirmation timeout.

| Key | Default | Effect |
| --- | --- | --- |
| `fee_payer` | all-zero pubkey | Fee payer baked into generated `/v2/tx/*` transactions. **Set it to the deterministic test wallet before any signing flow** — the placeholder makes `place()` throw a loud `StateError`. |
| `tx_version` | `"legacy"` | `"legacy"` or `"v0"` for generated transactions. |
| `tx_presigned` | `false` | `false` = all-zero signature slots, exercising the blockhash-rewrite branch. `true` = a dummy non-zero server signature in a non-wallet slot, exercising the sign-as-is branch the market / raffle staleness checks depend on. Both branches are covered by tests. |
| `confirm_after_polls` | `1` | `getSignatureStatuses` polls before the tx lands. |
| `blockhash_valid` | `true` | The `isBlockhashValid` answer. |
| `tx_error` | `null` | Non-null puts an error into the confirmation status. |
| `sim_error` | `null` | Non-null fails `simulateTransaction`. |
| `balance_lamports` | `2000000000` | The `getBalance` answer. |
| `sim_cost_lamports` | `5000` | How far the simulated post-balance sits below `balance_lamports`. |
| `units_consumed` | `5000` | `simulateTransaction`'s compute units. |
| `blockhash` | fixed 32-byte value | The blockhash served and baked into generated transactions. |
| `slot` | `300000000` | Context slot; increments per RPC request. |

### Self-test

```bash
python3 -m unittest discover -s test/e2e -p 'test_*.py'
```

Boots the mock on an ephemeral port and asserts the whole contract above. Run it
after any change to `mock_backend.py` or `txfixture.py`.

Run it first in any CI job you build around this suite, before the toolchain
provisioning and the emulator, because it costs ~1.3 s and needs only `python3`.
The mock **is** the environment under test: a broken route resolver or control
surface fails every flow for a reason that has nothing to do with the app, and
catching that in seconds beats catching it 20 minutes in.

## Reading a whole-suite run

A whole-directory run is **one** `flutter test integration_test/`, so its exit
code alone says only "the run failed" — not which flow, and nothing at all on a
green build about which flows actually ran. Add
`--file-reporter=json:build/e2e/report.json`, which writes the machine-readable
event stream *alongside* the normal console output, and convert it:

```bash
python3 tool/junit_report.py build/e2e/report.json build/e2e/junit.xml
```

A CI job can then publish that XML through whatever JUnit reporting its platform
offers, for a per-test pass/fail list, per-flow durations and a failure trend
across builds. The same converter works on the unit suite. It has its own tests
in `tool/test_junit_report.py`; run those whenever you touch it.

The converter reports the cases that would otherwise vanish, because a run that
under-reports looks like a run that went well:

- a suite that **failed to compile** — that error only ever lands on the hidden
  synthetic `loading <file>` test, so it is kept while the passing hidden ones
  are dropped;
- a test with **no `testDone`** — a job timeout or a dead emulator killed the
  run mid-flow;
- a **truncated last line** in the event stream, for the same reason.

Only a **failing** case carries its stdout into the XML — the console log
already holds every line, and repeating it for ~4,100 passing unit tests would
roughly quadruple the published report on every retained build.

Its exit status is about the *conversion*, not the tests. The job keeps
`flutter test`'s own status and only escalates a green run to red when no report
could be written.

## Adding a flow

Everything shared lives in `integration_test/support/`. One import:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await MockControl.reset();       // default scenario, no faults, empty log
    // ...or, when the file needs a scenario, do BOTH in one round trip:
    // await MockControl.reset(scenario: 'funded_wallet');
  });

  // Covers: every Security & Privacy toggle survives a kill-and-reopen, so a
  // preference written to secure storage is read back on the next launch.
  testWidgets('settings toggles persist across a relaunch', (tester) async {
    await completeOnboardingWithTestWallet(tester);   // -> signed-in Home
    ...
    await restartApp(tester, wipe: false);            // relaunch, keep data
    ...
  });

  // Covers: reset wipes the wallet and lands on Welcome, not on a half-torn-down
  // Home that still shows the old balance.
  testWidgets('reset app returns to Welcome', (tester) async {
    await restartApp(tester);                          // wipe + relaunch
    ...
  });
}
```

Eight rules, in order of how expensive it is to get them wrong:

1. **Bundle many cases into ONE file.** This is a day-one runtime constraint,
   not an optimization. The suite serialises on a single emulator, so it cannot
   be sharded, and `flutter test integration_test/` does **not** amortize the
   build across the directory — it re-runs `assembleDebug`, uninstalls the app,
   reinstalls it and cold-boots it **for every file**. Measured: **~34 s of pure
   overhead per file** (~30 s Gradle up-to-date pass, ~0.8 s install, ~1.7 s app
   launch), against 2-13 s of actual test work. A file-per-case layout spends
   the whole budget on process startup. One file per feature, many `testWidgets`
   inside.
2. **Start every `testWidgets` with `restartApp(tester)`.** Within a file all
   cases share one process and one app-data dir, and `configureDependencies()`
   cannot be called twice; `restartApp` disposes the tree, wipes app state,
   rebuilds the DI graph and relaunches. Pass `wipe: false` for the "kill and
   reopen the app" scenario. Skip it and case 2 inherits case 1's wallet, PIN
   and session. See `resetAppState()` in `harness.dart` for what is wiped —
   four stores, not two — and why it runs after DI init, not before. It also
   pops any open sheet/menu through the real navigator and resets the app-level
   statics a real process restart would clear (`resetAppStatics`): `restartApp`
   disposes a widget tree, so without that step `NavBarState.selectedTab` /
   `.activeTab` / `.visible` and `DrawerSignal.*` all leak into the next case.

   *Measured, because the answer is not obvious:* app data does **not** survive
   from file to file today. `flutter test` uninstalls the app after each file
   (`--uninstall` defaults to true; `IntegrationTestDevice.kill()`), and logcat
   shows `PACKAGE_FULLY_REMOVED` between every pair of files, so each file
   really does start from a fresh install. Do not lean on that: it is a
   flutter_tools default that `--no-uninstall` flips, it is not pinned by
   anything in this repo, and it does nothing for case-to-case isolation inside
   a file, which is where most contamination actually happens.
3. **Never `pumpAndSettle`.** The welcome screen runs a perpetual three_js ring
   animation, so the frame scheduler never idles and `pumpAndSettle` blocks
   until the test times out. Use `pumpUntil` / `pumpUntilGone` / `settleAt` /
   `tapAndSettle` / `enterTextInto` / `dismissKeyboard` / `scrollUntil` from
   `harness.dart`. Do not reach for `tester.scrollUntilVisible` or
   `dragUntilVisible` either — both call `pumpAndSettle` internally.

   Typing raises a **real** Android IME here (`integration_test` sets
   `registerTestTextInput => false`), and it eats ~310 dp of viewport for
   several frames after you move on. `enterTextInto` hides it for you; if you
   call `tester.enterText` directly, call `dismissKeyboard(tester)` after. Skip
   that and a screen two navigations later lays out in a 529 dp viewport and
   throws `A RenderFlex overflowed by 121 pixels` — an error naming a widget
   your test never touched.
4. **Import the deterministic wallet, never a generated one.** `test_wallet.dart`
   holds the fixed phrase plus the Solana / EVM (checksummed *and* lowercased) /
   Tezos addresses that fixtures must template in, a SECOND phrase for cases
   that need a wallet the device does not already hold
   (`kSecondTestWalletMnemonic`), and three throwaway private keys
   (`kThrowawaySolanaKey` / `kThrowawayEvmKey` / `kThrowawayTezosKey`) with the
   addresses `PrivateKeyParser` derives from them.
   `test/e2e/test_wallet_derivation_test.dart` re-derives every one of them on
   each `flutter test` run and fails if any moved — never hand-write an
   address, run `test/e2e/tools/derive_test_wallet.dart` and paste. None of
   these is ever funded. Before any signing flow, point the mock's transaction
   builder at the same address:
   `await MockControl.state({'fee_payer': kTestWalletSolana});`
5. **Wait on a signal that can be false.** `find.byType(MallowBottomNavBar)`
   is the trap this suite has already fallen into three times: `app.dart`
   mounts `_PersistentNavBar` as a Stack **sibling** of the routed content, so
   the bar is in the tree on **every** screen — measured 1 match on a wiped
   install's Welcome screen, before a single tap — and only faded out via
   `NavBarState.visible`. `pumpUntil(find.byType(MallowBottomNavBar))` returns
   on the first frame from anywhere and proves nothing; the walking-skeleton
   test's only assertion was that finder, and it could not fail.

   Use **`waitForHome(tester)`** (`harness.dart`), which waits on
   `find.byType(HomeScreen)`. `HomeScreen` is instantiated in exactly one
   place (`TabNavigator._screens`), under `SessionInitializer`'s **resolved**
   child, and `find.byType` skips offstage widgets — so it matches when, and
   only when, the Home tab is on stage with a live session. Verified on device
   in that order: Welcome 0, PIN screen 0, session-loading 0, Home 1,
   Portfolio tab 0.

   For "the shell is up on *some* tab" use `find.byType(SharedHeader)`; for
   "a `TabNavigator` route is topmost" use `NavBarState.visible`. Neither is a
   session signal on its own — `visible` is raised from `TabNavigator`'s
   RouteAware `didPush`, measured true six frames before the session resolved.

6. **One unhandled async error kills the whole FILE, not just its case.** When
   an error escapes into the test zone mid-`pump`, the test aborts with
   `LiveTestWidgetsFlutterBinding._pendingFrame` still set, and every later
   `testWidgets` in the file dies immediately on
   `'_pendingFrame == null': is not true` — one real failure producing five
   phantom ones, none of which names the cause. Consequences:

   - Read the FIRST failure in a file and ignore the rest until it is fixed.
   - Never leave an app path that throws asynchronously running under a wait.
     The known ones in this sandbox are `[core/no-app]` from anything touching
     `FirebaseMessaging.instance` (turn the push preference off before opening
     Settings) and a failing `/v0/login` racing an unlock (let the login
     finish first).
   - If a case genuinely has to tolerate a known leak, drain it inside the
     pump loop with `tester.takeException()` and RETHROW anything you did not
     expect — see `_drainKnownAppLeaks` in `onboarding_import_test.dart`.

7. **Format only your own file.** `dart format lib test integration_test`
   rewrites anyone else's work in progress; run
   `dart format integration_test/your_file_test.dart` and verify with
   `dart format --output=none --set-exit-if-changed <your files>` (exit 0 is
   what CI checks).

8. **Say what each test covers** in a comment above it — the flow and the
   condition, not just a name. Without that, nobody can tell what the suite
   covers, so it gets manually re-tested anyway and the whole return is
   forfeited. Existing files carry short case IDs (`ONB-014`, `SEND-032`) from
   the release test plan they were written against; that plan is not part of
   this repository, so a new test should spell the case out in words instead.

Verify with `test/e2e/run_one.sh <your file>` while iterating, then
`test/e2e/run_e2e.sh` once before you hand it over. A flow is done when it
passes **three consecutive runs** on a cold emulator; one failure in three is a
flake and must be fixed or removed, not retried.

## A green run proves the pipeline, not the transaction

For Solana server-built transactions the client performs **no check of the
transaction contents** — `signSendConfirm` decodes the base64, rewrites the
blockhash when no signature is pre-attached, signs, broadcasts and confirms.
The only structural constraint is that the signer's pubkey occupies a signer
slot. That is exactly why these flows are testable against a mock: the mock
only has to emit a *deserializable* transaction whose required signer is the
test wallet.

It is also why **a mock cannot catch a wrong transaction.** The money cases
exist mostly to catch a transaction that is well-formed and wrong, and nothing
in this suite can tell the difference. A run against a real network,
by a human, with real value at stake, is still required before a release.
**A green E2E run is not permission to skip it.**

## Known non-fatal noise

A handful of endpoints are deliberately left to the generic `DEFAULT` body and
log a shape mismatch the app tolerates. Each one is listed with its reason in
the `_comment` block at the top of `fixtures/default/routes.json` — the biggest
is `POST /v0/authToken`, where answering would push the app into a signed-login
handshake (a real signature, a `Set-Cookie` the mock cannot produce) that no
case is written for. Add a fixture route when a flow needs the shape, and put
the reason next to it either way.

## Next step: Patrol

This suite uses Flutter's `integration_test`, which drives the Dart widget tree
only. Flows that need native OS interaction (the biometric unlock prompt,
permission dialogs) need **Patrol**, which wraps `integration_test` and adds
native automation (`patrolTest`, `$.native.*`). The current flow deliberately
skips biometrics (optional in onboarding), so it needs no native control yet.
Layering Patrol is the follow-up for biometric-gated flows.
