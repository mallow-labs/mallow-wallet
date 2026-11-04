import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:solana/encoder.dart';
import '../models/dapp_request.dart';

/// Strict wire validation before the SDK parser. SDK deserialization alone
/// accepts trailing bytes and some inconsistent account/signature counts.
SignedTx parseDappTransaction(Uint8List bytes, {String? signer}) {
  try {
    if (bytes.isEmpty || bytes.length > 1232) throw const FormatException();
    final tx = SignedTx.fromBytes(bytes);
    if (!const ListEquality<int>().equals(bytes, tx.toByteArray().toList())) {
      throw const FormatException();
    }
    final message = tx.compiledMessage;
    final header = message.header;
    final required = header.numRequiredSignatures;
    final staticCount = message.accountKeys.length;
    if (required == 0 ||
        required > staticCount ||
        tx.signatures.length != required ||
        header.numReadonlySignedAccounts >= required ||
        header.numReadonlyUnsignedAccounts > staticCount - required) {
      throw const FormatException();
    }
    var count = staticCount;
    if (message is CompiledMessageV0) {
      for (final table in message.addressTableLookups) {
        count += table.writableIndexes.length + table.readonlyIndexes.length;
      }
    }
    if (count > 256 || message.accountKeys.toSet().length != staticCount)
      throw const FormatException();
    for (final instruction in message.instructions) {
      if (instruction.programIdIndex >= staticCount ||
          instruction.programIdIndex == 0 ||
          instruction.accountKeyIndexes.any((i) => i >= count))
        throw const FormatException();
    }
    if (signer != null &&
        !message.accountKeys
            .take(required)
            .any((key) => key.toBase58() == signer)) {
      throw const DappException(
        4100,
        'The selected wallet is not a required signer.',
      );
    }
    return tx;
  } on DappException {
    rethrow;
  } catch (_) {
    throw const DappException(
      -32602,
      'Malformed or unsupported Solana transaction.',
    );
  }
}

bool isSolanaTransaction(Uint8List bytes) {
  try {
    parseDappTransaction(bytes);
    return true;
  } catch (_) {
    return false;
  }
}

/// A raw compiled message is the exact spend-authorizing Ed25519 payload, so
/// message signing must refuse it as well as the complete transaction envelope.
///
/// Only legacy and v0 can be parsed here. A versioned message starts with a
/// byte that has its high bit set, the version in the low seven bits: v0 is
/// 0x80 and v1 is 0x81, both as a bare message and as a whole v1 transaction,
/// which carries its signatures at the end. A v1 message can also run to
/// 4,096 bytes, past the legacy and v0 size limit. So a payload that starts
/// with any of 0x80 to 0xBF, the prefixes of v0 to v63, is refused before any
/// parse. No UTF-8 text starts there (those are continuation bytes), and the
/// off-chain message signing domain starts 0xFF, so neither is affected.
bool isSolanaSigningPayload(Uint8List bytes) {
  if (bytes.isNotEmpty && bytes.first >= 0x80 && bytes.first < 0xc0) {
    return true;
  }
  if (isSolanaTransaction(bytes)) return true;
  try {
    if (bytes.isEmpty || bytes.length > 1232) return false;
    final message = CompiledMessage(ByteArray(bytes));
    if (!const ListEquality<int>().equals(
      bytes,
      message.toByteArray().toList(),
    ))
      return false;
    final tx = SignedTx(
      compiledMessage: message,
      signatures: message.accountKeys
          .take(message.requiredSignatureCount)
          .map((key) => Signature(List.filled(64, 0), publicKey: key))
          .toList(),
    );
    parseDappTransaction(Uint8List.fromList(tx.toByteArray().toList()));
    return true;
  } catch (_) {
    return false;
  }
}
