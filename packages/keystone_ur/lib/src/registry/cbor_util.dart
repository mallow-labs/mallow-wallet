import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../cbor_shape.dart';
import '../ur.dart';

/// Registry tags. Keystone uses the original Blockchain Commons numbers
/// (BCR-2020-006), not the later 40000-range replacements.
abstract final class RegistryTag {
  static const int uuid = 37;
  static const int cryptoHdKey = 303;
  static const int cryptoKeypath = 304;
  static const int cryptoCoinInfo = 305;
  static const int cryptoAccount = 311;
  static const int ethSignRequest = 401;
  static const int ethSignature = 402;
  static const int solSignRequest = 1101;
  static const int solSignature = 1102;
  static const int cryptoMultiAccounts = 1103;
}

/// Registry type names, as they appear in a UR string.
abstract final class RegistryType {
  static const String cryptoHdKey = 'crypto-hdkey';
  static const String cryptoKeypath = 'crypto-keypath';
  static const String cryptoAccount = 'crypto-account';
  static const String ethSignRequest = 'eth-sign-request';
  static const String ethSignature = 'eth-signature';
  static const String solSignRequest = 'sol-sign-request';
  static const String solSignature = 'sol-signature';
  static const String cryptoMultiAccounts = 'crypto-multi-accounts';
}

/// Runs [body], converting anything it throws other than a
/// [UrDecodeException] into one. Every public decode entry point goes through
/// this, so malformed input can never escape as a `TypeError` or `RangeError`.
T guardDecode<T>(String what, T Function() body) {
  try {
    return body();
  } on UrDecodeException {
    rethrow;
  } on Object {
    throw UrDecodeException('$what: malformed', kind: UrDecodeErrorKind.malformed);
  }
}

/// Checks that [ur] has type [type].
void expectUrType(UR ur, String type) {
  if (ur.type != type) {
    throw UrDecodeException(
      'expected a $type UR, got ${ur.type}',
      kind: UrDecodeErrorKind.unexpectedType,
    );
  }
}

/// Decodes exactly one CBOR item; trailing bytes are an error.
///
/// The bytes pass [cborShapeError] first, so hostile nesting is refused in
/// linear time before the recursive decoder sees it.
CborValue decodeCbor(List<int> bytes, String what) {
  final shape = cborShapeError(bytes);
  if (shape != null) {
    throw UrDecodeException('$what: malformed CBOR ($shape)', kind: UrDecodeErrorKind.malformed);
  }
  try {
    return cborDecode(bytes);
  } on Object {
    throw UrDecodeException('$what: malformed CBOR', kind: UrDecodeErrorKind.malformed);
  }
}

Uint8List encodeCbor(CborValue value) => Uint8List.fromList(cborEncode(value));

void _expectTag(CborValue v, int? tag, String what) {
  final ok = tag == null ? v.tags.isEmpty : (v.tags.length == 1 && v.tags.single == tag);
  if (!ok) {
    throw UrDecodeException(
      tag == null ? '$what: unexpected CBOR tag' : '$what: expected CBOR tag $tag',
      kind: UrDecodeErrorKind.malformed,
    );
  }
}

/// [v] as a map with unsigned-integer keys. Keys of any other kind are an
/// error; unknown integer keys are kept and ignored by callers, as Keystone's
/// own decoders ignore them. [decodeCbor] rejects duplicate integer keys in
/// the raw bytes before the CBOR decoder collapses equal keys.
Map<int, CborValue> expectIntKeyMap(CborValue v, String what, {int? tag}) {
  if (v is! CborMap) {
    throw UrDecodeException('$what: expected a map', kind: UrDecodeErrorKind.malformed);
  }
  _expectTag(v, tag, what);
  final out = <int, CborValue>{};
  for (final e in v.entries) {
    final k = e.key;
    if (k is! CborSmallInt || k.tags.isNotEmpty || k.value < 0) {
      throw UrDecodeException('$what: unexpected map key', kind: UrDecodeErrorKind.malformed);
    }
    out[k.value] = e.value;
  }
  return out;
}

Uint8List expectBytes(CborValue v, String what, {int? tag}) {
  if (v is! CborBytes || v is CborBigInt) {
    throw UrDecodeException('$what: expected bytes', kind: UrDecodeErrorKind.malformed);
  }
  _expectTag(v, tag, what);
  return Uint8List.fromList(v.bytes);
}

/// An unsigned integer no larger than [max].
int expectUint(CborValue v, String what, {int max = 0xFFFFFFFF}) {
  if (v is! CborSmallInt || v.value < 0 || v.value > max) {
    throw UrDecodeException(
      '$what: expected an unsigned integer',
      kind: UrDecodeErrorKind.malformed,
    );
  }
  _expectTag(v, null, what);
  return v.value;
}

String expectText(CborValue v, String what) {
  if (v is! CborString) {
    throw UrDecodeException('$what: expected text', kind: UrDecodeErrorKind.malformed);
  }
  _expectTag(v, null, what);
  try {
    return v.toString();
  } on Object {
    throw UrDecodeException('$what: invalid UTF-8', kind: UrDecodeErrorKind.malformed);
  }
}

bool expectBool(CborValue v, String what) {
  if (v is! CborBool) {
    throw UrDecodeException('$what: expected a boolean', kind: UrDecodeErrorKind.malformed);
  }
  _expectTag(v, null, what);
  return v.value;
}

List<CborValue> expectList(CborValue v, String what) {
  if (v is! CborList) {
    throw UrDecodeException('$what: expected an array', kind: UrDecodeErrorKind.malformed);
  }
  _expectTag(v, null, what);
  return v;
}

/// A map whose keys are written in ascending order — the order Keystone's
/// encoders emit, which byte-identical output depends on.
CborMap orderedMap(Map<int, CborValue> entries, {int? tag}) {
  final keys = entries.keys.toList()..sort();
  return CborMap.fromEntries([
    for (final k in keys) MapEntry(CborSmallInt(k), entries[k]!),
  ], tags: tag == null ? const [] : [tag]);
}

/// [value] with [tag] applied (the cbor package keeps tags on the value).
CborValue tagged(CborValue value, int tag) => switch (value) {
  CborMap m => CborMap.fromEntries(m.entries, tags: [tag]),
  CborBytes b => CborBytes(b.bytes, tags: [tag]),
  _ => throw ArgumentError('cannot tag ${value.runtimeType}'),
};
