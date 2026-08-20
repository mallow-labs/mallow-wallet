import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/private_key_parser.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

/// Build a deterministic 64-byte ed25519 keypair (seed → secret+public) using
/// the `solana` package, then expose it in the three formats accepted by
/// [PrivateKeyParser]. Keeping this in one place ensures every format under
/// test maps to the same expected Solana address — if any encoding path
/// drifts we catch it.
class _TestKeypair {
  _TestKeypair._(this.keyBytes, this.address);

  final Uint8List keyBytes; // 64 bytes: secret(32) || public(32)
  final String address;

  static Future<_TestKeypair> generate(int seedByte) async {
    // Construct a deterministic 32-byte seed (avoids randomness in tests).
    final seed = Uint8List(32)..fillRange(0, 32, seedByte);
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: seed,
    );
    final pub = await keypair.extractPublicKey();
    final bytes = Uint8List(64)
      ..setRange(0, 32, seed)
      ..setRange(32, 64, pub.bytes);
    return _TestKeypair._(bytes, keypair.address);
  }

  String get base58 => base58encode(keyBytes);

  String get hex =>
      keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get jsonArray => jsonEncode(keyBytes.toList());
}

void main() {
  group('PrivateKeyParser.parse — happy path formats', () {
    late _TestKeypair kp;

    setUpAll(() async {
      kp = await _TestKeypair.generate(0x42);
    });

    test('accepts base58-encoded 64-byte keypair', () async {
      final result = await PrivateKeyParser.parse(kp.base58);
      expect(result.chain, Chain.solana);
      expect(result.address, kp.address);
      expect(result.storedKey, kp.base58);
    });

    test('accepts hex-encoded 64-byte keypair (lowercase)', () async {
      final result = await PrivateKeyParser.parse(kp.hex);
      expect(result.address, kp.address);
      // Normalization always re-emits as base58.
      expect(result.storedKey, kp.base58);
    });

    test('accepts hex-encoded 64-byte keypair (mixed case)', () async {
      final mixed = kp.hex
          .split('')
          .asMap()
          .entries
          .map((e) => e.key.isEven ? e.value.toUpperCase() : e.value)
          .join();
      final result = await PrivateKeyParser.parse(mixed);
      expect(result.address, kp.address);
    });

    test('accepts JSON byte array (Solana CLI export format)', () async {
      final result = await PrivateKeyParser.parse(kp.jsonArray);
      expect(result.address, kp.address);
    });

    test('accepts JSON byte array with whitespace inside brackets', () async {
      final spaced = '[ ${kp.keyBytes.join(' , ')} ]';
      final result = await PrivateKeyParser.parse(spaced);
      expect(result.address, kp.address);
    });

    test('strips leading/trailing whitespace before parsing', () async {
      final padded = '  \n\t${kp.base58}\n  ';
      final result = await PrivateKeyParser.parse(padded);
      expect(result.address, kp.address);
    });

    test('different seeds produce different addresses', () async {
      final other = await _TestKeypair.generate(0x07);
      final a = await PrivateKeyParser.parse(kp.base58);
      final b = await PrivateKeyParser.parse(other.base58);
      expect(a.address, isNot(b.address));
    });
  });

  group('PrivateKeyParser.parse — rejection cases', () {
    test('throws on empty input', () async {
      expect(
        () => PrivateKeyParser.parse(''),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on whitespace-only input', () async {
      expect(
        () => PrivateKeyParser.parse('   \n\t  '),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on JSON array of wrong length', () async {
      // 32 bytes — could be a raw secret key, not the 64-byte format we want.
      final wrong = jsonEncode(List<int>.filled(32, 0));
      expect(
        () => PrivateKeyParser.parse(wrong),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on all-zero 64-hex (invalid Ethereum scalar)', () async {
      // 64 hex chars is now read as an Ethereum key; the zero scalar is out of
      // range and must be rejected rather than producing a dead wallet.
      final wrong = '00' * 32;
      expect(
        () => PrivateKeyParser.parse(wrong),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on non-hex chars at full length', () async {
      // 128 chars but contains 'g' — must not be misclassified as hex.
      final almost = '${'a' * 127}g';
      expect(
        () => PrivateKeyParser.parse(almost),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on garbage / unrecognizable input', () async {
      expect(
        () => PrivateKeyParser.parse('hello world this is not a key'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on JSON with non-numeric entries', () async {
      expect(
        () => PrivateKeyParser.parse('["a","b","c"]'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('throws on bracketed-but-malformed JSON', () async {
      expect(
        () => PrivateKeyParser.parse('[1, 2, 3, ,]'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('rejects base58 string that decodes to wrong byte length', () async {
      // "Hello" decodes to 5 bytes — wrong length for a keypair.
      expect(
        () => PrivateKeyParser.parse('9Ajdvzr'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });
  });

  group('PrivateKeyParser.parse — secret/public consistency', () {
    test(
      'rejects 64-byte keypair where trailing pubkey does not match secret',
      () async {
        // Build a real keypair, then swap in a foreign public key in the
        // trailing 32 bytes. Without verification the parser would report
        // address B while the signer (which uses the first 32 bytes) would
        // sign for address A — silent fund-loss vector.
        final real = await _TestKeypair.generate(0x11);
        final foreign = await _TestKeypair.generate(0x22);
        final tampered = Uint8List(64)
          ..setRange(0, 32, real.keyBytes.sublist(0, 32))
          ..setRange(32, 64, foreign.keyBytes.sublist(32, 64));

        expect(
          () => PrivateKeyParser.parse(base58encode(tampered)),
          throwsA(isA<InvalidPrivateKeyException>()),
        );
      },
    );

    test(
      'reported address matches what the secret bytes actually sign for',
      () async {
        // Defense-in-depth: even on the happy path, the parser must report the
        // address derived from the FIRST 32 bytes (what the wallet will sign
        // with), not blindly trust the trailing bytes.
        final kp = await _TestKeypair.generate(0x33);
        final result = await PrivateKeyParser.parse(kp.base58);
        final signer = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: kp.keyBytes.sublist(0, 32),
        );
        expect(result.address, signer.address);
      },
    );
  });

  group('PrivateKeyParser.parse — Ethereum (secp256k1)', () {
    // Canonical secp256k1 test vector: the private key `1` maps to the
    // generator-point address. If EIP-55 derivation drifts, this breaks.
    const privOne =
        '0000000000000000000000000000000000000000000000000000000000000001';
    const addrOne = '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf';

    test('parses a 0x-prefixed 32-byte key to its EIP-55 address', () async {
      final result = await PrivateKeyParser.parse('0x$privOne');
      expect(result.chain, Chain.ethereum);
      expect(result.address.toLowerCase(), addrOne);
      // Stored as bare lowercase hex (no 0x) so the signer reads it back raw.
      expect(result.storedKey, privOne);
    });

    test('returns an EIP-55 checksummed (mixed-case) address', () async {
      final result = await PrivateKeyParser.parse('0x$privOne');
      // EIP-55 mixes case; a wallet that displays all-lowercase would be wrong.
      expect(result.address, isNot(result.address.toLowerCase()));
    });

    test('accepts the same key without the 0x prefix', () async {
      final withPrefix = await PrivateKeyParser.parse('0x$privOne');
      final bare = await PrivateKeyParser.parse(privOne);
      expect(bare.chain, Chain.ethereum);
      expect(bare.address, withPrefix.address);
    });

    test('rejects an out-of-range (all-zero) key', () async {
      expect(
        () => PrivateKeyParser.parse('0x${'00' * 32}'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });
  });

  group('PrivateKeyParser.parse — Tezos (Ed25519 edsk)', () {
    // Base58Check version prefixes for the two edsk variants.
    const seedPrefix = [13, 15, 58, 7]; // edsk, 54 chars (32-byte seed)
    const secretKeyPrefix = [43, 246, 78, 7]; // edsk, 98 chars (64-byte key)

    String b58check(List<int> prefix, List<int> payload) {
      final data = <int>[...prefix, ...payload];
      final checksum = sha256
          .convert(sha256.convert(data).bytes)
          .bytes
          .sublist(0, 4);
      return base58encode(Uint8List.fromList([...data, ...checksum]));
    }

    late Uint8List seed;
    late Uint8List publicKey;
    late String expectedAddress;

    setUpAll(() async {
      seed = Uint8List(32)..fillRange(0, 32, 0x5a);
      final kp = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: seed);
      publicKey = Uint8List.fromList(kp.publicKey.bytes);
      expectedAddress = await MultiChainDerivation.tezosAddressFromSeed(seed);
    });

    test('the 32-byte seed form encodes to a 54-char edsk string', () {
      final edsk = b58check(seedPrefix, seed);
      // Confirms our prefix bytes produce the canonical human-readable prefix.
      expect(edsk, startsWith('edsk'));
      expect(edsk.length, 54);
    });

    test('parses a 54-char edsk seed to its tz1 address', () async {
      final edsk = b58check(seedPrefix, seed);
      final result = await PrivateKeyParser.parse(edsk);
      expect(result.chain, Chain.tezos);
      expect(result.address, startsWith('tz1'));
      expect(result.address, expectedAddress);
      // Stored as the bare 32-byte seed hex.
      final hex = seed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(result.storedKey, hex);
    });

    test('parses a 98-char expanded edsk to the same address', () async {
      final edsk = b58check(secretKeyPrefix, [...seed, ...publicKey]);
      expect(edsk, startsWith('edsk'));
      expect(edsk.length, 98);
      final result = await PrivateKeyParser.parse(edsk);
      expect(result.chain, Chain.tezos);
      expect(result.address, expectedAddress);
    });

    test('rejects an expanded edsk whose embedded pubkey is wrong', () async {
      final foreign = Uint8List(32)..fillRange(0, 32, 0x99);
      final edsk = b58check(secretKeyPrefix, [...seed, ...foreign]);
      expect(
        () => PrivateKeyParser.parse(edsk),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('rejects an edsk with a corrupted checksum', () async {
      final edsk = b58check(seedPrefix, seed);
      // Flip the last character to a different valid base58 char.
      final last = edsk[edsk.length - 1];
      final swapped = last == 'A' ? 'B' : 'A';
      final corrupted = edsk.substring(0, edsk.length - 1) + swapped;
      expect(
        () => PrivateKeyParser.parse(corrupted),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });

    test('rejects non-Ed25519 Tezos keys (spsk / p2sk)', () async {
      expect(
        () => PrivateKeyParser.parse('spsk${'1' * 50}'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
      expect(
        () => PrivateKeyParser.parse('p2sk${'1' * 50}'),
        throwsA(isA<InvalidPrivateKeyException>()),
      );
    });
  });
}
