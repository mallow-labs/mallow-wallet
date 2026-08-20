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
/// nodes (FA token amounts / ids). Non-negative for our transfers, but the sign
/// bit is handled for completeness.
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
// Micheline value AST (only the nodes FA1.2 / FA2 transfers need)
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
};

List<int> _forgeEntrypoint(String name) {
  final builtin = _builtinEntrypoints[name];
  if (builtin != null) return [builtin];
  final bytes = utf8.encode(name);
  if (bytes.length > 255) {
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

    final params = parameters;
    if (params == null) {
      out.addByte(0x00); // parameters absent
      return;
    }
    out.addByte(0xff); // parameters present
    out.add(_forgeEntrypoint(params.entrypoint));
    final valueBuilder = BytesBuilder();
    params.value._forge(valueBuilder);
    final valueBytes = valueBuilder.toBytes();
    out.add(_len32(valueBytes.length));
    out.add(valueBytes);
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
    final params = parameters;
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
