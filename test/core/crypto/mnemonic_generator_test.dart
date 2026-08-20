import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/mnemonic_generator.dart';

void main() {
  // BIP39 official test vector (Trezor):
  //   https://github.com/trezor/python-mnemonic/blob/master/vectors.json
  // Entropy 0x00...00 → "abandon abandon abandon abandon abandon abandon
  //   abandon abandon abandon abandon abandon about". The published vector
  //   ships the seed for passphrase="TREZOR"; the empty-passphrase seed is
  //   the canonical PBKDF2 output for the same mnemonic.
  const abandonMnemonic =
      'abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon abandon abandon about';
  // PBKDF2(mnemonic, salt="mnemonic") — empty BIP39 passphrase.
  const abandonSeedHex =
      '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a'
      '5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4';
  // Published BIP39 vector with passphrase "TREZOR".
  const abandonSeedWithPassphraseHex =
      'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f'
      '09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04';

  group('MnemonicGenerator.generate12Words', () {
    test('produces a valid 12-word mnemonic', () {
      final m = MnemonicGenerator.generate12Words();
      expect(MnemonicGenerator.getWordCount(m), 12);
      expect(bip39.validateMnemonic(m), isTrue);
    });

    test('produces fresh entropy each call', () {
      final a = MnemonicGenerator.generate12Words();
      final b = MnemonicGenerator.generate12Words();
      // Astronomically unlikely to collide; if it does, the RNG is broken.
      expect(a, isNot(b));
    });
  });

  group('MnemonicGenerator.generate24Words', () {
    test('produces a valid 24-word mnemonic', () {
      final m = MnemonicGenerator.generate24Words();
      expect(MnemonicGenerator.getWordCount(m), 24);
      expect(bip39.validateMnemonic(m), isTrue);
    });
  });

  group('generated entropy spans the full byte range', () {
    // bip39 1.0.6's built-in entropy source calls `nextInt(255)`, which is
    // exclusive of its bound and therefore CANNOT emit 0xFF — every phrase it
    // produces is drawn from a biased 255-value alphabet worth 7.99435 bits
    // per byte instead of 8. MnemonicGenerator injects its own `randomBytes`
    // to close that. These tests fail deterministically if the injection is
    // ever dropped from a call site, since 0xFF would become unreachable.
    //
    // Each case samples 6400 entropy bytes, so a false failure against the
    // CORRECT generator needs 0xFF to be absent from all of them:
    // (255/256)^6400 = 1.4e-11.
    Set<int> entropyBytesFrom(Iterable<String> mnemonics) {
      final seen = <int>{};
      for (final m in mnemonics) {
        final hex = bip39.mnemonicToEntropy(m);
        for (var i = 0; i < hex.length; i += 2) {
          seen.add(int.parse(hex.substring(i, i + 2), radix: 16));
        }
      }
      return seen;
    }

    test('12-word entropy reaches 0xFF', () {
      final seen = entropyBytesFrom(
        List.generate(400, (_) => MnemonicGenerator.generate12Words()),
      );
      expect(seen, contains(0xFF), reason: 'nextInt(255) bug is back');
      expect(seen.length, 256, reason: 'some byte value is unreachable');
    });

    test('24-word entropy reaches 0xFF', () {
      final seen = entropyBytesFrom(
        List.generate(200, (_) => MnemonicGenerator.generate24Words()),
      );
      expect(seen, contains(0xFF), reason: 'nextInt(255) bug is back');
      expect(seen.length, 256, reason: 'some byte value is unreachable');
    });
  });

  group('MnemonicGenerator.validate', () {
    test('accepts the BIP39 abandon test vector', () {
      expect(MnemonicGenerator.validate(abandonMnemonic), isTrue);
    });

    test('accepts mnemonics with surrounding whitespace and case noise', () {
      final messy = '  ${abandonMnemonic.toUpperCase()}\n';
      expect(MnemonicGenerator.validate(messy), isTrue);
    });

    test('rejects mnemonic with bad checksum', () {
      // 12 valid wordlist words but bad checksum (last word swapped).
      const bad =
          'abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon abandon';
      expect(MnemonicGenerator.validate(bad), isFalse);
    });

    test('rejects mnemonic with off-list word', () {
      const bad =
          'abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon notaword';
      expect(MnemonicGenerator.validate(bad), isFalse);
    });

    test('rejects empty input', () {
      expect(MnemonicGenerator.validate(''), isFalse);
    });
  });

  group('MnemonicGenerator.toSeed / toSeedHex', () {
    test('matches the BIP39 vector for the abandon mnemonic', () {
      expect(MnemonicGenerator.toSeedHex(abandonMnemonic), abandonSeedHex);
    });

    test('matches the BIP39 vector with TREZOR passphrase', () {
      expect(
        MnemonicGenerator.toSeedHex(abandonMnemonic, passphrase: 'TREZOR'),
        abandonSeedWithPassphraseHex,
      );
    });

    test('toSeed and toSeedHex agree byte-for-byte', () {
      final hex = MnemonicGenerator.toSeedHex(abandonMnemonic);
      final bytes = MnemonicGenerator.toSeed(abandonMnemonic);
      expect(bytes.length, 64);
      final reHex = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(reHex, hex);
    });

    test('whitespace + case in the mnemonic do not change the seed', () {
      final messy = '  ${abandonMnemonic.toUpperCase()}\n';
      expect(MnemonicGenerator.toSeedHex(messy), abandonSeedHex);
    });
  });

  group('MnemonicGenerator word helpers', () {
    test('isValidWordCount accepts 12 and 24, rejects others', () {
      expect(MnemonicGenerator.isValidWordCount(abandonMnemonic), isTrue);
      // 24 words — count-only check, no checksum validation here.
      expect(
        MnemonicGenerator.isValidWordCount('${'abandon ' * 23}about'),
        isTrue,
      );
      expect(MnemonicGenerator.isValidWordCount('abandon abandon'), isFalse);
      expect(
        MnemonicGenerator.isValidWordCount('${'abandon ' * 14}about'),
        isFalse, // 15 words — disallowed by app policy (only 12 or 24).
      );
    });

    test('getWords splits on any whitespace and lowercases', () {
      final words = MnemonicGenerator.getWords('  Abandon\tABANDON\n abandon ');
      expect(words, ['abandon', 'abandon', 'abandon']);
    });

    test('joinWords trims and lowercases each word', () {
      expect(
        MnemonicGenerator.joinWords([' Abandon ', 'ABOUT', 'aLiEn']),
        'abandon about alien',
      );
    });

    test('getSuggestions returns wordlist words with the prefix', () {
      final suggestions = MnemonicGenerator.getSuggestions('ab', limit: 10);
      expect(suggestions, isNotEmpty);
      for (final s in suggestions) {
        expect(s.startsWith('ab'), isTrue);
      }
    });

    test('getSuggestions returns [] for empty prefix', () {
      expect(MnemonicGenerator.getSuggestions(''), isEmpty);
    });

    test('isValidWord respects trimming and case', () {
      expect(MnemonicGenerator.isValidWord('abandon'), isTrue);
      expect(MnemonicGenerator.isValidWord(' ABANDON '), isTrue);
      expect(MnemonicGenerator.isValidWord('notaword'), isFalse);
    });
  });
}
