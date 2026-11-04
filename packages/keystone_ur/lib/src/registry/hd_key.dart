import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../ur.dart';
import 'cbor_util.dart';
import 'keypath.dart';

/// `crypto-hdkey` (BCR-2020-007, tag 303), public keys only.
///
/// CBOR map: `1: is-master`, `2: is-private`, `3: key-data`, `4: chain-code`,
/// `5: #6.305 use-info {1: coin type, 2: network}`, `6: #6.304 origin`,
/// `7: #6.304 children`, `8: uint32 parent-fingerprint`, `9: name`,
/// `10: note`.
///
/// Keystone exports a Solana account as an Ed25519 key (32-byte [keyData], no
/// [chainCode]) and an Ethereum account as a secp256k1 xpub (33-byte
/// compressed [keyData] plus a 32-byte [chainCode]).
class KeystoneHdKey {
  const KeystoneHdKey({
    required this.keyData,
    this.chainCode,
    this.origin,
    this.children,
    this.parentFingerprint,
    this.name,
    this.note,
    this.useInfoCoinType,
    this.useInfoNetwork,
    this.isPrivate,
  }) : assert(isPrivate != true, 'crypto-hdkey is public-only');

  /// Decodes a `crypto-hdkey` UR. Throws [UrDecodeException].
  factory KeystoneHdKey.fromUr(UR ur) {
    expectUrType(ur, RegistryType.cryptoHdKey);
    return KeystoneHdKey.fromCbor(ur.cbor);
  }

  /// Decodes an untagged `crypto-hdkey` CBOR body. Throws [UrDecodeException].
  factory KeystoneHdKey.fromCbor(List<int> bytes) =>
      guardDecode('crypto-hdkey', () => fromCborValue(decodeCbor(bytes, 'crypto-hdkey')));

  /// Decodes a key map; [tagged] requires (and strips) tag 303, as the key
  /// appears inside `crypto-multi-accounts` and `crypto-account`.
  ///
  /// A private key (`2: true`) is refused: nothing in the wallet should ever
  /// receive one, so it is treated as malformed rather than silently held.
  static KeystoneHdKey fromCborValue(CborValue v, {bool tagged = false}) {
    const what = 'crypto-hdkey';
    final map = expectIntKeyMap(v, what, tag: tagged ? RegistryTag.cryptoHdKey : null);
    final isPrivate = map[2];
    if (isPrivate != null && expectBool(isPrivate, what)) {
      throw UrDecodeException(
        '$what: private keys are not accepted',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    final isMaster = map[1];
    if (isMaster != null) expectBool(isMaster, what);
    final keyData = map[3];
    if (keyData == null) {
      throw UrDecodeException('$what: missing key data', kind: UrDecodeErrorKind.malformed);
    }

    int? coinType;
    int? network;
    final useInfo = map[5];
    if (useInfo != null) {
      final info = expectIntKeyMap(useInfo, what, tag: RegistryTag.cryptoCoinInfo);
      final type = info[1];
      final net = info[2];
      coinType = type == null ? null : expectUint(type, what, max: 0x7FFFFFFF);
      network = net == null ? null : expectUint(net, what);
    }

    final chainCode = map[4];
    final origin = map[6];
    final children = map[7];
    final parentFp = map[8];
    final name = map[9];
    final note = map[10];
    return KeystoneHdKey(
      keyData: expectBytes(keyData, what),
      chainCode: chainCode == null ? null : expectBytes(chainCode, what),
      useInfoCoinType: coinType,
      useInfoNetwork: network,
      isPrivate: isPrivate == null ? null : false,
      origin: origin == null ? null : KeystoneKeypath.fromCborValue(origin, tagged: true),
      children: children == null ? null : KeystoneKeypath.fromCborValue(children, tagged: true),
      parentFingerprint: parentFp == null ? null : expectUint(parentFp, what),
      name: name == null ? null : expectText(name, what),
      note: note == null ? null : expectText(note, what),
    );
  }

  /// The public key: 32 bytes for Ed25519, 33 (compressed) for secp256k1.
  final Uint8List keyData;

  /// The BIP-32 chain code, present on an extended (derivable) key.
  final Uint8List? chainCode;

  /// The path from the master key to this key, usually with the master
  /// fingerprint.
  final KeystoneKeypath? origin;

  /// The path pattern of the keys meant to be derived from this one, e.g.
  /// `0/*` for BIP-44 receive addresses.
  final KeystoneKeypath? children;

  final int? parentFingerprint;
  final String? name;

  /// Keystone's account-type marker: `account.standard`,
  /// `account.ledger_legacy` or `account.ledger_live`.
  final String? note;

  /// SLIP-44 coin type from the use-info (`5: {1: …}`), if present.
  /// BCR-2020-007 reads an absent type as 0 (Bitcoin); this keeps it null so
  /// that re-encoding reproduces the original bytes.
  final int? useInfoCoinType;

  /// The use-info network (`5: {2: …}`): 0 mainnet, 1 testnet.
  final int? useInfoNetwork;

  /// The is-private flag (`2`) as written, which is null or false: some
  /// Keystone exports write an explicit `false`, others omit it, and keeping
  /// the difference makes re-encoding byte-identical. A key with `true` is
  /// refused on decode and cannot be constructed.
  final bool? isPrivate;

  /// The key as a CBOR map, tagged 303 when [tagged]. Fields are written in
  /// ascending key order and only when set, as Keystone's encoder does.
  CborMap toCborValue({bool tagged = false}) {
    final cc = chainCode;
    final o = origin;
    final ch = children;
    final pfp = parentFingerprint;
    final n = name;
    final nt = note;
    final coin = useInfoCoinType;
    final net = useInfoNetwork;
    return orderedMap({
      if (isPrivate != null) 2: CborBool(isPrivate!),
      3: CborBytes(keyData),
      if (cc != null) 4: CborBytes(cc),
      if (coin != null || net != null)
        5: orderedMap({
          if (coin != null) 1: CborSmallInt(coin),
          if (net != null) 2: CborSmallInt(net),
        }, tag: RegistryTag.cryptoCoinInfo),
      if (o != null) 6: o.toCborValue(tagged: true),
      if (ch != null) 7: ch.toCborValue(tagged: true),
      if (pfp != null) 8: CborSmallInt(pfp),
      if (n != null) 9: CborString(n),
      if (nt != null) 10: CborString(nt),
    }, tag: tagged ? RegistryTag.cryptoHdKey : null);
  }

  /// The untagged CBOR body of a `crypto-hdkey` UR.
  Uint8List toCbor() => encodeCbor(toCborValue());

  UR toUr() => UR(RegistryType.cryptoHdKey, toCbor());

  /// A copy whose origin carries [fingerprint] as its source fingerprint.
  KeystoneHdKey withOriginFingerprint(int fingerprint) {
    final o = origin;
    return KeystoneHdKey(
      keyData: keyData,
      chainCode: chainCode,
      origin: o == null
          ? null
          : KeystoneKeypath(
              components: o.components,
              sourceFingerprint: fingerprint,
              depth: o.depth,
            ),
      children: children,
      parentFingerprint: parentFingerprint,
      name: name,
      note: note,
      useInfoCoinType: useInfoCoinType,
      useInfoNetwork: useInfoNetwork,
      isPrivate: isPrivate,
    );
  }

  @override
  String toString() =>
      'KeystoneHdKey(${origin?.toPathString() ?? 'no origin'}, '
      '${keyData.length}-byte key${chainCode == null ? '' : ' + chain code'}'
      '${note == null ? '' : ', $note'})';
}
