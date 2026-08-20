import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:ed25519_hd_key/ed25519_hd_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:ledger_tezos/ledger_tezos.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';

void main() {
  group('TezosDerivationPath', () {
    test('encodes m/44\'/1729\'/{account}\'/0\' with all four hardened', () {
      final bytes = const TezosDerivationPath(account: 1).toBytes();

      // [depth][44'][1729'][account'][0']
      expect(bytes[0], 4, reason: 'four path components');
      expect(bytes.sublist(1, 5), [0x80, 0x00, 0x00, 0x2C]); // 44 hardened
      expect(bytes.sublist(5, 9), [0x80, 0x00, 0x06, 0xC1]); // 1729 hardened
      expect(bytes.sublist(9, 13), [0x80, 0x00, 0x00, 0x01]); // account 1 hard.
      expect(bytes.sublist(13, 17), [0x80, 0x00, 0x00, 0x00]); // 0 hardened
    });
  });

  group('TezosGetPublicKeyOperation', () {
    test(
      'writes the get-public-key APDU header + path (80 02 00 00)',
      () async {
        final op = TezosGetPublicKeyOperation(
          derivationPath: const TezosDerivationPath(),
        );

        final frame = (await op.write(ByteDataWriter())).single;
        final path = const TezosDerivationPath().toBytes();

        expect(frame[0], 0x80); // CLA
        expect(frame[1], 0x02); // INS get public key (no on-device confirm)
        expect(frame[2], 0x00); // P1
        expect(frame[3], 0x00); // P2 — ED25519 / tz1
        expect(frame[4], path.length); // Lc
        expect(frame.sublist(5), path);
      },
    );

    test(
      'strips the Ed25519 curve tag, returning the bare 32-byte key',
      () async {
        // Device returns [len=33][curve tag 0x02][32-byte key].
        final key32 = List<int>.generate(32, (i) => i + 1);
        final payload = <int>[33, 0x02, ...key32];
        final reader = ByteDataReader()..add(Uint8List.fromList(payload));

        final op = TezosGetPublicKeyOperation(
          derivationPath: const TezosDerivationPath(),
        );
        final result = await op.read(reader);

        expect(result, hasLength(32));
        expect(result, key32);
      },
    );
  });

  group('TezosSignOperation', () {
    // Each packet is its own APDU exchange (the BLE gateway completes one
    // operation per device response). The path packet and intermediate chunks
    // ack with 0x9000; only the final packet returns the signature.
    test('writes one APDU: [CLA, INS, p1, P2, Lc, payload]', () async {
      final payload = Uint8List.fromList(List<int>.generate(40, (i) => i));
      final op = TezosSignOperation(
        p1: TezosApdu.p1Message | TezosApdu.p1Last,
        payload: payload,
        expectSignature: true,
      );

      final frames = await op.write(ByteDataWriter());
      expect(frames, hasLength(1), reason: 'single APDU per operation');
      final frame = frames.single;
      // 0x81 = 0x01 message | 0x80 last.
      expect(frame.sublist(0, 5), [0x80, 0x04, 0x81, 0x00, payload.length]);
      expect(frame.sublist(5), payload);
    });

    test('path packet uses P1=0x00 and does not expect a signature', () async {
      final path = const TezosDerivationPath().toBytes();
      final op = TezosSignOperation(
        p1: TezosApdu.p1First,
        payload: path,
        expectSignature: false,
      );

      final frame = (await op.write(ByteDataWriter())).single;
      expect(frame.sublist(0, 5), [0x80, 0x04, 0x00, 0x00, path.length]);

      // The device acks the path packet with a bare 0x9000 — read returns empty.
      final ack = ByteDataReader()..add(Uint8List.fromList([0x90, 0x00]));
      expect(await op.read(ack), isEmpty);
    });

    test('final packet reads the 64-byte signature, ignoring the SW', () async {
      final sig = List<int>.generate(64, (i) => i + 1);
      // Device returns signature followed by the 0x9000 status word.
      final reader = ByteDataReader()
        ..add(Uint8List.fromList([...sig, 0x90, 0x00]));
      final op = TezosSignOperation(
        p1: TezosApdu.p1Message | TezosApdu.p1Last,
        payload: Uint8List(0),
        expectSignature: true,
      );

      expect(await op.read(reader), sig);
    });

    test('final packet throws on a rejection status word', () async {
      // 0x6985 = user rejected on device.
      final reader = ByteDataReader()..add(Uint8List.fromList([0x69, 0x85]));
      final op = TezosSignOperation(
        p1: TezosApdu.p1Message | TezosApdu.p1Last,
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

    test('ack packet throws when the status word is not 0x9000', () async {
      final reader = ByteDataReader()..add(Uint8List.fromList([0x6a, 0x80]));
      final op = TezosSignOperation(
        p1: TezosApdu.p1First,
        payload: Uint8List(0),
        expectSignature: false,
      );

      expect(() => op.read(reader), throwsA(isA<LedgerDeviceException>()));
    });
  });

  group('MultiChainDerivation.tezosAddressFromPublicKey', () {
    // The Ledger device returns the same 32-byte Ed25519 key (after tag
    // stripping) that SLIP-0010 derives from the seed, so a hardware import and
    // a seed-phrase import MUST yield the identical tz1 address at a given
    // index — otherwise a user re-importing the same key would see a different
    // account. This locks that invariant.
    test(
      'matches the seed-phrase Tezos derivation at the same index',
      () async {
        const mnemonic =
            'abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon about';
        const index = 3;

        final seed = bip39.mnemonicToSeed(mnemonic);
        final data = await ED25519_HD_KEY.derivePath(
          "m/44'/1729'/$index'/0'",
          seed,
        );
        final pubKey = await ED25519_HD_KEY.getPublicKey(data.key, false);

        final fromLedgerKey = MultiChainDerivation.tezosAddressFromPublicKey(
          Uint8List.fromList(pubKey),
        );
        final fromSeed = await MultiChainDerivation.getTezosAddressAtIndex(
          mnemonic,
          index,
        );

        expect(fromLedgerKey, fromSeed);
        expect(fromLedgerKey, startsWith('tz1'));
      },
    );
  });
}
