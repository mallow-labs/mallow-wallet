import 'dart:typed_data';

import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';

/// Which Ledger app the user currently has open on the device.
///
/// Determined from the dashboard-level "Get App and Version" APDU, which the
/// BOLOS OS answers from inside any running app — so we can route the import
/// to the right chain instead of asking the user to pick one.
enum LedgerOpenApp {
  solana,
  ethereum,
  tezos,

  /// The device is on the dashboard (`BOLOS`) or running an app we don't
  /// support for import. The caller should prompt the user to open Solana,
  /// Ethereum, or Tezos.
  unsupported;

  /// Map the device-reported app name to a [LedgerOpenApp]. The Ethereum app
  /// reports itself as "Ethereum" and the Tezos app as "Tezos Wallet";
  /// testnet/clone apps prefix the base name (e.g. "Ethereum Sepolia"), so we
  /// match by prefix.
  static LedgerOpenApp fromAppName(String name) {
    final n = name.trim().toLowerCase();
    if (n == 'solana') return LedgerOpenApp.solana;
    if (n.startsWith('ethereum')) return LedgerOpenApp.ethereum;
    if (n.startsWith('tezos')) return LedgerOpenApp.tezos;
    return LedgerOpenApp.unsupported;
  }
}

/// The app name + version reported by a connected Ledger device.
class LedgerAppInfo {
  const LedgerAppInfo({required this.name, required this.version});

  /// e.g. "Solana", "Ethereum", or "BOLOS" when on the dashboard.
  final String name;
  final String version;

  LedgerOpenApp get openApp => LedgerOpenApp.fromAppName(name);
}

/// GET APP AND VERSION — a BOLOS dashboard command (CLA=0xB0, INS=0x01) that
/// every Ledger app proxies to the OS, returning the running app's name and
/// version regardless of which app is open.
///
/// Response: [format(1)][nameLen][name(ASCII)][versionLen][version(ASCII)]...
class LedgerGetAppAndVersionOperation
    extends LedgerRawOperation<LedgerAppInfo> {
  @override
  Future<List<Uint8List>> write(ByteDataWriter writer) async {
    writer.writeUint8(0xB0); // CLA (BOLOS)
    writer.writeUint8(0x01); // INS (get app and version)
    writer.writeUint8(0x00); // P1
    writer.writeUint8(0x00); // P2
    writer.writeUint8(0x00); // Lc = 0 (no data)
    return [writer.toBytes()];
  }

  @override
  Future<LedgerAppInfo> read(ByteDataReader reader) async {
    reader.readUint8(); // format byte (always 1)
    final nameLen = reader.readUint8();
    final name = String.fromCharCodes(reader.read(nameLen));
    final versionLen = reader.readUint8();
    final version = String.fromCharCodes(reader.read(versionLen));
    return LedgerAppInfo(name: name, version: version);
  }
}
