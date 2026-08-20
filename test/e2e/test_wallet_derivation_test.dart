// Guard test for the E2E deterministic wallet's committed addresses.
//
// Runs in the ordinary `flutter test` suite, not on a device. It re-derives
// every constant in `integration_test/support/test_wallet.dart` from the
// committed phrase and fails if any of them moved.
//
// Why this exists: the derivation SCHEME is part of a wallet's identity. If a
// dependency bump or a refactor changes what `MultiChainDerivation` produces,
// the E2E suite would keep signing happily — with a valid signature from a
// DIFFERENT address — while every fixture still names the old one. That fails
// as "the owner CTA did not appear", ten files away from the cause. This test
// fails at the cause instead.
//
// If it goes red, do NOT edit the constants to match. Work out why the
// derivation changed first; then re-run
// `flutter test test/e2e/tools/derive_test_wallet.dart` and paste its output.

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/mnemonic_generator.dart';
import 'package:mallow_wallet/core/crypto/private_key_parser.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

import '../../integration_test/support/test_wallet.dart';

void main() {
  group('E2E test wallet', () {
    test('phrase is a valid 12-word BIP-39 mnemonic', () {
      expect(MnemonicGenerator.validate(kTestWalletMnemonic), isTrue);
      expect(MnemonicGenerator.getWordCount(kTestWalletMnemonic), 12);
    });

    test('phrase is not one a funded harness or unit test also uses', () {
      // `abandon ... about` is the zero-entropy vector every wallet tutorial
      // publishes and this repo's unit tests share; the shadownet harness
      // takes a FUNDED phrase from the environment. Neither may leak in here.
      expect(kTestWalletMnemonic, isNot(contains('abandon')));
      expect(kTestWalletMnemonic.split(' ').toSet().length, greaterThan(6));
    });

    test('Solana addresses match, per derivation scheme', () async {
      expect(
        await MultiChainDerivation.getSolanaAddressForScheme(
          kTestWalletMnemonic,
          0,
          SolanaDerivationScheme.standard,
        ),
        kTestWalletSolana,
      );
      expect(
        await MultiChainDerivation.getSolanaAddressForScheme(
          kTestWalletMnemonic,
          0,
          SolanaDerivationScheme.legacy,
        ),
        kTestWalletSolanaLegacy,
      );
      expect(
        await MultiChainDerivation.getSolanaAddressForScheme(
          kTestWalletMnemonic,
          0,
          SolanaDerivationScheme.root,
        ),
        kTestWalletSolanaRoot,
      );
    });

    test('the three schemes really do differ', () {
      // A refactor that collapsed the scheme switch would make every one of
      // the assertions above pass against the same string.
      expect({
        kTestWalletSolana,
        kTestWalletSolanaLegacy,
        kTestWalletSolanaRoot,
      }, hasLength(3));
    });

    test('EVM address matches in both the display and wire forms', () async {
      final derived = await MultiChainDerivation.getEthereumAddressAtIndex(
        kTestWalletMnemonic,
        0,
      );
      expect(derived, kTestWalletEvm, reason: 'EIP-55 checksummed form');
      // The backend matches EVM owners lowercase; a fixture templated with the
      // checksummed form returns zero NFTs and the case fails far downstream.
      expect(kTestWalletEvmLower, kTestWalletEvm.toLowerCase());
      expect(kTestWalletEvmLower, isNot(kTestWalletEvm));
    });

    test('Tezos tz1 address matches', () async {
      expect(
        await MultiChainDerivation.getTezosAddressAtIndex(
          kTestWalletMnemonic,
          0,
        ),
        kTestWalletTezos,
      );
    });
  });

  group('second E2E test wallet', () {
    test(
      'phrase is a valid 12-word BIP-39 mnemonic, and is a DIFFERENT one',
      () {
        expect(MnemonicGenerator.validate(kSecondTestWalletMnemonic), isTrue);
        expect(MnemonicGenerator.getWordCount(kSecondTestWalletMnemonic), 12);
        expect(kSecondTestWalletMnemonic, isNot(contains('abandon')));
        expect(kSecondTestWalletMnemonic, isNot(kTestWalletMnemonic));
      },
    );

    test(
      'addresses match, and none of them collide with the first wallet',
      () async {
        expect(
          await MultiChainDerivation.getSolanaAddressForScheme(
            kSecondTestWalletMnemonic,
            0,
            SolanaDerivationScheme.standard,
          ),
          kSecondTestWalletSolana,
        );
        expect(
          await MultiChainDerivation.getEthereumAddressAtIndex(
            kSecondTestWalletMnemonic,
            0,
          ),
          kSecondTestWalletEvm,
        );
        expect(
          await MultiChainDerivation.getTezosAddressAtIndex(
            kSecondTestWalletMnemonic,
            0,
          ),
          kSecondTestWalletTezos,
        );

        // The whole point of a second phrase: importing it must create NEW
        // wallet rows. An address collision would silently turn every
        // second-account case into a duplicate-rejection case.
        expect({
          kTestWalletSolana,
          kTestWalletEvm,
          kTestWalletTezos,
          kSecondTestWalletSolana,
          kSecondTestWalletEvm,
          kSecondTestWalletTezos,
        }, hasLength(6));
      },
    );
  });

  group('E2E throwaway private keys', () {
    test('each key parses to its committed chain and address', () async {
      final solana = await PrivateKeyParser.parse(kThrowawaySolanaKey);
      expect(solana.chain, Chain.solana);
      expect(solana.address, kThrowawaySolanaAddress);

      final evm = await PrivateKeyParser.parse(kThrowawayEvmKey);
      expect(evm.chain, Chain.ethereum);
      expect(evm.address, kThrowawayEvmAddress);
      expect(
        evm.address,
        isNot(evm.address.toLowerCase()),
        reason: 'the EVM address is stored EIP-55 checksummed',
      );

      final tezos = await PrivateKeyParser.parse(kThrowawayTezosKey);
      expect(tezos.chain, Chain.tezos);
      expect(tezos.address, kThrowawayTezosAddress);
    });

    test('no key re-derives an address either phrase already holds', () {
      // A key that landed on a phrase-derived address would trip the
      // duplicate-wallet guard, and every private-key import case would
      // quietly become a duplicate-rejection case instead.
      expect({
        kTestWalletSolana,
        kTestWalletEvm,
        kTestWalletTezos,
        kSecondTestWalletSolana,
        kSecondTestWalletEvm,
        kSecondTestWalletTezos,
        kThrowawaySolanaAddress,
        kThrowawayEvmAddress,
        kThrowawayTezosAddress,
      }, hasLength(9));
    });
  });
}
