import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/bip39_english_wordlist.dart';
import 'package:mallow_wallet/core/crypto/mnemonic_generator.dart';

void main() {
  group('bip39EnglishWordlist', () {
    test('contains exactly 2048 words', () {
      expect(bip39EnglishWordlist, hasLength(2048));
    });

    test('matches canonical BIP39 spec SHA-256', () {
      // SHA-256 of the canonical newline-separated BIP39 English wordlist
      // (https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt,
      // trailing newline included). Any drift here means the bundled list
      // diverges from the spec — fail loud rather than ship a fork.
      const canonicalSha256 =
          '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda';
      final bytes = utf8.encode('${bip39EnglishWordlist.join('\n')}\n');
      expect(sha256.convert(bytes).toString(), canonicalSha256);
    });

    test('first and last entries match spec', () {
      expect(bip39EnglishWordlist.first, 'abandon');
      expect(bip39EnglishWordlist.last, 'zoo');
    });
  });

  group('MnemonicGenerator wordlist surface', () {
    test('isValidWord accepts words across the full wordlist', () {
      // Sample words from the tail of the list that the old truncated
      // wordlist would have rejected.
      const samples = ['zoo', 'zone', 'zero', 'youth', 'mango', 'pizza'];
      for (final word in samples) {
        expect(
          MnemonicGenerator.isValidWord(word),
          isTrue,
          reason: '$word should be a valid BIP39 word',
        );
      }
    });

    test('isValidWord rejects non-BIP39 words', () {
      expect(MnemonicGenerator.isValidWord('notaword'), isFalse);
      expect(MnemonicGenerator.isValidWord(''), isFalse);
    });

    test('getSuggestions returns entries from beyond the first 100 words', () {
      final suggestions = MnemonicGenerator.getSuggestions('piz');
      expect(suggestions, contains('pizza'));
    });
  });
}
