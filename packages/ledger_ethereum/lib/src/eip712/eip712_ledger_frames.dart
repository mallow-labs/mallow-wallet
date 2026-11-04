import 'dart:convert';
import 'dart:typed_data';

import '../ethereum_apdu.dart';

/// One field of an EIP-712 struct type.
class Eip712LedgerField {
  const Eip712LedgerField(this.name, this.type);
  final String name;

  /// The Solidity type as written in the payload, e.g. `uint256`, `Person`,
  /// `address[]`.
  final String type;
}

/// EIP-712 typed data, already validated and in canonical form, ready to be
/// streamed to the Ethereum app for on-device hashing.
///
/// Leaf values must be canonical, not JSON: integers as [BigInt], booleans as
/// [bool], addresses and `bytes` / `bytesN` as [Uint8List], strings as
/// [String]. Arrays are [List]s and structs are [Map]s keyed by field name.
/// The device recomputes the digest from exactly these values, so they must
/// be the ones the host's own review hashed.
class Eip712LedgerMessage {
  const Eip712LedgerMessage({
    required this.types,
    required this.primaryType,
    required this.domain,
    required this.message,
  });

  /// Every struct type, `EIP712Domain` included, with fields in declared
  /// order.
  final Map<String, List<Eip712LedgerField>> types;
  final String primaryType;
  final Map<String, Object?> domain;
  final Map<String, Object?> message;
}

/// Typed data this package cannot stream to the device. The message names
/// the field or type, never a value.
class Eip712LedgerException implements Exception {
  const Eip712LedgerException(this.message);
  final String message;
  @override
  String toString() => 'Eip712LedgerException($message)';
}

/// One APDU of an Ethereum app exchange, before it is framed.
class EthereumApduFrame {
  const EthereumApduFrame({
    required this.ins,
    required this.p1,
    required this.p2,
    required this.data,
    this.returnsSignature = false,
  });
  final int ins;
  final int p1;
  final int p2;
  final Uint8List data;

  /// The device answers this frame with `[v][r][s]` rather than a bare
  /// status word.
  final bool returnsSignature;
}

/// The APDU stream that has the Ethereum app hash and sign [message] itself
/// ("full implementation", app version 1.9.19 or later), at the derivation
/// path [pathBytes] (as `EthereumDerivationPath.toBytes` encodes it).
///
/// Order, per the app's EIP-712 protocol: every struct definition (name,
/// then one APDU per field), then the `EIP712Domain` values, then the primary
/// type's values, then the sign command. Values follow the declared field
/// order, depth first; the device tracks which field comes next, so the
/// order is the protocol. With the app's Raw messages setting on, the device
/// shows the fields as they arrive, so the APDUs carrying values can each
/// wait on the user. With only Blind signing on, it shows the domain and the
/// message hash. With neither, it answers the first value APDU with 0x6A80.
/// Display metadata signed by Ledger would lift that requirement; this
/// stream sends none.
///
/// Throws [Eip712LedgerException] for payloads the protocol cannot carry:
/// a domain-only payload, an array of more than 255 items, a multi-level
/// array with a fixed size, or a value or name too long for its length byte.
List<EthereumApduFrame> eip712LedgerFrames(
  Eip712LedgerMessage message,
  Uint8List pathBytes,
) {
  if (message.primaryType == 'EIP712Domain') {
    throw const Eip712LedgerException(
      'A domain-only signature cannot be signed on this device.',
    );
  }
  final types = message.types;
  final domainType = types['EIP712Domain'];
  if (domainType == null || !types.containsKey(message.primaryType)) {
    throw const Eip712LedgerException('Typed data is missing a struct type.');
  }
  final frames = <EthereumApduFrame>[];

  // Sorted by name, as the reference client sends them; the device sorts
  // dependencies itself when it builds each type hash, so the order of the
  // definitions does not change the digest.
  for (final name in types.keys.toList()..sort()) {
    if (_primitive(name)) {
      throw Eip712LedgerException('Type $name shadows a built-in type.');
    }
    frames.add(
      _frame(
        EthereumApdu.insEip712StructDefinition,
        EthereumApdu.p2Eip712Name,
        _name(name),
      ),
    );
    for (final field in types[name]!) {
      frames.add(
        _frame(
          EthereumApdu.insEip712StructDefinition,
          EthereumApdu.p2Eip712Field,
          _fieldDefinition(field, types),
        ),
      );
    }
  }

  void root(String name, Map<String, Object?> value) {
    frames.add(
      _frame(
        EthereumApdu.insEip712StructImplementation,
        EthereumApdu.p2Eip712Name,
        _name(name),
      ),
    );
    for (final field in types[name]!) {
      _values(
        frames,
        _TypeShape.parse(field.type, types),
        value[field.name],
        field.name,
        types,
      );
    }
  }

  root('EIP712Domain', message.domain);
  root(message.primaryType, message.message);

  frames.add(
    EthereumApduFrame(
      ins: EthereumApdu.insSignEip712,
      p1: 0x00,
      p2: EthereumApdu.p2Eip712Full,
      data: pathBytes,
      returnsSignature: true,
    ),
  );
  return frames;
}

/// The single APDU that signs a host-computed EIP-712 [domainSeparator] and
/// [messageHash] ("v0", for app versions before 1.9.19). The device shows
/// the two hashes, not the fields, and refuses with 0x6A80 unless Blind
/// signing is on.
EthereumApduFrame eip712LedgerHashesFrame(
  Uint8List pathBytes, {
  required Uint8List domainSeparator,
  required Uint8List messageHash,
}) {
  if (domainSeparator.length != 32 || messageHash.length != 32) {
    throw const Eip712LedgerException('EIP-712 hashes are 32 bytes.');
  }
  return EthereumApduFrame(
    ins: EthereumApdu.insSignEip712,
    p1: 0x00,
    p2: EthereumApdu.p2Eip712Hashes,
    data:
        Uint8List.fromList([...pathBytes, ...domainSeparator, ...messageHash]),
    returnsSignature: true,
  );
}

EthereumApduFrame _frame(int ins, int p2, Uint8List data, {int p1 = 0x00}) {
  if (data.length > 255) {
    throw const Eip712LedgerException('An APDU is longer than 255 bytes.');
  }
  return EthereumApduFrame(ins: ins, p1: p1, p2: p2, data: data);
}

Uint8List _name(String name) {
  final bytes = utf8.encode(name);
  if (bytes.isEmpty || bytes.length > 255) {
    throw Eip712LedgerException('Name $name is too long.');
  }
  return Uint8List.fromList(bytes);
}

/// Type ids from the app's EIP-712 field definition.
const _custom = 0, _int = 1, _uint = 2, _address = 3, _bool = 4, _string = 5;
const _fixedBytes = 6, _dynamicBytes = 7;

final _typePattern = RegExp(r'^([A-Za-z_$][A-Za-z0-9_$]*)((?:\[\d*\])*)$');
final _dimensionPattern = RegExp(r'\[(\d*)\]');
final _integerPattern = RegExp(r'^(u?)int(\d{0,3})$');
final _bytesPattern = RegExp(r'^bytes(\d{1,2})$');

bool _primitive(String name) =>
    const {'address', 'bool', 'string', 'bytes'}.contains(name) ||
    _integerPattern.hasMatch(name) ||
    _bytesPattern.hasMatch(name);

class _TypeShape {
  _TypeShape({
    required this.id,
    required this.base,
    required this.size,
    required this.dimensions,
  });

  /// One of the type ids above.
  final int id;

  /// The struct name for a custom type, else the primitive's name.
  final String base;

  /// Byte size of an `intN` / `uintN` / `bytesN`, else null.
  final int? size;

  /// Array levels as written, null for a dynamic level.
  final List<int?> dimensions;

  _TypeShape get element => _TypeShape(
        id: id,
        base: base,
        size: size,
        dimensions: dimensions.sublist(1),
      );

  static _TypeShape parse(
    String type,
    Map<String, List<Eip712LedgerField>> types,
  ) {
    final match = _typePattern.firstMatch(type);
    if (match == null) throw Eip712LedgerException('Type $type is invalid.');
    final base = match.group(1)!;
    final dimensions = [
      for (final level in _dimensionPattern.allMatches(match.group(2)!))
        level.group(1)!.isEmpty ? null : int.parse(level.group(1)!),
    ];
    // Which written level a fixed size applies to is read innermost-first by
    // Solidity and is not specified for the app's array levels. With every
    // level dynamic the order cannot matter, so that is the only multi-level
    // shape sent.
    if (dimensions.length > 1 && dimensions.any((size) => size != null)) {
      throw Eip712LedgerException(
        'Type $type nests a fixed-size array, which this device flow does '
        'not support.',
      );
    }
    for (final size in dimensions) {
      if (size != null && (size < 1 || size > 255)) {
        throw Eip712LedgerException('Type $type has an unsupported size.');
      }
    }
    int id;
    int? size;
    if (base == 'address') {
      id = _address;
    } else if (base == 'bool') {
      id = _bool;
    } else if (base == 'string') {
      id = _string;
    } else if (base == 'bytes') {
      id = _dynamicBytes;
    } else if (_integerPattern.firstMatch(base) case final integer?) {
      final bits =
          integer.group(2)!.isEmpty ? 256 : int.parse(integer.group(2)!);
      if (bits < 8 || bits > 256 || bits % 8 != 0) {
        throw Eip712LedgerException('Type $type is invalid.');
      }
      id = integer.group(1)!.isEmpty ? _int : _uint;
      size = bits ~/ 8;
    } else if (_bytesPattern.firstMatch(base) case final bytes?) {
      size = int.parse(bytes.group(1)!);
      if (size < 1 || size > 32) {
        throw Eip712LedgerException('Type $type is invalid.');
      }
      id = _fixedBytes;
    } else if (types.containsKey(base)) {
      id = _custom;
    } else {
      throw Eip712LedgerException('Type $type is not defined.');
    }
    return _TypeShape(id: id, base: base, size: size, dimensions: dimensions);
  }
}

/// `[TypeDesc][TypeName?][TypeSize?][ArrayLevels?][KeyName]` for one field.
Uint8List _fieldDefinition(
  Eip712LedgerField field,
  Map<String, List<Eip712LedgerField>> types,
) {
  final shape = _TypeShape.parse(field.type, types);
  final out = BytesBuilder(copy: false)
    ..addByte(
      (shape.dimensions.isNotEmpty ? 0x80 : 0) |
          (shape.size != null ? 0x40 : 0) |
          shape.id,
    );
  if (shape.id == _custom) {
    final name = _name(shape.base);
    out
      ..addByte(name.length)
      ..add(name);
  }
  if (shape.size != null) out.addByte(shape.size!);
  if (shape.dimensions.isNotEmpty) {
    out.addByte(shape.dimensions.length);
    for (final size in shape.dimensions) {
      if (size == null) {
        out.addByte(0);
      } else {
        out
          ..addByte(1)
          ..addByte(size);
      }
    }
  }
  final key = _name(field.name);
  out
    ..addByte(key.length)
    ..add(key);
  return out.toBytes();
}

/// Appends the APDUs that carry [value], a field of [shape], depth first.
void _values(
  List<EthereumApduFrame> frames,
  _TypeShape shape,
  Object? value,
  String name,
  Map<String, List<Eip712LedgerField>> types,
) {
  if (shape.dimensions.isNotEmpty) {
    if (value is! List) throw Eip712LedgerException('$name must be an array.');
    final fixed = shape.dimensions.first;
    if (fixed != null && value.length != fixed) {
      throw Eip712LedgerException('$name must have $fixed items.');
    }
    if (value.length > 255) {
      throw Eip712LedgerException(
        '$name has more items than this device can review.',
      );
    }
    frames.add(
      _frame(
        EthereumApdu.insEip712StructImplementation,
        EthereumApdu.p2Eip712Array,
        Uint8List.fromList([value.length]),
      ),
    );
    final element = shape.element;
    for (final item in value) {
      _values(frames, element, item, name, types);
    }
    return;
  }
  if (shape.id == _custom) {
    if (value is! Map) throw Eip712LedgerException('$name must be a struct.');
    for (final field in types[shape.base]!) {
      _values(
        frames,
        _TypeShape.parse(field.type, types),
        value[field.name],
        field.name,
        types,
      );
    }
    return;
  }
  final encoded = _leaf(shape, value, name);
  if (encoded.length > 0xFFFF) {
    throw Eip712LedgerException('$name is too long for this device.');
  }
  // `[2-byte BE length][value]`, split across APDUs of at most 255 bytes;
  // every APDU but the last is marked partial.
  final payload = Uint8List.fromList([
    encoded.length >> 8,
    encoded.length & 0xFF,
    ...encoded,
  ]);
  for (var offset = 0; offset < payload.length; offset += 255) {
    final end = offset + 255 < payload.length ? offset + 255 : payload.length;
    frames.add(
      _frame(
        EthereumApdu.insEip712StructImplementation,
        EthereumApdu.p2Eip712Field,
        Uint8List.sublistView(payload, offset, end),
        p1: end < payload.length
            ? EthereumApdu.p1Eip712Partial
            : EthereumApdu.p1Eip712Complete,
      ),
    );
  }
}

/// A leaf value as the app reads it: integers big-endian at their shortest
/// length (at least one byte); a negative signed integer at its full width,
/// because the app sign-extends only a value of exactly the type's size whose
/// top bit is set; addresses as 20 bytes; booleans as one byte; strings as
/// UTF-8; bytes as-is.
Uint8List _leaf(_TypeShape shape, Object? value, String name) {
  switch (shape.id) {
    case _int:
    case _uint:
      if (value is! BigInt) {
        throw Eip712LedgerException('$name must be an integer.');
      }
      final bits = shape.size! * 8;
      final signed = shape.id == _int;
      final min = signed ? -(BigInt.one << (bits - 1)) : BigInt.zero;
      final max = signed
          ? (BigInt.one << (bits - 1)) - BigInt.one
          : (BigInt.one << bits) - BigInt.one;
      if (value < min || value > max) {
        throw Eip712LedgerException('$name is out of range.');
      }
      if (value.isNegative) {
        return _bigEndian(value.toUnsigned(bits), length: shape.size);
      }
      return _bigEndian(value);
    case _address:
      if (value is! Uint8List || value.length != 20) {
        throw Eip712LedgerException('$name must be a 20-byte address.');
      }
      return value;
    case _bool:
      if (value is! bool) {
        throw Eip712LedgerException('$name must be true or false.');
      }
      return Uint8List.fromList([value ? 1 : 0]);
    case _string:
      if (value is! String) {
        throw Eip712LedgerException('$name must be a string.');
      }
      return Uint8List.fromList(utf8.encode(value));
    case _fixedBytes:
      if (value is! Uint8List || value.length != shape.size) {
        throw Eip712LedgerException('$name must be ${shape.size} bytes.');
      }
      return value;
    case _dynamicBytes:
      if (value is! Uint8List) {
        throw Eip712LedgerException('$name must be bytes.');
      }
      return value;
  }
  throw Eip712LedgerException('$name has an unsupported type.');
}

/// Big-endian bytes of non-negative [value]: [length] bytes when given,
/// else as few as hold it, and never fewer than one.
Uint8List _bigEndian(BigInt value, {int? length}) {
  final bytes = <int>[];
  var remaining = value;
  while (remaining > BigInt.zero) {
    bytes.insert(0, (remaining & BigInt.from(0xFF)).toInt());
    remaining >>= 8;
  }
  if (bytes.isEmpty) bytes.add(0);
  if (length != null) {
    while (bytes.length < length) {
      bytes.insert(0, 0);
    }
  }
  return Uint8List.fromList(bytes);
}
