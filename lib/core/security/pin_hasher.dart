// Argon2id parameters below are pinned explicitly to define the `v1` hash
// contract, so we intentionally keep values that match pointycastle defaults.
// ignore_for_file: avoid_redundant_argument_values
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// Hashes and verifies app-lock PINs with Argon2id.
///
/// Stored format is `v1$<base64url salt>$<base64url hash>`. The leading
/// version tag lets us migrate parameters later without re-prompting the user.
///
/// SECURITY: PINs are short (typically 4-6 digits), so a memory-hard KDF is
/// the only thing standing between a stolen Keychain/Keystore dump and instant
/// recovery of the plaintext PIN. Argon2id (64 MiB, 3 iterations) is tuned to
/// stay memory-hard while taking only a few hundred ms on a modern phone. The
/// derivation is run on a background isolate (via [compute]) so it never janks
/// the PIN keypad.
class PinHasher {
  const PinHasher() : _random = null, _runInBackground = true;

  /// Test-only constructor: a deterministic RNG makes encoded values
  /// reproducible, and [runInBackground] false runs the KDF inline so unit
  /// tests don't pay for (or flake on) isolate spin-up.
  @visibleForTesting
  const PinHasher.withRandom(Random random, {bool runInBackground = false})
    : _random = random,
      _runInBackground = runInBackground;

  static const _version = 'v1';
  static const _saltLength = 16;
  static const _hashLength = 32;

  // Argon2id parameters (must stay in sync with the `v1` tag above).
  static const _memoryKiB = 65536; // 64 MiB
  static const _iterations = 3;
  static const _parallelism = 1;

  final Random? _random;
  final bool _runInBackground;

  /// Hash a plaintext PIN. Returns the encoded `v1$salt$hash` string.
  Future<String> hash(String pin) async {
    final salt = _generateSalt();
    final digest = await _derive(_Argon2Request(pin, salt));
    return _encode(salt, digest);
  }

  /// Verify [pin] against a previously [hash]-ed value.
  ///
  /// Returns false (never throws) on any parse error so a corrupted stored
  /// value cannot be used as a bypass oracle.
  Future<bool> verify(String pin, String encoded) async {
    final parsed = _tryParse(encoded);
    if (parsed == null) return false;
    final candidate = await _derive(_Argon2Request(pin, parsed.salt));
    return _constantTimeEquals(candidate, parsed.hash);
  }

  /// True if [encoded] has the current encoded format (used to detect legacy
  /// plaintext PINs that need migration).
  static bool isEncoded(String value) => value.startsWith('$_version\$');

  Future<Uint8List> _derive(_Argon2Request request) => _runInBackground
      ? compute(_argon2idDerive, request)
      : Future.value(_argon2idDerive(request));

  Uint8List _generateSalt() {
    final rng = _random ?? Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => rng.nextInt(256)),
    );
  }

  String _encode(Uint8List salt, Uint8List hash) =>
      '$_version\$${base64Url.encode(salt)}\$${base64Url.encode(hash)}';

  _Parsed? _tryParse(String encoded) {
    final parts = encoded.split('\$');
    if (parts.length != 3 || parts[0] != _version) return null;
    try {
      final salt = base64Url.decode(parts[1]);
      final hash = base64Url.decode(parts[2]);
      if (salt.length != _saltLength || hash.length != _hashLength) return null;
      return _Parsed(salt: salt, hash: hash);
    } catch (_) {
      return null;
    }
  }

  /// Constant-time byte comparison. Returns true iff the inputs are
  /// element-wise equal AND the same length.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Top-level so it can be dispatched to a background isolate via [compute].
///
/// Lives at library scope (not as a method) because [compute] requires a
/// top-level or static function. Argon2 state is constructed here, inside the
/// target isolate, so nothing non-serializable crosses the boundary.
Uint8List _argon2idDerive(_Argon2Request request) {
  // Every parameter is pinned explicitly — even where it matches a current
  // pointycastle default — because they collectively define the `v1` hash
  // contract. A silent upstream default change must not alter how stored PINs
  // verify, so we do not lean on defaults here (see ignore_for_file above).
  final params = Argon2Parameters(
    Argon2Parameters.ARGON2_id,
    request.salt,
    desiredKeyLength: PinHasher._hashLength,
    version: Argon2Parameters.ARGON2_VERSION_13,
    iterations: PinHasher._iterations,
    // pointycastle expresses memory as log2(KiB); _memoryKiB is a power of two
    // so bitLength-1 is its exact log2 (65536 -> 16).
    memoryPowerOf2: PinHasher._memoryKiB.bitLength - 1,
    lanes: PinHasher._parallelism,
  );
  final generator = Argon2BytesGenerator()..init(params);
  final out = Uint8List(PinHasher._hashLength);
  final pinBytes = Uint8List.fromList(utf8.encode(request.pin));
  generator.deriveKey(pinBytes, 0, out, 0);
  return out;
}

class _Argon2Request {
  const _Argon2Request(this.pin, this.salt);
  final String pin;
  final Uint8List salt;
}

class _Parsed {
  const _Parsed({required this.salt, required this.hash});
  final Uint8List salt;
  final Uint8List hash;
}
