import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_crypto.dart';
import 'package:mallow_wallet/core/social_vault/social_wallet_keys.dart';
import 'package:solana/base58.dart' as base58;
import 'package:solana/solana.dart' show Ed25519HDKeyPair;

/// The keys a vault yields must sign for exactly the addresses the shared
/// vectors pin, in the storage formats the imported-key signing paths read.
void main() {
  final derivation =
      (jsonDecode(
                File(
                  'test/assets/social_vault_vectors.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['derivation']
          as Map<String, dynamic>;

  test('a bip39 vault yields the vector addresses and storable keys', () async {
    final v = derivation['bip39'] as Map<String, dynamic>;
    final keys = await SocialWalletKeys.fromPayload(
      SocialVaultPayload(v['mnemonic'] as String),
    );
    expect(keys.solanaAddress, v['solana']);
    expect(keys.ethereumAddress, v['ethereum']);
    expect(keys.tezosAddress, v['tezos']);

    // Solana: base58 of seed ‖ public key, whose seed signs for the address —
    // the shape `_loadImportedSolanaSecretKey` reads.
    final keypair = base58.base58decode(keys.solanaStoredKey);
    expect(keypair, hasLength(64));
    final rebuilt = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: keypair.sublist(0, 32),
    );
    expect(rebuilt.address, v['solana']);

    // Ethereum: the raw key hex the imported-key path decodes.
    expect(
      MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
        keys.ethereumKeyHex,
      ),
      v['ethereum'],
    );
    // Tezos: the raw Ed25519 seed hex the imported-key path reads.
    expect(
      await MultiChainDerivation.tezosAddressFromSeedHex(keys.tezosSeedHex),
      v['tezos'],
    );
  });

  // Reading and writing spell a phrase the same way. BIP39 hashes the text,
  // so a phrase read with its stray white space would be another wallet —
  // or, as it was, no phrase at all.
  test('a payload sealed with stray white space and capitals opens to the '
      'same wallet', () async {
    final vectors =
        ((jsonDecode(
                      File(
                        'test/assets/social_vault_vectors.json',
                      ).readAsStringSync(),
                    )
                    as Map<String, dynamic>)['nonCanonicalPayload']
                as List)
            .cast<Map<String, dynamic>>();
    expect(vectors, isNotEmpty);
    for (final v in vectors) {
      final opened = await SocialVaultCrypto.openPayload(
        vaultId: v['vaultId'] as String,
        dataKey: [
          for (var i = 0; i < (v['dataKeyHex'] as String).length; i += 2)
            int.parse(
              (v['dataKeyHex'] as String).substring(i, i + 2),
              radix: 16,
            ),
        ],
        sealed: SocialVaultSealed.fromWire(
          nonce: v['nonce'] as String,
          ciphertext: v['ciphertext'] as String,
        ),
      );
      final keys = await SocialWalletKeys.fromPayload(opened);
      expect(keys.solanaAddress, v['solana']);
      expect(keys.ethereumAddress, v['ethereum']);
      expect(keys.tezosAddress, v['tezos']);

      // A payload built in memory, never read from JSON, goes through the
      // same normaliser when its keys are derived.
      final raw =
          (jsonDecode(v['payloadJson'] as String)
                  as Map<String, dynamic>)['mnemonic']
              as String;
      final direct = await SocialWalletKeys.fromPayload(
        SocialVaultPayload(raw),
      );
      expect(direct.solanaAddress, v['solana']);
      expect(direct.ethereumAddress, v['ethereum']);
      expect(direct.tezosAddress, v['tezos']);
    }
  });

  test('Ethereum and Tezos are derived on their own paths', () async {
    // A phrase wallet never shares one key between the two chains.
    final v = derivation['bip39'] as Map<String, dynamic>;
    final keys = await SocialWalletKeys.fromPayload(
      SocialVaultPayload(v['mnemonic'] as String),
    );
    expect(keys.tezosSeedHex, isNot(keys.ethereumKeyHex));
  });

  test('a payload that is not a recovery phrase yields no keys', () async {
    await expectLater(
      SocialWalletKeys.fromPayload(const SocialVaultPayload('not a phrase')),
      throwsA(isA<SocialVaultCryptoException>()),
    );
  });

  test('matches compares Ethereum case-insensitively only', () async {
    final v = derivation['bip39'] as Map<String, dynamic>;
    final keys = await SocialWalletKeys.fromPayload(
      SocialVaultPayload(v['mnemonic'] as String),
    );
    expect(
      keys.matches(
        solana: v['solana'] as String,
        ethereum: (v['ethereum'] as String).toLowerCase(),
        tezos: v['tezos'] as String,
      ),
      isTrue,
    );
    expect(
      keys.matches(
        solana: (v['solana'] as String).toLowerCase(),
        ethereum: null,
        tezos: null,
      ),
      isFalse,
    );
  });

  test('toString never prints a key', () async {
    final v = derivation['bip39'] as Map<String, dynamic>;
    final keys = await SocialWalletKeys.fromPayload(
      SocialVaultPayload(v['mnemonic'] as String),
    );
    final printed = keys.toString();
    expect(printed, isNot(contains(keys.solanaStoredKey)));
    expect(printed, isNot(contains(keys.ethereumKeyHex)));
    expect(printed, isNot(contains(keys.tezosSeedHex)));
  });

  group('canonical payload', () {
    test('normalizes phrase case and whitespace before sealing', () {
      final b = derivation['bip39'] as Map<String, dynamic>;
      final phrase = b['mnemonic'] as String;
      final messy = '  ${phrase.toUpperCase().replaceAll(' ', '   ')} ';
      expect(
        SocialVaultCrypto.canonicalPayloadJson(SocialVaultPayload(messy)),
        SocialVaultPayload(phrase).toJsonString(),
      );
    });

    test('refuses a payload no other client could parse', () {
      expect(
        () => SocialVaultCrypto.canonicalPayloadJson(
          const SocialVaultPayload('not a real recovery phrase'),
        ),
        throwsA(isA<SocialVaultCryptoException>()),
      );
    });
  });
}
