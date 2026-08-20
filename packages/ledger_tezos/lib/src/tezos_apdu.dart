/// Tezos Ledger app (Wallet app) APDU constants.
///
/// Reference: https://github.com/LedgerHQ/app-tezos (app/docs/apdu.md)
class TezosApdu {
  TezosApdu._();

  /// Class byte for the Tezos Ledger app (always 0x80).
  static const int cla = 0x80;

  /// Get a public key for a derivation path, without on-device confirmation.
  static const int insGetPublicKey = 0x02;

  /// Get a public key and prompt the user to confirm it on the device screen.
  static const int insPromptPublicKey = 0x03;

  /// Sign a message: the device Blake2b-256-hashes the bytes and Ed25519-signs
  /// the digest after on-screen confirmation (magic byte 0x05 = Micheline).
  static const int insSign = 0x04;

  /// P1: index of the message — 0x00 for the single-APDU get-public-key call,
  /// and the first (derivation-path) packet of a multi-packet sign.
  static const int p1First = 0x00;

  /// P1: a message-payload packet of a sign command (follows the path packet).
  static const int p1Message = 0x01;

  /// P1 high bit OR-ed onto the final sign packet to mark the end of the stream.
  static const int p1Last = 0x80;

  /// P2: derivation type ED25519 — the curve behind `tz1` addresses.
  static const int p2Ed25519 = 0x00;
}
