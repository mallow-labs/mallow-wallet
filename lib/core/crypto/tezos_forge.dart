/// Local (offline) Micheline binary forging for a Tezos manager operation
/// group — the foundation of the Tezos send flow.
///
/// A signed operation is `forged_bytes ++ signature`, where `forged_bytes` is
/// `branch(32) ++ content₀ ++ content₁ ++ …`. Forging locally (rather than
/// trusting a node's `/helpers/forge/operations`) means the exact bytes we sign
/// are the bytes we built, so a malicious or buggy node cannot swap in a
/// different destination or amount behind the signature.
///
/// The binary layout follows the current (post-Nairobi) protocol encoding:
///  - operation tags: `reveal` = `0x6b`, `transaction` = `0x6c`
///  - unsigned scalars (fee/counter/gas/storage/amount) use natural Zarith
///  - Micheline `int` nodes use *signed* Zarith
///  - implicit accounts forge as `curve_tag(1) ++ hash(20)`; contract ids
///    (transaction destinations, Michelson `address` values) forge as a 22-byte
///    tagged form (`0x00 ++ pkh(21)` for implicit, `0x01 ++ hash(20) ++ 0x00`
///    for `KT1`).
///
/// Every [TezosOperationContent] renders to BOTH its forged binary ([forge],
/// via the group) and its `run_operation` JSON ([TezosOperationContent.toJson]),
/// so the operation simulated for fees and the operation actually
/// signed are built from one source and can never drift.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/base58.dart' as base58;

import '../../shared/utils/tezos_address.dart';

// ---------------------------------------------------------------------------
// Low-level encoders
// ---------------------------------------------------------------------------

/// Natural-number (unsigned) Zarith: 7 bits per byte, little-endian, high bit
/// set on every byte except the last. Used for fee/counter/gas/storage/amount.
List<int> forgeZarithNat(BigInt value) {
  if (value < BigInt.zero) {
    throw ArgumentError.value(value, 'value', 'Zarith nat must be >= 0');
  }
  final out = <int>[];
  var v = value;
  final mask = BigInt.from(0x7f);
  while (true) {
    var byte = (v & mask).toInt();
    v = v >> 7;
    if (v > BigInt.zero) byte |= 0x80;
    out.add(byte);
    if (v == BigInt.zero) break;
  }
  return out;
}

/// Signed Zarith (`Z`): the first byte carries the sign in bit 6 and 6 value
/// bits; continuation bytes carry 7 value bits. Used inside Micheline `int`
/// nodes: token amounts and ids, and any integer a website sends, which may be
/// negative.
List<int> forgeZarithInt(BigInt value) {
  final negative = value < BigInt.zero;
  var v = value.abs();
  final out = <int>[];
  var first = (v & BigInt.from(0x3f)).toInt();
  v = v >> 6;
  if (negative) first |= 0x40;
  if (v > BigInt.zero) first |= 0x80;
  out.add(first);
  while (v > BigInt.zero) {
    var byte = (v & BigInt.from(0x7f)).toInt();
    v = v >> 7;
    if (v > BigInt.zero) byte |= 0x80;
    out.add(byte);
  }
  return out;
}

/// A 4-byte big-endian length prefix, as Micheline uses for `bytes`, sequences,
/// and the transaction `parameters` value blob.
List<int> _len32(int n) => [
  (n >> 24) & 0xff,
  (n >> 16) & 0xff,
  (n >> 8) & 0xff,
  n & 0xff,
];

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Base58Check payload extraction (Tezos prefixes are fixed-width)
// ---------------------------------------------------------------------------

/// The 20-byte hash inside any Tezos address (`tz1/2/3` or `KT1`): strip the
/// 3-byte version prefix and the 4-byte Base58Check checksum.
Uint8List _addressHash(String address) {
  final decoded = base58.base58decode(address);
  final body = decoded.sublist(0, decoded.length - 4); // drop checksum
  return Uint8List.fromList(body.sublist(3)); // drop 3-byte prefix
}

/// Forge an *implicit* account (operation `source`, or the `public_key_hash`
/// inside an address value) as `curve_tag(1) ++ hash(20)`.
List<int> _forgeImplicit(String address) {
  final kind = tezosAddressKind(address);
  final curveTag = switch (kind) {
    TezosAddressKind.tz1 => 0x00,
    TezosAddressKind.tz2 => 0x01,
    TezosAddressKind.tz3 => 0x02,
    _ => throw ArgumentError.value(
      address,
      'address',
      'not an implicit (tz1/tz2/tz3) Tezos account',
    ),
  };
  return [curveTag, ..._addressHash(address)];
}

/// Forge a `contract_id` (transaction destination) / Michelson `address` value
/// as the 22-byte tagged form: implicit → `0x00 ++ pkh(21)`, originated (`KT1`)
/// → `0x01 ++ hash(20) ++ 0x00`.
List<int> _forgeContractId(String address) {
  final kind = tezosAddressKind(address);
  if (kind == null) {
    throw ArgumentError.value(address, 'address', 'invalid Tezos address');
  }
  if (kind == TezosAddressKind.kt1) {
    return [0x01, ..._addressHash(address), 0x00];
  }
  return [0x00, ..._forgeImplicit(address)];
}

/// The raw 32-byte Ed25519 key inside an `edpk…` public key (strip 4-byte
/// prefix + 4-byte checksum). Reveal only supports Ed25519 (`tz1`) in v1.
Uint8List _decodeEdpk(String edpk) {
  if (!edpk.startsWith('edpk')) {
    throw ArgumentError.value(
      edpk,
      'publicKey',
      'only Ed25519 (edpk…) public keys are supported',
    );
  }
  final decoded = base58.base58decode(edpk);
  return Uint8List.fromList(decoded.sublist(4, decoded.length - 4));
}

/// The 32-byte block hash inside a `B…` branch (strip 2-byte prefix + checksum).
Uint8List _forgeBranch(String blockHash) {
  final decoded = base58.base58decode(blockHash);
  return Uint8List.fromList(decoded.sublist(2, decoded.length - 4));
}

// ---------------------------------------------------------------------------
// Micheline value AST (typed nodes for the wallet's own transfers, plus
// validated JSON for site-supplied values)
// ---------------------------------------------------------------------------

/// A Micheline expression node. Renders to its forged binary form and to the
/// `run_operation` JSON form from a single definition.
sealed class Micheline {
  const Micheline();

  void _forge(BytesBuilder out);

  /// The Micheline JSON node (`{"int":…}`, `{"bytes":…}`, `{"prim":…}`, or a
  /// list for a sequence) used in a `run_operation` request.
  Object toJson();
}

/// Micheline JSON from a dapp, validated and forged locally. Depth and node
/// limits bound work before any simulation or approval.
class MichelineJson extends Micheline {
  MichelineJson(Object value)
    : _value = jsonDecode(jsonEncode(value)) as Object {
    var nodes = 0;
    void validate(Object? v, int depth) {
      if (++nodes > 10000 || depth > 64)
        throw const FormatException('Micheline is too large');
      if (v is List) {
        for (final item in v) {
          validate(item, depth + 1);
        }
        return;
      }
      if (v is! Map) throw const FormatException('Invalid Micheline');
      if (v.length == 1 &&
          v['int'] is String &&
          RegExp(r'^-?[0-9]+$').hasMatch(v['int'] as String))
        return;
      if (v.length == 1 && v['string'] is String) return;
      if (v.length == 1 &&
          v['bytes'] is String &&
          RegExp(r'^(?:[0-9a-fA-F]{2})*$').hasMatch(v['bytes'] as String))
        return;
      if (v['prim'] is! String ||
          !_michelinePrimitives.containsKey(v['prim']) ||
          v.keys.any((k) => !{'prim', 'args', 'annots'}.contains(k)))
        throw const FormatException('Unsupported Micheline primitive');
      final args = v['args'] ?? const <Object>[];
      final annots = v['annots'] ?? const <String>[];
      if (args is! List ||
          annots is! List ||
          annots.any((a) => a is! String || a.contains(RegExp(r'\s'))))
        throw const FormatException('Invalid Micheline arguments');
      for (final arg in args) {
        validate(arg, depth + 1);
      }
    }

    validate(_value, 0);
  }
  final Object _value;
  @override
  Object toJson() => jsonDecode(jsonEncode(_value)) as Object;
  @override
  void _forge(BytesBuilder out) {
    void write(Object v, BytesBuilder target) {
      if (v is List) {
        final inner = BytesBuilder();
        for (final item in v) {
          write(item as Object, inner);
        }
        final bytes = inner.takeBytes();
        target.addByte(2);
        target.add(_len32(bytes.length));
        target.add(bytes);
        return;
      }
      final node = v as Map;
      if (node.containsKey('int')) {
        target.addByte(0);
        target.add(forgeZarithInt(BigInt.parse(node['int'] as String)));
        return;
      }
      if (node.containsKey('string') || node.containsKey('bytes')) {
        final string = node.containsKey('string');
        final bytes = string
            ? utf8.encode(node['string'] as String)
            : _hexToBytes(node['bytes'] as String);
        target.addByte(string ? 1 : 10);
        target.add(_len32(bytes.length));
        target.add(bytes);
        return;
      }
      final args = (node['args'] as List?) ?? const [];
      final annotations = utf8.encode(
        ((node['annots'] as List?) ?? const []).join(' '),
      );
      final annotated = annotations.isNotEmpty;
      target.addByte(
        args.length > 2 ? 9 : 3 + args.length * 2 + (annotated ? 1 : 0),
      );
      target.addByte(_michelinePrimitives[node['prim']]!);
      if (args.length > 2) {
        final inner = BytesBuilder();
        for (final arg in args) {
          write(arg as Object, inner);
        }
        final bytes = inner.takeBytes();
        target.add(_len32(bytes.length));
        target.add(bytes);
      } else {
        for (final arg in args) {
          write(arg as Object, target);
        }
      }
      if (annotated || args.length > 2) {
        target.add(_len32(annotations.length));
        target.add(annotations);
      }
    }

    write(_value, out);
  }
}

// Protocol primitive tags are fixed by the Micheline binary encoding.
const _michelinePrimitives = <String, int>{
  'parameter': 0x00,
  'storage': 0x01,
  'code': 0x02,
  'False': 0x03,
  'Elt': 0x04,
  'Left': 0x05,
  'None': 0x06,
  'Pair': 0x07,
  'Right': 0x08,
  'Some': 0x09,
  'True': 0x0a,
  'Unit': 0x0b,
  'PACK': 0x0c,
  'UNPACK': 0x0d,
  'BLAKE2B': 0x0e,
  'SHA256': 0x0f,
  'SHA512': 0x10,
  'ABS': 0x11,
  'ADD': 0x12,
  'AMOUNT': 0x13,
  'AND': 0x14,
  'BALANCE': 0x15,
  'CAR': 0x16,
  'CDR': 0x17,
  'CHECK_SIGNATURE': 0x18,
  'COMPARE': 0x19,
  'CONCAT': 0x1a,
  'CONS': 0x1b,
  'CREATE_ACCOUNT': 0x1c,
  'CREATE_CONTRACT': 0x1d,
  'IMPLICIT_ACCOUNT': 0x1e,
  'DIP': 0x1f,
  'DROP': 0x20,
  'DUP': 0x21,
  'EDIV': 0x22,
  'EMPTY_MAP': 0x23,
  'EMPTY_SET': 0x24,
  'EQ': 0x25,
  'EXEC': 0x26,
  'FAILWITH': 0x27,
  'GE': 0x28,
  'GET': 0x29,
  'GT': 0x2a,
  'HASH_KEY': 0x2b,
  'IF': 0x2c,
  'IF_CONS': 0x2d,
  'IF_LEFT': 0x2e,
  'IF_NONE': 0x2f,
  'INT': 0x30,
  'LAMBDA': 0x31,
  'LE': 0x32,
  'LEFT': 0x33,
  'LOOP': 0x34,
  'LSL': 0x35,
  'LSR': 0x36,
  'LT': 0x37,
  'MAP': 0x38,
  'MEM': 0x39,
  'MUL': 0x3a,
  'NEG': 0x3b,
  'NEQ': 0x3c,
  'NIL': 0x3d,
  'NONE': 0x3e,
  'NOT': 0x3f,
  'NOW': 0x40,
  'OR': 0x41,
  'PAIR': 0x42,
  'PUSH': 0x43,
  'RIGHT': 0x44,
  'SIZE': 0x45,
  'SOME': 0x46,
  'SOURCE': 0x47,
  'SENDER': 0x48,
  'SELF': 0x49,
  'STEPS_TO_QUOTA': 0x4a,
  'SUB': 0x4b,
  'SWAP': 0x4c,
  'TRANSFER_TOKENS': 0x4d,
  'SET_DELEGATE': 0x4e,
  'UNIT': 0x4f,
  'UPDATE': 0x50,
  'XOR': 0x51,
  'ITER': 0x52,
  'LOOP_LEFT': 0x53,
  'ADDRESS': 0x54,
  'CONTRACT': 0x55,
  'ISNAT': 0x56,
  'CAST': 0x57,
  'RENAME': 0x58,
  'bool': 0x59,
  'contract': 0x5a,
  'int': 0x5b,
  'key': 0x5c,
  'key_hash': 0x5d,
  'lambda': 0x5e,
  'list': 0x5f,
  'map': 0x60,
  'big_map': 0x61,
  'nat': 0x62,
  'option': 0x63,
  'or': 0x64,
  'pair': 0x65,
  'set': 0x66,
  'signature': 0x67,
  'string': 0x68,
  'bytes': 0x69,
  'mutez': 0x6a,
  'timestamp': 0x6b,
  'unit': 0x6c,
  'operation': 0x6d,
  'address': 0x6e,
  'SLICE': 0x6f,
  'DIG': 0x70,
  'DUG': 0x71,
  'EMPTY_BIG_MAP': 0x72,
  'APPLY': 0x73,
  'chain_id': 0x74,
  'CHAIN_ID': 0x75,
  'LEVEL': 0x76,
  'SELF_ADDRESS': 0x77,
  'never': 0x78,
  'NEVER': 0x79,
  'UNPAIR': 0x7a,
  'VOTING_POWER': 0x7b,
  'TOTAL_VOTING_POWER': 0x7c,
  'KECCAK': 0x7d,
  'SHA3': 0x7e,
  'PAIRING_CHECK': 0x7f,
  'bls12_381_g1': 0x80,
  'bls12_381_g2': 0x81,
  'bls12_381_fr': 0x82,
  'sapling_state': 0x83,
  'sapling_transaction_deprecated': 0x84,
  'SAPLING_EMPTY_STATE': 0x85,
  'SAPLING_VERIFY_UPDATE': 0x86,
  'ticket': 0x87,
  'TICKET_DEPRECATED': 0x88,
  'READ_TICKET': 0x89,
  'SPLIT_TICKET': 0x8a,
  'JOIN_TICKETS': 0x8b,
  'GET_AND_UPDATE': 0x8c,
  'chest': 0x8d,
  'chest_key': 0x8e,
  'OPEN_CHEST': 0x8f,
  'VIEW': 0x90,
  'view': 0x91,
  'constant': 0x92,
  'SUB_MUTEZ': 0x93,
  'tx_rollup_l2_address': 0x94,
  'MIN_BLOCK_TIME': 0x95,
  'sapling_transaction': 0x96,
  'EMIT': 0x97,
  'Lambda_rec': 0x98,
  'LAMBDA_REC': 0x99,
  'TICKET': 0x9a,
  'BYTES': 0x9b,
  'NAT': 0x9c,
  'Ticket': 0x9d,
  'IS_IMPLICIT_ACCOUNT': 0x9e,
  'INDEX_ADDRESS': 0x9f,
  'GET_ADDRESS_INDEX': 0xa0,
};

/// A Micheline integer (`0x00 ++ signed-Zarith`).
class MichelineInt extends Micheline {
  const MichelineInt(this.value);
  final BigInt value;

  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x00);
    out.add(forgeZarithInt(value));
  }

  @override
  Object toJson() => {'int': value.toString()};
}

/// A Micheline byte string (`0x0a ++ len(4) ++ bytes`). Michelson `address`
/// values are encoded this way over their [_forgeContractId] bytes.
class MichelineBytes extends Micheline {
  MichelineBytes(this.bytes);

  /// A Michelson `address` value node from a Tezos [address].
  MichelineBytes.address(String address)
    : bytes = Uint8List.fromList(_forgeContractId(address));

  final Uint8List bytes;

  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x0a);
    out.add(_len32(bytes.length));
    out.add(bytes);
  }

  @override
  Object toJson() => {'bytes': _hex(bytes)};
}

/// A two-argument `Pair` primitive with no annotations
/// (`0x07 ++ Pair-tag(0x07) ++ arg₀ ++ arg₁`).
class MichelinePair extends Micheline {
  const MichelinePair(this.first, this.second);
  final Micheline first;
  final Micheline second;

  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x07); // prim, 2 args, no annots
    out.addByte(0x07); // Pair
    first._forge(out);
    second._forge(out);
  }

  @override
  Object toJson() => {
    'prim': 'Pair',
    'args': [first.toJson(), second.toJson()],
  };
}

/// A Micheline sequence / list (`0x02 ++ len(4) ++ items`).
class MichelineSeq extends Micheline {
  const MichelineSeq(this.items);
  final List<Micheline> items;

  @override
  void _forge(BytesBuilder out) {
    final inner = BytesBuilder();
    for (final item in items) {
      item._forge(inner);
    }
    final bytes = inner.toBytes();
    out.addByte(0x02);
    out.add(_len32(bytes.length));
    out.add(bytes);
  }

  @override
  Object toJson() => items.map((e) => e.toJson()).toList();
}

// ---------------------------------------------------------------------------
// Transaction parameters + entrypoints
// ---------------------------------------------------------------------------

/// Built-in entrypoint tags. Anything else is forged as a named entrypoint
/// (`0xff ++ len(1) ++ utf8-name`) — this is how `transfer` is encoded.
const Map<String, int> _builtinEntrypoints = {
  'default': 0x00,
  'root': 0x01,
  'do': 0x02,
  'set_delegate': 0x03,
  'remove_delegate': 0x04,
  'deposit': 0x05,
  'stake': 0x06,
  'unstake': 0x07,
  'finalize_unstake': 0x08,
  'set_delegate_parameters': 0x09,
};

List<int> _forgeEntrypoint(String name) {
  final builtin = _builtinEntrypoints[name];
  if (builtin != null) return [builtin];
  final bytes = utf8.encode(name);
  if (bytes.isEmpty || bytes.length > 31) {
    throw ArgumentError.value(name, 'entrypoint', 'name too long');
  }
  return [0xff, bytes.length, ...bytes];
}

/// The `parameters` of a smart-contract call: an [entrypoint] and its Micheline
/// [value]. Absent for a plain XTZ transfer to an implicit account.
class TezosTransactionParameters {
  const TezosTransactionParameters({
    required this.entrypoint,
    required this.value,
  });

  final String entrypoint;
  final Micheline value;

  Map<String, dynamic> toJson() => {
    'entrypoint': entrypoint,
    'value': value.toJson(),
  };
}

/// FA1.2 `transfer(from, to, value)` parameters — `Pair from (Pair to value)`,
/// addresses as Michelson `address` byte values.
TezosTransactionParameters fa12TransferParameters({
  required String from,
  required String to,
  required BigInt amount,
}) => TezosTransactionParameters(
  entrypoint: 'transfer',
  value: MichelinePair(
    MichelineBytes.address(from),
    MichelinePair(MichelineBytes.address(to), MichelineInt(amount)),
  ),
);

/// FA2 `transfer` parameters — a batch `list [ { from_; txs: list [ { to_;
/// token_id; amount } ] } ]`. This builds the single-transfer case:
/// `[ Pair from_ [ Pair to_ (Pair token_id amount) ] ]`.
TezosTransactionParameters fa2TransferParameters({
  required String from,
  required String to,
  required BigInt tokenId,
  required BigInt amount,
}) => TezosTransactionParameters(
  entrypoint: 'transfer',
  value: MichelineSeq([
    MichelinePair(
      MichelineBytes.address(from),
      MichelineSeq([
        MichelinePair(
          MichelineBytes.address(to),
          MichelinePair(MichelineInt(tokenId), MichelineInt(amount)),
        ),
      ]),
    ),
  ]),
);

// ---------------------------------------------------------------------------
// Operation contents
// ---------------------------------------------------------------------------

/// One content of a manager operation group.
sealed class TezosOperationContent {
  const TezosOperationContent();

  void _forge(BytesBuilder out);

  /// The `run_operation` / injection JSON for this content.
  Map<String, dynamic> toJson();
}

/// Changes or removes the account's baker delegation.
class TezosDelegation extends TezosOperationContent {
  const TezosDelegation({
    required this.source,
    required this.fee,
    required this.counter,
    required this.gasLimit,
    required this.storageLimit,
    this.delegate,
  });
  final String source;
  final String? delegate;
  final BigInt fee;
  final BigInt counter;
  final BigInt gasLimit;
  final BigInt storageLimit;
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'delegation',
    'source': source,
    'fee': '$fee',
    'counter': '$counter',
    'gas_limit': '$gasLimit',
    'storage_limit': '$storageLimit',
    if (delegate != null) 'delegate': delegate,
  };
  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x6e);
    out.add(_forgeImplicit(source));
    for (final value in [fee, counter, gasLimit, storageLimit]) {
      out.add(forgeZarithNat(value));
    }
    out.addByte(delegate == null ? 0 : 255);
    if (delegate != null) out.add(_forgeImplicit(delegate!));
  }
}

/// A `reveal` operation — publishes the account's manager key. Must be
/// prepended to the first outgoing operation of a never-revealed account.
/// v1 supports Ed25519 (`edpk…`) keys only.
class TezosReveal extends TezosOperationContent {
  const TezosReveal({
    required this.source,
    required this.publicKey,
    required this.fee,
    required this.counter,
    required this.gasLimit,
    required this.storageLimit,
  });

  final String source;

  /// The `edpk…` Ed25519 public key being revealed.
  final String publicKey;
  final BigInt fee;
  final BigInt counter;
  final BigInt gasLimit;
  final BigInt storageLimit;

  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x6b);
    out.add(_forgeImplicit(source));
    out.add(forgeZarithNat(fee));
    out.add(forgeZarithNat(counter));
    out.add(forgeZarithNat(gasLimit));
    out.add(forgeZarithNat(storageLimit));
    out.addByte(0x00); // Ed25519 public-key tag
    out.add(_decodeEdpk(publicKey));
    // Optional BLS `proof` field (added in protocol Paris): `None` for Ed25519.
    // Current mainnet/shadownet nodes reject a reveal without this byte.
    out.addByte(0x00);
  }

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'reveal',
    'source': source,
    'fee': fee.toString(),
    'counter': counter.toString(),
    'gas_limit': gasLimit.toString(),
    'storage_limit': storageLimit.toString(),
    'public_key': publicKey,
  };
}

/// A `transaction` operation. For a native XTZ transfer to an implicit account,
/// leave [parameters] null and set [amount] to the mutez sent. For an FA1.2 /
/// FA2 token transfer, set [destination] to the token `KT1`, [amount] to zero,
/// and [parameters] to the entrypoint call ([fa12TransferParameters] /
/// [fa2TransferParameters]).
class TezosTransaction extends TezosOperationContent {
  const TezosTransaction({
    required this.source,
    required this.destination,
    required this.amount,
    required this.fee,
    required this.counter,
    required this.gasLimit,
    required this.storageLimit,
    this.parameters,
  });

  final String source;
  final String destination;
  final BigInt amount;
  final BigInt fee;
  final BigInt counter;
  final BigInt gasLimit;
  final BigInt storageLimit;
  final TezosTransactionParameters? parameters;

  @override
  void _forge(BytesBuilder out) {
    out.addByte(0x6c);
    out.add(_forgeImplicit(source));
    out.add(forgeZarithNat(fee));
    out.add(forgeZarithNat(counter));
    out.add(forgeZarithNat(gasLimit));
    out.add(forgeZarithNat(storageLimit));
    out.add(forgeZarithNat(amount));
    out.add(_forgeContractId(destination));

    final params = _canonicalParameters;
    if (params == null) {
      out.addByte(0x00); // parameters absent
      return;
    }
    out.addByte(0xff); // parameters present
    out.add(_forgeEntrypoint(params.entrypoint));
    final valueBytes = _forgeValue(params.value);
    out.add(_len32(valueBytes.length));
    out.add(valueBytes);
  }

  static Uint8List _forgeValue(Micheline value) {
    final builder = BytesBuilder();
    value._forge(builder);
    return builder.toBytes();
  }

  /// [parameters] in the protocol's canonical form. The protocol encodes
  /// `default` called with exactly `Unit` (bytes `030b`, no annotations) as
  /// "parameters absent" and re-serializes the operation that way before it
  /// checks the signature. Signing the explicit form would produce a signature
  /// over bytes the node never sees, so injection would fail after approval.
  TezosTransactionParameters? get _canonicalParameters {
    final params = parameters;
    if (params == null || params.entrypoint != 'default') return params;
    final bytes = _forgeValue(params.value);
    final unit = bytes.length == 2 && bytes[0] == 0x03 && bytes[1] == 0x0b;
    return unit ? null : params;
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'kind': 'transaction',
      'source': source,
      'fee': fee.toString(),
      'counter': counter.toString(),
      'gas_limit': gasLimit.toString(),
      'storage_limit': storageLimit.toString(),
      'amount': amount.toString(),
      'destination': destination,
    };
    final params = _canonicalParameters;
    if (params != null) json['parameters'] = params.toJson();
    return json;
  }
}

// ---------------------------------------------------------------------------
// Group forging
// ---------------------------------------------------------------------------

/// Forge a manager operation group (`branch ++ contents`) to a hex string.
///
/// The returned hex is what gets Blake2b-256-hashed under the `0x03` watermark
/// and Ed25519-signed; `hex ++ signature_hex` is then injected.
String forgeOperationGroup(
  String branch,
  List<TezosOperationContent> contents,
) {
  if (contents.isEmpty) {
    throw ArgumentError.value(contents, 'contents', 'must not be empty');
  }
  final out = BytesBuilder();
  out.add(_forgeBranch(branch));
  for (final content in contents) {
    content._forge(out);
  }
  return _hex(out.toBytes());
}

/// Decode an even-length hex string (no `0x` prefix) to bytes — for the signing
/// layer and tests to recover the forged bytes from [forgeOperationGroup].
Uint8List hexToBytes(String hex) => _hexToBytes(hex);

/// Encode bytes as lowercase hex (two chars per byte), no `0x` prefix — the
/// inverse of [hexToBytes], shared with the signing layer.
String bytesToHex(List<int> bytes) => _hex(bytes);
