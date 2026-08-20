import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

import '../solana_apdu.dart';

/// Response from the Solana app configuration request.
class SolanaAppConfig {
  const SolanaAppConfig({
    required this.blindSigningEnabled,
    required this.pubKeyDisplayMode,
    required this.major,
    required this.minor,
    required this.patch,
  });

  final bool blindSigningEnabled;
  final int pubKeyDisplayMode;
  final int major;
  final int minor;
  final int patch;

  String get version => '$major.$minor.$patch';
}

/// GET APP CONFIGURATION — returns Solana app version and settings.
///
/// APDU: CLA=0xE0, INS=0x04, P1=0x00, P2=0x00, no data.
/// Response: [blindSigningFlag, pubKeyDisplayMode, major, minor, patch]
class SolanaGetAppConfigOperation extends LedgerRawOperation<SolanaAppConfig> {
  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(SolanaApdu.cla);
    writer.writeUint8(SolanaApdu.insGetAppConfig);
    writer.writeUint8(0x00); // P1
    writer.writeUint8(0x00); // P2
    writer.writeUint8(0x00); // Lc = 0 (no data)
    return [writer.toBytes()];
  }

  @override
  Future<SolanaAppConfig> read(ByteDataReader reader) async {
    final blindSigning = reader.readUint8();
    final pubKeyDisplay = reader.readUint8();
    final major = reader.readUint8();
    final minor = reader.readUint8();
    final patch = reader.readUint8();

    return SolanaAppConfig(
      blindSigningEnabled: blindSigning == 1,
      pubKeyDisplayMode: pubKeyDisplay,
      major: major,
      minor: minor,
      patch: patch,
    );
  }
}
