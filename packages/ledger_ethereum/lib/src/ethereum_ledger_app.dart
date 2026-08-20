import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import 'ethereum_apdu.dart';
import 'models/ethereum_derivation_path.dart';
import 'operations/ethereum_get_address_operation.dart';
import 'operations/ethereum_sign_personal_message_operation.dart';
import 'operations/ethereum_sign_transaction_operation.dart';

/// The raw secp256k1 signature the Ethereum app returns for a transaction:
/// [v] is the recovery byte (parity for EIP-1559 type-2 txs), [r] and [s] are
/// the 32-byte big-endian signature components.
typedef EthereumLedgerSignature = ({int v, Uint8List r, Uint8List s});

/// High-level interface for the Ethereum Ledger app.
///
/// Wraps the low-level APDU operations into convenient methods. Each method
/// requires a [LedgerConnection] obtained from [LedgerInterface.connect].
class EthereumLedgerApp {
  const EthereumLedgerApp();

  /// Get the public key + address at the given derivation index
  /// (`m/44'/60'/0'/0/{account}`), without prompting the user on the device.
  Future<EthereumLedgerAddress> getAddress(
    LedgerConnection connection, {
    int account = 0,
  }) =>
      connection.sendOperation(
        EthereumGetAddressOperation(
          derivationPath: EthereumDerivationPath(account: account),
        ),
      );

  /// Discover multiple accounts by deriving addresses at sequential indices.
  Future<List<EthereumLedgerAddress>> getAccounts(
    LedgerConnection connection, {
    int count = 5,
    int startIndex = 0,
  }) async {
    final accounts = <EthereumLedgerAddress>[];
    for (var i = startIndex; i < startIndex + count; i++) {
      accounts.add(await getAddress(connection, account: i));
    }
    return accounts;
  }

  /// EIP-191 `personal_sign` of [message] at `m/44'/60'/0'/0/{account}`.
  ///
  /// app-ethereum streams the message across APDUs and the BLE gateway completes
  /// one operation per device response, so each packet is sent as its own
  /// [EthereumSignPersonalMessageOperation]: the first carries
  /// `[path][4-byte BE total length][chunk]`, continuations carry message bytes
  /// only. When the message fits one packet the device signs immediately; for a
  /// chunked message only the final packet returns the signature (after the user
  /// confirms — the device applies the `\x19Ethereum Signed Message:\n<len>`
  /// prefix, keccak256-hashes, and signs).
  ///
  /// Returns the 65-byte `r‖s‖v` signature (v normalized to {27, 28}).
  Future<Uint8List> signPersonalMessage(
    LedgerConnection connection, {
    required Uint8List message,
    int account = 0,
  }) async {
    final pathBytes = EthereumDerivationPath(account: account).toBytes();
    // First packet also carries the path and the 4-byte length, so its message
    // budget is smaller; keep every frame's data field within the 255-byte Lc.
    final firstBudget = 255 - pathBytes.length - 4;
    const contBudget = 230;

    var offset = 0;
    var first = true;
    var signature = Uint8List(0);
    // do/while so a zero-length message still sends the path + length frame.
    do {
      final budget = first ? firstBudget : contBudget;
      final end = math.min(offset + budget, message.length);
      final chunk = message.sublist(offset, end);
      final isLast = end >= message.length;

      final Uint8List data;
      if (first) {
        final builder = ByteDataWriter()
          ..write(pathBytes)
          // 4-byte big-endian total message length.
          ..writeUint8((message.length >> 24) & 0xff)
          ..writeUint8((message.length >> 16) & 0xff)
          ..writeUint8((message.length >> 8) & 0xff)
          ..writeUint8(message.length & 0xff)
          ..write(chunk);
        data = builder.toBytes();
      } else {
        data = chunk;
      }

      final result = await connection.sendOperation(
        EthereumSignPersonalMessageOperation(
          p1: first ? EthereumApdu.p1SignFirst : EthereumApdu.p1SignSubsequent,
          payload: data,
          expectSignature: isLast,
        ),
      );
      if (isLast) signature = result;

      offset = end;
      first = false;
    } while (offset < message.length);

    return signature;
  }

  /// Sign the RLP-serialized unsigned [rawTx] at `m/44'/60'/0'/0/{account}`.
  ///
  /// [rawTx] is the exact byte payload the device keccak256-hashes and signs —
  /// for an EIP-1559 transaction that is the `0x02`-prefixed RLP of the unsigned
  /// fields (i.e. `Transaction.getUnsignedSerialized`). app-ethereum streams it
  /// across APDUs and the BLE gateway completes one operation per device
  /// response, so each packet is sent as its own
  /// [EthereumSignTransactionOperation]: the first carries `[path][rlp-chunk]`,
  /// continuations carry RLP bytes only. Only the final packet returns the
  /// signature (after the user confirms the transaction on-device).
  ///
  /// Returns the raw `(v, r, s)` — the caller reassembles the signed envelope.
  Future<EthereumLedgerSignature> signTransaction(
    LedgerConnection connection, {
    required Uint8List rawTx,
    int account = 0,
  }) async {
    final pathBytes = EthereumDerivationPath(account: account).toBytes();
    // The first packet also carries the derivation path, so its transaction
    // budget is smaller; keep every frame's data field within the 255-byte Lc.
    final firstBudget = 255 - pathBytes.length;
    const contBudget = 230;

    var offset = 0;
    var first = true;
    var signature = (v: 0, r: Uint8List(0), s: Uint8List(0));
    // do/while so a (degenerate) empty payload still sends the path frame.
    do {
      final budget = first ? firstBudget : contBudget;
      final end = math.min(offset + budget, rawTx.length);
      final chunk = rawTx.sublist(offset, end);
      final isLast = end >= rawTx.length;

      final Uint8List data;
      if (first) {
        data = (ByteDataWriter()
              ..write(pathBytes)
              ..write(chunk))
            .toBytes();
      } else {
        data = chunk;
      }

      final result = await connection.sendOperation(
        EthereumSignTransactionOperation(
          p1: first ? EthereumApdu.p1SignFirst : EthereumApdu.p1SignSubsequent,
          payload: data,
          expectSignature: isLast,
        ),
      );
      if (isLast) {
        signature = (
          v: result[0],
          r: Uint8List.sublistView(result, 1, 33),
          s: Uint8List.sublistView(result, 33, 65),
        );
      }

      offset = end;
      first = false;
    } while (offset < rawTx.length);

    return signature;
  }
}
