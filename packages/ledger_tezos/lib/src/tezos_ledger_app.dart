import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import 'models/tezos_derivation_path.dart';
import 'operations/tezos_get_public_key_operation.dart';
import 'operations/tezos_sign_operation.dart';
import 'tezos_apdu.dart';

/// High-level interface for the Tezos Ledger app (the "Tezos Wallet" app).
///
/// Wraps the low-level APDU operations into convenient methods. Each method
/// requires a [LedgerConnection] obtained from [LedgerInterface.connect].
///
/// [getPublicKey]/[getAccounts] derive `tz1` addresses for display; [signMessage]
/// signs a Micheline-packed off-chain message; [signOperation] adds the
/// operation watermark to locally forged bytes. The device hashes and signs.
class TezosLedgerApp {
  const TezosLedgerApp();

  /// Get the 32-byte Ed25519 public key at `m/44'/1729'/{account}'/0'`,
  /// without prompting the user on the device.
  Future<Uint8List> getPublicKey(
    LedgerConnection connection, {
    int account = 0,
  }) =>
      connection.sendOperation(
        TezosGetPublicKeyOperation(
          derivationPath: TezosDerivationPath(account: account),
        ),
      );

  /// Discover multiple accounts by deriving public keys at sequential indices.
  Future<List<Uint8List>> getAccounts(
    LedgerConnection connection, {
    int count = 5,
    int startIndex = 0,
  }) async {
    final keys = <Uint8List>[];
    for (var i = startIndex; i < startIndex + count; i++) {
      keys.add(await getPublicKey(connection, account: i));
    }
    return keys;
  }

  /// Sign the Micheline-packed [message] at `m/44'/1729'/{account}'/0'`.
  ///
  /// The Tezos app streams a signature across multiple APDUs and the BLE gateway
  /// completes one operation per device response, so each packet is sent as its
  /// own [TezosSignOperation]: first the derivation path, then the message in
  /// ≤230-byte chunks. The path and any non-final chunk return a bare `0x9000`
  /// ack; the final chunk returns the signature after the user confirms on the
  /// device, which Blake2b-256-hashes the bytes and Ed25519-signs the digest.
  ///
  /// Returns the raw 64-byte signature.
  Future<Uint8List> signMessage(
    LedgerConnection connection, {
    required Uint8List message,
    int account = 0,
    void Function()? ensureActive,
  }) =>
      _signPayload(connection, message,
          account: account, ensureActive: ensureActive);

  /// Signs the operation watermark (0x03) followed by the locally forged
  /// operation group. The device hashes these bytes; callers must not hash.
  Future<Uint8List> signOperation(
    LedgerConnection connection, {
    required Uint8List operation,
    int account = 0,
    void Function()? ensureActive,
  }) {
    if (operation.length <= 32) {
      throw ArgumentError(
          'An operation needs a branch and at least one content');
    }
    return _signPayload(connection, Uint8List.fromList([3, ...operation]),
        account: account, ensureActive: ensureActive);
  }

  Future<Uint8List> _signPayload(
    LedgerConnection connection,
    Uint8List payload, {
    required int account,
    void Function()? ensureActive,
  }) async {
    // Snapshot before any device wait so the reviewed bytes cannot change.
    final message = Uint8List.fromList(payload).asUnmodifiableView();
    const maxChunkSize = 230;

    // Packet 0: derivation path (P1=0x00) — device acks, no signing yet.
    ensureActive?.call();
    await connection.sendOperation(
      TezosSignOperation(
        p1: TezosApdu.p1First,
        payload: TezosDerivationPath(account: account).toBytes(),
        expectSignature: false,
      ),
    );

    // Packets 1..n: message chunks. The final chunk ORs in the 0x80 last flag
    // and is the one that prompts the user and returns the signature.
    if (message.isEmpty) {
      ensureActive?.call();
      return connection.sendOperation(
        TezosSignOperation(
          p1: TezosApdu.p1Message | TezosApdu.p1Last,
          payload: message,
          expectSignature: true,
        ),
      );
    }

    var signature = Uint8List(0);
    for (var offset = 0; offset < message.length; offset += maxChunkSize) {
      final end = math.min(offset + maxChunkSize, message.length);
      final isLast = end >= message.length;
      ensureActive?.call();
      final result = await connection.sendOperation(
        TezosSignOperation(
          p1: TezosApdu.p1Message | (isLast ? TezosApdu.p1Last : 0),
          payload: message.sublist(offset, end),
          expectSignature: isLast,
        ),
      );
      ensureActive?.call();
      if (isLast) signature = result;
    }
    return signature;
  }
}
