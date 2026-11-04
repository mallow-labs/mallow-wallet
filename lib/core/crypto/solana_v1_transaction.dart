import 'dart:typed_data';

import 'package:solana/base58.dart';

/// A Solana v1 transaction (SIMD-0385), held as its wire bytes.
///
/// v1 holds up to 4,096 bytes where legacy and v0 hold 1,232. It carries every
/// account inline (no address lookup tables) and states its compute limit and
/// priority fee in the message config, with no ComputeBudget instructions. The
/// `solana` package decodes only legacy and v0, so a v1 transaction never
/// passes through `SignedTx`: it is signed, refreshed and sent as bytes.
///
/// Wire layout:
///
/// ```text
/// 0x81                                version prefix
/// header            3 bytes           required signatures, readonly signed,
///                                     readonly unsigned
/// config mask       u32 little-endian
/// recent blockhash  32 bytes          offset 8
/// instruction count u8
/// address count     u8                offset 41
/// addresses         32 bytes each     offset 42; signers first
/// config values, instruction headers and payloads
/// signatures        64 bytes each, one per required signer, no length prefix
/// ```
///
/// The signed message is everything before the signatures, version prefix
/// included. The signatures are a fixed array sized by the header, so the
/// message ends exactly `requiredSignatures * 64` bytes before the end, and
/// nothing past the address list has to be parsed.
class SolanaV1Transaction {
  SolanaV1Transaction._(this._bytes, this.requiredSignatures, this.signerKeys);

  /// Parses [wire]. Throws [FormatException] when it is not a well-formed v1
  /// transaction.
  factory SolanaV1Transaction.fromBytes(List<int> wire) {
    final bytes = Uint8List.fromList(wire);
    if (!isV1Wire(bytes)) {
      throw const FormatException('Not a v1 transaction');
    }
    if (bytes.length < _addressesOffset || bytes.length > maxSize) {
      throw FormatException('v1 transaction is ${bytes.length} bytes');
    }
    final required = bytes[_headerOffset];
    final addressCount = bytes[_addressCountOffset];
    final messageLength = bytes.length - required * signatureLength;
    if (required == 0 ||
        required > addressCount ||
        _addressesOffset + addressCount * _keyLength > messageLength) {
      throw const FormatException('Malformed v1 transaction header');
    }
    final signers = List<String>.unmodifiable([
      for (var i = 0; i < required; i++)
        base58encode(
          bytes.sublist(
            _addressesOffset + i * _keyLength,
            _addressesOffset + (i + 1) * _keyLength,
          ),
        ),
    ]);
    return SolanaV1Transaction._(bytes, required, signers);
  }

  /// The version byte a v1 transaction starts with. Legacy and v0 start with
  /// their signature count instead, which is always below 0x80.
  static const int versionPrefix = 0x81;

  /// The largest v1 transaction the network accepts.
  static const int maxSize = 4096;

  static const int signatureLength = 64;
  static const int _keyLength = 32;
  static const int _headerOffset = 1;
  static const int _blockhashOffset = 8;
  static const int _addressCountOffset = 41;
  static const int _addressesOffset = 42;

  /// Whether [wire] is a v1 transaction.
  static bool isV1Wire(List<int> wire) =>
      wire.isNotEmpty && wire.first == versionPrefix;

  final Uint8List _bytes;

  /// How many signatures the transaction carries.
  final int requiredSignatures;

  /// The signer addresses (base58), in signature-slot order.
  final List<String> signerKeys;

  int get _messageLength =>
      _bytes.length - requiredSignatures * signatureLength;

  /// The bytes every signer signs.
  Uint8List get messageBytes =>
      Uint8List.fromList(_bytes.sublist(0, _messageLength));

  /// The recent blockhash (base58).
  String get recentBlockhash => base58encode(
    _bytes.sublist(_blockhashOffset, _blockhashOffset + _keyLength),
  );

  /// The signature in each slot. An unsigned slot is 64 zero bytes.
  List<Uint8List> get signatures => [
    for (var i = 0; i < requiredSignatures; i++)
      Uint8List.fromList(
        _bytes.sublist(
          _messageLength + i * signatureLength,
          _messageLength + (i + 1) * signatureLength,
        ),
      ),
  ];

  /// Whether any slot already holds a signature, typically the backend's.
  bool get hasPreAttachedSignature =>
      signatures.any((signature) => signature.any((byte) => byte != 0));

  /// A copy with [blockhash] (base58) as the recent blockhash. Changing the
  /// message invalidates every signature, so this is only for a transaction
  /// nobody has signed yet.
  SolanaV1Transaction withRecentBlockhash(String blockhash) {
    final decoded = base58decode(blockhash);
    if (decoded.length != _keyLength) {
      throw FormatException('Blockhash is ${decoded.length} bytes');
    }
    final bytes = Uint8List.fromList(_bytes)
      ..setRange(_blockhashOffset, _blockhashOffset + _keyLength, decoded);
    return SolanaV1Transaction._(bytes, requiredSignatures, signerKeys);
  }

  /// A copy with [signature] in the slot of [signer] (base58). Throws
  /// [StateError] when [signer] is not one of the transaction's signers.
  SolanaV1Transaction withSignature(String signer, List<int> signature) {
    final slot = signerKeys.indexOf(signer);
    if (slot < 0) {
      throw StateError('Signer $signer is not in the tx signer slots');
    }
    if (signature.length != signatureLength) {
      throw ArgumentError.value(signature.length, 'signature', 'not 64 bytes');
    }
    final start = _messageLength + slot * signatureLength;
    final bytes = Uint8List.fromList(_bytes)
      ..setRange(start, start + signatureLength, signature);
    return SolanaV1Transaction._(bytes, requiredSignatures, signerKeys);
  }

  /// The transaction id: the fee payer's signature (base58).
  String get id => base58encode(signatures.first);

  /// The wire bytes.
  Uint8List toBytes() => Uint8List.fromList(_bytes);
}
