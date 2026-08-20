// Offline derivation tool for the E2E deterministic test wallet.
//
// This is NOT a test. It has no `_test.dart` suffix on purpose, so the
// default `flutter test` glob (`test/**_test.dart`) skips it and it never
// runs in CI. Run it by hand only:
//
//   flutter test test/e2e/tools/derive_test_wallet.dart
//
// It prints the addresses the app's own `MultiChainDerivation` produces for
// `kTestWalletMnemonic`. Copy the printed block into
// `integration_test/support/test_wallet.dart` — never hand-write an address.
// `test/e2e/test_wallet_derivation_test.dart` re-derives the same values on
// every `flutter test` run and fails if the committed constants drift.
//
// To mint a brand-new throwaway phrase instead of deriving the committed one,
// pass MINT=1:
//
//   MINT=1 flutter test test/e2e/tools/derive_test_wallet.dart
//
// A minted phrase must never be funded. See the security note in
// `integration_test/support/test_wallet.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/mnemonic_generator.dart';
import 'package:mallow_wallet/core/crypto/private_key_parser.dart';

import '../../../integration_test/support/test_wallet.dart';

void main() {
  test('derive E2E test-wallet addresses', () async {
    final mint = Platform.environment['MINT'] == '1';
    final mnemonic = mint
        ? MnemonicGenerator.generate12Words()
        : kTestWalletMnemonic;

    final solStandard = await MultiChainDerivation.getSolanaAddressForScheme(
      mnemonic,
      0,
      SolanaDerivationScheme.standard,
    );
    final solLegacy = await MultiChainDerivation.getSolanaAddressForScheme(
      mnemonic,
      0,
      SolanaDerivationScheme.legacy,
    );
    final solRoot = await MultiChainDerivation.getSolanaAddressForScheme(
      mnemonic,
      0,
      SolanaDerivationScheme.root,
    );
    final eth = await MultiChainDerivation.getEthereumAddressAtIndex(
      mnemonic,
      0,
    );
    final tz1 = await MultiChainDerivation.getTezosAddressAtIndex(mnemonic, 0);

    // ignore: avoid_print — this file is a hand-run tool, not a test.
    print('''

--- paste into integration_test/support/test_wallet.dart ---
const String kTestWalletMnemonic =
    '$mnemonic';
const String kTestWalletSolana = '$solStandard';
const String kTestWalletSolanaLegacy = '$solLegacy';
const String kTestWalletSolanaRoot = '$solRoot';
const String kTestWalletEvm = '$eth';
const String kTestWalletEvmLower = '${eth.toLowerCase()}';
const String kTestWalletTezos = '$tz1';
-----------------------------------------------------------
''');
  });

  // The SECOND phrase, used by cases that need a wallet the device does not
  // already hold (importing another account, switching between two).
  test('derive the second E2E test-wallet addresses', () async {
    final mint = Platform.environment['MINT'] == '1';
    final mnemonic = mint
        ? MnemonicGenerator.generate12Words()
        : kSecondTestWalletMnemonic;

    final sol = await MultiChainDerivation.getSolanaAddressForScheme(
      mnemonic,
      0,
      SolanaDerivationScheme.standard,
    );
    final eth = await MultiChainDerivation.getEthereumAddressAtIndex(
      mnemonic,
      0,
    );
    final tz1 = await MultiChainDerivation.getTezosAddressAtIndex(mnemonic, 0);

    // ignore: avoid_print — this file is a hand-run tool, not a test.
    print('''

--- paste into integration_test/support/test_wallet.dart ---
const String kSecondTestWalletMnemonic =
    '$mnemonic';
const String kSecondTestWalletSolana = '$sol';
const String kSecondTestWalletEvm = '$eth';
const String kSecondTestWalletTezos = '$tz1';
-----------------------------------------------------------
''');
  });

  // The throwaway private keys. Their addresses are what `PrivateKeyParser`
  // returns, never a hand-written string — the parser is the only thing that
  // decides which chain a key belongs to and how its address is encoded.
  test('parse the E2E throwaway private keys', () async {
    final solana = await PrivateKeyParser.parse(kThrowawaySolanaKey);
    final evm = await PrivateKeyParser.parse(kThrowawayEvmKey);
    final tezos = await PrivateKeyParser.parse(kThrowawayTezosKey);

    // ignore: avoid_print — this file is a hand-run tool, not a test.
    print('''

--- paste into integration_test/support/test_wallet.dart ---
const String kThrowawaySolanaAddress = '${solana.address}';
const String kThrowawayEvmAddress = '${evm.address}';
const String kThrowawayTezosAddress = '${tezos.address}';
-----------------------------------------------------------
''');
  });
}
