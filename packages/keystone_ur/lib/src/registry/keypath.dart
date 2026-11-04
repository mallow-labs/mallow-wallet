import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../ur.dart';
import 'cbor_util.dart';

/// One component of a derivation path. A null [index] is a wildcard (`*`).
class KeypathComponent {
  const KeypathComponent(this.index, {required this.hardened});

  /// The child index without the hardening bit (0..2^31-1), or null for `*`.
  final int? index;
  final bool hardened;

  bool get isWildcard => index == null;

  @override
  bool operator ==(Object other) =>
      other is KeypathComponent && other.index == index && other.hardened == hardened;

  @override
  int get hashCode => Object.hash(index, hardened);

  @override
  String toString() => '${index ?? '*'}${hardened ? "'" : ''}';
}

/// `crypto-keypath` (BCR-2020-007, tag 304): a derivation path, optionally
/// with the master key's fingerprint and the key's depth.
///
/// CBOR map: `1: [index, hardened, …]` (a wildcard is `[]` in the index
/// slot), `2: uint32 source fingerprint`, `3: uint8 depth`. Keys 2 and 3 are
/// written only when set, in that order, matching Keystone's encoder.
class KeystoneKeypath {
  const KeystoneKeypath({required this.components, this.sourceFingerprint, this.depth});

  /// Parses `m/44'/501'/0'/0'`, `44'/501'/0'/0'`, `M/44h/60h/0h/0/*` and the
  /// like. `'`, `h` and `H` all mark hardening; `*` is a wildcard. Throws
  /// [FormatException] on anything else.
  factory KeystoneKeypath.parse(String path, {int? sourceFingerprint}) {
    var p = path.trim();
    if (p == 'm' || p == 'M') p = '';
    if (p.startsWith('m/') || p.startsWith('M/')) p = p.substring(2);
    final components = <KeypathComponent>[];
    if (p.isNotEmpty) {
      for (final raw in p.split('/')) {
        var s = raw;
        var hardened = false;
        if (s.endsWith("'") || s.endsWith('h') || s.endsWith('H')) {
          hardened = true;
          s = s.substring(0, s.length - 1);
        }
        if (s == '*') {
          components.add(KeypathComponent(null, hardened: hardened));
          continue;
        }
        if (!RegExp(r'^[0-9]{1,10}$').hasMatch(s)) {
          throw FormatException('Invalid derivation path component', path);
        }
        final index = int.parse(s);
        if (index >= 0x80000000) {
          throw FormatException('Derivation index out of range', path);
        }
        components.add(KeypathComponent(index, hardened: hardened));
      }
    }
    if (sourceFingerprint != null && (sourceFingerprint < 0 || sourceFingerprint > 0xFFFFFFFF)) {
      throw ArgumentError.value(sourceFingerprint, 'sourceFingerprint', 'not a uint32');
    }
    return KeystoneKeypath(components: components, sourceFingerprint: sourceFingerprint);
  }

  /// Decodes an untagged `crypto-keypath` CBOR body.
  factory KeystoneKeypath.fromCbor(List<int> bytes) =>
      guardDecode('crypto-keypath', () => fromCborValue(decodeCbor(bytes, 'crypto-keypath')));

  /// Decodes a `crypto-keypath` UR.
  factory KeystoneKeypath.fromUr(UR ur) {
    expectUrType(ur, RegistryType.cryptoKeypath);
    return KeystoneKeypath.fromCbor(ur.cbor);
  }

  /// Decodes a keypath map. [tagged] requires (and strips) tag 304, as the
  /// keypath appears inside other registry types.
  static KeystoneKeypath fromCborValue(CborValue v, {bool tagged = false}) {
    const what = 'crypto-keypath';
    final map = expectIntKeyMap(v, what, tag: tagged ? RegistryTag.cryptoKeypath : null);
    final rawComponents = map[1];
    if (rawComponents == null) {
      throw UrDecodeException('$what: missing components', kind: UrDecodeErrorKind.malformed);
    }
    final list = expectList(rawComponents, what);
    if (list.length.isOdd) {
      throw UrDecodeException('$what: odd component array', kind: UrDecodeErrorKind.malformed);
    }
    final components = <KeypathComponent>[];
    for (var i = 0; i < list.length; i += 2) {
      final indexValue = list[i];
      final int? index;
      if (indexValue is CborList) {
        if (indexValue.isNotEmpty || indexValue.tags.isNotEmpty) {
          // A non-empty array is a BCR range or pair; Keystone never sends one.
          throw UrDecodeException(
            '$what: unsupported component',
            kind: UrDecodeErrorKind.malformed,
          );
        }
        index = null;
      } else {
        index = expectUint(indexValue, what, max: 0x7FFFFFFF);
      }
      components.add(KeypathComponent(index, hardened: expectBool(list[i + 1], what)));
    }
    final fp = map[2];
    final depth = map[3];
    return KeystoneKeypath(
      components: components,
      sourceFingerprint: fp == null ? null : expectUint(fp, what),
      depth: depth == null ? null : expectUint(depth, what, max: 255),
    );
  }

  final List<KeypathComponent> components;

  /// The master key fingerprint (BIP-32, big-endian uint32), if present.
  final int? sourceFingerprint;

  /// The depth of the key this path leads to, if present.
  final int? depth;

  /// `m/44'/501'/0'/0'`; `m` for an empty path.
  String toPathString() =>
      components.isEmpty ? 'm' : 'm/${components.map((c) => c.toString()).join('/')}';

  /// A copy with [depth] removed — the form Keystone's sign-request encoders
  /// write.
  KeystoneKeypath withoutDepth() =>
      KeystoneKeypath(components: components, sourceFingerprint: sourceFingerprint);

  /// The keypath as a CBOR map, tagged 304 when [tagged].
  CborMap toCborValue({bool tagged = false}) {
    final array = <CborValue>[];
    for (final c in components) {
      final index = c.index;
      array
        ..add(index == null ? CborList(const []) : CborSmallInt(index))
        ..add(CborBool(c.hardened));
    }
    final fp = sourceFingerprint;
    final d = depth;
    return orderedMap({
      1: CborList(array),
      if (fp != null) 2: CborSmallInt(fp),
      if (d != null) 3: CborSmallInt(d),
    }, tag: tagged ? RegistryTag.cryptoKeypath : null);
  }

  /// The untagged CBOR body of a `crypto-keypath` UR.
  Uint8List toCbor() => encodeCbor(toCborValue());

  UR toUr() => UR(RegistryType.cryptoKeypath, toCbor());

  @override
  bool operator ==(Object other) {
    if (other is! KeystoneKeypath ||
        other.sourceFingerprint != sourceFingerprint ||
        other.depth != depth ||
        other.components.length != components.length) {
      return false;
    }
    for (var i = 0; i < components.length; i++) {
      if (other.components[i] != components[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(components), sourceFingerprint, depth);

  @override
  String toString() {
    final fp = sourceFingerprint;
    final fpHex = fp == null ? '' : ' [${fp.toRadixString(16).padLeft(8, '0')}]';
    return 'KeystoneKeypath(${toPathString()}$fpHex${depth == null ? '' : ' depth $depth'})';
  }
}
