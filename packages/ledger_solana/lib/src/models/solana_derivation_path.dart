import 'dart:typed_data';

/// The two Solana Ledger derivation conventions.
enum SolanaDerivationScheme {
  /// m/44'/501'/{account}'/0'  (4-level, BIP44-standard)
  /// Used by Phantom, Solflare, and Ledger Live.
  standard,

  /// m/44'/501'/{account}'  (3-level, legacy)
  /// Used by older Solana wallets (solana-keygen, SPL CLI).
  legacy,

  /// m/44'/501'  (2-level, root)
  /// Single account derived at the coin-type level.
  root,
}

/// Solana BIP44 derivation path.
///
/// [scheme] controls the depth:
/// - [SolanaDerivationScheme.standard]: m/44'/501'/{account}'/0'
/// - [SolanaDerivationScheme.legacy]:   m/44'/501'/{account}'
/// - [SolanaDerivationScheme.root]:     m/44'/501'
///
/// All indices are hardened (required by Ed25519/SLIP-0010).
class SolanaDerivationPath {
  const SolanaDerivationPath({
    this.account = 0,
    this.scheme = SolanaDerivationScheme.standard,
  });

  /// The account index in the BIP44 path.
  final int account;

  /// Which derivation convention to use.
  final SolanaDerivationScheme scheme;

  /// Hardened flag for BIP32 derivation.
  static const int _hardened = 0x80000000;

  /// The path components (2, 3, or 4 depending on scheme).
  List<int> get components => switch (scheme) {
        SolanaDerivationScheme.standard => [
            44 | _hardened,
            501 | _hardened,
            account | _hardened,
            0 | _hardened,
          ],
        SolanaDerivationScheme.legacy => [
            44 | _hardened,
            501 | _hardened,
            account | _hardened,
          ],
        SolanaDerivationScheme.root => [
            44 | _hardened,
            501 | _hardened,
          ],
      };

  /// Encode the derivation path as bytes for APDU transmission.
  ///
  /// Format: [depth (1 byte)] [component1 (4 bytes BE)] ... [componentN (4 bytes BE)]
  Uint8List toBytes() {
    final comps = components;
    final writer = ByteData(1 + comps.length * 4);
    writer.setUint8(0, comps.length);
    for (var i = 0; i < comps.length; i++) {
      writer.setUint32(1 + i * 4, comps[i]);
    }
    return Uint8List.view(writer.buffer);
  }
}
