import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../models/solana_derivation_path.dart';
import '../solana_apdu.dart';

/// GET PUBKEY — returns the 32-byte Ed25519 public key for a derivation path.
///
/// APDU: CLA=0xE0, INS=0x05, P1=0x00, P2=0x00, data=BIP32 path.
/// Response: 32 bytes (Ed25519 public key).
class SolanaGetPubkeyOperation extends LedgerRawOperation<Uint8List> {
  SolanaGetPubkeyOperation({required this.derivationPath});

  final SolanaDerivationPath derivationPath;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    final pathBytes = derivationPath.toBytes();

    writer.writeUint8(SolanaApdu.cla);
    writer.writeUint8(SolanaApdu.insGetPubkey);
    writer.writeUint8(0x00); // P1
    writer.writeUint8(0x00); // P2
    writer.writeUint8(pathBytes.length); // Lc
    writer.write(pathBytes);

    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    // Response is 32 bytes: Ed25519 public key.
    return reader.read(32);
  }
}
