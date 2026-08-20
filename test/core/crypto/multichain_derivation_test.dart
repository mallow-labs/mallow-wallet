import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/tezos_forge.dart' show hexToBytes;
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

/// Standard BIP-39 test vector.
const _abandon =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// 24-word mnemonic used by Kukai's published Tezos HD test vectors
/// (kukai-wallet/kukai-crypto-swift KeyPairTests). Lets us assert tz1 output
/// against an independent, production Tezos wallet implementation.
const _kukai =
    'gym exact clown can answer hope sample mirror knife twenty powder super '
    'imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';

/// RFC 8032 §7.1 TEST 1 Ed25519 secret seed — also fed in as the Tezos seed,
/// which is what Web3Auth's Tezos convention does with `getPrivKey()`.
const _seedHex =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';

/// The same vector's 64-byte keypair (seed ‖ public key) — the shape
/// `Web3AuthFlutter.getEd25519PrivKey()` returns.
const _ed25519KeyHex =
    '$_seedHex'
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';

/// secp256k1 key of the published Hardhat account #0, whose EIP-55 address is
/// widely quoted — an external check on the Ethereum derivation.
const _secp256k1Hex =
    'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const _solanaAddress = 'FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z';
const _solanaStoredKey =
    '49W385L4rePHy6PAaQUovbD2aacgN4HsKXSMeUzRg4fmwXszN91JuMFrQRj3vMDpZuRF3Zkn'
    'QBuRBoWQJEfXstMw';
const _ethereumAddress = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const _tezosAddress = 'tz1N7tYGMGs3GGjeJAJKtbycAWcvoPNSUYgu';

/// 28 bytes — neither a 32-byte key nor a 64-byte keypair.
const _wrongLengthHex =
    'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';

void main() {
  group('Ethereum derivation (secp256k1, EIP-55)', () {
    test(
      'abandon mnemonic index 0 matches the canonical MetaMask vector',
      () async {
        // Well-known vector for m/44'/60'/0'/0/0 of the abandon-about mnemonic.
        expect(
          await MultiChainDerivation.getEthereumAddressAtIndex(_abandon, 0),
          '0x9858EfFD232B4033E47d90003D41EC34EcaEda94',
        );
      },
    );

    test('abandon mnemonic index 1 matches the canonical vector', () async {
      // The batch derivation walks to m/44'/60'/0'/0 once and takes the last
      // step per index. Anchoring index 1 to a published vector proves that
      // reuse still lands on the same key an untouched full-path walk would —
      // a wrong address here would sign valid but for a different wallet.
      expect(
        await MultiChainDerivation.getEthereumAddressAtIndex(_abandon, 1),
        '0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0',
      );
    });

    test(
      'is deterministic and EIP-55 checksummed (mixed case, 0x, 42 chars)',
      () async {
        final a = await MultiChainDerivation.getEthereumAddressAtIndex(
          _abandon,
          1,
        );
        final b = await MultiChainDerivation.getEthereumAddressAtIndex(
          _abandon,
          1,
        );
        expect(a, b);
        expect(a, startsWith('0x'));
        expect(a.length, 42);
        // EIP-55 mixes case — a non-checksummed impl would be all-lowercase.
        expect(a.substring(2), isNot(equals(a.substring(2).toLowerCase())));
      },
    );

    test('distinct indices yield distinct addresses', () async {
      final a0 = await MultiChainDerivation.getEthereumAddressAtIndex(
        _abandon,
        0,
      );
      final a1 = await MultiChainDerivation.getEthereumAddressAtIndex(
        _abandon,
        1,
      );
      expect(a0, isNot(a1));
    });
  });

  group('Tezos derivation (Ed25519, tz1)', () {
    // Authoritative vectors from Kukai (production Tezos wallet), SLIP-0010
    // ed25519 at 44'/1729'/i'/0'. Proves our algorithm matches a real wallet.
    test('Kukai vector index 0', () async {
      expect(
        await MultiChainDerivation.getTezosAddressAtIndex(_kukai, 0),
        'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL',
      );
    });

    test('Kukai vector index 1', () async {
      expect(
        await MultiChainDerivation.getTezosAddressAtIndex(_kukai, 1),
        'tz1WCBJKr1rRivyCnN9hREpRAMqrLdmqDcym',
      );
    });

    test('produces a well-formed tz1 address for any mnemonic', () async {
      final addr = await MultiChainDerivation.getTezosAddressAtIndex(
        _abandon,
        0,
      );
      expect(addr, startsWith('tz1'));
      expect(addr.length, 36);
    });
  });

  group('Solana derivation schemes', () {
    test('standard / legacy / root produce three distinct addresses', () async {
      final standard = await MultiChainDerivation.getSolanaAddressForScheme(
        _abandon,
        0,
        SolanaDerivationScheme.standard,
      );
      final legacy = await MultiChainDerivation.getSolanaAddressForScheme(
        _abandon,
        0,
        SolanaDerivationScheme.legacy,
      );
      final root = await MultiChainDerivation.getSolanaAddressForScheme(
        _abandon,
        0,
        SolanaDerivationScheme.root,
      );
      expect({standard, legacy, root}, hasLength(3));
    });

    test('standard scheme matches the existing index-0 derivation', () async {
      expect(
        await MultiChainDerivation.getSolanaAddressForScheme(
          _abandon,
          0,
          SolanaDerivationScheme.standard,
        ),
        await MultiChainDerivation.getSolanaAddressAtIndex(_abandon, 0),
      );
    });

    test('root path is index-independent', () async {
      final r0 = await MultiChainDerivation.getSolanaAddressForScheme(
        _abandon,
        0,
        SolanaDerivationScheme.root,
      );
      final r5 = await MultiChainDerivation.getSolanaAddressForScheme(
        _abandon,
        5,
        SolanaDerivationScheme.root,
      );
      expect(r0, r5);
    });
  });

  group('Multi-chain batch discovery', () {
    test(
      'returns all chains per index, consistent with single-index getters',
      () async {
        final batch =
            await MultiChainDerivation.getMultiChainAddressesAtIndices(
              _abandon,
              [0, 1],
            );
        expect(batch.map((e) => e.index), [0, 1]);

        final eth0 = await MultiChainDerivation.getEthereumAddressAtIndex(
          _abandon,
          0,
        );
        final tez0 = await MultiChainDerivation.getTezosAddressAtIndex(
          _abandon,
          0,
        );
        final sol0 = await MultiChainDerivation.getSolanaAddressAtIndex(
          _abandon,
          0,
        );
        expect(batch[0].ethereum, eth0);
        expect(batch[0].tezos, tez0);
        expect(batch[0].solanaStandard, sol0);
        // Legacy paths omitted by default.
        expect(batch[0].solanaLegacy, isNull);
        expect(batch[0].solanaRoot, isNull);
      },
    );

    test('skips a chain the caller switched off, and only that chain', () async {
      Future<List<AccountAddresses>> derive({
        bool eth = true,
        bool tezos = true,
      }) => MultiChainDerivation.getMultiChainAddressesAtIndices(
        _abandon,
        [0, 1],
        deriveEthereum: eth,
        deriveTezos: tezos,
      );

      // The picker sets the two flags independently per chain, so one-off-one-
      // on is the common real combination — turning both off cannot show that a
      // flag skips only its own chain.
      final full = await derive();
      final noEth = await derive(eth: false);
      final noTezos = await derive(tezos: false);
      final solanaOnly = await derive(eth: false, tezos: false);

      // A switched-off chain comes back absent, not empty — nothing derived it,
      // so no address can leak into an import selection.
      expect(noEth.map((e) => e.ethereum), everyElement(isNull));
      expect(noTezos.map((e) => e.tezos), everyElement(isNull));
      expect(solanaOnly.map((e) => e.ethereum), everyElement(isNull));
      expect(solanaOnly.map((e) => e.tezos), everyElement(isNull));

      // The flags are a cost switch, not a derivation-path change: every chain
      // left on must land on exactly the addresses a full batch produces.
      expect(noEth.map((e) => e.tezos), full.map((e) => e.tezos));
      expect(noTezos.map((e) => e.ethereum), full.map((e) => e.ethereum));
      for (final batch in [noEth, noTezos, solanaOnly]) {
        expect(
          batch.map((e) => e.solanaStandard),
          full.map((e) => e.solanaStandard),
        );
      }
    });

    test(
      'includeLegacyPaths adds legacy per index and root on index 0 only',
      () async {
        final batch =
            await MultiChainDerivation.getMultiChainAddressesAtIndices(
              _abandon,
              [0, 1],
              includeLegacyPaths: true,
            );
        expect(batch[0].solanaLegacy, isNotNull);
        expect(batch[1].solanaLegacy, isNotNull);
        expect(batch[0].solanaRoot, isNotNull); // index 0 carries root
        expect(batch[1].solanaRoot, isNull); // index 1 does not
      },
    );
  });

  group('Social (Web3Auth) key material', () {
    test('Solana address is the trailing public half of the keypair hex', () {
      expect(
        MultiChainDerivation.solanaAddressFromEd25519KeyHex(_ed25519KeyHex),
        _solanaAddress,
      );
    });

    test(
      'Solana address equals the keypair built from the leading seed half',
      () async {
        // The seed-vs-pubkey byte order is the one mistake that yields a valid
        // signature from the *wrong* address, so pin it against the primitive
        // the imported-key sign path uses (`_loadImportedSolanaSecretKey` →
        // `Ed25519HDKeyPair.fromPrivateKeyBytes`).
        final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: MultiChainDerivation.privateKeyBytesFromHex(_seedHex),
        );
        expect(
          MultiChainDerivation.solanaAddressFromEd25519KeyHex(_ed25519KeyHex),
          keypair.address,
        );
      },
    );

    test('Solana stored key is base58 of all 64 bytes', () {
      expect(
        MultiChainDerivation.solanaStoredKeyFromEd25519KeyHex(_ed25519KeyHex),
        _solanaStoredKey,
      );
    });

    test(
      'Solana stored key round-trips through the imported-key loader decode',
      () async {
        final stored = MultiChainDerivation.solanaStoredKeyFromEd25519KeyHex(
          _ed25519KeyHex,
        );
        // Byte-for-byte what `WalletManager._loadImportedSolanaSecretKey` does.
        final secret = base58decode(stored).sublist(0, 32);
        expect(secret, MultiChainDerivation.privateKeyBytesFromHex(_seedHex));

        final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: secret,
        );
        expect(keypair.address, _solanaAddress);
      },
    );

    test('Ethereum address matches the published secp256k1 vector', () {
      expect(
        MultiChainDerivation.ethereumAddressFromPrivateKeyHex(_secp256k1Hex),
        _ethereumAddress,
      );
    });

    test('Ethereum address matches the raw-bytes imported-key helper', () {
      expect(
        MultiChainDerivation.ethereumAddressFromPrivateKeyHex(_secp256k1Hex),
        MultiChainDerivation.ethereumAddressFromPrivateKey(
          MultiChainDerivation.privateKeyBytesFromHex(_secp256k1Hex),
        ),
      );
    });

    test('tz1 address for a hex Ed25519 seed', () async {
      expect(
        await MultiChainDerivation.tezosAddressFromSeedHex(_seedHex),
        _tezosAddress,
      );
    });

    test('the seed stored for that tz1 address signs for it', () async {
      // A Tezos row stores this seed and signs with
      // `signTezosOperationWithSeed`. If that path built a different keypair,
      // the operation would carry a valid signature for another account and be
      // rejected on injection — so verify the produced signature against the
      // public key the address is derived from.
      final address = await MultiChainDerivation.tezosAddressFromSeedHex(
        _seedHex,
      );
      final seed = MultiChainDerivation.privateKeyBytesFromHex(_seedHex);
      final edpk = await MultiChainDerivation.tezosPublicKeyFromSeed(seed);
      final publicKey = Uint8List.fromList(
        _base58CheckPayload(edpk, 4), // strip the edpk prefix
      );
      expect(
        MultiChainDerivation.tezosAddressFromPublicKey(publicKey),
        address,
      );

      const forgedHex = 'deadbeef';
      final signed = await MultiChainDerivation.signTezosOperationWithSeed(
        seed,
        forgedHex,
      );
      // Re-verify as a node does: Blake2b-256 over 0x03 ++ forged bytes.
      final forgedBytes = hexToBytes(forgedHex);
      final watermarked = Uint8List(forgedBytes.length + 1)
        ..[0] = 0x03
        ..setRange(1, forgedBytes.length + 1, forgedBytes);
      final digest = Blake2bDigest(digestSize: 32);
      digest.update(watermarked, 0, watermarked.length);
      final hash = Uint8List(32);
      digest.doFinal(hash, 0);

      final ok = await verifySignature(
        message: hash,
        signature: _base58CheckPayload(signed.signature, 5), // edsig prefix
        publicKey: Ed25519HDPublicKey(publicKey),
      );
      expect(ok, isTrue);
    });

    test('a 0x prefix and upper-case hex decode identically', () async {
      expect(
        MultiChainDerivation.solanaAddressFromEd25519KeyHex(
          '0x${_ed25519KeyHex.toUpperCase()}',
        ),
        _solanaAddress,
      );
      expect(
        MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
          '0x$_secp256k1Hex',
        ),
        _ethereumAddress,
      );
      expect(
        await MultiChainDerivation.tezosAddressFromSeedHex('0x$_seedHex'),
        _tezosAddress,
      );
    });

    test('wrong-length input throws instead of deriving a stray key', () {
      // A 32-byte value where a 64-byte keypair is required (and vice versa)
      // would otherwise sublist into garbage or mis-encode the stored key.
      expect(
        () => MultiChainDerivation.solanaAddressFromEd25519KeyHex(_seedHex),
        throwsArgumentError,
      );
      expect(
        () => MultiChainDerivation.solanaStoredKeyFromEd25519KeyHex(_seedHex),
        throwsArgumentError,
      );
      expect(
        () => MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
          _ed25519KeyHex,
        ),
        throwsArgumentError,
      );
      expect(
        () => MultiChainDerivation.tezosAddressFromSeedHex(_ed25519KeyHex),
        throwsArgumentError,
      );
    });

    test('non-hex input throws', () {
      expect(
        () => MultiChainDerivation.ethereumAddressFromPrivateKeyHex('z' * 64),
        throwsArgumentError,
      );
    });

    test('the thrown error carries no key material', () {
      expect(
        () => MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
          _wrongLengthHex,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(_wrongLengthHex)),
          ),
        ),
      );
    });
  });
}

/// Strip the [prefixLength]-byte Tezos prefix and the 4-byte Base58Check
/// checksum from a Base58Check string, returning the payload.
List<int> _base58CheckPayload(String encoded, int prefixLength) {
  final raw = base58decode(encoded);
  return raw.sublist(prefixLength, raw.length - 4);
}
