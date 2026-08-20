/// Solana Ledger app APDU constants.
///
/// Reference: https://github.com/LedgerHQ/app-solana
class SolanaApdu {
  SolanaApdu._();

  /// Class byte for the Solana Ledger app.
  static const int cla = 0xE0;

  /// Get app configuration (version, flags).
  static const int insGetAppConfig = 0x04;

  /// Get public key for a derivation path.
  static const int insGetPubkey = 0x05;

  /// Sign a Solana transaction.
  static const int insSignTransaction = 0x06;

  /// Sign an off-chain message (Anza spec).
  static const int insSignOffChainMessage = 0x07;

  /// P1: confirm signing on device.
  static const int p1Confirm = 0x01;

  // Legacy aliases (used by off-chain message and get-pubkey operations).
  static const int p1First = 0x01;
  static const int p1More = 0x02;

  /// P2 flags for chunked payloads (matches @ledgerhq/hw-app-solana).
  static const int p2Init = 0x00;
  static const int p2Extend = 0x01;
  static const int p2More = 0x02;

  /// Maximum data payload per APDU packet (excluding header).
  static const int maxChunkSize = 255;
}
