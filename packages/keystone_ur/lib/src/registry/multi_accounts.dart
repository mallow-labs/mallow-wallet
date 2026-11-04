import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../ur.dart';
import 'cbor_util.dart';
import 'hd_key.dart';

/// `crypto-multi-accounts` (Keystone extension, tag 1103): the account export
/// a Keystone shows under "Connect Software Wallet".
///
/// CBOR map: `1: uint32 master fingerprint`, `2: [#6.303 crypto-hdkey, …]`,
/// `3: device`, `4: device id`, `5: device version`.
class KeystoneMultiAccounts {
  const KeystoneMultiAccounts({
    required this.masterFingerprint,
    required this.keys,
    this.device,
    this.deviceId,
    this.deviceVersion,
  });

  /// Decodes a `crypto-multi-accounts` UR. Throws [UrDecodeException] on a
  /// wrong type, malformed CBOR, or more than [maxKeys] keys.
  factory KeystoneMultiAccounts.fromUr(UR ur, {int maxKeys = 64}) {
    expectUrType(ur, RegistryType.cryptoMultiAccounts);
    return KeystoneMultiAccounts.fromCbor(ur.cbor, maxKeys: maxKeys);
  }

  /// Decodes an untagged `crypto-multi-accounts` CBOR body.
  factory KeystoneMultiAccounts.fromCbor(List<int> bytes, {int maxKeys = 64}) {
    const what = 'crypto-multi-accounts';
    return guardDecode(what, () {
      final map = expectIntKeyMap(decodeCbor(bytes, what), what);
      final fp = map[1];
      final keys = map[2];
      if (fp == null || keys == null) {
        throw UrDecodeException(
          '$what: missing fingerprint or keys',
          kind: UrDecodeErrorKind.malformed,
        );
      }
      final list = expectList(keys, what);
      if (list.length > maxKeys) {
        throw UrDecodeException(
          '$what: ${list.length} keys exceeds the limit of $maxKeys',
          kind: UrDecodeErrorKind.limitExceeded,
        );
      }
      final device = map[3];
      final deviceId = map[4];
      final deviceVersion = map[5];
      return KeystoneMultiAccounts(
        masterFingerprint: expectUint(fp, what),
        keys: List.unmodifiable([
          for (final k in list) KeystoneHdKey.fromCborValue(k, tagged: true),
        ]),
        device: device == null ? null : expectText(device, what),
        deviceId: deviceId == null ? null : expectText(deviceId, what),
        deviceVersion: deviceVersion == null ? null : expectText(deviceVersion, what),
      );
    });
  }

  /// The BIP-32 fingerprint of the device's master key (big-endian uint32).
  /// It identifies the seed, and every sign request must carry it.
  final int masterFingerprint;
  final List<KeystoneHdKey> keys;
  final String? device;
  final String? deviceId;
  final String? deviceVersion;

  /// The untagged CBOR body, keys in ascending order as Keystone writes them.
  Uint8List toCbor() {
    final d = device;
    final id = deviceId;
    final v = deviceVersion;
    return encodeCbor(
      orderedMap({
        1: CborSmallInt(masterFingerprint),
        2: CborList([for (final k in keys) k.toCborValue(tagged: true)]),
        if (d != null) 3: CborString(d),
        if (id != null) 4: CborString(id),
        if (v != null) 5: CborString(v),
      }),
    );
  }

  UR toUr() => UR(RegistryType.cryptoMultiAccounts, toCbor());
}
