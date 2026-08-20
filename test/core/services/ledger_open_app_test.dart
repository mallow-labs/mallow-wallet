import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:mallow_wallet/core/services/ledger_open_app.dart';

void main() {
  group('LedgerOpenApp.fromAppName', () {
    test('maps the Solana app (case-insensitive)', () {
      expect(LedgerOpenApp.fromAppName('Solana'), LedgerOpenApp.solana);
      expect(LedgerOpenApp.fromAppName('solana'), LedgerOpenApp.solana);
      expect(LedgerOpenApp.fromAppName(' Solana '), LedgerOpenApp.solana);
    });

    test('maps the Ethereum app, including testnet/clone prefixes', () {
      expect(LedgerOpenApp.fromAppName('Ethereum'), LedgerOpenApp.ethereum);
      expect(
        LedgerOpenApp.fromAppName('Ethereum Sepolia'),
        LedgerOpenApp.ethereum,
      );
    });

    test('maps the Tezos app, including the "Tezos Wallet" name', () {
      expect(LedgerOpenApp.fromAppName('Tezos'), LedgerOpenApp.tezos);
      expect(LedgerOpenApp.fromAppName('Tezos Wallet'), LedgerOpenApp.tezos);
    });

    test('treats the dashboard and other apps as unsupported', () {
      // "BOLOS" is the dashboard — no app open, so we must prompt the user.
      expect(LedgerOpenApp.fromAppName('BOLOS'), LedgerOpenApp.unsupported);
      expect(LedgerOpenApp.fromAppName('Bitcoin'), LedgerOpenApp.unsupported);
    });
  });

  group('LedgerGetAppAndVersionOperation', () {
    test(
      'writes the BOLOS get-app-and-version APDU (B0 01 00 00 00)',
      () async {
        final frames = await LedgerGetAppAndVersionOperation().write(
          ByteDataWriter(),
        );
        expect(frames, hasLength(1));
        expect(
          frames.single,
          Uint8List.fromList([0xB0, 0x01, 0x00, 0x00, 0x00]),
        );
      },
    );

    test('parses the app name + version, exposing the open app', () async {
      const name = 'Ethereum';
      const version = '1.10.4';
      final payload = <int>[
        0x01, // format byte
        name.length, ...name.codeUnits,
        version.length, ...version.codeUnits,
        0x01, 0x00, // flags (ignored)
      ];
      final reader = ByteDataReader()..add(Uint8List.fromList(payload));

      final info = await LedgerGetAppAndVersionOperation().read(reader);

      expect(info.name, name);
      expect(info.version, version);
      expect(info.openApp, LedgerOpenApp.ethereum);
    });
  });
}
