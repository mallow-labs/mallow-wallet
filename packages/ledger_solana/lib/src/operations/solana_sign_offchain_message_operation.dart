import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../solana_apdu.dart';

/// SIGN OFF-CHAIN MESSAGE — a SINGLE APDU frame of the Solana app's off-chain
/// message signing stream (INS 0x07, Anza spec).
///
/// Same streaming shape as [SolanaSignTransactionOperation]: the payload is
/// `[pathsCount][pathBytes][messageBytes]`, chunked across frames with P2
/// flags, and each frame is its own device exchange because the BLE gateway
/// completes one operation per device response. The chunking lives in
/// `SolanaSignChunkedOperation`.
///
/// Non-final frames ack with a bare `0x9000` (set [expectSignature] false);
/// only the final frame returns the 64-byte Ed25519 signature.
class SolanaSignOffChainMessageOperation extends LedgerRawOperation<Uint8List> {
  SolanaSignOffChainMessageOperation({
    required this.p2,
    required this.payload,
    required this.expectSignature,
  }) {
    // Same single-byte `Lc` ceiling as [SolanaSignTransactionOperation]: over
    // 255 the length byte wraps and the device parses garbage rather than
    // erroring.
    RangeError.checkValueInInterval(
      payload.length,
      0,
      SolanaApdu.maxChunkSize,
      'payload',
    );
  }

  /// The P2 byte for this frame — bare `p2Init` for a single-frame payload,
  /// otherwise a `p2More` / `p2Extend` combination.
  final int p2;

  /// The APDU data field for this frame.
  final Uint8List payload;

  /// Whether this frame's response carries the signature (final frame) versus a
  /// bare success status word (non-final frames of a chunked payload).
  final bool expectSignature;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(SolanaApdu.cla);
    writer.writeUint8(SolanaApdu.insSignOffChainMessage);
    writer.writeUint8(SolanaApdu.p1Confirm);
    writer.writeUint8(p2);
    writer.writeUint8(payload.length); // Lc
    writer.write(payload);
    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    final available = reader.remainingLength;

    if (!expectSignature) {
      // Non-final frame: the device acks with a 2-byte status word.
      if (available >= 2) {
        final statusWord = _statusWord(reader);
        if (statusWord == 0x9000) return Uint8List(0);
        throw _deviceError(statusWord);
      }
      throw LedgerDeviceException(
        message: 'Unexpected ack length: $available bytes',
        connectionType: ConnectionType.ble,
      );
    }

    // Final frame: 64-byte Ed25519 signature on success, else a status word.
    if (available < 64) {
      if (available >= 2) {
        throw _deviceError(_statusWord(reader));
      }
      throw LedgerDeviceException(
        message: 'Unexpected response length: $available bytes',
        connectionType: ConnectionType.ble,
      );
    }
    return reader.read(64);
  }

  int _statusWord(ByteDataReader reader) {
    final sw1 = reader.readUint8();
    final sw2 = reader.readUint8();
    return (sw1 << 8) | sw2;
  }

  LedgerDeviceException _deviceError(int statusWord) => LedgerDeviceException(
        errorCode: statusWord,
        message: 'Off-chain signing failed (0x${statusWord.toRadixString(16)})',
        connectionType: ConnectionType.ble,
      );
}
