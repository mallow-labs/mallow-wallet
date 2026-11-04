import 'dart:math';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../ur.dart';
import 'cbor_util.dart';
import 'keypath.dart';
import 'multi_accounts.dart';

/// `sol-sign-request` key 6. Keystone's firmware works out for itself whether
/// the bytes are a transaction or a message, so this is informational.
enum SolSignType {
  transaction(1),
  message(2);

  const SolSignType(this.wire);

  final int wire;
}

/// `sol-sign-request` (tag 1101): asks the device to sign [signData] with the
/// key at [path].
///
/// CBOR map, keys ascending: `1: #6.37 request id`, `2: sign data`,
/// `3: #6.304 keypath`, `5: origin`, `6: sign type`. Key 4 (the signer's
/// address) is never written — the firmware ignores it and signs by path, so
/// it could only mislead.
class SolSignRequest {
  SolSignRequest({
    required this.requestId,
    required this.signData,
    required this.path,
    this.origin = 'mallow',
    this.type = SolSignType.transaction,
  });

  /// Decodes a `sol-sign-request` UR — for tests and tooling; the app only
  /// ever encodes requests. Key 4 is read and discarded.
  factory SolSignRequest.fromUr(UR ur) {
    expectUrType(ur, RegistryType.solSignRequest);
    return SolSignRequest.fromCbor(ur.cbor);
  }

  factory SolSignRequest.fromCbor(List<int> bytes) {
    const what = 'sol-sign-request';
    return guardDecode(what, () {
      final map = expectIntKeyMap(decodeCbor(bytes, what), what);
      final id = map[1];
      final data = map[2];
      final path = map[3];
      final origin = map[5];
      final type = map[6];
      if (id == null || data == null || path == null) {
        throw UrDecodeException('$what: missing field', kind: UrDecodeErrorKind.malformed);
      }
      final wire = type == null ? 1 : expectUint(type, what);
      return SolSignRequest(
        requestId: expectBytes(id, what, tag: RegistryTag.uuid),
        signData: expectBytes(data, what),
        path: KeystoneKeypath.fromCborValue(path, tagged: true),
        origin: origin == null ? '' : expectText(origin, what),
        type: SolSignType.values.firstWhere(
          (t) => t.wire == wire,
          orElse: () =>
              throw UrDecodeException('$what: bad sign type', kind: UrDecodeErrorKind.malformed),
        ),
      );
    });
  }

  /// 16 bytes, normally an RFC 4122 UUID from [newRequestId]. The device
  /// echoes it in its [SolSignature].
  final Uint8List requestId;

  /// For a transaction, the compiled message bytes (not the signed envelope).
  final Uint8List signData;

  /// The signing key's path. It must carry the device's master fingerprint as
  /// [KeystoneKeypath.sourceFingerprint]: the firmware refuses a request whose
  /// fingerprint does not match the seed it holds.
  final KeystoneKeypath path;

  /// Shown on the device as the requesting wallet.
  final String origin;

  final SolSignType type;

  /// 16 random bytes from a CSPRNG with the RFC 4122 version-4 and variant
  /// bits set.
  static Uint8List newRequestId() => newUuidV4();

  /// The CBOR body.
  ///
  /// The keypath is written without its depth (key 3), whatever [path]
  /// carries: Keystone's own encoders never write it in a sign request, and
  /// leaving it out keeps the request byte-identical to theirs.
  ///
  /// Throws [ArgumentError] if [requestId] is not 16 bytes, if [path] has no
  /// source fingerprint or contains a wildcard, or if [signData] is empty.
  Uint8List toCbor() {
    validateSignRequestPath(path, requestId);
    if (signData.isEmpty) throw ArgumentError.value(signData, 'signData', 'is empty');
    return encodeCbor(
      orderedMap({
        1: CborBytes(requestId, tags: const [RegistryTag.uuid]),
        2: CborBytes(signData),
        3: path.withoutDepth().toCborValue(tagged: true),
        if (origin.isNotEmpty) 5: CborString(origin),
        6: CborSmallInt(type.wire),
      }),
    );
  }

  UR toUr() => UR(RegistryType.solSignRequest, toCbor());
}

/// `sol-signature` (tag 1102): the device's reply. CBOR map:
/// `1: #6.37 request id`, `2: 64-byte Ed25519 signature`.
///
/// The reply does not say which key signed. A different Keystone, fingerprint
/// or path still yields a valid signature from some other key, so callers must
/// match [requestId] and verify [signature] against the expected public key
/// over the exact bytes sent before using it.
class SolSignature {
  const SolSignature({required this.requestId, required this.signature});

  /// Decodes a `sol-signature` UR. Throws [UrDecodeException] on a wrong type,
  /// malformed CBOR, a request id that is not 16 bytes, or a signature that is
  /// not 64 bytes.
  factory SolSignature.fromUr(UR ur) {
    expectUrType(ur, RegistryType.solSignature);
    return SolSignature.fromCbor(ur.cbor);
  }

  factory SolSignature.fromCbor(List<int> bytes) {
    const what = 'sol-signature';
    return guardDecode(what, () {
      final map = expectIntKeyMap(decodeCbor(bytes, what), what);
      final id = map[1];
      final sig = map[2];
      if (sig == null) {
        throw UrDecodeException('$what: missing signature', kind: UrDecodeErrorKind.malformed);
      }
      final requestId = id == null ? null : expectBytes(id, what, tag: RegistryTag.uuid);
      if (requestId != null && requestId.length != 16) {
        throw UrDecodeException(
          '$what: request id is not 16 bytes',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      final signature = expectBytes(sig, what);
      if (signature.length != 64) {
        throw UrDecodeException(
          '$what: signature is ${signature.length} bytes, expected 64',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      return SolSignature(requestId: requestId, signature: signature);
    });
  }

  final Uint8List? requestId;
  final Uint8List signature;

  /// The CBOR body, as the device writes it. Lets tests fabricate a reply.
  Uint8List toCbor() {
    final id = requestId;
    return encodeCbor(
      orderedMap({
        if (id != null) 1: CborBytes(id, tags: const [RegistryTag.uuid]),
        2: CborBytes(signature),
      }),
    );
  }

  UR toUr() => UR(RegistryType.solSignature, toCbor());
}

/// The three Solana derivation shapes a Keystone exports.
enum KeystoneSolanaPath {
  /// `m/44'/501'/i'/0'` — Keystone's "Sub-account Path"; Phantom, Solflare.
  standard,

  /// `m/44'/501'/i'` — Keystone's "Account-based Path".
  legacy,

  /// `m/44'/501'` — Keystone's "Single Account Path"; index 0 only.
  root,
}

/// One Solana account from a Keystone export.
class KeystoneSolanaAccount {
  const KeystoneSolanaAccount({
    required this.index,
    required this.scheme,
    required this.publicKey,
    this.name,
  });

  /// The account index `i` (0 for [KeystoneSolanaPath.root]).
  final int index;
  final KeystoneSolanaPath scheme;

  /// The 32-byte Ed25519 public key, i.e. the address before base58.
  final Uint8List publicKey;
  final String? name;

  @override
  String toString() => 'KeystoneSolanaAccount(${scheme.name} #$index)';
}

/// The device keeps Solana keys for account indexes 0–49 only.
const int kKeystoneMaxSolanaIndex = 49;

const int _purpose = 44;
const int _solanaCoin = 501;

/// Every Solana key in [export], mapped to (index, scheme), sorted by scheme
/// then index.
///
/// A key is Solana-looking when its origin path starts `44/501` (hardened or
/// not). Such a key must have a hardened, wildcard-free origin of one of the
/// three [KeystoneSolanaPath] shapes, an index ≤ 49, a 32-byte key, and no
/// source fingerprint other than the export's; otherwise the whole export is
/// rejected with [UrDecodeException]. Keys of other chains are ignored. An
/// export whose master fingerprint is 0 is rejected, since every sign request
/// must carry it.
List<KeystoneSolanaAccount> solanaAccountsFromExport(KeystoneMultiAccounts export) {
  const what = 'Solana export';
  if (export.masterFingerprint == 0) {
    throw UrDecodeException('$what: master fingerprint is 0', kind: UrDecodeErrorKind.malformed);
  }
  final byPath = <(KeystoneSolanaPath, int), KeystoneSolanaAccount>{};
  for (final key in export.keys) {
    final origin = key.origin;
    if (origin == null) continue;
    final c = origin.components;
    if (c.length < 2 || c[0].index != _purpose || c[1].index != _solanaCoin) continue;

    if (c.any((x) => x.isWildcard || !x.hardened)) {
      throw UrDecodeException(
        '$what: non-hardened path ${origin.toPathString()}',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    final fp = origin.sourceFingerprint;
    if (fp != null && fp != export.masterFingerprint) {
      throw UrDecodeException(
        '$what: key fingerprint differs from the device fingerprint',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    final KeystoneSolanaPath scheme;
    final int index;
    switch (c.length) {
      case 2:
        scheme = KeystoneSolanaPath.root;
        index = 0;
      case 3:
        scheme = KeystoneSolanaPath.legacy;
        index = c[2].index!;
      case 4 when c[3].index == 0:
        scheme = KeystoneSolanaPath.standard;
        index = c[2].index!;
      default:
        throw UrDecodeException(
          '$what: unsupported path ${origin.toPathString()}',
          kind: UrDecodeErrorKind.malformed,
        );
    }
    if (index > kKeystoneMaxSolanaIndex) {
      throw UrDecodeException(
        '$what: account index $index is above $kKeystoneMaxSolanaIndex',
        kind: UrDecodeErrorKind.limitExceeded,
      );
    }
    if (key.keyData.length != 32) {
      throw UrDecodeException(
        '$what: key is ${key.keyData.length} bytes, expected 32',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    if (key.chainCode != null) {
      throw UrDecodeException(
        '$what: unexpected chain code on an Ed25519 key',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    final account = KeystoneSolanaAccount(
      index: index,
      scheme: scheme,
      publicKey: Uint8List.fromList(key.keyData),
      name: key.name,
    );
    final existing = byPath[(scheme, index)];
    if (existing != null) {
      if (!_bytesEqual(existing.publicKey, account.publicKey)) {
        throw UrDecodeException(
          '$what: two different keys for one path',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      continue;
    }
    byPath[(scheme, index)] = account;
  }
  return byPath.values.toList()..sort((a, b) {
    final s = a.scheme.index.compareTo(b.scheme.index);
    return s != 0 ? s : a.index.compareTo(b.index);
  });
}

/// The signing keypath for a Solana account: standard `44'/501'/i'/0'`,
/// legacy `44'/501'/i'`, root `44'/501'` — with [masterFingerprint] as the
/// source fingerprint and `depth` = the number of components.
///
/// Throws [ArgumentError] for an index outside 0–49, a root index other than
/// 0, or a fingerprint that is 0 or not a uint32.
KeystoneKeypath solanaKeypath(KeystoneSolanaPath scheme, int index, int masterFingerprint) {
  if (index < 0 || index > kKeystoneMaxSolanaIndex) {
    throw ArgumentError.value(index, 'index', 'must be 0..$kKeystoneMaxSolanaIndex');
  }
  if (scheme == KeystoneSolanaPath.root && index != 0) {
    throw ArgumentError.value(index, 'index', 'the root path has index 0 only');
  }
  if (masterFingerprint <= 0 || masterFingerprint > 0xFFFFFFFF) {
    throw ArgumentError.value(masterFingerprint, 'masterFingerprint', 'must be a non-zero uint32');
  }
  const h44 = KeypathComponent(_purpose, hardened: true);
  const h501 = KeypathComponent(_solanaCoin, hardened: true);
  final components = switch (scheme) {
    KeystoneSolanaPath.standard => [
      h44,
      h501,
      KeypathComponent(index, hardened: true),
      const KeypathComponent(0, hardened: true),
    ],
    KeystoneSolanaPath.legacy => [h44, h501, KeypathComponent(index, hardened: true)],
    KeystoneSolanaPath.root => [h44, h501],
  };
  return KeystoneKeypath(
    components: List.unmodifiable(components),
    sourceFingerprint: masterFingerprint,
    depth: components.length,
  );
}

/// 16 CSPRNG bytes with the RFC 4122 version-4 and variant bits set.
Uint8List newUuidV4() {
  final rng = Random.secure();
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = rng.nextInt(256);
  }
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  return b;
}

/// Shared sign-request preconditions. Throws [ArgumentError].
void validateSignRequestPath(KeystoneKeypath path, Uint8List requestId) {
  if (requestId.length != 16) {
    throw ArgumentError.value(requestId.length, 'requestId', 'must be 16 bytes');
  }
  final fp = path.sourceFingerprint;
  if (fp == null || fp == 0) {
    throw ArgumentError.value(path, 'path', 'must carry the device master fingerprint');
  }
  if (path.components.isEmpty || path.components.any((c) => c.isWildcard)) {
    throw ArgumentError.value(path, 'path', 'must be a concrete, non-empty path');
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
