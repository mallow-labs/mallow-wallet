// E2E: create-wallet onboarding flow, driven end-to-end on a real Android
// emulator against the sandboxed mock backend (test/e2e/mock_backend.py).
//
// This is the walking skeleton that proves the whole loop works: the app
// boots hermetically (no Firebase/Sentry/analytics), the driver taps through
// every onboarding screen, client-side wallet generation + PIN storage run
// for real, and the app lands on the main shell — all with zero network
// egress beyond the mock. It is a regression gate for the onboarding flow:
// if any screen's finder, navigation, or the create→home redirect breaks,
// this fails.
//
// It carries NO case ID, and that is not an oversight: it predates the case
// list and its job is the pipeline itself. The generate-phrase assertions
// are `ONB-006` in `onboarding_import_test.dart`,
// which owns that bucket; `ONB-015` (backgrounding mid-onboarding) is PATROL.
//
// Run: `test/e2e/run_one.sh integration_test/onboarding_create_wallet_test.dart`.
//
// This file deliberately does NOT import the deterministic test wallet: the
// case is the GENERATE path, so the phrase has to come from the app.
// Everything else — the bounded-pump primitives, the PIN driver, the Home
// signal — comes from `support/e2e.dart`. It used to carry private copies of
// all of them, which is how its final assertion rotted (see below).

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/shared/widgets/seed_phrase_grid.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await MockControl.reset();
  });

  testWidgets(
    'create-wallet onboarding reaches the main app shell',
    (tester) async {
      await restartApp(tester);

      // 1. Welcome → open the create-wallet menu.
      final createBtn = find.text('Create a new wallet');
      await pumpUntil(tester, createBtn, label: 'Welcome screen');
      await tapAndSettle(tester, createBtn);

      // 2. Create menu → recovery-phrase path.
      final recoveryBtn = find.text('Use a recovery phrase');
      await pumpUntil(tester, recoveryBtn, label: 'Create-wallet menu');
      await tapAndSettle(tester, recoveryBtn);

      // 3. Wallet intro → generate.
      final generateBtn = find.text('Generate recovery phrase');
      await pumpUntil(tester, generateBtn, label: 'Wallet intro screen');
      await tapAndSettle(tester, generateBtn);

      // 4. Seed phrase display → confirm saved, continue. The grid really is
      //    filled in by the app's own generator; nothing here reads the words.
      final confirmCheckbox = find.text(
        "I've saved my recovery phrase in a secure location",
      );
      await pumpUntil(tester, confirmCheckbox, label: 'Seed phrase screen');
      expect(find.byType(SeedPhraseGrid), findsOneWidget);
      await tapAndSettle(tester, confirmCheckbox);
      await tapAndSettle(tester, find.text('Continue'));

      // 5. Biometric setup (self-skipping on an emulator with no enrolment) and
      //    both PIN steps. `completePinSetup` returns on a Home frame with the
      //    PIN actually written — not merely with the redirect fired.
      await completePinSetup(tester);
      await waitForHome(tester);

      // 6. Landed on the main app shell — onboarding complete, create→home
      //    redirect fired, session initialised.
      //
      //    🛑 This assertion used to be `find.byType(MallowBottomNavBar)`, and
      //    it proved NOTHING: `app.dart` mounts the nav bar as a Stack sibling
      //    of the routed content, so it is in the tree on the Welcome screen
      //    too (measured: 1 match on a wiped install before a single tap). The
      //    whole file could have failed to leave onboarding and still passed.
      //    [HomeScreen] exists only as `SessionInitializer`'s resolved child —
      //    see `waitForHome` in `support/harness.dart`.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Create a new wallet'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
