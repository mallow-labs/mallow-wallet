// The deterministic E2E test wallet.
//
// Every flow that needs a wallet imports THIS phrase rather than generating
// one, so the addresses below are known at fixture-build time. Ownership gates
// only light the owner CTAs when a fixture's owner field equals the signed-in
// wallet's address, so a generated wallet makes owner-action cases untestable.
//
// SECURITY
//   This phrase is committed in a public repo. It is a throwaway, minted for
//   this suite and used nowhere else — NEVER fund it, never reuse it, and
//   never paste it into a wallet you care about. It is deliberately NOT the
//   `abandon ... about` vector the unit tests use, and NOT the env-supplied
//   phrase the live Tezos shadownet harness in `test/integration/` runs on
//   (that one takes `TEZOS_GHOSTNET_FUNDING_MNEMONIC` from the environment and
//   IS funded).
//
// THE ADDRESSES ARE DERIVED, NOT WRITTEN BY HAND.
//   `test/e2e/tools/derive_test_wallet.dart` prints them from the app's own
//   `MultiChainDerivation`; `test/e2e/test_wallet_derivation_test.dart`
//   re-derives them on every `flutter test` run and fails if they drift. The
//   derivation SCHEME is part of a wallet's identity: derive with the wrong
//   one and you get a valid signature from a DIFFERENT address, which fails
//   silently rather than erroring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mallow_wallet/shared/widgets/seed_phrase_grid.dart';

import 'harness.dart';

/// The fixed 12-word BIP-39 phrase every E2E flow imports. Throwaway; never
/// funded. See the security note at the top of this file.
const String kTestWalletMnemonic =
    'memory pattern crack poet easy text chicken visa sadness sadness '
    'pistol aware';

/// Solana address at the standard path `m/44'/501'/0'/0'` — the one the import
/// UI actually creates, and the address fixtures must carry as `owner`.
const String kTestWalletSolana = '2hkiXrNpDftCm9f7ZMat6KJteGjZR6a9UBiXqMG42uNt';

/// Solana address at the legacy path `m/44'/501'/0'` (import-only, behind the
/// legacy-derivation toggle). Here so a derivation-picker case can assert the
/// picker offers the right alternative, not just "an address".
const String kTestWalletSolanaLegacy =
    '5JcpR6h3sifu33hvxQqSP39m6eBdkXLGctMBuCVyxDCb';

/// Solana address at the index-less root path `m/44'/501'`.
const String kTestWalletSolanaRoot =
    '9JjdVe6wKqaVV7Gt7zRumuWiKvPucxuJtuLBRt8a8Eib';

/// EVM address at `m/44'/60'/0'/0/0`, EIP-55 checksummed — the form the app
/// DISPLAYS.
const String kTestWalletEvm = '0xA3a71415Da99b3962A12342f60A0B8F9db742b62';

/// The same EVM address lowercased — the form the BACKEND matches on.
///
/// Not a convenience: templating a checksummed address into an EVM fixture's
/// owner field makes the app's portfolio read return zero NFTs, because the
/// comparison is done lowercase server-side. Use this constant in fixtures and
/// [kTestWalletEvm] in display assertions.
const String kTestWalletEvmLower = '0xa3a71415da99b3962a12342f60a0b8f9db742b62';

/// Tezos `tz1` address at `m/44'/1729'/0'/0'`.
const String kTestWalletTezos = 'tz1dDsYeRrKjCJBunrfDJWhEZ1WnQSwjZNpx';

// ---------------------------------------------------------------------------
// The SECOND throwaway phrase
// ---------------------------------------------------------------------------
//
// For cases that need a phrase the device does NOT already hold: importing a
// second account, switching between two, or asserting that a re-import of a
// different phrase creates new rows rather than reusing the old ones. Using
// [kTestWalletMnemonic] twice trips the duplicate-wallet guard and turns those
// cases into an accidental "already exists" test.
//
// Same rules as the first: minted for this suite, committed in a public repo,
// NEVER funded. Derived by `test/e2e/tools/derive_test_wallet.dart` and
// guarded by `test/e2e/test_wallet_derivation_test.dart`.

/// A second fixed 12-word BIP-39 phrase. Throwaway; never funded.
const String kSecondTestWalletMnemonic =
    'version economy desert virtual elephant eyebrow inquiry field suspect '
    'solar kiwi retreat';

/// Second phrase's Solana address at the standard path `m/44'/501'/0'/0'`.
const String kSecondTestWalletSolana =
    'DtGDJKjeRe6mqjWoVwsp9hyo7y8tqU3DBM4tXFvaQHaC';

/// Second phrase's EVM address at `m/44'/60'/0'/0/0`, EIP-55 checksummed.
const String kSecondTestWalletEvm =
    '0x71e0C168B7a24F425acB6C8832b9EE6925CDd6d9';

/// Second phrase's Tezos `tz1` address at `m/44'/1729'/0'/0'`.
const String kSecondTestWalletTezos = 'tz1h7iSfztwaG9xMtScx62UVEEP3CP3xu2uz';

// ---------------------------------------------------------------------------
// Throwaway private keys
// ---------------------------------------------------------------------------
//
// SECURITY: minted from fixed, arbitrary 32-byte seeds and used nowhere else.
// They are committed in a public repo — NEVER fund them.
//
// Deliberately NOT derived from either phrase above: a phrase import creates
// Solana + Ethereum + Tezos wallets at index 0, so a key that re-derived any
// of those addresses would trip the duplicate-wallet guard and quietly turn a
// private-key import case into an accidental duplicate-rejection case.
//
// Each address is what `PrivateKeyParser.parse` returns for its key (Solana
// base58 pubkey, EIP-55 checksummed EVM, tz1 Tezos) — the parser is what
// decides both the chain and the encoding, so the addresses are printed by
// `test/e2e/tools/derive_test_wallet.dart`, never written by hand.

/// A throwaway Solana keypair, base58 of the 64-byte secret key.
const String kThrowawaySolanaKey =
    '5Y7H58EbZtqjnWbzgr1DhAPKocXd7jk59zxYezfcFFUXKaFNJCXxbXUw3rq5rtaQMh4n62CbWbhg74tHuomWAspf';

/// The Solana address [kThrowawaySolanaKey] controls.
const String kThrowawaySolanaAddress =
    '5sE1g68BnSjXMz6e14YhSbRphrHe2HHKdem7fHoma8G3';

/// A throwaway Ethereum secp256k1 key, 0x-prefixed hex.
const String kThrowawayEvmKey =
    '0xe2e5020000000000000000000000000000000000000000000000000065766d31';

/// The EIP-55 checksummed address [kThrowawayEvmKey] controls.
const String kThrowawayEvmAddress =
    '0x69752450d129167b3bEb8788e0b0501A90d42788';

/// A throwaway Tezos Ed25519 key in `edsk` seed form.
const String kThrowawayTezosKey =
    'edsk4Ppzn4yjjGiqP6foQ4z6mj43zThzpXk3AjV1srFnATYg2bEJMy';

/// The tz1 address [kThrowawayTezosKey] controls.
const String kThrowawayTezosAddress = 'tz1Xi5qxYwDttu9r5iH9zeEyZpLqccZxMqSL';

/// Drives the REAL import UI with [phrase], from the Welcome screen up to —
/// and only up to — the "Create a PIN" screen.
///
/// It types rather than seeding storage directly, so the resulting state is
/// genuinely a user's: the seed phrase row, the account, the per-chain wallet
/// rows and the vault entry are all written by the app's own code paths.
///
/// The whole phrase goes into word field 1 in one `enterText`. That is not a
/// shortcut around the UI — `SeedPhraseGrid`'s `onChanged` detects a
/// multi-word value and fans it out through `onPhrasePasted`, which is the
/// same handler the paste button uses. Twelve separate field entries cost
/// roughly twelve extra seconds per file for no extra coverage.
///
/// Use this rather than [importTestWallet] when the case has to assert
/// something ON the PIN screen before it is dismissed.
///
/// Expects the app to be at the Welcome screen (call `restartApp(tester)`
/// first).
Future<void> importTestWalletToPinSetup(
  WidgetTester tester, {
  String phrase = kTestWalletMnemonic,
}) async {
  final haveWallet = find.text('I already have a wallet');
  await pumpUntil(tester, haveWallet, label: 'Welcome screen');
  await tapAndSettle(tester, haveWallet);

  final recoveryPhrase = find.text('Use a recovery phrase');
  await pumpUntil(tester, recoveryPhrase, label: 'Import-wallet menu');
  await tapAndSettle(tester, recoveryPhrase);

  final grid = find.byType(SeedPhraseGrid);
  await pumpUntil(tester, grid, label: 'Recovery-phrase entry screen');
  await enterTextInto(
    tester,
    find.descendant(of: grid, matching: find.byType(TextField)).first,
    phrase,
  );

  await tapAndSettle(tester, find.text('Continue'));
  await waitForPinSetup(tester);
}

/// Drives the REAL import UI with [phrase] all the way through the PIN steps,
/// and returns once Home is up AND the app lock is armed.
Future<void> importTestWallet(
  WidgetTester tester, {
  String phrase = kTestWalletMnemonic,
}) async {
  await importTestWalletToPinSetup(tester, phrase: phrase);
  await completePinSetup(tester);
  await waitForHome(tester);
}

/// One-liner from a cold app to a signed-in Home on the deterministic wallet.
///
/// ```dart
/// testWidgets('portfolio shows the funded fixture', (tester) async {
///   await MockControl.scenario('funded_wallet');
///   await completeOnboardingWithTestWallet(tester);
///   ...
/// });
/// ```
///
/// Wipes app state, relaunches, and imports. Use [importTestWallet] directly
/// when the case needs to assert something on the way through onboarding.
///
/// Returns on a Home frame with the app lock ARMED — `completePinSetup` waits
/// for both. A relaunch straight after this therefore really does land on the
/// lock screen, which it would not if the PIN write were still in flight.
Future<void> completeOnboardingWithTestWallet(
  WidgetTester tester, {
  String phrase = kTestWalletMnemonic,
}) async {
  await restartApp(tester);
  await importTestWallet(tester, phrase: phrase);
}
