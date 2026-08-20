import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/pin_hasher.dart';

void main() {
  // Real Argon2id (64 MiB, 3 iter) is too slow to spam, so we run the KDF
  // inline (no isolate) with a deterministic RNG. That keeps the same PIN/salt
  // pair reproducible while still exercising the genuine hash, so we can assert
  // that:
  //   - the stored value reveals only base64 of salt+hash, never the PIN
  //   - verify() is true for matches and false for everything else
  //   - parsing rejects tampered values without throwing
  final hasher = PinHasher.withRandom(Random(42));

  group('PinHasher.hash', () {
    test('stored value never contains the plaintext PIN digits', () async {
      const pin = '195371';
      final encoded = await hasher.hash(pin);
      expect(encoded.contains(pin), isFalse);
      // Must be the documented v1$salt$hash format so callers/migrations can
      // recognize it.
      expect(encoded.startsWith('v1\$'), isTrue);
      expect(encoded.split('\$').length, 3);
    });

    test('hash output differs across PINs (salt + KDF working)', () async {
      final a = await hasher.hash('1234');
      final b = await hasher.hash('1235');
      expect(a, isNot(equals(b)));
    });
  });

  group('PinHasher.verify', () {
    late String encoded;
    setUpAll(() async {
      encoded = await hasher.hash('246810');
    });

    test('true for the exact PIN', () async {
      expect(await hasher.verify('246810', encoded), isTrue);
    });

    test('false for any wrong PIN', () async {
      expect(await hasher.verify('246811', encoded), isFalse);
      expect(await hasher.verify('', encoded), isFalse);
      expect(await hasher.verify('24681', encoded), isFalse); // prefix
      expect(await hasher.verify('2468100', encoded), isFalse); // suffix
    });

    test('rejects malformed encoded values without throwing', () async {
      // A bypass via a corrupted/empty stored hash would be game over, so
      // verify must return false rather than throw or short-circuit.
      expect(await hasher.verify('1234', ''), isFalse);
      expect(await hasher.verify('1234', 'not-a-hash'), isFalse);
      expect(await hasher.verify('1234', 'v1\$bad\$bad'), isFalse);
      expect(await hasher.verify('1234', 'v2\$AAAA\$BBBB'), isFalse);
    });
  });

  group('PinHasher.isEncoded', () {
    test('distinguishes new format from legacy plaintext', () {
      expect(PinHasher.isEncoded('v1\$abc\$def'), isTrue);
      expect(PinHasher.isEncoded('1234'), isFalse);
      expect(PinHasher.isEncoded(''), isFalse);
    });
  });
}
