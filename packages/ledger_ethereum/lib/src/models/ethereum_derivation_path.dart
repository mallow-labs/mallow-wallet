import 'dart:typed_data';

/// Ethereum BIP44 derivation path: `m/44'/60'/0'/0/{account}`.
///
/// This is the path used by MetaMask, Ledger Live, and the app's own
/// mnemonic Ethereum derivation (`Derivation.ethereumPath`). Only the first
/// three components are hardened (secp256k1 supports non-hardened children),
/// which is why this differs from the all-hardened Solana scheme.
class EthereumDerivationPath {
  const EthereumDerivationPath({this.account = 0});

  /// The address index in the BIP44 path (the final, non-hardened component).
  final int account;

  /// Hardened flag for BIP32 derivation.
  static const int _hardened = 0x80000000;

  /// The five path components: `44' / 60' / 0' / 0 / account`.
  List<int> get components => [
        44 | _hardened,
        60 | _hardened,
        0 | _hardened,
        0,
        account,
      ];

  /// Encode the derivation path as bytes for APDU transmission.
  ///
  /// Format: [depth (1 byte)] [component1 (4 bytes BE)] ... [componentN]
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
