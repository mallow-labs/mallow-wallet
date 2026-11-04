import 'dart:math';
import 'dart:typed_data';

import 'package:keystone_ur/keystone_ur.dart';
import 'package:keystone_ur/src/bc_ur/bytewords.dart';
import 'package:keystone_ur/src/bc_ur/fountain_encoder.dart';
import 'package:keystone_ur/src/cbor_shape.dart';
import 'package:test/test.dart';

final throwsDecode = throwsA(isA<UrDecodeException>());

Uint8List randomBytes(Random rng, int n) =>
    Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

/// A multi-part UR string for an arbitrary fountain part.
String partString(String type, FountainPart p) =>
    'ur:$type/${p.seqNum}-${p.seqLen}/${Bytewords.encode(BytewordsStyle.minimal, p.toCbor())}';

void main() {
  group('UrEncoder', () {
    test('single part: repeats the same uppercase string', () {
      final ur = UR('bytes', Uint8List.fromList([0x43, 1, 2, 3]));
      final encoder = UrEncoder(ur);
      expect(encoder.isSinglePart, isTrue);
      expect(encoder.fragmentCount, 1);
      final first = encoder.nextPart();
      expect(first, startsWith('UR:BYTES/'));
      expect(first, isNot(contains('-')));
      expect(encoder.nextPart(), first);
    });

    test('multi part: pure fragments first, then fountain parts forever', () {
      final ur = UR('bytes', randomBytes(Random(1), 1000));
      final encoder = UrEncoder(ur);
      expect(encoder.isSinglePart, isFalse);
      expect(encoder.fragmentCount, 5);
      final parts = [for (var i = 0; i < 12; i++) encoder.nextPart()];
      expect(parts[0], startsWith('UR:BYTES/1-5/'));
      expect(parts[4], startsWith('UR:BYTES/5-5/'));
      expect(parts[11], startsWith('UR:BYTES/12-5/'));
      expect(parts.every((p) => p == p.toUpperCase()), isTrue);
    });

    test('keystone constants', () {
      expect(kKeystoneFragmentLength, 200);
      expect(kKeystoneFrameInterval, const Duration(milliseconds: 150));
    });

    test('rejects an invalid type', () {
      expect(() => UrEncoder(UR('Bad_Type', Uint8List(1))), throwsArgumentError);
    });
  });

  group('round trips', () {
    test('random payloads 1..5000 bytes, shuffled, ~30% dropped', () {
      final rng = Random(20261002);
      final sizes = [1, 2, 9, 10, 11, 199, 200, 201, 399, 400, 401, 1000, 2047, 4096, 5000];
      for (var i = 0; i < 25; i++) {
        sizes.add(1 + rng.nextInt(5000));
      }
      for (final size in sizes) {
        final ur = UR('crypto-multi-accounts', randomBytes(rng, size));
        final encoder = UrEncoder(ur, maxFragmentLength: 200);
        final decoder = UrDecoder(expectedTypes: {'crypto-multi-accounts'});

        // The first lap: every pure fragment once, in random order, ~30%
        // dropped. Then keep feeding fountain parts (also ~30% dropped),
        // in small shuffled batches, until done.
        final firstLap = [for (var i = 0; i < encoder.fragmentCount; i++) encoder.nextPart()]
          ..shuffle(rng);
        for (final p in firstLap) {
          if (rng.nextDouble() < 0.3) continue;
          expect(decoder.receivePart(p), isTrue);
        }
        var sent = encoder.fragmentCount;
        while (!decoder.isComplete) {
          final batch = [for (var i = 0; i < 4; i++) encoder.nextPart()]..shuffle(rng);
          for (final p in batch) {
            if (rng.nextDouble() < 0.3) continue;
            expect(decoder.receivePart(p), isTrue);
          }
          sent += 4;
          expect(sent, lessThan(encoder.fragmentCount * 20 + 100), reason: 'size $size stalled');
        }
        expect(decoder.progress, 1.0);
        expect(decoder.result!.type, ur.type);
        expect(decoder.result!.cbor, ur.cbor, reason: 'size $size');
      }
    });

    test('mixed-case input decodes', () {
      final rng = Random(7);
      final ur = UR('sol-sign-request', randomBytes(rng, 700));
      final encoder = UrEncoder(ur);
      final decoder = UrDecoder();
      var i = 0;
      while (!decoder.isComplete) {
        final p = encoder.nextPart();
        final mixed = String.fromCharCodes(
          p.codeUnits.map(
            (c) => (i++).isEven ? c : String.fromCharCode(c).toLowerCase().codeUnitAt(0),
          ),
        );
        decoder.receivePart(' $mixed\n');
      }
      expect(decoder.result!.cbor, ur.cbor);
    });

    test('progress rises monotonically from 0 to 1', () {
      final ur = UR('bytes', randomBytes(Random(3), 2000));
      final encoder = UrEncoder(ur);
      final decoder = UrDecoder();
      expect(decoder.progress, 0);
      var last = 0.0;
      while (!decoder.isComplete) {
        decoder.receivePart(encoder.nextPart());
        expect(decoder.progress, greaterThanOrEqualTo(last));
        expect(decoder.progress, lessThanOrEqualTo(1));
        last = decoder.progress;
      }
      expect(decoder.progress, 1);
      expect(decoder.expectedFragmentCount, encoder.fragmentCount);
    });

    test('duplicates and parts after completion are accepted', () {
      final ur = UR('bytes', randomBytes(Random(4), 500));
      final encoder = UrEncoder(ur);
      final decoder = UrDecoder();
      final first = encoder.nextPart();
      expect(decoder.receivePart(first), isTrue);
      expect(decoder.receivePart(first), isTrue);
      while (!decoder.isComplete) {
        decoder.receivePart(encoder.nextPart());
      }
      expect(decoder.receivePart(encoder.nextPart()), isTrue);
      expect(decoder.receivePart(first), isTrue);
      expect(decoder.result!.cbor, ur.cbor);
    });
  });

  group('UrDecoder rejects', () {
    test('non-UR QR codes return false', () {
      final decoder = UrDecoder();
      expect(decoder.receivePart('https://example.com'), isFalse);
      expect(decoder.receivePart('solana:abc'), isFalse);
      expect(decoder.receivePart(''), isFalse);
      expect(decoder.isComplete, isFalse);
    });

    test('a type outside expectedTypes', () {
      final decoder = UrDecoder(expectedTypes: {'sol-signature'});
      final ur = UR('eth-signature', Uint8List.fromList([0xa0]));
      expect(() => decoder.receivePart(UrEncoder(ur).nextPart()), throwsDecode);
    });

    test('a type change mid-scan', () {
      final decoder = UrDecoder();
      final a = UrEncoder(UR('bytes', randomBytes(Random(5), 600)));
      decoder.receivePart(a.nextPart());
      final b = UrEncoder(UR('other', randomBytes(Random(5), 600)));
      expect(() => decoder.receivePart(b.nextPart()), throwsDecode);
    });

    test('a part from a different message (different checksum) mid-stream', () {
      final rng = Random(6);
      final decoder = UrDecoder();
      final a = UrEncoder(UR('bytes', randomBytes(rng, 600)));
      final b = UrEncoder(UR('bytes', randomBytes(rng, 600)));
      decoder.receivePart(a.nextPart());
      expect(() => decoder.receivePart(b.nextPart()), throwsDecode);
    });

    test('a sequence length above maxSequenceLength', () {
      final ur = UR('bytes', randomBytes(Random(8), 3000));
      final encoder = UrEncoder(ur, maxFragmentLength: 100);
      expect(encoder.fragmentCount, 30);
      final decoder = UrDecoder(maxSequenceLength: 29);
      expect(() => decoder.receivePart(encoder.nextPart()), throwsDecode);
      expect(UrDecoder(maxSequenceLength: 30).receivePart(encoder.nextPart()), isTrue);
    });

    test('a message above maxMessageLength, single- and multi-part', () {
      final big = UR('bytes', randomBytes(Random(9), 1000));
      expect(
        () => UrDecoder(maxMessageLength: 999).receivePart(UrEncoder.encodeSinglePart(big)),
        throwsDecode,
      );
      expect(
        () => UrDecoder(maxMessageLength: 999).receivePart(UrEncoder(big).nextPart()),
        throwsDecode,
      );
      expect(() => UrDecoder().receivePart('ur:bytes/${'ae' * 200000}'), throwsDecode);
    });

    test('a bytewords checksum failure', () {
      final s = UrEncoder.encodeSinglePart(UR('bytes', Uint8List.fromList([0x41, 0x55])));
      final corrupted = '${s.substring(0, s.length - 2)}${s.endsWith('ae') ? 'ad' : 'ae'}';
      expect(() => UrDecoder().receivePart(corrupted), throwsDecode);
    });

    test('a fountain checksum failure (consistent headers, wrong data)', () {
      final message = randomBytes(Random(10), 50);
      final good = FountainEncoder(message, 20);
      final decoder = UrDecoder();
      final parts = [for (var i = 0; i < good.seqLen; i++) good.nextPart()];
      parts.last.data[0] ^= 0xFF;
      expect(() {
        for (final p in parts) {
          decoder.receivePart(partString('bytes', p));
        }
      }, throwsDecode);
      expect(decoder.isComplete, isFalse);
      expect(decoder.result, isNull);
      for (final next in [
        partString('bytes', parts.first),
        partString('bytes', good.nextPart()),
        UrEncoder.encodeSinglePart(UR('bytes', message)),
        'some other QR code',
      ]) {
        expect(() => decoder.receivePart(next), throwsDecode);
        expect(decoder.isComplete, isFalse);
        expect(decoder.result, isNull);
      }
    });

    test('a header that disagrees with its sequence component', () {
      final encoder = FountainEncoder(randomBytes(Random(11), 100), 30);
      final p = encoder.nextPart();
      final body = Bytewords.encode(BytewordsStyle.minimal, p.toCbor());
      expect(() => UrDecoder().receivePart('ur:bytes/2-${p.seqLen}/$body'), throwsDecode);
    });

    test('structurally impossible parts', () {
      FountainPart part({int seqNum = 1, int seqLen = 2, int messageLen = 20, int dataLen = 10}) =>
          FountainPart(
            seqNum: seqNum,
            seqLen: seqLen,
            messageLen: messageLen,
            checksum: 1,
            data: Uint8List(dataLen),
          );
      // seqLen disagrees with messageLen / fragment length.
      expect(() => UrDecoder().receivePart(partString('bytes', part(seqLen: 3))), throwsDecode);
      expect(() => UrDecoder().receivePart(partString('bytes', part(dataLen: 0))), throwsDecode);
      // seqNum 0 cannot even be expressed: the sequence component rejects it.
      final p0 = part();
      final body = Bytewords.encode(BytewordsStyle.minimal, p0.toCbor());
      expect(() => UrDecoder().receivePart('ur:bytes/0-2/$body'), throwsDecode);
    });

    test('malformed UR strings', () {
      for (final bad in [
        'ur:',
        'ur:bytes',
        'ur:bytes/',
        'ur:by_tes/aeadaolazmjendeoti',
        'ur:bytes/1-2/3/aeadaolazmjendeoti',
        'ur:bytes/x-2/aeadaolazmjendeoti',
        'ur:bytes/1-/aeadaolazmjendeoti',
        'ur:bytes/99999999999-2/aeadaolazmjendeoti',
        'ur:bytes/aeadaolazmjendeot',
        'ur:bytes/1-1/aeadaolazmjendeoti', // valid bytewords, but not a part
      ]) {
        expect(() => UrDecoder().receivePart(bad), throwsDecode, reason: bad);
      }
    });

    test('truncated multi-part body', () {
      final encoder = UrEncoder(UR('bytes', randomBytes(Random(12), 600)));
      final p = encoder.nextPart();
      expect(() => UrDecoder().receivePart(p.substring(0, p.length - 10)), throwsDecode);
    });

    test('fuzz: random mutations never escape as anything but UrDecodeException', () {
      final rng = Random(13);
      final ur = UR('sol-signature', randomBytes(rng, 700));
      final encoder = UrEncoder(ur);
      const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789-/:';
      for (var i = 0; i < 2000; i++) {
        final chars = encoder.nextPartLowercase().split('');
        final edits = 1 + rng.nextInt(3);
        for (var e = 0; e < edits; e++) {
          final at = rng.nextInt(chars.length);
          switch (rng.nextInt(3)) {
            case 0:
              chars[at] = alphabet[rng.nextInt(alphabet.length)];
            case 1:
              chars.removeAt(at);
            default:
              chars.insert(at, alphabet[rng.nextInt(alphabet.length)]);
          }
        }
        final decoder = UrDecoder(expectedTypes: {'sol-signature'});
        try {
          decoder.receivePart(chars.join());
        } on UrDecodeException {
          // expected
        }
      }
    });
  });

  group('cborShapeError', () {
    Uint8List b(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    test('accepts well-formed definite items', () {
      for (final ok in [
        '00',
        'a0',
        '80',
        '40',
        '60',
        'f5',
        'f6',
        'fb3ff0000000000000',
        'd8255000000000000000000000000000000000',
        'a201820102028180',
        '1bffffffffffffffff',
      ]) {
        expect(cborShapeError(b(ok)), isNull, reason: ok);
      }
    });
    test('rejects duplicate integer map keys before decoding collapses them', () {
      for (final bad in [
        'a202000201',
        'a20200180201', // Same integer with a wider encoding.
        'a22000380001', // Duplicate negative key.
        'a201a2020002010280', // Duplicate in a nested map.
        'a20181000101', // A container value must not hide the next key.
        'a21bffffffffffffffff001bffffffffffffffff01',
      ]) {
        expect(cborShapeError(b(bad)), 'duplicate map key', reason: bad);
      }
      for (final ok in ['a201a1020002a10201', 'a200002000', 'a20200c10201']) {
        // Reused integers in separate maps, different majors or tagged keys.
        expect(cborShapeError(b(ok)), isNull, reason: ok);
      }
    });

    test('rejects the rest', () {
      for (final bad in [
        '',
        '0000',
        '81',
        'a1',
        '5f',
        '9f00ff',
        '1c',
        '42ff',
        'd825',
        'f818',
        'c1c1c1c1c100',
        '5b8000000000000000',
        'bb4000000000000000',
        'bb7fffffffffffffff',
        'bb8000000000000000',
        'bbffffffffffffffff',
        '9b4000000000000000',
        '9b8000000000000000',
      ]) {
        expect(cborShapeError(b(bad)), isNotNull, reason: bad);
      }
      expect(cborShapeError(b('${'81' * 9}00')), isNotNull);
      expect(cborShapeError(b('${'81' * 8}00')), isNull);
    });
  });

  test('deeply nested CBOR is rejected, not a crash', () {
    final nested = Uint8List(60000)..fillRange(0, 60000, 0x81);
    expect(() => SolSignature.fromUr(UR('sol-signature', nested)), throwsDecode);
    final mapNest = Uint8List.fromList([
      for (var i = 0; i < 30000; i++) ...[0xa1, 0x01],
    ]);
    expect(() => KeystoneMultiAccounts.fromUr(UR('crypto-multi-accounts', mapNest)), throwsDecode);
  });

  test('registry decoders turn arbitrary CBOR into UrDecodeException only', () {
    final rng = Random(14);
    final decoders = <void Function(UR)>[
      SolSignature.fromUr,
      SolSignRequest.fromUr,
      (ur) => KeystoneMultiAccounts.fromUr(ur),
      KeystoneHdKey.fromUr,
      EthSignature.fromUr,
      EthSignRequest.fromUr,
      classifyEthExport,
      ethStandardXpubFromUr,
    ];
    const types = [
      'sol-signature',
      'sol-sign-request',
      'crypto-multi-accounts',
      'crypto-hdkey',
      'eth-signature',
      'eth-sign-request',
      'crypto-account',
    ];
    for (var i = 0; i < 3000; i++) {
      final bytes = randomBytes(rng, 1 + rng.nextInt(80));
      // Bias towards maps so the schema checks, not just the CBOR parser,
      // get exercised.
      if (rng.nextBool()) bytes[0] = 0xa0 | rng.nextInt(6);
      for (final decode in decoders) {
        for (final type in types) {
          try {
            decode(UR(type, bytes));
          } on UrDecodeException {
            // expected
          }
        }
      }
    }
  });
}
