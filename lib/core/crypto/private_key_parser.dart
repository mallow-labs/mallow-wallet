import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

import 'derivation.dart';
import 'exceptions.dart';

import '../../shared/utils/chain.dart';

/// Result of parsing a private key.
class ParsedPrivateKey {
  const ParsedPrivateKey({
    required this.chain,
    required this.address,
    required this.storedKey,
  });

  /// The blockchain this key controls, inferred from its format.
  final Chain chain;

  /// The chain-native address: Solana base58, Ethereum EIP-55, or Tezos `tz1`.
  final String address;

  /// The secure-storage form of the secret (keyed `mallow_pk_<walletId>`):
  ///  - **Solana** — base58 of the 64-byte keypair (32 secret + 32 public).
  ///  - **Ethereum** — 64-char lowercase hex of the 32-byte secp256k1 key.
  ///  - **Tezos** — 64-char lowercase hex of the 32-byte Ed25519 seed.
  ///
  /// The chain-specific encodings are intentionally distinct so a loader can
  /// never mistake a raw Ethereum/Tezos key for a Solana keypair.
  final String storedKey;
}

/// Auto-detects a private key's chain + format and normalizes it for storage.
///
/// Supported inputs:
///  - **Solana** — base58 (Phantom export), 128-char hex, or 64-int JSON array;
///    all encode the 64-byte keypair (32 secret + 32 public).
///  - **Ethereum** — raw secp256k1 key as `0x`-prefixed or bare 64-char hex.
///  - **Tezos** — Ed25519 secret key as `edsk…` (54-char 32-byte seed form or
///    98-char 64-byte expanded form). secp256k1 (`spsk…`) / P-256 (`p2sk…`)
///    Tezos keys are rejected with a clear message.
class PrivateKeyParser {
  const PrivateKeyParser._();

  /// Base58Check version prefix for a 32-byte Ed25519 seed (`edsk`, 54 chars).
  static const _edskSeedPrefix = [13, 15, 58, 7];

  /// Base58Check version prefix for a 64-byte Ed25519 secret key (`edsk`, 98).
  static const _edskSecretKeyPrefix = [43, 246, 78, 7];

  /// Hex-string validator, shared by the Ethereum and Solana hex paths.
  static final _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

  /// Parse an input string and return the chain, address, and stored key form.
  ///
  /// Throws [InvalidPrivateKeyException] if the input is unrecognizable.
  static Future<ParsedPrivateKey> parse(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw InvalidPrivateKeyException('Input is empty');
    }

    // Tezos Ed25519 secret key (edsk…). Only Ed25519 is supported — secp256k1
    // (spsk…) and P-256 (p2sk…) keys would derive tz2/tz3 addresses the rest of
    // the app can't handle, so reject them with an explicit message rather than
    // failing later as "unrecognized".
    if (trimmed.startsWith('edsk')) {
      return _parseTezosEdsk(trimmed);
    }
    if (trimmed.startsWith('spsk') || trimmed.startsWith('p2sk')) {
      throw InvalidPrivateKeyException(
        'Only Ed25519 Tezos keys (edsk…) are supported, not secp256k1 (spsk…) '
        'or P-256 (p2sk…).',
      );
    }

    // Ethereum raw secp256k1 key: 0x-prefixed or bare 64 hex chars (32 bytes).
    // Solana hex is always 128 chars (the full keypair), so a 64-char hex is
    // unambiguously an Ethereum key here.
    final eth = _tryParseEthereum(trimmed);
    if (eth != null) return eth;

    // Solana 64-byte keypair (base58 / 128-char hex / JSON byte array).
    return _parseSolana(trimmed);
  }

  // ---------------------------------------------------------------------------
  // Ethereum
  // ---------------------------------------------------------------------------

  static ParsedPrivateKey? _tryParseEthereum(String input) {
    final hex = (input.startsWith('0x') || input.startsWith('0X'))
        ? input.substring(2)
        : input;
    if (hex.length != 64) return null;
    if (!_hexPattern.hasMatch(hex)) return null;

    final keyBytes = _hexToBytes(hex);
    // Reject the zero scalar outright; let address derivation reject any other
    // out-of-range key. Importing an invalid key would create a wallet that can
    // never sign — better to fail loud at import.
    if (keyBytes.every((b) => b == 0)) {
      throw InvalidPrivateKeyException('Ethereum private key is out of range.');
    }
    final String address;
    try {
      address = MultiChainDerivation.ethereumAddressFromPrivateKey(keyBytes);
    } catch (_) {
      throw InvalidPrivateKeyException(
        'Could not derive an Ethereum address from this private key.',
      );
    }
    return ParsedPrivateKey(
      chain: Chain.ethereum,
      address: address,
      storedKey: hex.toLowerCase(),
    );
  }

  // ---------------------------------------------------------------------------
  // Tezos
  // ---------------------------------------------------------------------------

  static Future<ParsedPrivateKey> _parseTezosEdsk(String input) async {
    final raw = _tryBase58(input);
    if (raw == null) {
      throw InvalidPrivateKeyException('Invalid Tezos key: not valid Base58.');
    }
    final decoded = _stripBase58Checksum(raw);
    if (decoded == null) {
      throw InvalidPrivateKeyException('Invalid Tezos key: checksum mismatch.');
    }

    final Uint8List seed;
    if (_hasPrefix(decoded, _edskSeedPrefix) &&
        decoded.length == _edskSeedPrefix.length + 32) {
      // 32-byte seed form.
      seed = Uint8List.fromList(decoded.sublist(_edskSeedPrefix.length));
    } else if (_hasPrefix(decoded, _edskSecretKeyPrefix) &&
        decoded.length == _edskSecretKeyPrefix.length + 64) {
      // 64-byte expanded form: first 32 bytes are the seed, trailing 32 are the
      // public key. Verify they match so a tampered key can't display address A
      // while signing as B (mirrors the Solana check in [parse]).
      final payload = decoded.sublist(_edskSecretKeyPrefix.length);
      seed = Uint8List.fromList(payload.sublist(0, 32));
      final embeddedPublic = Uint8List.fromList(payload.sublist(32, 64));
      final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: seed,
      );
      final derivedPublic = Uint8List.fromList(keypair.publicKey.bytes);
      if (!_constantTimeEquals(derivedPublic, embeddedPublic)) {
        throw InvalidPrivateKeyException(
          'Tezos private key is malformed: the embedded public key does not '
          'match the secret key. Refusing to import to prevent signing with a '
          'key that controls a different address.',
        );
      }
    } else {
      throw InvalidPrivateKeyException('Unrecognized Tezos edsk key format.');
    }

    final address = await MultiChainDerivation.tezosAddressFromSeed(seed);
    return ParsedPrivateKey(
      chain: Chain.tezos,
      address: address,
      storedKey: _bytesToHex(seed),
    );
  }

  // ---------------------------------------------------------------------------
  // Solana
  // ---------------------------------------------------------------------------

  static Future<ParsedPrivateKey> _parseSolana(String trimmed) async {
    Uint8List? keyBytes;

    // Try JSON byte array: [1, 2, 3, ...]
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      keyBytes = _tryParseJsonByteArray(trimmed);
    }

    // Try hex string: 128 hex chars = 64 bytes
    keyBytes ??= _tryParseSolanaHex(trimmed);

    // Try base58 (Phantom export)
    keyBytes ??= _tryParseSolanaBase58(trimmed);

    if (keyBytes == null || keyBytes.length != 64) {
      throw InvalidPrivateKeyException(
        'Unrecognized private key. Expected a Solana keypair (base58, 64-byte '
        'JSON array, or 128-char hex), an Ethereum key (0x… 32-byte hex), or a '
        'Tezos key (edsk…).',
      );
    }

    // Re-derive the public key from the first 32 bytes (the secret seed) and
    // verify it matches the trailing 32 bytes. Without this check a tampered
    // export could make the wallet display address A while signing as address
    // B — silent fund loss.
    final secretBytes = keyBytes.sublist(0, 32);
    final trailingPublicBytes = keyBytes.sublist(32, 64);
    final keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: secretBytes,
    );
    final derivedPublic = await keypair.extractPublicKey();
    final derivedPublicBytes = Uint8List.fromList(derivedPublic.bytes);

    if (!_constantTimeEquals(derivedPublicBytes, trailingPublicBytes)) {
      throw InvalidPrivateKeyException(
        'Private key is malformed: the embedded public key does not match '
        'the secret key. Refusing to import to prevent signing with a key '
        'that controls a different address.',
      );
    }

    return ParsedPrivateKey(
      chain: Chain.solana,
      address: derivedPublic.toBase58(),
      storedKey: base58encode(keyBytes),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Constant-time byte comparison so that mismatches don't leak position
  /// information through timing.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List? _tryParseJsonByteArray(String input) {
    try {
      final list = (jsonDecode(input) as List).cast<num>();
      if (list.length != 64) return null;
      return Uint8List.fromList(list.map((n) => n.toInt()).toList());
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _tryParseSolanaHex(String input) {
    if (input.length != 128) return null;
    if (!_hexPattern.hasMatch(input)) return null;
    try {
      return _hexToBytes(input);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _tryParseSolanaBase58(String input) {
    final decoded = _tryBase58(input);
    if (decoded == null || decoded.length != 64) return null;
    return decoded;
  }

  static Uint8List? _tryBase58(String input) {
    try {
      return Uint8List.fromList(base58decode(input));
    } catch (_) {
      return null;
    }
  }

  /// Validate the trailing 4-byte double-SHA256 Base58Check checksum and return
  /// the prefixed payload (checksum stripped), or null on mismatch.
  static Uint8List? _stripBase58Checksum(Uint8List data) {
    if (data.length < 5) return null;
    final payload = data.sublist(0, data.length - 4);
    final checksum = Uint8List.fromList(data.sublist(data.length - 4));
    final expected = Uint8List.fromList(
      crypto.sha256
          .convert(crypto.sha256.convert(payload).bytes)
          .bytes
          .sublist(0, 4),
    );
    if (!_constantTimeEquals(checksum, expected)) return null;
    return payload;
  }

  static bool _hasPrefix(Uint8List data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
