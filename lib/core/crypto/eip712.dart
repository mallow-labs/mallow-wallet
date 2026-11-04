import 'dart:convert';
import 'dart:typed_data';

import 'package:web3dart/web3dart.dart' show keccak256;

/// A typed-data payload this wallet refuses to encode. The message never
/// carries the payload itself, so it is safe to show and to return to the
/// website.
class Eip712Exception implements Exception {
  const Eip712Exception(this.message);
  final String message;
  @override
  String toString() => 'Eip712Exception($message)';
}

class Eip712Field {
  const Eip712Field(this.name, this.type);
  final String name;
  final String type;
}

/// A validated `eth_signTypedData_v4` payload and its EIP-712 digest.
///
/// Everything a review shows comes from here, and [digest] is computed from
/// the same parsed values, so what the user reads is what gets signed. The
/// website's JSON is never re-read after [Eip712TypedData.parse].
class Eip712TypedData {
  Eip712TypedData._({
    required this.types,
    required this.primaryType,
    required this.domain,
    required this.message,
    required this.domainSeparator,
    required this.structHash,
  });

  /// Parses and hashes [raw] — the JSON string or object a website passed to
  /// `eth_signTypedData_v4`. Strict where the reference implementations are
  /// lenient: an unknown type, a missing field, an out-of-range integer or an
  /// extra domain key is refused rather than guessed at, because a value that
  /// is silently coerced is one the review may show differently from how it
  /// was hashed.
  factory Eip712TypedData.parse(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      if (raw.length > 65536) {
        throw const Eip712Exception('Typed data is too large.');
      }
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const Eip712Exception('Typed data is not valid JSON.');
      }
    }
    if (decoded is! Map) {
      throw const Eip712Exception('Typed data must be an object.');
    }
    final rawTypes = decoded['types'];
    final primaryType = decoded['primaryType'];
    final rawDomain = decoded['domain'] ?? const <String, Object?>{};
    final rawMessage = decoded['message'];
    if (rawTypes is! Map || primaryType is! String || rawDomain is! Map) {
      throw const Eip712Exception(
        'Typed data needs types, a primary type and a domain.',
      );
    }
    if (rawTypes.length > _maxTypes) {
      throw const Eip712Exception('Typed data defines too many types.');
    }
    final types = <String, List<Eip712Field>>{};
    for (final entry in rawTypes.entries) {
      final name = entry.key;
      final fields = entry.value;
      if (name is! String || !_typeName.hasMatch(name) || fields is! List) {
        throw const Eip712Exception('Typed data has an invalid type name.');
      }
      if (fields.length > _maxFields) {
        throw Eip712Exception('Type $name has too many fields.');
      }
      final seen = <String>{};
      types[name] = [
        for (final field in fields)
          if (field is Map &&
              field['name'] is String &&
              field['type'] is String &&
              _fieldName.hasMatch(field['name'] as String) &&
              seen.add(field['name'] as String))
            Eip712Field(field['name'] as String, field['type'] as String)
          else
            throw Eip712Exception('Type $name has an invalid field.'),
      ];
    }
    final domain = Map<String, Object?>.from(rawDomain);
    if (types['EIP712Domain'] == null) {
      types['EIP712Domain'] = [
        for (final field in _domainFields)
          if (domain.containsKey(field.name)) field,
      ];
    }
    final domainType = types['EIP712Domain']!;
    for (final key in domain.keys) {
      if (!domainType.any((field) => field.name == key)) {
        throw Eip712Exception('Domain field $key is not declared.');
      }
    }
    for (final field in domainType) {
      final standard = _domainFields
          .where((f) => f.name == field.name)
          .firstOrNull;
      if (standard == null || standard.type != field.type) {
        throw Eip712Exception('Domain field ${field.name} is not standard.');
      }
    }
    // Validate every field type before hashing anything, including types the
    // primary type does not reach: they are never hashed, but a reviewer
    // could still be shown them.
    for (final entry in types.entries) {
      for (final field in entry.value) {
        _checkType(field.type, types);
      }
    }
    if (!types.containsKey(primaryType)) {
      throw Eip712Exception('Primary type $primaryType is not defined.');
    }
    final encoder = _Encoder(types);
    final domainSeparator = encoder.hashStruct('EIP712Domain', domain, 0);
    final Map<String, Object?> message;
    final Uint8List structHash;
    if (primaryType == 'EIP712Domain') {
      message = const {};
      structHash = Uint8List(0);
    } else {
      if (rawMessage is! Map) {
        throw const Eip712Exception('Typed data message must be an object.');
      }
      message = Map<String, Object?>.from(rawMessage);
      structHash = encoder.hashStruct(primaryType, message, 0);
    }
    return Eip712TypedData._(
      types: Map.unmodifiable(types),
      primaryType: primaryType,
      domain: Map.unmodifiable(domain),
      message: Map.unmodifiable(message),
      domainSeparator: domainSeparator,
      structHash: structHash,
    );
  }

  /// Struct definitions, `EIP712Domain` included.
  final Map<String, List<Eip712Field>> types;
  final String primaryType;
  final Map<String, Object?> domain;
  final Map<String, Object?> message;
  final Uint8List domainSeparator;

  /// `hashStruct(primaryType, message)`; empty for a domain-only payload.
  final Uint8List structHash;

  /// `keccak256(0x1901 ‖ domainSeparator ‖ structHash)` — the 32 bytes that are
  /// signed. A payload whose primary type is `EIP712Domain` signs
  /// `0x1901 ‖ domainSeparator` alone, as the reference implementations do.
  Uint8List get digest => keccak256(
    Uint8List.fromList([0x19, 0x01, ...domainSeparator, ...structHash]),
  );

  /// The payload as `eth_signTypedData_v4` JSON for a signer that hashes the
  /// JSON itself (a Keystone), built from [canonicalDomain] and
  /// [canonicalMessage] — the values [digest] was computed from — and never
  /// from the website's string. Integers are written as decimal strings and
  /// bytes and addresses as `0x` hex, so no value depends on how a JSON
  /// number was parsed (an integral `1.0`, or an integer past 2^53). The
  /// signer's result must still be checked against [digest].
  String get json => jsonEncode({
    'types': {
      for (final MapEntry(key: name, value: fields) in types.entries)
        name: [
          for (final field in fields) {'name': field.name, 'type': field.type},
        ],
    },
    'primaryType': primaryType,
    'domain': _jsonValue(canonicalDomain),
    'message': _jsonValue(canonicalMessage),
  });

  static Object? _jsonValue(Object? value) => switch (value) {
    BigInt() => value.toString(),
    Uint8List() =>
      '0x${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    List() => [for (final item in value) _jsonValue(item)],
    Map() => {
      for (final MapEntry(:key, value: item) in value.entries)
        key as String: _jsonValue(item),
    },
    _ => value,
  };

  /// The domain's `chainId` as an integer, or null when the domain has none.
  BigInt? get chainId => domain['chainId'] == null
      ? null
      : _integer(domain['chainId'], 'chainId', bits: 256, signed: false);

  /// [domain] with every leaf in canonical form: integers as [BigInt],
  /// booleans as [bool], addresses and `bytes`/`bytesN` as [Uint8List],
  /// strings as [String]; arrays as [List] and structs as [Map] in declared
  /// field order. Converted by the same rules that produced [digest], so a
  /// signer that re-hashes these values (a hardware wallet) signs exactly the
  /// payload that was reviewed.
  Map<String, Object?> get canonicalDomain =>
      _Canonicalizer(types).struct('EIP712Domain', domain);

  /// [message] in the canonical form of [canonicalDomain]; empty for a
  /// domain-only payload.
  Map<String, Object?> get canonicalMessage => primaryType == 'EIP712Domain'
      ? const {}
      : _Canonicalizer(types).struct(primaryType, message);

  /// The domain's `verifyingContract`, lower-cased, or null.
  String? get verifyingContract {
    final value = domain['verifyingContract'];
    return value is String ? value.toLowerCase() : null;
  }

  static const _maxTypes = 64;
  static const _maxFields = 64;
  static const _maxDepth = 12;
  static const _maxArrayLength = 1024;
  static const _maxValues = 8192;

  static final _typeName = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,63}$');
  static final _fieldName = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,63}$');
  static final _arraySuffix = RegExp(r'^(.+)\[(\d*)\]$');
  static final _intType = RegExp(r'^(u?)int(\d{0,3})$');
  static final _bytesType = RegExp(r'^bytes(\d{1,2})$');

  /// Domain fields in the order EIP-712 implementations derive them when a
  /// payload omits its `EIP712Domain` definition.
  static const _domainFields = [
    Eip712Field('name', 'string'),
    Eip712Field('version', 'string'),
    Eip712Field('chainId', 'uint256'),
    Eip712Field('verifyingContract', 'address'),
    Eip712Field('salt', 'bytes32'),
  ];

  static void _checkType(String type, Map<String, List<Eip712Field>> types) {
    final array = _arraySuffix.firstMatch(type);
    if (array != null) {
      final length = array.group(2)!;
      if (length.isNotEmpty) {
        final n = int.parse(length);
        if (n < 1 || n > _maxArrayLength) {
          throw Eip712Exception('Array type $type has an invalid length.');
        }
      }
      _checkType(array.group(1)!, types);
      return;
    }
    if (types.containsKey(type)) return;
    if (const {'address', 'bool', 'string', 'bytes'}.contains(type)) return;
    final integer = _intType.firstMatch(type);
    if (integer != null) {
      final bits = integer.group(2)!.isEmpty
          ? 256
          : int.parse(integer.group(2)!);
      if (bits < 8 || bits > 256 || bits % 8 != 0) {
        throw Eip712Exception('Integer type $type is invalid.');
      }
      return;
    }
    final bytes = _bytesType.firstMatch(type);
    if (bytes != null) {
      final n = int.parse(bytes.group(1)!);
      if (n < 1 || n > 32)
        throw Eip712Exception('Bytes type $type is invalid.');
      return;
    }
    throw Eip712Exception('Type $type is not defined.');
  }
}

class _Encoder {
  _Encoder(this.types);
  final Map<String, List<Eip712Field>> types;
  int _values = 0;

  /// `encodeType`: the primary type, then every type it references, sorted.
  String encodeType(String primary) {
    final deps = <String>{};
    void collect(String type) {
      final base = _baseType(type);
      if (!types.containsKey(base) || !deps.add(base)) return;
      for (final field in types[base]!) {
        collect(field.type);
      }
    }

    collect(primary);
    deps.remove(primary);
    return [primary, ...deps.toList()..sort()]
        .map(
          (name) =>
              '$name(${types[name]!.map((f) => '${f.type} ${f.name}').join(',')})',
        )
        .join();
  }

  Uint8List hashStruct(String type, Map<String, Object?> value, int depth) {
    if (depth > Eip712TypedData._maxDepth) {
      throw const Eip712Exception('Typed data is nested too deeply.');
    }
    final fields = types[type]!;
    for (final key in value.keys) {
      if (!fields.any((field) => field.name == key)) {
        throw Eip712Exception('$type has an undeclared field $key.');
      }
    }
    final out = BytesBuilder(copy: false)
      ..add(keccak256(Uint8List.fromList(utf8.encode(encodeType(type)))));
    for (final field in fields) {
      if (!value.containsKey(field.name)) {
        throw Eip712Exception('$type is missing ${field.name}.');
      }
      out.add(_encodeField(field.type, value[field.name], field.name, depth));
    }
    return keccak256(out.toBytes());
  }

  Uint8List _encodeField(String type, Object? value, String name, int depth) {
    if (++_values > Eip712TypedData._maxValues) {
      throw const Eip712Exception('Typed data has too many values.');
    }
    final array = Eip712TypedData._arraySuffix.firstMatch(type);
    if (array != null) {
      if (value is! List) throw Eip712Exception('$name must be an array.');
      final fixed = array.group(2)!;
      if (fixed.isNotEmpty && value.length != int.parse(fixed)) {
        throw Eip712Exception('$name must have $fixed items.');
      }
      if (value.length > Eip712TypedData._maxArrayLength) {
        throw Eip712Exception('$name has too many items.');
      }
      final out = BytesBuilder(copy: false);
      for (final item in value) {
        out.add(_encodeField(array.group(1)!, item, name, depth + 1));
      }
      return keccak256(out.toBytes());
    }
    if (types.containsKey(type)) {
      if (value is! Map) throw Eip712Exception('$name must be an object.');
      return hashStruct(type, Map<String, Object?>.from(value), depth + 1);
    }
    switch (type) {
      case 'string':
        if (value is! String) throw Eip712Exception('$name must be a string.');
        return keccak256(Uint8List.fromList(utf8.encode(value)));
      case 'bytes':
        return keccak256(_hexBytes(value, name));
      case 'bool':
        if (value is! bool)
          throw Eip712Exception('$name must be true or false.');
        return _word(value ? BigInt.one : BigInt.zero);
      case 'address':
        return _word(_hexInt(_address(value, name), name));
    }
    final integer = Eip712TypedData._intType.firstMatch(type);
    if (integer != null) {
      final bits = integer.group(2)!.isEmpty
          ? 256
          : int.parse(integer.group(2)!);
      final number = _integer(
        value,
        name,
        bits: bits,
        signed: integer.group(1)!.isEmpty,
      );
      return _word(number.toUnsigned(256));
    }
    final size = int.parse(
      Eip712TypedData._bytesType.firstMatch(type)!.group(1)!,
    );
    final bytes = _hexBytes(value, name);
    if (bytes.length != size) {
      throw Eip712Exception('$name must be $size bytes.');
    }
    return Uint8List(32)..setRange(0, size, bytes);
  }
}

/// Mirrors [_Encoder]'s traversal and value rules, but returns each value in
/// canonical form instead of its hash. The payload was already validated by
/// [Eip712TypedData.parse], so a failure here is a bug, not bad input.
class _Canonicalizer {
  _Canonicalizer(this.types);
  final Map<String, List<Eip712Field>> types;

  Map<String, Object?> struct(String type, Map<String, Object?> value) => {
    for (final field in types[type]!)
      field.name: _value(field.type, value[field.name], field.name),
  };

  Object? _value(String type, Object? value, String name) {
    final array = Eip712TypedData._arraySuffix.firstMatch(type);
    if (array != null) {
      if (value is! List) throw Eip712Exception('$name must be an array.');
      return List<Object?>.unmodifiable([
        for (final item in value) _value(array.group(1)!, item, name),
      ]);
    }
    if (types.containsKey(type)) {
      if (value is! Map) throw Eip712Exception('$name must be an object.');
      return Map<String, Object?>.unmodifiable(
        struct(type, Map<String, Object?>.from(value)),
      );
    }
    switch (type) {
      case 'string':
        if (value is! String) throw Eip712Exception('$name must be a string.');
        return value;
      case 'bytes':
        return _hexBytes(value, name);
      case 'bool':
        if (value is! bool) {
          throw Eip712Exception('$name must be true or false.');
        }
        return value;
      case 'address':
        return _hexBytes(_address(value, name), name);
    }
    final integer = Eip712TypedData._intType.firstMatch(type);
    if (integer != null) {
      final bits = integer.group(2)!.isEmpty
          ? 256
          : int.parse(integer.group(2)!);
      return _integer(
        value,
        name,
        bits: bits,
        signed: integer.group(1)!.isEmpty,
      );
    }
    return _hexBytes(value, name);
  }
}

String _baseType(String type) {
  final bracket = type.indexOf('[');
  return bracket < 0 ? type : type.substring(0, bracket);
}

Uint8List _word(BigInt value) {
  final out = Uint8List(32);
  var remaining = value;
  for (var i = 31; i >= 0 && remaining > BigInt.zero; i--) {
    out[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return out;
}

final _hex = RegExp(r'^0x[0-9a-fA-F]*$');
final _decimal = RegExp(r'^-?[0-9]+$');

String _address(Object? value, String name) {
  if (value is! String || value.length != 42 || !_hex.hasMatch(value)) {
    throw Eip712Exception('$name must be an address.');
  }
  return value;
}

BigInt _hexInt(String value, String name) => value.length == 2
    ? BigInt.zero
    : BigInt.parse(value.substring(2), radix: 16);

Uint8List _hexBytes(Object? value, String name) {
  if (value is! String || !_hex.hasMatch(value) || value.length.isOdd) {
    throw Eip712Exception('$name must be 0x-prefixed hex bytes.');
  }
  final out = Uint8List((value.length - 2) ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(value.substring(2 + i * 2, 4 + i * 2), radix: 16);
  }
  return out;
}

/// An integer field as JSON number, decimal string or 0x hex string. A JSON
/// number beyond 2^53 has already lost precision in the website's JSON, so it
/// is refused rather than signed as some nearby value.
BigInt _integer(
  Object? value,
  String name, {
  required int bits,
  required bool signed,
}) {
  final BigInt number;
  if (value is int) {
    if (value.abs() > 9007199254740991) {
      throw Eip712Exception('$name is too large for a JSON number.');
    }
    number = BigInt.from(value);
  } else if (value is double) {
    if (value != value.truncateToDouble() || value.abs() > 9007199254740991) {
      throw Eip712Exception('$name must be a whole number.');
    }
    number = BigInt.from(value);
  } else if (value is String && value.length <= 80 && _hex.hasMatch(value)) {
    number = value.length == 2
        ? BigInt.zero
        : BigInt.parse(value.substring(2), radix: 16);
  } else if (value is String &&
      value.length <= 80 &&
      _decimal.hasMatch(value)) {
    number = BigInt.parse(value);
  } else {
    throw Eip712Exception('$name must be an integer.');
  }
  final min = signed ? -(BigInt.one << (bits - 1)) : BigInt.zero;
  final max = signed
      ? (BigInt.one << (bits - 1)) - BigInt.one
      : (BigInt.one << bits) - BigInt.one;
  if (number < min || number > max) {
    throw Eip712Exception('$name is out of range.');
  }
  return number;
}

/// [_integer] for callers outside this file that read a parsed payload's
/// numeric fields for display.
BigInt? eip712Integer(Object? value) {
  try {
    return _integer(value, 'value', bits: 256, signed: false);
  } on Eip712Exception {
    return null;
  }
}
