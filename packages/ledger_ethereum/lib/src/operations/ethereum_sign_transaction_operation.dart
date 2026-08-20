import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../ethereum_apdu.dart';

/// SIGN TRANSACTION — a SINGLE APDU exchange of the Ethereum app's transaction
/// signing stream (INS 0x04).
///
/// app-ethereum streams the RLP-serialized unsigned transaction across APDUs:
/// the first packet (P1=0x00) carries `[path][rlp-chunk]`, continuations
/// (P1=0x80) carry raw RLP bytes only. Unlike SIGN PERSONAL MESSAGE there is no
/// 4-byte length prefix — the device infers the total length from the RLP
/// structure. The BLE gateway completes one operation per device response, so
/// each packet MUST be its own `sendOperation`; the orchestration lives in
/// `EthereumLedgerApp.signTransaction`, and this class models a single packet.
///
/// When the whole transaction fits one packet, that packet is also the last, so
/// the device returns the signature directly (after on-screen confirmation —
/// the device keccak256-hashes the payload and secp256k1-signs). For a chunked
/// transaction the first/intermediate packets return a bare `0x9000` ack (set
/// [expectSignature] false) and only the final packet returns `[v][r][s]`.
///
/// On the final packet [read] returns the raw 65-byte `v‖r‖s` exactly as the
/// device emits it — the caller splits it and reassembles the signed EIP-1559
/// envelope (the `v` byte is the recovery parity for type-2 transactions).
class EthereumSignTransactionOperation extends LedgerRawOperation<Uint8List> {
  EthereumSignTransactionOperation({
    required this.p1,
    required this.payload,
    required this.expectSignature,
  });

  /// The P1 byte for this packet (0x00 first, 0x80 continuation).
  final int p1;

  /// The APDU data field — `[path][rlp-chunk]` for the first packet, or a bare
  /// RLP chunk for a continuation.
  final Uint8List payload;

  /// Whether this packet's response carries the signature (final packet) versus
  /// a bare success status word (non-final packets of a chunked transaction).
  final bool expectSignature;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(EthereumApdu.cla);
    writer.writeUint8(EthereumApdu.insSignTransaction);
    writer.writeUint8(p1);
    writer.writeUint8(0x00); // P2 unused for transaction signing.
    writer.writeUint8(payload.length); // Lc
    writer.write(payload);
    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    final available = reader.remainingLength;

    if (!expectSignature) {
      // Non-final packet: the device acks with a 2-byte status word.
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

    // Final packet: [v][r][s] (65 bytes) on success, else a 2-byte status word.
    if (available < 65) {
      if (available >= 2) {
        throw _deviceError(_statusWord(reader));
      }
      throw LedgerDeviceException(
        message: 'Unexpected response length: $available bytes',
        connectionType: ConnectionType.ble,
      );
    }

    final v = reader.readUint8();
    final r = reader.read(32);
    final s = reader.read(32);
    return Uint8List.fromList([v, ...r, ...s]);
  }

  int _statusWord(ByteDataReader reader) {
    final sw1 = reader.readUint8();
    final sw2 = reader.readUint8();
    return (sw1 << 8) | sw2;
  }

  LedgerDeviceException _deviceError(int statusWord) => LedgerDeviceException(
        errorCode: statusWord,
        message:
            'Transaction signing failed (0x${statusWord.toRadixString(16)})',
        connectionType: ConnectionType.ble,
      );
}
