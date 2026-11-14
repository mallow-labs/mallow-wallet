import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Format v1 of the social vault: the encryption that lets a social-login
/// wallet be stored by the backend without the backend being able to open it.
///
/// - The wallet secret ([SocialVaultPayload]) is sealed with AES-256-GCM under
///   a random 32-byte **data key**.
/// - The data key is wrapped once per **slot**. A slot secret (a passkey's
///   WebAuthn PRF output, or a random secret in the platform's end-to-end
///   encrypted keychain backup) is never sent to the backend, and any one
///   slot unlocks the vault.
/// - A **vault key** (Ed25519), derived from the data key, signs every change
///   after creation. The backend holds its public key, so it can tell that a
///   writer holds the data key without ever seeing it — a stolen Google or
///   Apple login can read the ciphertext but cannot rewrite or delete it.
///
/// Every byte here must match the web client's implementation exactly. The
/// shared vectors in `test/assets/social_vault_vectors.json` come from an
/// independent reference (`tool/social_vault/gen_vectors.py`); both clients
/// test against them. Change nothing here without regenerating them, and
/// never change v1 in place — a new format gets a new prefix.
abstract final class SocialVaultCrypto {
  static const prefix = 'mallow-social-vault/v1';

  static const vaultIdLength = 16;
  static const slotIdLength = 16;
  static const keyLength = 32;
  static const nonceLength = 12;

  // AES-GCM's default nonce is the 12 bytes [nonceLength] names.
  static final AesGcm _aes = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);
  static final Ed25519 _ed25519 = Ed25519();

  /// AAD binding a payload ciphertext to its vault, so a ciphertext copied
  /// into another vault record does not open there.
  static String payloadAad(String vaultId) => '$prefix/payload/$vaultId';

  /// AAD binding a wrapped data key to its vault and slot.
  static String slotAad(String vaultId, String slotId) =>
      '$prefix/slot/$vaultId/$slotId';

  /// HKDF info for a slot's key-encryption key. The slot kind is part of it,
  /// so a passkey secret can never unwrap a platform slot or vice versa.
  static String kekInfo(SocialVaultSlotKind kind) =>
      '$prefix/kek/${kind.wireName}';

  static const authInfo = '$prefix/auth';

  // ---------------------------------------------------------------------------
  // Random material
  // ---------------------------------------------------------------------------

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String newVaultId() => base64UrlNoPad(randomBytes(vaultIdLength));
  static String newSlotId() => base64UrlNoPad(randomBytes(slotIdLength));
  static Uint8List newDataKey() => randomBytes(keyLength);

  // ---------------------------------------------------------------------------
  // Payload
  // ---------------------------------------------------------------------------

  /// Seal [payload] under [dataKey] for [vaultId]. [nonce] is for tests only;
  /// production calls must let it be random — a repeated nonce under one key
  /// breaks AES-GCM.
  static Future<SocialVaultSealed> sealPayload({
    required String vaultId,
    required List<int> dataKey,
    required SocialVaultPayload payload,
    List<int>? nonce,
  }) async {
    _checkVaultId(vaultId);
    _checkLength(dataKey, keyLength, 'data key');
    return _seal(
      key: dataKey,
      clearText: utf8.encode(canonicalPayloadJson(payload)),
      aad: payloadAad(vaultId),
      nonce: nonce,
    );
  }

  /// A recovery phrase in its one spelling: trimmed, lower-case, its words
  /// separated by single spaces.
  ///
  /// The one normaliser, for writing and for reading alike. BIP39 hashes the
  /// phrase as text, so two spellings of the same words are two different
  /// wallets: a phrase must be spelled the same way when it is sealed
  /// ([canonicalPayloadJson]), when it is read back out of a payload
  /// ([SocialVaultPayload.fromJsonString]) and when keys are derived from
  /// it. A payload another client sealed with a double space or a line
  /// break between words therefore opens to the same wallet here. The
  /// shared vectors pin it (`nonCanonicalPayload`).
  static String normalizeMnemonic(String mnemonic) =>
      mnemonic.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  /// The exact JSON [sealPayload] encrypts: [payload] normalized
  /// ([normalizeMnemonic]) and then read back through
  /// [SocialVaultPayload.fromJsonString]. Anything that would not parse is
  /// refused here, so no client can create a vault that only it can open.
  static String canonicalPayloadJson(SocialVaultPayload payload) {
    final normalized = SocialVaultPayload(normalizeMnemonic(payload.mnemonic));
    if (!bip39.validateMnemonic(normalized.mnemonic)) {
      throw const SocialVaultCryptoException('not a valid recovery phrase');
    }
    final json = normalized.toJsonString();
    final reparsed = SocialVaultPayload.fromJsonString(json);
    if (reparsed.toJsonString() != json) {
      throw const SocialVaultCryptoException('payload does not round-trip');
    }
    return json;
  }

  /// Open a payload sealed by [sealPayload]. Throws [SocialVaultCryptoException]
  /// when the key, vault id or bytes are wrong — never returns garbage.
  static Future<SocialVaultPayload> openPayload({
    required String vaultId,
    required List<int> dataKey,
    required SocialVaultSealed sealed,
  }) async {
    _checkVaultId(vaultId);
    _checkLength(dataKey, keyLength, 'data key');
    final clear = await _open(
      key: dataKey,
      sealed: sealed,
      aad: payloadAad(vaultId),
      what: 'payload',
    );
    return SocialVaultPayload.fromJsonString(utf8.decode(clear));
  }

  // ---------------------------------------------------------------------------
  // Slots
  // ---------------------------------------------------------------------------

  /// The key-encryption key a slot secret yields for [vaultId].
  static Future<Uint8List> deriveKek({
    required List<int> slotSecret,
    required String vaultId,
    required SocialVaultSlotKind kind,
  }) async {
    _checkLength(slotSecret, keyLength, 'slot secret');
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(List<int>.of(slotSecret)),
      nonce: _decodeId(vaultId, vaultIdLength, 'vault id'),
      info: utf8.encode(kekInfo(kind)),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Wrap [dataKey] for one slot.
  static Future<SocialVaultSealed> wrapDataKey({
    required String vaultId,
    required String slotId,
    required SocialVaultSlotKind kind,
    required List<int> slotSecret,
    required List<int> dataKey,
    List<int>? nonce,
  }) async {
    _checkLength(dataKey, keyLength, 'data key');
    _decodeId(slotId, slotIdLength, 'slot id');
    final kek = await deriveKek(
      slotSecret: slotSecret,
      vaultId: vaultId,
      kind: kind,
    );
    return _seal(
      key: kek,
      clearText: dataKey,
      aad: slotAad(vaultId, slotId),
      nonce: nonce,
    );
  }

  /// Unwrap the data key from one slot.
  static Future<Uint8List> unwrapDataKey({
    required String vaultId,
    required String slotId,
    required SocialVaultSlotKind kind,
    required List<int> slotSecret,
    required SocialVaultSealed wrapped,
  }) async {
    _decodeId(slotId, slotIdLength, 'slot id');
    final kek = await deriveKek(
      slotSecret: slotSecret,
      vaultId: vaultId,
      kind: kind,
    );
    final dataKey = await _open(
      key: kek,
      sealed: wrapped,
      aad: slotAad(vaultId, slotId),
      what: 'slot',
    );
    _checkLength(dataKey, keyLength, 'unwrapped data key');
    return dataKey;
  }

  // ---------------------------------------------------------------------------
  // The vault key (write authorization)
  // ---------------------------------------------------------------------------

  /// The Ed25519 key pair that authorizes changes to [vaultId].
  static Future<SimpleKeyPair> vaultKeyPair({
    required List<int> dataKey,
    required String vaultId,
  }) async {
    _checkLength(dataKey, keyLength, 'data key');
    final seed = await _hkdf.deriveKey(
      secretKey: SecretKey(List<int>.of(dataKey)),
      nonce: _decodeId(vaultId, vaultIdLength, 'vault id'),
      info: utf8.encode(authInfo),
    );
    return _ed25519.newKeyPairFromSeed(await seed.extractBytes());
  }

  /// Base64url public key of [keyPair], as the backend stores it.
  static Future<String> vaultPublicKey(SimpleKeyPair keyPair) async =>
      base64UrlNoPad((await keyPair.extractPublicKey()).bytes);

  /// The exact text a vault-key signature covers. Binding the method, path,
  /// revision, body hash and time means a captured signature authorizes one
  /// request against one revision and nothing else.
  static String requestMessage({
    required String method,
    required String path,
    required String vaultId,
    required int revision,
    required List<int> body,
    required int timestamp,
  }) => [
    '$prefix/request',
    method.toUpperCase(),
    path,
    vaultId,
    '$revision',
    crypto.sha256.convert(body).toString(),
    '$timestamp',
  ].join('\n');

  /// Sign a vault write. Returns the base64url signature.
  static Future<String> signRequest({
    required SimpleKeyPair keyPair,
    required String method,
    required String path,
    required String vaultId,
    required int revision,
    required List<int> body,
    required int timestamp,
  }) async {
    final message = requestMessage(
      method: method,
      path: path,
      vaultId: vaultId,
      revision: revision,
      body: body,
      timestamp: timestamp,
    );
    final signature = await _ed25519.sign(
      utf8.encode(message),
      keyPair: keyPair,
    );
    return base64UrlNoPad(signature.bytes);
  }

  // ---------------------------------------------------------------------------
  // Encoding helpers
  // ---------------------------------------------------------------------------

  /// The one form a WebAuthn credential id is stored and compared in:
  /// base64url without padding.
  ///
  /// The platforms' passkey plugins report ids in base64 or base64url, padded
  /// or not, and the same passkey must match its slot whichever one answered.
  /// Comparing two spellings of one id as different strings would drop a
  /// working passkey on a rotation, or find no slot for it at unlock.
  static String canonicalCredentialId(String id) =>
      id.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');

  static String base64UrlNoPad(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List decodeBase64UrlNoPad(String value) {
    if (value.contains('=')) {
      throw const SocialVaultCryptoException('padded base64url');
    }
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    try {
      return base64Url.decode(padded);
    } on FormatException {
      throw const SocialVaultCryptoException('malformed base64url');
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static Future<SocialVaultSealed> _seal({
    required List<int> key,
    required List<int> clearText,
    required String aad,
    List<int>? nonce,
  }) async {
    if (nonce != null) _checkLength(nonce, nonceLength, 'nonce');
    final box = await _aes.encrypt(
      clearText,
      secretKey: SecretKey(List<int>.of(key)),
      nonce: nonce ?? randomBytes(nonceLength),
      aad: utf8.encode(aad),
    );
    // Ciphertext with the 16-byte tag appended: WebCrypto's layout, so the
    // web client reads the same field without re-framing it.
    return SocialVaultSealed(
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  static Future<Uint8List> _open({
    required List<int> key,
    required SocialVaultSealed sealed,
    required String aad,
    required String what,
  }) async {
    _checkLength(sealed.nonce, nonceLength, '$what nonce');
    const tagLength = 16;
    if (sealed.ciphertext.length < tagLength) {
      throw SocialVaultCryptoException('$what ciphertext too short');
    }
    final split = sealed.ciphertext.length - tagLength;
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          sealed.ciphertext.sublist(0, split),
          nonce: sealed.nonce,
          mac: Mac(sealed.ciphertext.sublist(split)),
        ),
        secretKey: SecretKey(List<int>.of(key)),
        aad: utf8.encode(aad),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw SocialVaultCryptoException('$what did not authenticate');
    }
  }

  static void _checkVaultId(String vaultId) =>
      _decodeId(vaultId, vaultIdLength, 'vault id');

  static Uint8List _decodeId(String id, int length, String label) {
    final bytes = decodeBase64UrlNoPad(id);
    _checkLength(bytes, length, label);
    return bytes;
  }

  static void _checkLength(List<int> bytes, int length, String label) {
    if (bytes.length != length) {
      throw SocialVaultCryptoException(
        '$label must be $length bytes, got ${bytes.length}',
      );
    }
  }
}

/// Where a slot's secret lives. The wire names are part of the format: they
/// are mixed into each slot's key derivation.
enum SocialVaultSlotKind {
  /// The WebAuthn PRF output of a passkey on the app's relying-party id
  /// (the `PASSKEY_RP_ID` build variable).
  passkeyPrf('passkey-prf'),

  /// A random secret in the platform's end-to-end encrypted keychain backup
  /// (iCloud Keychain on iOS, Block Store on Android).
  platform('platform');

  const SocialVaultSlotKind(this.wireName);
  final String wireName;

  static SocialVaultSlotKind fromWireName(String name) => values.firstWhere(
    (k) => k.wireName == name,
    orElse: () => throw SocialVaultCryptoException('unknown slot kind "$name"'),
  );
}

/// An AES-GCM sealed value: 12-byte nonce, ciphertext with the tag appended.
class SocialVaultSealed {
  const SocialVaultSealed({required this.nonce, required this.ciphertext});

  factory SocialVaultSealed.fromWire({
    required String nonce,
    required String ciphertext,
  }) => SocialVaultSealed(
    nonce: SocialVaultCrypto.decodeBase64UrlNoPad(nonce),
    ciphertext: SocialVaultCrypto.decodeBase64UrlNoPad(ciphertext),
  );

  final Uint8List nonce;
  final Uint8List ciphertext;

  String get nonceWire => SocialVaultCrypto.base64UrlNoPad(nonce);
  String get ciphertextWire => SocialVaultCrypto.base64UrlNoPad(ciphertext);
}

/// The secret a social vault holds: a BIP39 recovery phrase, derived like any
/// seed-phrase wallet. `bip39` is the only payload kind in format v1.
///
/// Hand-written with a redacted [toString]: a generated one would print the
/// phrase, and anything printed can reach the platform log.
final class SocialVaultPayload {
  const SocialVaultPayload(this.mnemonic);

  /// Decode and validate. An unknown version or kind is refused rather than
  /// guessed at: a misread payload derives a different wallet, silently.
  /// The phrase comes out in its one spelling
  /// ([SocialVaultCrypto.normalizeMnemonic]), whatever white space or
  /// capitals the client that sealed it left in.
  factory SocialVaultPayload.fromJsonString(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const SocialVaultCryptoException('payload is not JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const SocialVaultCryptoException('payload is not an object');
    }
    if (decoded['v'] != _version) {
      throw SocialVaultCryptoException(
        'unsupported payload version ${decoded['v']}',
      );
    }
    final kind = decoded['kind'];
    if (kind != _kind) {
      // Only the kind's name is quoted, never a field of the payload.
      throw SocialVaultCryptoException(
        'unknown payload kind "$kind": this app opens only "$_kind" wallets',
      );
    }
    final mnemonic = decoded['mnemonic'];
    if (mnemonic is! String || mnemonic.trim().isEmpty) {
      throw const SocialVaultCryptoException('bip39 payload has no phrase');
    }
    return SocialVaultPayload(SocialVaultCrypto.normalizeMnemonic(mnemonic));
  }

  static const _version = 1;
  static const _kind = 'bip39';

  final String mnemonic;

  /// The canonical JSON. Key order is fixed and shared with the web client.
  String toJsonString() =>
      jsonEncode({'v': _version, 'kind': _kind, 'mnemonic': mnemonic});

  @override
  String toString() => 'SocialVaultPayload(<redacted>)';
}

/// A vault value that is malformed or does not authenticate. The message
/// never carries key material or plaintext.
class SocialVaultCryptoException implements Exception {
  const SocialVaultCryptoException(this.message);

  final String message;

  @override
  String toString() => 'SocialVaultCryptoException: $message';
}
