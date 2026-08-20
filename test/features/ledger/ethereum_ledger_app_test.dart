import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';

void main() {
  group('EthereumDerivationPath', () {
    test(
      'encodes m/44\'/60\'/0\'/0/{account} with only the first 3 hardened',
      () {
        final bytes = const EthereumDerivationPath(account: 1).toBytes();

        // [depth][44'][60'][0'][0][account]
        expect(bytes[0], 5, reason: 'five path components');
        expect(bytes.sublist(1, 5), [0x80, 0x00, 0x00, 0x2C]); // 44 hardened
        expect(bytes.sublist(5, 9), [0x80, 0x00, 0x00, 0x3C]); // 60 hardened
        expect(bytes.sublist(9, 13), [0x80, 0x00, 0x00, 0x00]); // 0 hardened
        expect(bytes.sublist(13, 17), [0x00, 0x00, 0x00, 0x00]); // change 0
        expect(bytes.sublist(17, 21), [0x00, 0x00, 0x00, 0x01]); // account 1
      },
    );
  });

  group('EthereumGetAddressOperation', () {
    test(
      'writes the get-address APDU header + path, no on-device confirm',
      () async {
        final op = EthereumGetAddressOperation(
          derivationPath: const EthereumDerivationPath(),
        );

        final frame = (await op.write(ByteDataWriter())).single;
        final path = const EthereumDerivationPath().toBytes();

        expect(frame[0], 0xE0); // CLA
        expect(frame[1], 0x02); // INS get address
        expect(frame[2], 0x00); // P1 — derive silently (no user confirm)
        expect(frame[3], 0x00); // P2 — no chain code
        expect(frame[4], path.length); // Lc
        expect(frame.sublist(5), path);
      },
    );

    test('parses the address, lowercasing and 0x-prefixing it', () async {
      // Device returns 40 ASCII hex chars (no 0x), here mixed-case.
      const deviceHex = '52908400098527886E0F7030069857D2E4169EE7';
      final payload = <int>[
        65, ...List.filled(65, 0xAB), // uncompressed public key
        deviceHex.length, ...deviceHex.codeUnits,
      ];
      final reader = ByteDataReader()..add(Uint8List.fromList(payload));

      final op = EthereumGetAddressOperation(
        derivationPath: const EthereumDerivationPath(),
      );
      final result = await op.read(reader);

      expect(result.address, '0x${deviceHex.toLowerCase()}');
      expect(result.publicKey, hasLength(65));
    });
  });

  group('EthereumSignPersonalMessageOperation', () {
    // Each packet is its own APDU exchange. For a single-packet message the
    // first packet is also the last and returns the signature; chunked messages
    // ack non-final packets with 0x9000.
    test('writes one APDU: [CLA, INS, p1, P2, Lc, payload]', () async {
      final payload = Uint8List.fromList(List<int>.generate(40, (i) => i));
      final op = EthereumSignPersonalMessageOperation(
        p1: 0x00,
        payload: payload,
        expectSignature: true,
      );

      final frames = await op.write(ByteDataWriter());
      expect(frames, hasLength(1), reason: 'single APDU per operation');
      final frame = frames.single;
      expect(frame.sublist(0, 5), [0xE0, 0x08, 0x00, 0x00, payload.length]);
      expect(frame.sublist(5), payload);
    });

    test('returns r‖s‖v, normalizing v=0 to 27', () async {
      final r = List<int>.generate(32, (i) => i + 1);
      final s = List<int>.generate(32, (i) => i + 100);
      // Device response is [v][r][s] + 0x9000 SW; v is the raw recovery id 0.
      final reader = ByteDataReader()
        ..add(Uint8List.fromList([0x00, ...r, ...s, 0x90, 0x00]));
      final op = EthereumSignPersonalMessageOperation(
        p1: 0x00,
        payload: Uint8List(0),
        expectSignature: true,
      );

      final sig = await op.read(reader);
      expect(sig, hasLength(65));
      expect(sig.sublist(0, 32), r);
      expect(sig.sublist(32, 64), s);
      expect(sig[64], 27, reason: 'v=0 recovery id normalized to 27');
    });

    test('leaves an already-EIP-191 v (28) unchanged', () async {
      final body = List<int>.generate(64, (i) => i);
      final reader = ByteDataReader()
        ..add(Uint8List.fromList([28, ...body, 0x90, 0x00]));
      final op = EthereumSignPersonalMessageOperation(
        p1: 0x00,
        payload: Uint8List(0),
        expectSignature: true,
      );

      final sig = await op.read(reader);
      expect(sig[64], 28);
    });

    test('non-final packet acks 0x9000 with an empty read', () async {
      final reader = ByteDataReader()..add(Uint8List.fromList([0x90, 0x00]));
      final op = EthereumSignPersonalMessageOperation(
        p1: 0x80,
        payload: Uint8List(0),
        expectSignature: false,
      );

      expect(await op.read(reader), isEmpty);
    });

    test('throws a device exception on a status-word error response', () async {
      final reader = ByteDataReader()..add(Uint8List.fromList([0x69, 0x85]));
      final op = EthereumSignPersonalMessageOperation(
        p1: 0x00,
        payload: Uint8List(0),
        expectSignature: true,
      );

      expect(
        () => op.read(reader),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'errorCode',
            0x6985,
          ),
        ),
      );
    });
  });

  group('MultiChainDerivation.checksumEthereumAddress', () {
    test('EIP-55 checksums a lowercase device address for display', () {
      // Known EIP-55 vector (EIP-55 spec).
      const lower = '0x52908400098527886e0f7030069857d2e4169ee7';
      expect(
        MultiChainDerivation.checksumEthereumAddress(lower),
        '0x52908400098527886E0F7030069857D2E4169EE7',
      );
    });
  });
}
