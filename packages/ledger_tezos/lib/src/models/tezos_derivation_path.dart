import 'dart:typed_data';

/// Tezos BIP44 derivation path: `m/44'/1729'/{account}'/0'`.
///
/// All four components are hardened — Ed25519 (SLIP-0010) supports only
/// hardened children. This matches the app's own mnemonic Tezos derivation
/// (`MultiChainDerivation.getTezosAddressAtIndex`) and Ledger Live, so a
/// Ledger-imported tz1 address matches a seed-imported one at the same index.
class TezosDerivationPath {
  const TezosDerivationPath({this.account = 0});

  /// The account index in the BIP44 path (the third, hardened component).
  final int account;

  /// Hardened flag for BIP32 derivation.
  static const int _hardened = 0x80000000;

  /// The four path components: `44' / 1729' / account' / 0'`.
  List<int> get components => [
        44 | _hardened,
        1729 | _hardened,
        account | _hardened,
        0 | _hardened,
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
