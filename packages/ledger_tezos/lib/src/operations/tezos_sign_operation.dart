import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../tezos_apdu.dart';

/// SIGN — a SINGLE APDU exchange of the Tezos app's streamed sign command.
///
/// The Tezos app signs in multiple APDUs: packet 0 carries the BIP32 path
/// (P1=0x00), then the Micheline message is streamed in chunks (P1=0x01, the
/// final chunk ORs in [TezosApdu.p1Last]=0x80). The BLE gateway completes one
/// operation per response, so each APDU MUST be its own `sendOperation` — the
/// orchestration lives in `TezosLedgerApp.signMessage`, and this class models a
/// single packet of that stream.
///
/// Set [expectSignature] true only for the final packet: the device replies with
/// the raw 64-byte Ed25519 signature after the user confirms. Every earlier
/// packet (path + non-final chunks) replies with a bare `0x9000` ack, for which
/// [read] returns an empty list.
class TezosSignOperation extends LedgerRawOperation<Uint8List> {
  TezosSignOperation({
    required this.p1,
    required this.payload,
    required this.expectSignature,
  });

  /// The P1 byte for this packet (0x00 path, 0x01 chunk, 0x80 OR-ed on the last).
  final int p1;

  /// The APDU data field — the path bytes or a message chunk.
  final Uint8List payload;

  /// Whether this packet's response carries the signature (final packet) versus
  /// a bare success status word (path / intermediate chunks).
  final bool expectSignature;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(TezosApdu.cla);
    writer.writeUint8(TezosApdu.insSign);
    writer.writeUint8(p1);
    writer.writeUint8(TezosApdu.p2Ed25519);
    writer.writeUint8(payload.length); // Lc
    writer.write(payload);
    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    final available = reader.remainingLength;

    if (!expectSignature) {
      // Path / intermediate chunk: the device acks with a 2-byte status word.
      // 0x9000 = continue; anything else is a device error to surface.
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

    // Final chunk: a 64-byte signature on success, else a 2-byte status word.
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
        message:
            'Tezos message signing failed (0x${statusWord.toRadixString(16)})',
        connectionType: ConnectionType.ble,
      );
}
