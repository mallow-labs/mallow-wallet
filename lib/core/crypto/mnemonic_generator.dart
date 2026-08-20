import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;

import 'bip39_english_wordlist.dart';

/// Utility class for BIP39 mnemonic generation and validation.
///
/// Supports both 12-word (128-bit) and 24-word (256-bit) mnemonics.
class MnemonicGenerator {
  const MnemonicGenerator._();

  /// CSPRNG-backed entropy source for [bip39.generateMnemonic].
  ///
  /// bip39 1.0.6's built-in `_randomBytes` calls `nextInt(255)`, and `nextInt`
  /// is exclusive of its bound — so byte value 0xFF is never produced. That
  /// drops each byte to log2(255) = 7.99435 bits, making a "128-bit" mnemonic
  /// 127.91 bits and leaving every phrase we generate with a distinguishing
  /// fingerprint (no 0xFF in the entropy). Not brute-forceable either way, but
  /// we generate at full width rather than ship a biased distribution.
  static Uint8List _secureRandomBytes(int size) {
    final rng = Random.secure();
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  /// Generate a 12-word mnemonic (128 bits of entropy).
  ///
  /// This is the standard for most wallets and provides
  /// sufficient security for most use cases.
  static String generate12Words() {
    return bip39.generateMnemonic(randomBytes: _secureRandomBytes);
  }

  /// Generate a 24-word mnemonic (256 bits of entropy).
  ///
  /// This provides stronger security but is harder to write down
  /// and remember.
  static String generate24Words() {
    return bip39.generateMnemonic(
      strength: 256,
      randomBytes: _secureRandomBytes,
    );
  }

  /// Validate a mnemonic phrase.
  ///
  /// Returns true if the mnemonic:
  /// - Contains valid BIP39 words
  /// - Has correct word count (12, 15, 18, 21, or 24)
  /// - Has valid checksum
  static bool validate(String mnemonic) {
    try {
      return bip39.validateMnemonic(mnemonic.trim().toLowerCase());
    } catch (_) {
      return false;
    }
  }

  /// Convert a mnemonic to seed bytes.
  ///
  /// The seed is used for HD key derivation.
  /// An optional passphrase can be provided for additional security.
  static List<int> toSeed(String mnemonic, {String passphrase = ''}) {
    return bip39.mnemonicToSeed(
      mnemonic.trim().toLowerCase(),
      passphrase: passphrase,
    );
  }

  /// Convert a mnemonic to seed as hex string.
  static String toSeedHex(String mnemonic, {String passphrase = ''}) {
    return bip39.mnemonicToSeedHex(
      mnemonic.trim().toLowerCase(),
      passphrase: passphrase,
    );
  }

  /// Get the word count from a mnemonic.
  static int getWordCount(String mnemonic) {
    return mnemonic.trim().split(RegExp(r'\s+')).length;
  }

  /// Check if word count is valid (12 or 24 for our app).
  static bool isValidWordCount(String mnemonic) {
    final count = getWordCount(mnemonic);
    return count == 12 || count == 24;
  }

  /// Get list of words from mnemonic.
  static List<String> getWords(String mnemonic) {
    return mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
  }

  /// Join words back into a mnemonic string.
  static String joinWords(List<String> words) {
    return words.map((w) => w.trim().toLowerCase()).join(' ');
  }

  /// Get BIP39 wordlist (English).
  ///
  /// Useful for autocomplete when user is typing words.
  static List<String> get wordlist => bip39EnglishWordlist;

  /// Check if a single word is in the BIP39 wordlist.
  static bool isValidWord(String word) {
    return _wordSet.contains(word.trim().toLowerCase());
  }

  /// Get suggestions for a partial word.
  ///
  /// Returns words from the BIP39 wordlist that start with the given prefix.
  static List<String> getSuggestions(String prefix, {int limit = 5}) {
    if (prefix.isEmpty) return [];

    final lowerPrefix = prefix.toLowerCase();
    return bip39EnglishWordlist
        .where((word) => word.startsWith(lowerPrefix))
        .take(limit)
        .toList();
  }

  static final Set<String> _wordSet = bip39EnglishWordlist.toSet();
}
