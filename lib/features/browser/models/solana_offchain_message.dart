import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/base58.dart';

/// `b"\xffsolana offchain"`, the 16 bytes every Solana off-chain message
/// starts with. A leading 0xff can never begin a transaction message, so a
/// signature over these bytes can never be replayed as a transaction.
final Uint8List solanaOffchainSigningDomain = Uint8List.fromList([
  0xff,
  ...ascii.encode('solana offchain'),
]);

/// The largest content the wallet will build or sign. The v1 format sets no
/// limit of its own; this matches the cap on `signMessage`.
const kMaxSolanaOffchainContent = 65535;

/// A version 1 Solana off-chain message (sRFC 38), as the
/// `solana:signOffchainMessage` wallet-standard feature defines it:
///
/// ```text
/// signing domain (16) | version = 1 (1) | signer count N (1)
/// | N × 32-byte signer keys, sorted ascending, no duplicates
/// | UTF-8 content, not empty, to the end
/// ```
///
/// The wallet builds these bytes itself from the site's text and signer list
/// and returns them with the signature, so a hardware signer that only signs
/// this format (a Ledger) can answer it. Each required signer signs the whole
/// byte string.
class SolanaOffchainMessage {
  SolanaOffchainMessage._(this.signers, this.content, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();

  /// Builds the canonical message for [content] and [requiredSigners] (raw
  /// 32-byte keys, in any order). Throws [FormatException] when the inputs
  /// cannot make a valid message: empty content, no signers, a key of the
  /// wrong length, a duplicate key, or more than 255 signers.
  factory SolanaOffchainMessage.build({
    required String content,
    required List<Uint8List> requiredSigners,
  }) {
    final body = utf8.encode(content);
    if (body.isEmpty) throw const FormatException('Message is empty');
    if (body.length > kMaxSolanaOffchainContent) {
      throw const FormatException('Message is too large');
    }
    if (requiredSigners.isEmpty || requiredSigners.length > 255) {
      throw const FormatException('A message needs 1 to 255 signers');
    }
    for (final key in requiredSigners) {
      if (key.length != 32) {
        throw const FormatException('Signer keys must be 32 bytes');
      }
    }
    final sorted = [...requiredSigners]..sort(_compareKeys);
    for (var i = 1; i < sorted.length; i++) {
      if (_compareKeys(sorted[i - 1], sorted[i]) == 0) {
        throw const FormatException('Signers must not repeat');
      }
    }
    final out = BytesBuilder(copy: false)
      ..add(solanaOffchainSigningDomain)
      ..addByte(1)
      ..addByte(sorted.length);
    for (final key in sorted) {
      out.add(key);
    }
    out.add(body);
    return SolanaOffchainMessage._(
      List.unmodifiable(sorted.map(base58encode)),
      content,
      out.toBytes(),
    );
  }

  /// Reads a version 1 message back, rejecting anything [build] would not
  /// have produced, so what a review shows is exactly what gets signed.
  factory SolanaOffchainMessage.parse(Uint8List bytes) {
    const header = 18;
    final domain = solanaOffchainSigningDomain;
    if (bytes.length <= header) {
      throw const FormatException('Not an off-chain message');
    }
    for (var i = 0; i < domain.length; i++) {
      if (bytes[i] != domain[i]) {
        throw const FormatException('Not an off-chain message');
      }
    }
    if (bytes[16] != 1) {
      throw const FormatException('Unsupported off-chain message version');
    }
    final count = bytes[17];
    final bodyStart = header + count * 32;
    if (count == 0 || bytes.length <= bodyStart) {
      throw const FormatException('Malformed off-chain message');
    }
    final signers = [
      for (var i = 0; i < count; i++)
        Uint8List.sublistView(bytes, header + i * 32, header + (i + 1) * 32),
    ];
    for (var i = 1; i < signers.length; i++) {
      if (_compareKeys(signers[i - 1], signers[i]) >= 0) {
        throw const FormatException('Signers must be sorted and unique');
      }
    }
    // Strict decoding: a malformed sequence is refused, not replaced.
    final content = utf8.decode(
      Uint8List.sublistView(bytes, bodyStart),
      allowMalformed: false,
    );
    final message = SolanaOffchainMessage.build(
      content: content,
      requiredSigners: signers,
    );
    if (message.bytes.length != bytes.length) {
      throw const FormatException('Malformed off-chain message');
    }
    return message;
  }

  /// The required signers' base58 addresses, in the order the message lists
  /// them.
  final List<String> signers;

  /// The text the site asked to sign.
  final String content;

  /// The full message: what the wallet signs and returns.
  final Uint8List bytes;

  static int _compareKeys(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
