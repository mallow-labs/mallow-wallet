import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../ethereum_apdu.dart';
import '../models/ethereum_derivation_path.dart';

/// A derived Ethereum account: its uncompressed public key and address.
class EthereumLedgerAddress {
  const EthereumLedgerAddress({required this.publicKey, required this.address});

  /// 65-byte uncompressed secp256k1 public key (0x04 ‖ X ‖ Y).
  final Uint8List publicKey;

  /// Lowercase, `0x`-prefixed hex address as returned by the device. The
  /// caller is responsible for EIP-55 checksumming for display.
  final String address;
}

/// GET ETH ADDRESS — returns the public key + address for a derivation path.
///
/// APDU: CLA=0xE0, INS=0x02, P1=0x00 (no on-device confirm), P2=0x00
/// (no chain code), data=BIP32 path.
///
/// Response: [pubKeyLen][pubKey][addressLen][address(ASCII hex, no 0x)].
class EthereumGetAddressOperation
    extends LedgerRawOperation<EthereumLedgerAddress> {
  EthereumGetAddressOperation({required this.derivationPath});

  final EthereumDerivationPath derivationPath;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    final pathBytes = derivationPath.toBytes();

    writer.writeUint8(EthereumApdu.cla);
    writer.writeUint8(EthereumApdu.insGetAddress);
    writer.writeUint8(EthereumApdu.p1NoConfirm);
    writer.writeUint8(EthereumApdu.p2NoChainCode);
    writer.writeUint8(pathBytes.length); // Lc
    writer.write(pathBytes);

    return [writer.toBytes()];
  }

  @override
  Future<EthereumLedgerAddress> read(ByteDataReader reader) async {
    final pubKeyLen = reader.readUint8();
    final pubKey = reader.read(pubKeyLen);
    final addressLen = reader.readUint8();
    final addressBytes = reader.read(addressLen);
    // The device returns the 20-byte address as 40 ASCII hex chars, no prefix.
    final address = '0x${String.fromCharCodes(addressBytes).toLowerCase()}';
    return EthereumLedgerAddress(publicKey: pubKey, address: address);
  }
}
