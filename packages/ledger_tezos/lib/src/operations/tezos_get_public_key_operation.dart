import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../models/tezos_derivation_path.dart';
import '../tezos_apdu.dart';

/// GET PUBLIC KEY — returns the Ed25519 public key for a derivation path,
/// without prompting the user on the device.
///
/// APDU: CLA=0x80, INS=0x02, P1=0x00, P2=0x00 (ED25519 / tz1), data=BIP32 path.
///
/// Response: [pubKeyLen][pubKey]. For Ed25519 the device returns a 33-byte key
/// — a one-byte curve tag followed by the raw 32-byte key — so we strip the tag
/// and return the bare 32-byte key, which is what tz1 address encoding
/// (Blake2b-160 + Base58Check) operates on.
class TezosGetPublicKeyOperation extends LedgerRawOperation<Uint8List> {
  TezosGetPublicKeyOperation({required this.derivationPath});

  final TezosDerivationPath derivationPath;

  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    final pathBytes = derivationPath.toBytes();

    writer.writeUint8(TezosApdu.cla);
    writer.writeUint8(TezosApdu.insGetPublicKey);
    writer.writeUint8(TezosApdu.p1First);
    writer.writeUint8(TezosApdu.p2Ed25519);
    writer.writeUint8(pathBytes.length); // Lc
    writer.write(pathBytes);

    return [writer.toBytes()];
  }

  @override
  Future<Uint8List> read(ByteDataReader reader) async {
    final len = reader.readUint8();
    final key = reader.read(len);
    // Ed25519 keys come back tagged (curve byte ‖ 32-byte key). Strip the tag
    // so callers get the bare 32-byte key the tz1 encoder expects.
    return key.length == 33 ? Uint8List.fromList(key.sublist(1)) : key;
  }
}
