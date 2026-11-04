import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../eip712/eip712_ledger_frames.dart';
import '../ethereum_apdu.dart';

/// A single APDU exchange for one [EthereumApduFrame] of a multi-packet
/// stream (EIP-712 typed data).
///
/// The BLE gateway completes one operation per device response, so the
/// stream is sent one frame per operation, as `EthereumLedgerApp` does for
/// transactions. A frame that does not return a signature expects a bare
/// `0x9000`; the final frame returns the 65-byte `r‖s‖v`, with `v` normalized
/// to {27, 28}.
class EthereumFrameOperation extends LedgerRawOperation<Uint8List> {
  EthereumFrameOperation(this.frame);

  final EthereumApduFrame frame;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(EthereumApdu.cla);
    writer.writeUint8(frame.ins);
    writer.writeUint8(frame.p1);
    writer.writeUint8(frame.p2);
    writer.writeUint8(frame.data.length); // Lc
    writer.write(frame.data);
    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    final available = reader.remainingLength;
    if (!frame.returnsSignature) {
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
    if (available < 65) {
      if (available >= 2) throw _deviceError(_statusWord(reader));
      throw LedgerDeviceException(
        message: 'Unexpected response length: $available bytes',
        connectionType: ConnectionType.ble,
      );
    }
    final v = reader.readUint8();
    final r = reader.read(32);
    final s = reader.read(32);
    return Uint8List.fromList([...r, ...s, v < 27 ? v + 27 : v]);
  }

  int _statusWord(ByteDataReader reader) {
    final sw1 = reader.readUint8();
    final sw2 = reader.readUint8();
    return (sw1 << 8) | sw2;
  }

  LedgerDeviceException _deviceError(int statusWord) => LedgerDeviceException(
        errorCode: statusWord,
        message:
            'Typed data signing failed (0x${statusWord.toRadixString(16)})',
        connectionType: ConnectionType.ble,
      );
}
