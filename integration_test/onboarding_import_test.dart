// E2E: the onboarding IMPORT paths, the multi-account picker (including the
// derivation-scheme picker), the private-key paths, watch-only addresses, and
// the reset-app round trip.
//
// Bucket `onboarding-import`: 22 E2E-eligible cases, 10 of them the CI smoke
// subset. Everything past the smoke quota
// carries `tags: 'nightly'` and is excluded from the 45-minute CI job with
// `--exclude-tags nightly`.
//
// Run it with `test/e2e/run_one.sh integration_test/onboarding_import_test.dart`
// while iterating; never `flutter test integration_test/...` directly (the
// runner owns the emulator lock, the mock backend, and the --dart-define set).
//
// ---------------------------------------------------------------------------
// Case map - case ID -> test name -> smoke|nightly
// ---------------------------------------------------------------------------
//
// | Case    | Test name                                                       | Run     |
// | ------- | --------------------------------------------------------------- | ------- |
// | ONB-001 | fresh install lands on the welcome screen                       | smoke   |
// | ONB-006 | generating a recovery phrase fills a 12-word grid, gated on the |         |
// |         |   confirmation checkbox                                         | nightly |
// | ONB-023 | biometric setup self-skips to the PIN step, and a relaunch      |         |
// | ONB-016 |   mid-onboarding resumes there                                  | nightly |
// | ONB-031 | importing a 12-word phrase derives the expected addresses       | smoke   |
// | ONB-030 | a completed onboarding survives a relaunch behind the lock      | smoke   |
// | ONB-041 | the account picker opens with five cards, first one preselected | smoke   |
// | ONB-044 | the legacy Solana toggle adds legacy and root rows              | smoke   |
// | ONB-045 | importing the selected wallets lands home with the new account  | smoke   |
// | ONB-046 | re-importing an on-device phrase marks its rows Imported        | nightly |
// | ONB-047 | "Import wallets from recovery phrase" reopens the picker        | nightly |
// | ONB-049 | importing a Solana private key during onboarding                | smoke   |
// | ONB-050 | importing an Ethereum private key after onboarding              | smoke   |
// | ONB-051 | importing a Tezos edsk private key after onboarding             | nightly |
// | ONB-055 | importing the same private key twice is rejected                | nightly |
// | ONB-057 | the private key is never displayed after import                 | nightly |
// | ONB-058 | adding a watch-only Solana address                              | smoke   |
// | ONB-059 | adding a watch-only Ethereum address                            | nightly |
// | ONB-064 | watching an address already in the wallet is rejected           | nightly |
// | ONB-065 | a watch address survives a relaunch                             | nightly |
// | ONB-106 | reset app returns to onboarding                                 | smoke   |
// | ONB-107 | re-importing after a reset restores the same addresses          | nightly |
//
// Smoke: 10 cases (ONB-001, 030, 031, 041, 044, 045, 049, 050, 058, 106).
// Nightly: 12 cases. Total 22 = the bucket's E2E-eligible count.
//
// Deliberately NOT here: every phrase / private-key / watch
// FIELD validation case (ONB-002..005, 007, 008, 032..040, 042, 043, 048,
// 052..054, 056, 060..063, 118) is a WIDGET test - "type bad input, see an
// error on the same screen" needs no device. ONB-009..014, 108..112 and 121
// stay MANUAL.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/accounts/screens/import_wallets_from_phrase_screen.dart';
import 'package:mallow_wallet/features/accounts/widgets/account_picker_card.dart';
import 'package:mallow_wallet/features/home/screens/home_screen.dart';
import 'package:mallow_wallet/features/home/widgets/account_menu_drawer.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';
import 'package:mallow_wallet/shared/widgets/custom_number_pad.dart';
import 'package:mallow_wallet/shared/widgets/lock_screen.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_pill_field.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mallow_wallet/shared/widgets/mallow_textarea_field.dart';
import 'package:mallow_wallet/shared/widgets/mallow_toggle.dart';
import 'package:mallow_wallet/shared/widgets/seed_phrase_grid.dart';
import 'package:mallow_wallet/shared/widgets/shared_header.dart';
import 'package:mallow_wallet/shared/widgets/wallet_type_badge.dart';

import 'support/e2e.dart';

// The throwaway private keys and both throwaway phrases now live in
// `support/test_wallet.dart` (`kThrowaway*Key` / `kThrowaway*Address`,
// `kSecondTestWalletMnemonic`), where `test/e2e/test_wallet_derivation_test.dart`
// re-parses them on every `flutter test` run. They used to be declared here,
// which put the only guard on a file no unit-test job ever loads.

/// Every flow here wipes and re-onboards, which runs well past `flutter_test`'s
/// 30 s default. Deliberately loose: every wait in this file is a bounded pump
/// that fails with its own message, so this is only a backstop against a true
/// hang and must never be the thing that turns a slow emulator red.
const Timeout _long = Timeout(Duration(minutes: 10));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Default scenario, no faults, empty request log. A fault left armed by a
    // failing case is the classic cross-case contaminant.
    await MockControl.reset();
  });

  // -------------------------------------------------------------------------
  // First run
  // -------------------------------------------------------------------------

  testWidgets('ONB-001 fresh install lands on the welcome screen', (
    tester,
  ) async {
    await restartApp(tester);

    await pumpUntil(
      tester,
      find.text('Create a new wallet'),
      label: 'Welcome screen',
    );
    expect(find.text('I already have a wallet'), findsOneWidget);
    expect(find.text('Select an option below to get started'), findsOneWidget);
    expect(find.text('Collect, curate & display'), findsOneWidget);
    expect(
      find.text('digital artwork across Solana, Tezos and Ethereum'),
      findsOneWidget,
    );
    expect(find.textContaining('Self-custodial'), findsOneWidget);
    // A wiped install has no PIN, so nothing may drop a lock over Welcome, and
    // the app shell must not be up. Asserted after the frames above, never on
    // the first frame - the lock overlay arrives from an async
    // `AppLockEvent.init` that reads the database.
    expect(find.byType(LockScreen), findsNothing);
    expect(find.byType(SharedHeader), findsNothing);
    // Measured, and the reason `_waitForHome` exists: the persistent nav bar
    // overlay IS mounted here, on the welcome screen of a wiped install. See
    // the note on [_waitForHome].
    expect(find.byType(MallowBottomNavBar), findsOneWidget);
  }, timeout: _long);

  testWidgets(
    'ONB-006 generating a recovery phrase fills a 12-word grid, gated on the '
    'confirmation checkbox',
    (tester) async {
      await restartApp(tester);
      await _openGeneratedPhraseScreen(tester);

      final words = _seedGridWords(tester);
      expect(words, hasLength(12), reason: 'a 12-word phrase fills 12 cells');
      for (final word in words) {
        expect(word, equals(word.toLowerCase()));
        expect(RegExp(r'^[a-z]+$').hasMatch(word), isTrue, reason: word);
      }
      // NB: the case text says "12 DISTINCT words". BIP-39 permits repeats -
      // this suite's own fixed phrase repeats "sadness" - so distinctness is
      // NOT asserted here. It would fail on a perfectly valid phrase.

      expect(find.text('Use a 24-word recovery phrase'), findsOneWidget);
      expect(
        find.textContaining('Write this phrase down and store it somewhere'),
        findsOneWidget,
      );
      expect(
        find.text("I've saved my recovery phrase in a secure location"),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MallowButton>(find.widgetWithText(MallowButton, 'Continue'))
            .enabled,
        isFalse,
        reason: 'Continue is gated on the confirmation checkbox',
      );
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-023/ONB-016 biometric setup self-skips to the PIN step, and a '
    'relaunch mid-onboarding resumes there',
    (tester) async {
      await restartApp(tester);
      await _openGeneratedPhraseScreen(tester);

      await tapAndSettle(
        tester,
        find.text("I've saved my recovery phrase in a secure location"),
      );
      await tapAndSettle(tester, find.text('Continue'));

      // ONB-023: the emulator has no enrolled biometric, so the setup screen
      // must forward on its own. Nothing below taps "Skip for now" - if the
      // flow needed that tap, this pumpUntil would time out.
      await pumpUntil(
        tester,
        find.text('Create a PIN'),
        label: 'PIN create (biometric step auto-skipped)',
        rounds: 200,
      );
      expect(
        find.text('Skip for now'),
        findsNothing,
        reason: 'the biometric screen is skipped, not shown-then-skipped',
      );

      // ONB-016: the wallet exists but onboarding is unfinished, so a relaunch
      // over the persisted state must resume onboarding - not bounce back to
      // Welcome, and not fall through into the app.
      await restartApp(tester, wipe: false);
      await pumpUntil(
        tester,
        find.text('Create a PIN'),
        label: 'PIN create after relaunch',
        rounds: 200,
      );
      expect(find.text('Create a new wallet'), findsNothing);
      expect(find.byType(SharedHeader), findsNothing);
    },
    tags: 'nightly',
    timeout: _long,
  );

  // -------------------------------------------------------------------------
  // Import - recovery phrase
  // -------------------------------------------------------------------------

  testWidgets(
    'ONB-031 importing a 12-word phrase derives the expected addresses',
    (tester) async {
      await restartApp(tester);
      await importTestWallet(tester);
      await _waitForHome(tester);

      // The address is the assertion of record, not the screen. Deriving with
      // the wrong scheme yields a VALID signature from a DIFFERENT address and
      // fails silently everywhere downstream; the home header renders the
      // account NAME, so only the persisted wallet rows can catch it.
      final addresses = await _persistedAddresses();
      expect(addresses, contains(kTestWalletSolana));
      expect(addresses, contains(kTestWalletTezos));
      expect(
        addresses.map((a) => a.toLowerCase()),
        contains(kTestWalletEvmLower),
      );
      // Standard is the path the import UI creates. Legacy and root are
      // import-only alternatives and must not appear from a plain import.
      expect(addresses, isNot(contains(kTestWalletSolanaLegacy)));
      expect(addresses, isNot(contains(kTestWalletSolanaRoot)));
    },
    timeout: _long,
  );

  testWidgets(
    'ONB-030 a completed onboarding survives a relaunch behind the lock screen',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);

      // The shared relaunch never samples once: `AppLockEvent.init` reads the
      // database asynchronously, so Home renders first and LockScreen drops
      // over it a frame later.
      await relaunchIntoLockScreen(tester);
      expect(find.text('Create a new wallet'), findsNothing);

      await unlockApp(tester);
      await _waitForHome(tester);
      expect(await _persistedAddresses(), contains(kTestWalletSolana));
    },
    timeout: _long,
  );

  // -------------------------------------------------------------------------
  // Import - multi-account picker
  // -------------------------------------------------------------------------

  testWidgets(
    'ONB-041 the account picker opens with five cards, first one preselected',
    (tester) async {
      // Onboard on a private key so the device holds NO seed phrase - that is
      // what makes the imported phrase brand new, which is the state this case
      // describes ("5 account cards, the first account's rows pre-selected").
      // Re-importing a phrase the device already has takes the ONB-046 branch
      // and preselects nothing.
      await _onboardWithPrivateKey(tester, kThrowawaySolanaKey);
      await _openPickerViaImportRecoveryPhrase(tester);

      expect(find.text('Import wallets from phrase'), findsOneWidget);
      expect(
        find.text('Select the accounts you wish to import'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MallowButton>(
              find.widgetWithText(MallowButton, 'Import wallets'),
            )
            .enabled,
        isTrue,
        reason: 'the first account is preselected, so import is available',
      );
      // The first card carries the phrase's index-0 addresses on all three
      // chains, truncated the way the row renders them. Asserted BEFORE any
      // scrolling: the list is lazy and card 1 is disposed once it leaves the
      // cache extent.
      expect(find.text(truncateAddress(kTestWalletSolana)), findsOneWidget);
      expect(find.text(truncateAddress(kTestWalletTezos)), findsOneWidget);
      expect(find.text(truncateAddress(kTestWalletEvm)), findsOneWidget);

      // "5 account cards" cannot be counted in one frame: the picker's
      // `ListView.builder` is lazy and five 5-row cards do not fit an 841 dp
      // viewport, so only four are ever mounted at once (this is what made the
      // first run report "4 of 5"). Scroll the batch and collect the
      // derivation indices actually rendered.
      expect(await _pickerAccountIndices(tester), {0, 1, 2, 3, 4});
      // Same reason the count needed scrolling: "+ Show more" is the list's
      // last item and is not built until the bottom is reached.
      expect(find.text('+ Show more'), findsOneWidget);
    },
    timeout: _long,
  );

  testWidgets('ONB-044 the legacy Solana toggle adds legacy and root rows', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await _waitForHome(tester);
    await _openPickerViaExistingPhrase(tester);

    // Off by default: only the standard path is offered.
    expect(find.text(truncateAddress(kTestWalletSolana)), findsOneWidget);
    expect(find.text(truncateAddress(kTestWalletSolanaLegacy)), findsNothing);
    expect(find.text(truncateAddress(kTestWalletSolanaRoot)), findsNothing);

    await _setLegacySolanaToggle(tester, on: true);

    // The SCHEME is part of a wallet's identity, so the new rows are asserted
    // by ADDRESS, not by count: a picker that grew three rows all carrying the
    // standard address would pass a count-only check and then sign from the
    // wrong wallet.
    await pumpUntil(
      tester,
      find.text(truncateAddress(kTestWalletSolanaLegacy)),
      label: 'Solana (legacy) row on account 01',
      rounds: 250,
    );
    expect(
      find.text(truncateAddress(kTestWalletSolanaRoot)),
      findsOneWidget,
      reason: 'root is index-less, so exactly one card can carry it',
    );
    expect(find.text(truncateAddress(kTestWalletSolana)), findsOneWidget);

    // Turning it back off removes them again.
    await _setLegacySolanaToggle(tester, on: false);
    await pumpUntilGone(
      tester,
      find.text(truncateAddress(kTestWalletSolanaLegacy)),
      label: 'Solana (legacy) row after the toggle goes off',
      rounds: 200,
    );
    expect(find.text(truncateAddress(kTestWalletSolanaRoot)), findsNothing);
  }, timeout: _long);

  testWidgets(
    'ONB-045 importing the selected wallets lands home with the new account',
    (tester) async {
      await _onboardWithPrivateKey(tester, kThrowawaySolanaKey);
      await _openPickerViaImportRecoveryPhrase(tester);

      expect(await _persistedAddresses(), isNot(contains(kTestWalletSolana)));

      await tapAndSettle(
        tester,
        find.widgetWithText(MallowButton, 'Import wallets'),
      );
      await pumpUntil(
        tester,
        find.textContaining('wallet(s)'),
        label: 'the "Imported N wallet(s)" snack bar',
        rounds: 200,
      );
      await _waitForHome(tester);
      await pumpUntilGone(
        tester,
        find.textContaining('wallet(s)'),
        label: 'the "Imported N wallet(s)" snack bar',
        rounds: 120,
      );

      final after = await _persistedAddresses();
      expect(after, contains(kTestWalletSolana));
      expect(after, contains(kTestWalletTezos));
      expect(after.map((a) => a.toLowerCase()), contains(kTestWalletEvmLower));

      // The drawer lists the new account beside the private-key one it joined.
      await _showAccountsPanel(tester);
      expect(
        _drawerAccountNames(tester).length,
        greaterThanOrEqualTo(2),
        reason: 'the private-key account plus the newly imported one',
      );
    },
    timeout: _long,
  );

  testWidgets(
    'ONB-046 re-importing an on-device phrase marks its rows Imported',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _openPickerViaImportRecoveryPhrase(tester);

      // Onboarding imported index 0 on all three chains, so those rows are
      // locked and nothing is preselected.
      expect(find.text('Imported'), findsNWidgets(3));
      expect(
        tester
            .widget<MallowButton>(
              find.widgetWithText(MallowButton, 'Import wallets'),
            )
            .enabled,
        isFalse,
        reason: 'nothing is preselected when the phrase already has imports',
      );
      // The other indices stay selectable, so more can still be added. Counted
      // by scrolling, because the lazy list only mounts four cards at a time.
      expect(await _pickerAccountIndices(tester), {0, 1, 2, 3, 4});
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-047 "Import wallets from recovery phrase" reopens the picker',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _openPickerViaExistingPhrase(tester);

      expect(find.text('Import wallets from phrase'), findsOneWidget);
      expect(find.text('Imported'), findsNWidgets(3));

      // No recovery word may be rendered anywhere along this route.
      for (final word in kTestWalletMnemonic.split(' ').toSet()) {
        expect(
          find.text(word),
          findsNothing,
          reason: 'recovery word "$word" leaked into the import picker',
        );
      }
    },
    tags: 'nightly',
    timeout: _long,
  );

  // -------------------------------------------------------------------------
  // Import - private key
  // -------------------------------------------------------------------------

  testWidgets('ONB-049 importing a Solana private key during onboarding', (
    tester,
  ) async {
    await restartApp(tester);
    await _openPrivateKeyEntryFromWelcome(tester);
    await _enterPrivateKey(tester, kThrowawaySolanaKey);
    await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Next'));

    // The summary renders the FULL derived address, so this is a real
    // key-to-address assertion rather than "a summary appeared".
    await pumpUntil(
      tester,
      find.text(kThrowawaySolanaAddress),
      label: 'private-key summary',
      rounds: 200,
    );
    await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Add wallet'));

    // A private-key import during onboarding continues into biometric/PIN
    // setup rather than dropping the user straight into the app.
    await completePinSetup(tester);
    await _waitForHome(tester);
    expect(await _persistedAddresses(), contains(kThrowawaySolanaAddress));
  }, timeout: _long);

  testWidgets('ONB-050 importing an Ethereum private key after onboarding', (
    tester,
  ) async {
    await completeOnboardingWithTestWallet(tester);
    await _waitForHome(tester);
    await _importPrivateKeyPostOnboarding(
      tester,
      kThrowawayEvmKey,
      kThrowawayEvmAddress,
    );

    // The summary must show the EIP-55 mixed-case form; the backend matches
    // lowercase, so the two forms are pinned separately on purpose.
    expect(kThrowawayEvmAddress, isNot(kThrowawayEvmAddress.toLowerCase()));
    expect(await _persistedAddresses(), contains(kThrowawayEvmAddress));
  }, timeout: _long);

  testWidgets(
    'ONB-051 importing a Tezos edsk private key after onboarding',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _importPrivateKeyPostOnboarding(
        tester,
        kThrowawayTezosKey,
        kThrowawayTezosAddress,
      );
      expect(await _persistedAddresses(), contains(kThrowawayTezosAddress));
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-055 importing the same private key twice is rejected',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _importPrivateKeyPostOnboarding(
        tester,
        kThrowawayEvmKey,
        kThrowawayEvmAddress,
      );

      await _openAddAccountScreen(tester);
      await tapAndSettle(tester, find.text('Import private key'));
      await _enterPrivateKey(tester, kThrowawayEvmKey);
      await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Next'));

      // Validation still passes - the key is well-formed - so the summary is
      // shown and only "Add wallet" fails.
      await pumpUntil(
        tester,
        find.text(kThrowawayEvmAddress),
        label: 'private-key summary',
        rounds: 200,
      );
      await tapAndSettle(
        tester,
        find.widgetWithText(MallowButton, 'Add wallet'),
      );

      await pumpUntil(
        tester,
        find.text('Could not import this key.'),
        label: 'the duplicate-key error on the entry step',
        rounds: 200,
      );
      expect(
        find.byType(MallowTextareaField),
        findsOneWidget,
        reason: 'the entry step reappears instead of the summary staying up',
      );
      expect(
        (await _allAddresses()).where((a) => a == kThrowawayEvmAddress).length,
        1,
        reason: 'no duplicate wallet row was created',
      );
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-057 the private key is never displayed after import',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _importPrivateKeyPostOnboarding(
        tester,
        kThrowawaySolanaKey,
        kThrowawaySolanaAddress,
        assertKeyHidden: true,
      );

      await _openAddAccountScreen(tester);
      await tapAndSettle(tester, find.text('Import private key'));
      await pumpUntil(
        tester,
        find.byType(MallowTextareaField),
        label: 'private-key entry step',
      );

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(MallowTextareaField),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text ?? '', isEmpty);
      expect(
        find.textContaining(kThrowawaySolanaKey.substring(0, 16)),
        findsNothing,
      );
    },
    tags: 'nightly',
    timeout: _long,
  );

  // -------------------------------------------------------------------------
  // Import - watch (view-only) address
  // -------------------------------------------------------------------------

  testWidgets('ONB-058 adding a watch-only Solana address', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await _waitForHome(tester);
    // The phrase's legacy-path address: a real Solana address from the same
    // throwaway phrase that a standard-path import never creates, so it is
    // genuinely absent from the device.
    await _addWatchAddress(tester, kTestWalletSolanaLegacy);

    expect(await _persistedAddresses(), contains(kTestWalletSolanaLegacy));

    await _showAccountsPanel(tester);
    expect(
      _drawerWatchOnlyBadges(tester),
      isNotEmpty,
      reason: 'the watched account is flagged view-only in the drawer',
    );
  }, timeout: _long);

  testWidgets(
    'ONB-059 adding a watch-only Ethereum address',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _addWatchAddress(tester, kThrowawayEvmAddress);
      expect(await _persistedAddresses(), contains(kThrowawayEvmAddress));
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-064 watching an address already in the wallet is rejected',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _openWatchAddressScreen(tester);

      // The phrase import already created this exact Solana wallet.
      await _enterWatchAddress(tester, kTestWalletSolana);
      await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Continue'));

      await pumpUntil(
        tester,
        find.textContaining('already exists'),
        label: 'the duplicate watch-address error',
        rounds: 200,
      );
      expect(
        NavBarState.visible.value,
        isFalse,
        reason: 'the flow stays on the watch screen instead of going home',
      );
      expect(
        (await _allAddresses()).where((a) => a == kTestWalletSolana).length,
        1,
        reason: 'no duplicate wallet row was created',
      );
    },
    tags: 'nightly',
    timeout: _long,
  );

  testWidgets(
    'ONB-065 a watch address survives a relaunch',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      await _addWatchAddress(tester, kTestWalletSolanaLegacy);

      await relaunchIntoLockScreen(tester);
      await unlockApp(tester);
      await _waitForHome(tester);

      expect(await _persistedAddresses(), contains(kTestWalletSolanaLegacy));
      await _showAccountsPanel(tester);
      expect(_drawerWatchOnlyBadges(tester), isNotEmpty);
    },
    tags: 'nightly',
    timeout: _long,
  );

  // -------------------------------------------------------------------------
  // Reset
  // -------------------------------------------------------------------------

  testWidgets('ONB-106 reset app returns to onboarding', (tester) async {
    await completeOnboardingWithTestWallet(tester);
    await _waitForHome(tester);
    await _resetAppFromSettings(tester);

    await _pumpUntilDraining(
      tester,
      find.text('Create a new wallet'),
      label: 'Welcome screen after the reset',
    );
    expect(find.text('I already have a wallet'), findsOneWidget);
    expect(await _persistedAddresses(), isEmpty);

    // Relaunching still shows Welcome: no wallet, no lock screen.
    await restartApp(tester, wipe: false);
    await _pumpUntilDraining(
      tester,
      find.text('Create a new wallet'),
      label: 'Welcome screen after the relaunch',
    );
    expect(find.byType(LockScreen), findsNothing);
  }, timeout: _long);

  testWidgets(
    'ONB-107 re-importing after a reset restores the same addresses',
    (tester) async {
      await completeOnboardingWithTestWallet(tester);
      await _waitForHome(tester);
      final before = await _persistedAddresses();
      expect(before, contains(kTestWalletSolana));

      await _resetAppFromSettings(tester);
      await _pumpUntilDraining(
        tester,
        find.text('I already have a wallet'),
        label: 'Welcome screen after the reset',
      );

      await importTestWallet(tester);
      await _waitForHome(tester);

      // Same phrase, same derivation, same addresses: the reset dropped the
      // rows without corrupting anything derivation depends on.
      expect(await _persistedAddresses(), equals(before));
    },
    tags: 'nightly',
    timeout: _long,
  );
}

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

/// Every address the app currently has persisted, read through its own
/// repository.
///
/// Used where no screen can carry the assertion: the home header renders the
/// ACCOUNT NAME, and the picker and drawer render truncated addresses, so a
/// wrong-scheme derivation would be invisible on screen while still producing a
/// valid signature from a different wallet.
Future<Set<String>> _persistedAddresses() async =>
    (await _allAddresses()).toSet();

Future<List<String>> _allAddresses() async {
  final wallets = await sl<WalletRepository>().getAllWallets();
  return wallets.map((w) => w.address).toList();
}

/// The words rendered in a read-only seed grid, with the "1." index labels
/// filtered out.
List<String> _seedGridWords(WidgetTester tester) {
  return tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(SeedPhraseGrid),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty && !RegExp(r'^\d+\.$').hasMatch(s))
      .toList();
}

// ---------------------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------------------

/// The shared [waitForHome] plus this file's leak drain.
///
/// Same signal as everywhere else - [HomeScreen], which exists only as
/// `SessionInitializer`'s resolved child, and never
/// `find.byType(MallowBottomNavBar)` (mounted on every screen, Welcome
/// included; ONB-001 above asserts exactly that). The only difference is
/// [drainKnownAppLeaks] on each round: this file drives the add-account and
/// settings surfaces that touch Firebase in a Firebase-less sandbox, and one
/// undrained async error aborts the whole FILE, not just its case.
Future<void> _waitForHome(WidgetTester tester) async {
  for (var i = 0; i < 250; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    drainKnownAppLeaks(tester);
    if (find.byType(HomeScreen).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
  fail('Timed out waiting for Home');
}

/// The pill in the drawer header: "Switch" in menu mode, "Close" while the
/// accounts panel is on top. Both content subtrees are always built, so this
/// pill is the only reliable read of which one the user is actually looking at.
Finder get _drawerClosePill => find.descendant(
  of: find.byType(AccountMenuDrawer),
  matching: find.text('Close'),
);

Finder get _drawerSwitchPill => find.descendant(
  of: find.byType(AccountMenuDrawer),
  matching: find.text('Switch'),
);

/// The shared [openAccountDrawer], behind this file's draining home wait.
///
/// The wait is the local part: every drawer entry here follows an import or a
/// reset, both of which leak (see [_waitForHome]). The opening itself is the
/// shared helper — idempotent, and it re-taps rather than sitting out a fixed
/// grace period for the `DrawerSignal.showAccountsOnNextOpen` post-frame
/// callback an import ends on, which is the race a single blind tap loses.
Future<void> _openAccountDrawer(WidgetTester tester) async {
  await _waitForHome(tester);
  await openAccountDrawer(tester);
}

/// Drawer -> "Add wallet" -> the add-account menu.
Future<void> _openAddAccountScreen(WidgetTester tester) async {
  await _openAccountDrawer(tester);
  if (_drawerClosePill.evaluate().isNotEmpty) {
    // Collapse the accounts panel first: it covers the menu rows and, being an
    // IgnorePointer sibling, swallows the tap that would otherwise reach them.
    await tapAndSettle(tester, _drawerClosePill);
    await pumpUntilGone(tester, _drawerClosePill, label: 'accounts panel');
  }
  await tapAndSettle(
    tester,
    find.descendant(
      of: find.byType(AccountMenuDrawer),
      matching: find.text('Add wallet'),
    ),
  );
  await pumpUntil(
    tester,
    find.text('Add account'),
    label: 'Add account screen',
    rounds: 200,
  );
  await settleAt(tester, find.text('Add account'));
}

/// Brings the drawer's accounts panel (Wallets tab) on stage.
Future<void> _showAccountsPanel(WidgetTester tester) async {
  await _openAccountDrawer(tester);
  if (_drawerClosePill.evaluate().isEmpty) {
    await tapAndSettle(tester, _drawerSwitchPill);
  }
  await pumpUntil(tester, _drawerClosePill, label: 'accounts panel');
  await settleAt(tester, _drawerClosePill);
}

/// Account names listed in the drawer's Wallets tab.
List<String> _drawerAccountNames(WidgetTester tester) {
  return tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(AccountMenuDrawer),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .where((s) => RegExp(r'^Account \d+$').hasMatch(s))
      .toList();
}

/// The view-only provenance marks currently rendered inside the drawer.
Iterable<WalletTypeBadge> _drawerWatchOnlyBadges(WidgetTester tester) {
  return tester
      .widgetList<WalletTypeBadge>(
        find.descendant(
          of: find.byType(AccountMenuDrawer),
          matching: find.byType(WalletTypeBadge),
        ),
      )
      .where((b) => b.badge == WalletBadge.watchOnly);
}

/// Welcome -> "Create a new wallet" -> "Use a recovery phrase" -> generate, and
/// waits for the grid's staggered fade to finish.
Future<void> _openGeneratedPhraseScreen(WidgetTester tester) async {
  await pumpUntil(
    tester,
    find.text('Create a new wallet'),
    label: 'Welcome screen',
  );
  await tapAndSettle(tester, find.text('Create a new wallet'));
  await pumpUntil(
    tester,
    find.text('Use a recovery phrase'),
    label: 'Create-wallet menu',
  );
  await tapAndSettle(tester, find.text('Use a recovery phrase'));
  await pumpUntil(
    tester,
    find.text('Generate recovery phrase'),
    label: 'Wallet intro screen',
  );
  await tapAndSettle(tester, find.text('Generate recovery phrase'));

  await pumpUntil(
    tester,
    find.byType(SeedPhraseGrid),
    label: 'Seed phrase screen',
  );
  await tester.pump(const Duration(milliseconds: 800));
}

/// Welcome -> "I already have a wallet" -> "Use a private key".
Future<void> _openPrivateKeyEntryFromWelcome(WidgetTester tester) async {
  await pumpUntil(
    tester,
    find.text('I already have a wallet'),
    label: 'Welcome screen',
  );
  await tapAndSettle(tester, find.text('I already have a wallet'));
  await pumpUntil(
    tester,
    find.text('Use a private key'),
    label: 'Import-wallet menu',
  );
  await tapAndSettle(tester, find.text('Use a private key'));
}

/// Welcome -> private key -> summary -> PIN -> Home.
Future<void> _onboardWithPrivateKey(WidgetTester tester, String key) async {
  await restartApp(tester);
  await _openPrivateKeyEntryFromWelcome(tester);
  await _enterPrivateKey(tester, key);
  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Next'));
  await pumpUntil(
    tester,
    find.widgetWithText(MallowButton, 'Add wallet'),
    label: 'private-key summary',
    rounds: 200,
  );
  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Add wallet'));
  await completePinSetup(tester);
  await _waitForHome(tester);
}

/// Types [key] into the private-key entry step.
Future<void> _enterPrivateKey(WidgetTester tester, String key) async {
  await pumpUntil(
    tester,
    find.byType(MallowTextareaField),
    label: 'private-key entry step',
    rounds: 200,
  );
  await enterTextInto(
    tester,
    find.descendant(
      of: find.byType(MallowTextareaField),
      matching: find.byType(TextField),
    ),
    key,
  );
}

/// Home -> add account -> "Import private key" -> summary -> Home.
///
/// With [assertKeyHidden] the summary is also checked for a leak of the raw key
/// before the import is confirmed (ONB-057).
Future<void> _importPrivateKeyPostOnboarding(
  WidgetTester tester,
  String key,
  String expectedAddress, {
  bool assertKeyHidden = false,
}) async {
  await _openAddAccountScreen(tester);
  await tapAndSettle(tester, find.text('Import private key'));
  await _enterPrivateKey(tester, key);
  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Next'));

  await pumpUntil(
    tester,
    find.text(expectedAddress),
    label: 'private-key summary for $expectedAddress',
    rounds: 200,
  );
  if (assertKeyHidden) {
    expect(find.textContaining(key.substring(0, 16)), findsNothing);
  }

  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Add wallet'));
  await pumpUntil(
    tester,
    find.text('Wallet imported'),
    label: 'the "Wallet imported" snack bar',
    rounds: 200,
  );
  await _waitForHome(tester);
  await _waitForSnackBarGone(tester, 'Wallet imported');
}

/// Home -> add account -> "Watch address".
Future<void> _openWatchAddressScreen(WidgetTester tester) async {
  await _openAddAccountScreen(tester);
  await tapAndSettle(tester, find.text('Watch address'));
  await pumpUntil(
    tester,
    find.text('Enter the wallet you want to watch'),
    label: 'watch-address screen',
    rounds: 150,
  );
  expect(find.text('Address or .sol/.eth domain'), findsOneWidget);
}

Future<void> _enterWatchAddress(WidgetTester tester, String address) async {
  await enterTextInto(
    tester,
    find.descendant(
      of: find.byType(MallowPillField),
      matching: find.byType(TextField),
    ),
    address,
  );
}

/// Home -> add account -> "Watch address" -> Home.
Future<void> _addWatchAddress(WidgetTester tester, String address) async {
  await _openWatchAddressScreen(tester);
  await _enterWatchAddress(tester, address);
  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Continue'));

  await pumpUntil(
    tester,
    find.text('Watch wallet added'),
    label: 'the "Watch wallet added" snack bar',
    rounds: 200,
  );
  await _waitForHome(tester);
  await _waitForSnackBarGone(tester, 'Watch wallet added');
}

/// Waits out a top-anchored [AppSnackBar].
///
/// Not cosmetic. `AppSnackBar` inserts an overlay entry 80 dp from the top for
/// 4 s, which lands exactly on the account drawer's header row - the "Close" /
/// "Switch" pill sits at y = 90. Opening the drawer while a snack bar is up
/// makes the pill tap land on the snack bar's `AbsorbPointer` instead, and the
/// drawer never changes mode. That is what failed ONB-055 and ONB-057 in the
/// first two runs, reported as "accounts panel to disappear" timeouts with a
/// hit-test warning naming `_RenderTheater`.
Future<void> _waitForSnackBarGone(WidgetTester tester, String message) async {
  await pumpUntilGone(
    tester,
    find.text(message),
    label: 'the "$message" snack bar',
    rounds: 120,
  );
}

/// Home -> add account -> "Import recovery phrase" -> the HD picker.
Future<void> _openPickerViaImportRecoveryPhrase(WidgetTester tester) async {
  await _openAddAccountScreen(tester);
  await tapAndSettle(tester, find.text('Import recovery phrase'));

  final grid = find.byType(SeedPhraseGrid);
  await pumpUntil(tester, grid, label: 'recovery-phrase entry screen');
  // One `enterText` of the whole phrase goes through SeedPhraseGrid's
  // multi-word branch, the same handler the paste button uses.
  await enterTextInto(
    tester,
    find.descendant(of: grid, matching: find.byType(TextField)).first,
    kTestWalletMnemonic,
  );
  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Continue'));
  await _waitForPickerCards(tester);
}

/// Home -> add account -> "Import wallets from recovery phrase" -> the HD
/// picker for the single on-device phrase (the selector auto-advances).
Future<void> _openPickerViaExistingPhrase(WidgetTester tester) async {
  await _openAddAccountScreen(tester);
  // The row only exists once a seed-phrase-backed account is on the device,
  // and `AddAccountScreen` reads that asynchronously.
  final fromPhrase = find.text('Import wallets from recovery phrase');
  await pumpUntil(
    tester,
    fromPhrase,
    label: '"Import wallets from recovery phrase" row',
    rounds: 150,
  );
  await tapAndSettle(tester, fromPhrase);
  await _waitForPickerCards(tester);
}

/// Waits for the picker's skeletons to be replaced by real account cards.
///
/// [count] is 4, not the batch size of 5, and that is not a fudge: the picker
/// uses a lazy `ListView.builder` and five 5-row cards do not fit an 841 dp
/// viewport, so the fifth is never mounted until the list is scrolled. Use
/// [_pickerAccountIndices] to assert the whole batch.
///
/// The budget is deliberately large. The picker derives five indices across
/// three chains before it can render anything, each over a PBKDF2 seed; on a
/// contended emulator that is tens of seconds, not the ~8 s a default
/// `pumpUntil` allows.
Future<void> _waitForPickerCards(WidgetTester tester, {int count = 4}) async {
  var seen = 0;
  for (var i = 0; i < 900; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    drainKnownAppLeaks(tester);
    seen = find.byType(AccountPickerCard).evaluate().length;
    if (seen >= count) {
      await settleAt(tester, find.byType(AccountPickerCard).first);
      return;
    }
  }
  fail('The import picker rendered $seen of $count account cards in 90 s');
}

/// Scrolls the picker to its "+ Show more" row, collecting every derivation
/// index whose card the lazy list builds on the way.
Future<Set<int>> _pickerAccountIndices(WidgetTester tester) async {
  final seen = <int>{};
  void collect() {
    for (final card in tester.widgetList<AccountPickerCard>(
      find.byType(AccountPickerCard),
    )) {
      seen.add(card.account.index);
    }
  }

  collect();
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 15; i++) {
    if (find.text('+ Show more').hitTestable().evaluate().isNotEmpty) break;
    await tester.drag(list, const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 200));
    drainKnownAppLeaks(tester);
    collect();
  }
  collect();
  return seen;
}

/// Opens the picker's gear sheet, sets "Show legacy Solana accounts" to [on],
/// and closes the sheet again.
Future<void> _setLegacySolanaToggle(
  WidgetTester tester, {
  required bool on,
}) async {
  // Routes below a pushed one stay mounted, so the drawer's own settings.svg
  // rows are still in the tree. Scope the gear to the picker screen.
  final gear = find.descendant(
    of: find.byType(ImportWalletsFromPhraseScreen),
    matching: find.byWidgetPredicate(
      (w) => w is MallowSvgIcon && w.assetPath == 'assets/icons/settings.svg',
      description: 'import-picker gear icon',
    ),
  );
  await tapAndSettle(tester, gear);
  await pumpUntil(
    tester,
    find.text('Show legacy Solana accounts'),
    label: 'import settings sheet',
  );

  // The picker behind the sheet renders one MallowToggle per wallet row, so
  // the sheet's toggle has to be reached through its own Row.
  final sheetToggle = find.descendant(
    of: find
        .ancestor(
          of: find.text('Show legacy Solana accounts'),
          matching: find.byType(Row),
        )
        .first,
    matching: find.byType(MallowToggle),
  );
  if (tester.widget<MallowToggle>(sheetToggle).value != on) {
    await tapAndSettle(tester, sheetToggle);
  }

  await tapAndSettle(tester, find.widgetWithText(MallowButton, 'Done'));
  await pumpUntilGone(
    tester,
    find.text('Show legacy Solana accounts'),
    label: 'import settings sheet',
  );
}

/// Home -> drawer -> Settings -> re-auth -> Security & Privacy -> Reset app.
Future<void> _resetAppFromSettings(WidgetTester tester) async {
  // The shared opener carries the whole Settings entry, including the
  // push-preference pre-empt this file used to do by hand: `_loadData`
  // evaluates `prefs.pushNotificationsEnabled && await push.isAuthorized()`,
  // and `isAuthorized()` reaches `FirebaseMessaging.instance` with no
  // try/catch in a harness that never calls `Firebase.initializeApp()`. The
  // `&&` short-circuits, so the stored preference being off keeps the call
  // from ever being made — and the leak drain covers the frames before it.
  await _waitForHome(tester);
  await openSettings(tester);

  final security = find.text('Security & Privacy');
  await _pumpUntilDraining(tester, security, label: 'Settings screen');
  await _tapSettingsRow(tester, security);

  // Security & Privacy is gated: `requireReauth` (settings_screen.dart) demands
  // the PIN again before the sub-screen is pushed. With a PIN set and no
  // enrolled biometric on this emulator that is always PinPromptSheet, so the
  // gate is a step in the flow, not a branch.
  final reauth = find.text('Enter your PIN');
  final resetRow = find.text('Reset app');
  await _pumpUntilDraining(
    tester,
    find.byWidgetPredicate(
      (w) => w is Text && (w.data == 'Enter your PIN' || w.data == 'Reset app'),
      description: 're-auth PIN prompt or the Security & Privacy screen',
    ),
    label: 're-auth PIN prompt',
  );
  if (reauth.evaluate().isNotEmpty) {
    await _typePinUntilPadCloses(tester);
    // `PinPromptSheet` validates through the background-isolate PIN hash, and
    // on this emulator under load the sheet has taken 6-8 s to pop afterwards.
    // A 20 s wait was not enough in run 2; this one is 60 s.
    await _waitForReauthToClear(tester, reauth);
    if (reauth.evaluate().isNotEmpty) {
      // Some taps were swallowed while the sheet was still sliding in. Top the
      // buffer up rather than starting over: `_onNumber` appends until it holds
      // six and only then validates, and every digit here is the same.
      await _typePinUntilPadCloses(tester);
      await _waitForReauthToClear(tester, reauth);
    }
    if (reauth.evaluate().isNotEmpty) {
      fail('The re-auth PIN prompt stayed up after two PIN entries');
    }
  }

  // The screen title and the confirm button share the string "Reset app", and
  // the row is the FIRST of the two in tree order.
  await _pumpUntilDraining(
    tester,
    resetRow,
    label: 'Security & Privacy screen',
  );
  await _tapSettingsRow(tester, resetRow.first);

  await _pumpUntilDraining(
    tester,
    find.text('I have my recovery phrase saved'),
    label: 'Reset app screen',
  );
  await tapAndSettle(tester, find.text('I have my recovery phrase saved'));
  // The confirm button is a bare AnimatedContainer that reuses the title
  // string, so scope the tap to the button itself.
  await tapAndSettle(
    tester,
    find.descendant(
      of: find.byType(AnimatedContainer),
      matching: find.text('Reset app'),
    ),
  );
  // Keep draining while the reset runs: the Settings screen's leaked future
  // (below) can still be in flight when the tree is torn down.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    drainKnownAppLeaks(tester);
  }
}

/// Taps the PIN digit until the number pad goes away, up to [maxTaps] times.
///
/// The harness's `enterPin` cannot drive the re-auth sheet, for two reasons
/// this file paid for in full:
///
///  * It taps each digit exactly once. At least one tap is swallowed while
///    `PinPromptSheet` is still sliding in, so the buffer stops at five, never
///    reaches `_pinLength`, and never validates - the sheet then sits there
///    forever (60 s in run 4). Over-tapping is the fix and is safe:
///    `_onNumber` returns early once the buffer holds six, and every digit of
///    [kTestWalletPin] is the same, so extra taps cannot enter a wrong PIN.
///  * It calls `tester.tap` on a finder it evaluated earlier. The sheet pops
///    itself the instant the sixth digit lands, so the pad can vanish between
///    the two - `Bad state: No element`, which is how ONB-106/107 died in
///    run 3. The re-check below sits in the same synchronous block as the tap,
///    so no frame can run in between.
Future<void> _typePinUntilPadCloses(
  WidgetTester tester, {
  int maxTaps = 12,
}) async {
  final digits = kTestWalletPin.split('').toSet();
  if (digits.length != 1) {
    fail(
      'kTestWalletPin is no longer a repeated single digit ($kTestWalletPin); '
      'over-tapping would enter a wrong PIN. Rework _typePinUntilPadCloses.',
    );
  }
  final key = find.descendant(
    of: find.byType(CustomNumberPad),
    matching: find.text(digits.single),
  );
  for (var i = 0; i < maxTaps; i++) {
    if (key.evaluate().isEmpty) return;
    await settleAt(tester, key);
    if (key.evaluate().isEmpty) return;
    await tester.tap(key.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Waits up to 60 s for the re-auth sheet to pop.
Future<void> _waitForReauthToClear(WidgetTester tester, Finder reauth) async {
  for (var i = 0; i < 600 && reauth.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    drainKnownAppLeaks(tester);
  }
}

/// The shared [pumpUntilDrained] on this file's budget.
///
/// 30 s rather than the shared 8 s default: every wait that needs the drain
/// here sits behind an Argon2id re-auth, a route push, or a reset that rebuilds
/// the whole graph, and this emulator has taken 6-8 s for the PIN sheet alone.
Future<void> _pumpUntilDraining(
  WidgetTester tester,
  Finder finder, {
  required String label,
  int rounds = 300,
}) => pumpUntilDrained(tester, finder, label: label, rounds: rounds);

/// Scrolls a settings row into view (settings bodies are `ListView`s) and taps
/// it. `scrollUntil` is not used here: routes below the pushed settings screen
/// stay mounted, so `find.byType(Scrollable).first` can pick a list on the home
/// tab underneath.
Future<void> _tapSettingsRow(WidgetTester tester, Finder row) async {
  await tester.ensureVisible(row);
  await tester.pump(const Duration(milliseconds: 200));
  await tapAndSettle(tester, row);
}
