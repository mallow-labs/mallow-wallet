import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import 'models/solana_derivation_path.dart';
import 'operations/solana_get_app_config_operation.dart';
import 'operations/solana_get_pubkey_operation.dart';
import 'operations/solana_sign_chunked_operation.dart';
import 'operations/solana_sign_offchain_message_operation.dart';
import 'operations/solana_sign_transaction_operation.dart';

/// High-level interface for the Solana Ledger app.
///
/// Wraps the low-level APDU operations into convenient methods.
/// Each method requires a [LedgerConnection] obtained from
/// [LedgerInterface.connect].
class SolanaLedgerApp {
  const SolanaLedgerApp();

  /// Get the Solana app configuration from the connected device.
  Future<SolanaAppConfig> getAppConfig(LedgerConnection connection) =>
      connection.sendOperation(SolanaGetAppConfigOperation());

  /// Get the Ed25519 public key at the given derivation index.
  ///
  /// Returns raw 32-byte public key.
  Future<Uint8List> getPublicKey(
    LedgerConnection connection, {
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) =>
      connection.sendOperation(
        SolanaGetPubkeyOperation(
          derivationPath:
              SolanaDerivationPath(account: account, scheme: scheme),
        ),
      );

  /// Discover multiple accounts by deriving public keys at sequential indices.
  ///
  /// Returns a list of 32-byte public keys.
  Future<List<Uint8List>> getAccounts(
    LedgerConnection connection, {
    int count = 5,
    int startIndex = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) async {
    final keys = <Uint8List>[];
    for (var i = startIndex; i < startIndex + count; i++) {
      final key = await getPublicKey(connection, account: i, scheme: scheme);
      keys.add(key);
    }
    return keys;
  }

  /// Sign a compiled Solana transaction message.
  ///
  /// [transaction] should be the compiled message bytes (not the full signed
  /// transaction envelope). The user must confirm on the Ledger device.
  ///
  /// Returns a 64-byte Ed25519 signature.
  Future<Uint8List> signTransaction(
    LedgerConnection connection, {
    required Uint8List transaction,
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) =>
      connection.sendOperation(
        SolanaSignChunkedOperation(
          derivationPath:
              SolanaDerivationPath(account: account, scheme: scheme),
          data: transaction,
          buildFrame: (p2, chunk, isLast) => SolanaSignTransactionOperation(
            p2: p2,
            payload: chunk,
            expectSignature: isLast,
          ),
        ),
      );

  /// Sign an off-chain message (Anza spec).
  ///
  /// The user must confirm on the Ledger device.
  ///
  /// Returns a 64-byte Ed25519 signature.
  Future<Uint8List> signOffChainMessage(
    LedgerConnection connection, {
    required Uint8List message,
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) =>
      connection.sendOperation(
        SolanaSignChunkedOperation(
          derivationPath:
              SolanaDerivationPath(account: account, scheme: scheme),
          data: message,
          buildFrame: (p2, chunk, isLast) => SolanaSignOffChainMessageOperation(
            p2: p2,
            payload: chunk,
            expectSignature: isLast,
          ),
        ),
      );
}
