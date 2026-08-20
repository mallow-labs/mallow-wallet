import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../ethereum_apdu.dart';

/// SIGN PERSONAL MESSAGE — a SINGLE APDU exchange of the Ethereum app's
/// EIP-191 `personal_sign` stream.
///
/// app-ethereum streams the message across APDUs: the first packet (P1=0x00)
/// carries `[path][4-byte BE total length][chunk]`, continuations (P1=0x80)
/// carry message bytes only. The BLE gateway completes one operation per device
/// response, so each packet MUST be its own `sendOperation` — the orchestration
/// lives in `EthereumLedgerApp.signPersonalMessage`, and this class models a
/// single packet of that stream.
///
/// When the whole message fits one packet, that packet is also the last, so the
/// device returns the signature directly. For a chunked message the first/
/// intermediate packets return a bare `0x9000` ack (set [expectSignature] false)
/// and only the final packet returns `[v][r][s]`.
///
/// On the final packet [read] returns the 65-byte `r‖s‖v` with `v` normalized to
/// {27, 28} — the exact form `MultiChainDerivation.signEthereumPersonalMessage`
/// produces and the backend's `verifyMessage` recovers the signer from.
class EthereumSignPersonalMessageOperation
    extends LedgerRawOperation<Uint8List> {
  EthereumSignPersonalMessageOperation({
    required this.p1,
    required this.payload,
    required this.expectSignature,
  });

  /// The P1 byte for this packet (0x00 first, 0x80 continuation).
  final int p1;

  /// The APDU data field — `[path][len][chunk]` for the first packet, or a bare
  /// message chunk for a continuation.
  final Uint8List payload;

  /// Whether this packet's response carries the signature (final packet) versus
  /// a bare success status word (non-final packets of a chunked message).
  final bool expectSignature;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(EthereumApdu.cla);
    writer.writeUint8(EthereumApdu.insSignPersonalMessage);
    writer.writeUint8(p1);
    writer.writeUint8(EthereumApdu.p2SignPersonalMessage);
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
    // Some firmware returns v as the recovery id {0,1}; EIP-191 expects {27,28}.
    final vNormalized = v < 27 ? v + 27 : v;
    return Uint8List.fromList([...r, ...s, vNormalized]);
  }

  int _statusWord(ByteDataReader reader) {
    final sw1 = reader.readUint8();
    final sw2 = reader.readUint8();
    return (sw1 << 8) | sw2;
  }

  LedgerDeviceException _deviceError(int statusWord) => LedgerDeviceException(
        errorCode: statusWord,
        message:
            'Personal message signing failed (0x${statusWord.toRadixString(16)})',
        connectionType: ConnectionType.ble,
      );
}
