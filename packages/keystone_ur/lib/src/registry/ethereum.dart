import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../ur.dart';
import 'cbor_util.dart';
import 'hd_key.dart';
import 'keypath.dart';
import 'multi_accounts.dart';
import 'solana.dart' show newUuidV4, validateSignRequestPath;

/// `eth-sign-request` key 3.
enum EthDataType {
  /// An RLP-encoded legacy transaction.
  transaction(1),

  /// EIP-712 typed data (JSON).
  typedData(2),

  /// An EIP-191 personal message.
  personalMessage(3),

  /// A typed (EIP-2718) transaction; Keystone accepts type 0x02 (EIP-1559).
  typedTransaction(4);

  const EthDataType(this.wire);

  final int wire;
}

/// `eth-sign-request` (tag 401, ERC-4527).
///
/// CBOR map, keys ascending: `1: #6.37 request id`, `2: sign data`,
/// `3: data type`, `4: chain id`, `5: #6.304 keypath`, `6: address`,
/// `7: origin`. The firmware signs by path once the keypath's fingerprint
/// matches; it does not check [address], so recovering the signer from the
/// [EthSignature] and comparing it is the only address check.
class EthSignRequest {
  EthSignRequest({
    required this.requestId,
    required this.signData,
    required this.dataType,
    required this.chainId,
    required this.path,
    this.address,
    this.origin = 'mallow',
  });

  /// Decodes an `eth-sign-request` UR — for tests and tooling.
  factory EthSignRequest.fromUr(UR ur) {
    expectUrType(ur, RegistryType.ethSignRequest);
    return EthSignRequest.fromCbor(ur.cbor);
  }

  factory EthSignRequest.fromCbor(List<int> bytes) {
    const what = 'eth-sign-request';
    return guardDecode(what, () {
      final map = expectIntKeyMap(decodeCbor(bytes, what), what);
      final id = map[1];
      final data = map[2];
      final type = map[3];
      final chain = map[4];
      final path = map[5];
      final address = map[6];
      final origin = map[7];
      if (id == null || data == null || type == null || path == null) {
        throw UrDecodeException('$what: missing field', kind: UrDecodeErrorKind.malformed);
      }
      final wire = expectUint(type, what);
      return EthSignRequest(
        requestId: expectBytes(id, what, tag: RegistryTag.uuid),
        signData: expectBytes(data, what),
        dataType: EthDataType.values.firstWhere(
          (t) => t.wire == wire,
          orElse: () =>
              throw UrDecodeException('$what: bad data type', kind: UrDecodeErrorKind.malformed),
        ),
        chainId: chain == null ? 1 : expectUint(chain, what, max: 0x7FFFFFFFFFFFFFFF),
        path: KeystoneKeypath.fromCborValue(path, tagged: true),
        address: address == null ? null : expectBytes(address, what),
        origin: origin == null ? '' : expectText(origin, what),
      );
    });
  }

  final Uint8List requestId;

  /// The unsigned payload: RLP for [EthDataType.transaction], the type byte
  /// plus RLP for [EthDataType.typedTransaction], the raw message for
  /// [EthDataType.personalMessage], UTF-8 JSON for [EthDataType.typedData].
  final Uint8List signData;
  final EthDataType dataType;
  final int chainId;

  /// Must carry the device's master fingerprint.
  final KeystoneKeypath path;

  /// The expected signer, 20 bytes; informational on the device.
  final Uint8List? address;
  final String origin;

  /// The CBOR body. As with [SolSignRequest.toCbor], the keypath is written
  /// without its depth, matching Keystone's encoders byte for byte.
  ///
  /// Throws [ArgumentError] on a request id that is not 16 bytes, a path
  /// without a fingerprint, an address that is not 20 bytes, or a negative
  /// chain id.
  Uint8List toCbor() {
    validateSignRequestPath(path, requestId);
    final addr = address;
    if (addr != null && addr.length != 20) {
      throw ArgumentError.value(addr.length, 'address', 'must be 20 bytes');
    }
    if (chainId < 0) throw ArgumentError.value(chainId, 'chainId', 'must be non-negative');
    return encodeCbor(
      orderedMap({
        1: CborBytes(requestId, tags: const [RegistryTag.uuid]),
        2: CborBytes(signData),
        3: CborSmallInt(dataType.wire),
        4: CborSmallInt(chainId),
        5: path.withoutDepth().toCborValue(tagged: true),
        if (addr != null) 6: CborBytes(addr),
        if (origin.isNotEmpty) 7: CborString(origin),
      }),
    );
  }

  UR toUr() => UR(RegistryType.ethSignRequest, toCbor());

  /// A fresh random request id (UUID v4) for [requestId].
  static Uint8List newRequestId() => newUuidV4();
}

/// The keypath of the BIP-44 standard Ethereum account at [index]:
/// `m/44'/60'/0'/0/index`, the layout [KeystoneEthExportKind.bip44Standard]
/// exports, carrying [masterFingerprint] so the device accepts the request.
///
/// Throws [ArgumentError] on an index outside the non-hardened range or a
/// fingerprint that is not a non-zero uint32.
KeystoneKeypath ethereumStandardKeypath(int index, int masterFingerprint) {
  if (index < 0 || index >= 0x80000000) {
    throw ArgumentError.value(index, 'index', 'must be a non-hardened index');
  }
  if (masterFingerprint <= 0 || masterFingerprint > 0xFFFFFFFF) {
    throw ArgumentError.value(masterFingerprint, 'masterFingerprint', 'must be a non-zero uint32');
  }
  final components = List<KeypathComponent>.unmodifiable([
    _h44,
    _h60,
    _h0,
    _n0,
    KeypathComponent(index, hardened: false),
  ]);
  return KeystoneKeypath(
    components: components,
    sourceFingerprint: masterFingerprint,
    depth: components.length,
  );
}

/// `eth-signature` (tag 402): `1: #6.37 request id`, `2: r ‖ s ‖ v`,
/// `3: origin`.
class EthSignature {
  const EthSignature({required this.requestId, required this.signature, this.origin});

  /// Decodes an `eth-signature` UR. Throws [UrDecodeException] on a wrong
  /// type, malformed CBOR, or a signature shorter than 65 bytes (or longer
  /// than 96, which no `v` needs).
  factory EthSignature.fromUr(UR ur) {
    expectUrType(ur, RegistryType.ethSignature);
    return EthSignature.fromCbor(ur.cbor);
  }

  factory EthSignature.fromCbor(List<int> bytes) {
    const what = 'eth-signature';
    return guardDecode(what, () {
      final map = expectIntKeyMap(decodeCbor(bytes, what), what);
      final id = map[1];
      final sig = map[2];
      final origin = map[3];
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
      if (signature.length < 65 || signature.length > 96) {
        throw UrDecodeException(
          '$what: signature is ${signature.length} bytes',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      return EthSignature(
        requestId: requestId,
        signature: signature,
        origin: origin == null ? null : expectText(origin, what),
      );
    });
  }

  final Uint8List? requestId;

  /// `r` (32) ‖ `s` (32) ‖ `v` (one or more bytes, big-endian). For typed
  /// transactions and personal messages Keystone returns `v` as 0/1 or
  /// 27/28; normalise before use.
  final Uint8List signature;
  final String? origin;

  /// The CBOR body, as the device writes it. Lets tests fabricate a reply.
  Uint8List toCbor() {
    final id = requestId;
    final o = origin;
    return encodeCbor(
      orderedMap({
        if (id != null) 1: CborBytes(id, tags: const [RegistryTag.uuid]),
        2: CborBytes(signature),
        if (o != null) 3: CborString(o),
      }),
    );
  }

  UR toUr() => UR(RegistryType.ethSignature, toCbor());
}

/// Which of Keystone's three Ethereum account layouts an export carries.
enum KeystoneEthExportKind {
  /// One xpub at `m/44'/60'/0'` (with chain code); addresses at `0/i`.
  bip44Standard,

  /// One xpub at `m/44'/60'/0'`; addresses at `i` (children `*`).
  ledgerLegacy,

  /// One plain key per account at `m/44'/60'/i'/0/0`, no chain code.
  ledgerLive,

  unknown,
}

const String _noteStandard = 'account.standard';
const String _noteLedgerLegacy = 'account.ledger_legacy';
const String _noteLedgerLive = 'account.ledger_live';

bool _isPath(KeystoneKeypath? p, List<KeypathComponent> expected) {
  if (p == null || p.components.length != expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (p.components[i] != expected[i]) return false;
  }
  return true;
}

const _h44 = KeypathComponent(44, hardened: true);
const _h60 = KeypathComponent(60, hardened: true);
const _h0 = KeypathComponent(0, hardened: true);
const _n0 = KeypathComponent(0, hardened: false);
const _star = KeypathComponent(null, hardened: false);

bool _isEthOrigin(KeystoneHdKey k) {
  final c = k.origin?.components;
  return c != null && c.length >= 2 && c[0] == _h44 && c[1] == _h60;
}

/// Classifies a single Ethereum key.
KeystoneEthExportKind _classifyKey(KeystoneHdKey k) {
  if (!_isEthOrigin(k)) return KeystoneEthExportKind.unknown;
  final note = k.note;
  final atAccount0 = _isPath(k.origin, const [_h44, _h60, _h0]);
  final extended = k.chainCode != null;
  final children = k.children;

  if (note == _noteLedgerLive) return KeystoneEthExportKind.ledgerLive;
  if (note == _noteLedgerLegacy || (children != null && _isPath(children, const [_star]))) {
    return atAccount0 && extended
        ? KeystoneEthExportKind.ledgerLegacy
        : KeystoneEthExportKind.unknown;
  }
  final standardChildren = children == null || _isPath(children, const [_n0, _star]);
  if ((note == null || note == _noteStandard) && atAccount0 && extended && standardChildren) {
    return KeystoneEthExportKind.bip44Standard;
  }
  final c = k.origin!.components;
  if (note == null &&
      !extended &&
      c.length == 5 &&
      c[2].hardened &&
      !c[2].isWildcard &&
      c[3] == _n0 &&
      c[4] == _n0) {
    return KeystoneEthExportKind.ledgerLive;
  }
  return KeystoneEthExportKind.unknown;
}

/// Classifies an Ethereum account export:
///
/// * a `crypto-hdkey` UR — by its note and children: `account.standard` or
///   children `0/*` (or none) on an extended key at `m/44'/60'/0'` is
///   [KeystoneEthExportKind.bip44Standard]; `account.ledger_legacy` or
///   children `*` is [KeystoneEthExportKind.ledgerLegacy];
/// * a `crypto-account` UR (tag 311) holding Ethereum keys —
///   [KeystoneEthExportKind.ledgerLive], the only layout Keystone sends that
///   way;
/// * a `crypto-multi-accounts` UR — by its Ethereum keys, preferring
///   bip44Standard, then ledgerLegacy, then ledgerLive when several are
///   present (Keystone's multi-chain exports carry the standard xpub and the
///   Ledger Live keys side by side).
///
/// Anything else — other UR types, exports with no Ethereum key — is
/// [KeystoneEthExportKind.unknown]. Malformed CBOR throws
/// [UrDecodeException].
KeystoneEthExportKind classifyEthExport(UR ur) {
  switch (ur.type) {
    case RegistryType.cryptoHdKey:
      return _classifyKey(KeystoneHdKey.fromUr(ur));
    case RegistryType.cryptoAccount:
      final keys = _cryptoAccountKeys(ur.cbor);
      return keys.any(_isEthOrigin)
          ? KeystoneEthExportKind.ledgerLive
          : KeystoneEthExportKind.unknown;
    case RegistryType.cryptoMultiAccounts:
      final kinds = KeystoneMultiAccounts.fromUr(ur).keys.map(_classifyKey).toSet();
      for (final k in const [
        KeystoneEthExportKind.bip44Standard,
        KeystoneEthExportKind.ledgerLegacy,
        KeystoneEthExportKind.ledgerLive,
      ]) {
        if (kinds.contains(k)) return k;
      }
      return KeystoneEthExportKind.unknown;
    default:
      return KeystoneEthExportKind.unknown;
  }
}

/// The BIP-44 standard Ethereum xpub (`m/44'/60'/0'`, addresses at `0/i`)
/// from a `crypto-hdkey` or `crypto-multi-accounts` UR.
///
/// The returned key's origin always carries the master fingerprint: from the
/// key itself, or from the export when the key omits it. Throws
/// [UrDecodeException] unless the export is
/// [KeystoneEthExportKind.bip44Standard] with a 33-byte compressed key, a
/// 32-byte chain code and a non-zero fingerprint.
KeystoneHdKey ethStandardXpubFromUr(UR ur) {
  const what = 'Ethereum export';
  KeystoneHdKey key;
  switch (ur.type) {
    case RegistryType.cryptoHdKey:
      key = KeystoneHdKey.fromUr(ur);
      if (_classifyKey(key) != KeystoneEthExportKind.bip44Standard) {
        throw UrDecodeException(
          '$what: not a BIP-44 standard account',
          kind: UrDecodeErrorKind.malformed,
        );
      }
    case RegistryType.cryptoMultiAccounts:
      final export = KeystoneMultiAccounts.fromUr(ur);
      final matches = export.keys
          .where((k) => _classifyKey(k) == KeystoneEthExportKind.bip44Standard)
          .toList();
      if (matches.length != 1) {
        throw UrDecodeException(
          matches.isEmpty
              ? '$what: no BIP-44 standard account'
              : '$what: more than one BIP-44 standard account',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      key = matches.single;
      final fp = key.origin!.sourceFingerprint;
      if (fp == null) {
        key = key.withOriginFingerprint(export.masterFingerprint);
      } else if (fp != export.masterFingerprint) {
        throw UrDecodeException(
          '$what: key fingerprint differs from the device fingerprint',
          kind: UrDecodeErrorKind.malformed,
        );
      }
    default:
      throw UrDecodeException(
        '$what: unsupported UR type ${ur.type}',
        kind: UrDecodeErrorKind.unexpectedType,
      );
  }
  final k = key.keyData;
  if (k.length != 33 || (k[0] != 0x02 && k[0] != 0x03)) {
    throw UrDecodeException(
      '$what: not a compressed secp256k1 public key',
      kind: UrDecodeErrorKind.malformed,
    );
  }
  if (key.chainCode?.length != 32) {
    throw UrDecodeException('$what: chain code is not 32 bytes', kind: UrDecodeErrorKind.malformed);
  }
  final fp = key.origin!.sourceFingerprint;
  if (fp == null || fp == 0) {
    throw UrDecodeException('$what: missing master fingerprint', kind: UrDecodeErrorKind.malformed);
  }
  return key;
}

/// The keys inside a `crypto-account` (BCR-2020-015) body:
/// `{1: master fingerprint, 2: [output descriptor, …]}`. Keystone writes each
/// Ledger Live output as a bare `#6.303` key; outputs wrapped in script
/// expressions (Bitcoin layouts) are skipped.
List<KeystoneHdKey> _cryptoAccountKeys(List<int> bytes) {
  const what = 'crypto-account';
  return guardDecode(what, () {
    final map = expectIntKeyMap(decodeCbor(bytes, what), what);
    final fp = map[1];
    final outputs = map[2];
    if (fp == null || outputs == null) {
      throw UrDecodeException('$what: missing field', kind: UrDecodeErrorKind.malformed);
    }
    expectUint(fp, what);
    final list = expectList(outputs, what);
    if (list.length > 64) {
      throw UrDecodeException('$what: too many outputs', kind: UrDecodeErrorKind.limitExceeded);
    }
    return [
      for (final o in list)
        if (o.tags.length == 1 && o.tags.single == RegistryTag.cryptoHdKey)
          KeystoneHdKey.fromCborValue(o, tagged: true),
    ];
  });
}
