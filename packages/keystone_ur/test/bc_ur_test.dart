// Ports of the bc-ur reference test suite (test/test.cpp in
// https://github.com/BlockchainCommons/bc-ur, commit 4479fb8), pinned to its
// vectors byte for byte.
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:convert';
import 'dart:typed_data';

import 'package:keystone_ur/keystone_ur.dart';
import 'package:keystone_ur/src/bc_ur/bytewords.dart';
import 'package:keystone_ur/src/bc_ur/crc32.dart';
import 'package:keystone_ur/src/bc_ur/fountain_decoder.dart';
import 'package:keystone_ur/src/bc_ur/fountain_encoder.dart';
import 'package:keystone_ur/src/bc_ur/fountain_utils.dart';
import 'package:keystone_ur/src/bc_ur/xoshiro256.dart';
import 'package:test/test.dart';

import 'vectors/bc_ur_vectors.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List makeMessage(int len, [String seed = 'Wolf']) => Xoshiro256.fromString(seed).nextData(len);

/// bc-ur's `make_message_ur`: the message wrapped as a CBOR byte string.
UR makeMessageUr(int len, [String seed = 'Wolf']) {
  final m = makeMessage(len, seed);
  final header = m.length < 24
      ? [0x40 | m.length]
      : m.length < 256
      ? [0x58, m.length]
      : [0x59, m.length >> 8, m.length & 0xFF];
  return UR('bytes', Uint8List.fromList([...header, ...m]));
}

int mod100(int x) => (BigInt.from(x).toUnsigned(64) % BigInt.from(100)).toInt();

void main() {
  test('crc32', () {
    expect(hex(crc32Bytes(utf8.encode('Hello, world!'))), 'ebe6c6e6');
    expect(hex(crc32Bytes(utf8.encode('Wolf'))), '598c84dc');
  });

  group('bytewords', () {
    test('vector 1', () {
      final input = [0, 1, 2, 128, 255];
      expect(
        Bytewords.encode(BytewordsStyle.standard, input),
        'able acid also lava zoom jade need echo taxi',
      );
      expect(
        Bytewords.encode(BytewordsStyle.uri, input),
        'able-acid-also-lava-zoom-jade-need-echo-taxi',
      );
      expect(Bytewords.encode(BytewordsStyle.minimal, input), 'aeadaolazmjendeoti');

      expect(
        Bytewords.decode(BytewordsStyle.standard, 'able acid also lava zoom jade need echo taxi'),
        input,
      );
      expect(
        Bytewords.decode(BytewordsStyle.uri, 'able-acid-also-lava-zoom-jade-need-echo-taxi'),
        input,
      );
      expect(Bytewords.decode(BytewordsStyle.minimal, 'aeadaolazmjendeoti'), input);
      expect(Bytewords.decode(BytewordsStyle.minimal, 'AEADAOLAZMJENDEOTI'), input);

      // Bad checksum.
      expect(
        () => Bytewords.decode(
          BytewordsStyle.standard,
          'able acid also lava zero jade need echo wolf',
        ),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(BytewordsStyle.uri, 'able-acid-also-lava-zero-jade-need-echo-wolf'),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(BytewordsStyle.minimal, 'aeadaolazojendeowf'),
        throwsA(isA<BytewordsException>()),
      );

      // Too short.
      expect(
        () => Bytewords.decode(BytewordsStyle.standard, 'wolf'),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(BytewordsStyle.standard, ''),
        throwsA(isA<BytewordsException>()),
      );
    });

    test('vector 2', () {
      expect(Bytewords.encode(BytewordsStyle.standard, bytewords2Input), bytewords2Standard);
      expect(Bytewords.encode(BytewordsStyle.minimal, bytewords2Input), bytewords2Minimal);
      expect(Bytewords.decode(BytewordsStyle.standard, bytewords2Standard), bytewords2Input);
      expect(Bytewords.decode(BytewordsStyle.minimal, bytewords2Minimal), bytewords2Input);
    });

    test('rejects odd length, unknown words and non-letters', () {
      expect(
        () => Bytewords.decode(BytewordsStyle.minimal, 'aeadaolazmjendeot'),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(BytewordsStyle.minimal, 'aeadaolazmjendeoqq'),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(BytewordsStyle.minimal, 'aeadaolazmjende1!'),
        throwsA(isA<BytewordsException>()),
      );
      expect(
        () => Bytewords.decode(
          BytewordsStyle.standard,
          'able acid also lava zoom jade need echo taxx',
        ),
        throwsA(isA<BytewordsException>()),
      );
    });
  });

  group('xoshiro256**', () {
    test('rng 1: seeded from "Wolf"', () {
      final rng = Xoshiro256.fromString('Wolf');
      expect([for (var i = 0; i < 100; i++) mod100(rng.next())], rng1Expected);
    });

    test('rng 2: seeded from the crc32 of "Wolf"', () {
      final rng = Xoshiro256.fromCrc32(crc32(utf8.encode('Wolf')));
      expect([for (var i = 0; i < 100; i++) mod100(rng.next())], rng2Expected);
    });

    test('rng 3: nextInt(1, 10)', () {
      final rng = Xoshiro256.fromString('Wolf');
      expect([for (var i = 0; i < 100; i++) rng.nextInt(1, 10)], rng3Expected);
    });
  });

  test('find nominal fragment length', () {
    expect(FountainEncoder.findNominalFragmentLength(12345, 1005, 1955), 1764);
    expect(FountainEncoder.findNominalFragmentLength(12345, 1005, 30000), 12345);
    // Shorter than the minimum: one fragment (the reference asserts here).
    expect(FountainEncoder.findNominalFragmentLength(5, 10, 200), 5);
  });

  test('random sampler', () {
    final sampler = RandomSampler([1, 2, 4, 8]);
    final rng = Xoshiro256.fromString('Wolf');
    expect([for (var i = 0; i < 500; i++) sampler.next(rng.nextDouble)], randomSamplerExpected);
  });

  test('shuffle', () {
    final rng = Xoshiro256.fromString('Wolf');
    final values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    expect([for (var i = 0; i < 10; i++) shuffled(values, rng)], shuffleExpected);
  });

  test('partition and join', () {
    final message = makeMessage(1024);
    final fragmentLen = FountainEncoder.findNominalFragmentLength(message.length, 10, 100);
    final fragments = FountainEncoder.partitionMessage(message, fragmentLen);
    expect(fragments.map(hex).toList(), partitionExpected);
    final joined = fragments.expand((f) => f).take(message.length).toList();
    expect(joined, message);
  });

  test('choose degree', () {
    final message = makeMessage(1024);
    final fragmentLen = FountainEncoder.findNominalFragmentLength(message.length, 10, 100);
    final fragments = FountainEncoder.partitionMessage(message, fragmentLen);
    final degrees = [
      for (var nonce = 1; nonce <= 200; nonce++)
        chooseDegree(fragments.length, Xoshiro256.fromString('Wolf-$nonce')),
    ];
    expect(degrees, chooseDegreeExpected);
  });

  test('choose fragments', () {
    final message = makeMessage(1024);
    final checksum = crc32(message);
    final fragmentLen = FountainEncoder.findNominalFragmentLength(message.length, 10, 100);
    final fragments = FountainEncoder.partitionMessage(message, fragmentLen);
    final indexes = [
      for (var seqNum = 1; seqNum <= 30; seqNum++)
        chooseFragments(seqNum, fragments.length, checksum),
    ];
    expect(indexes, chooseFragmentsExpected);
  });

  test('xor', () {
    final rng = Xoshiro256.fromString('Wolf');
    final data1 = rng.nextData(10);
    expect(hex(data1), '916ec65cf77cadf55cd7');
    final data2 = rng.nextData(10);
    expect(hex(data2), 'f9cda1a1030026ddd42e');
    final data3 = Uint8List.fromList(data1);
    xorInto(data3, data2);
    expect(hex(data3), '68a367fdf47c8b2888f9');
    xorInto(data3, data1);
    expect(data3, data2);
  });

  test('fountain encoder', () {
    final encoder = FountainEncoder(makeMessage(256), 30);
    expect([for (var i = 0; i < 20; i++) encoder.nextPart().description], fountainEncoderExpected);
  });

  test('fountain encoder cbor', () {
    final encoder = FountainEncoder(makeMessage(256), 30);
    expect([
      for (var i = 0; i < 20; i++) hex(encoder.nextPart().toCbor()),
    ], fountainEncoderCborExpected);
  });

  test('fountain encoder is complete', () {
    final encoder = FountainEncoder(makeMessage(256), 30);
    var generated = 0;
    while (!encoder.isComplete) {
      encoder.nextPart();
      generated += 1;
    }
    expect(encoder.seqLen, generated);
  });

  test('fountain decoder', () {
    final message = makeMessage(32767);
    final encoder = FountainEncoder(message, 1000, firstSeqNum: 100);
    final decoder = FountainDecoder();
    do {
      decoder.receivePart(encoder.nextPart());
    } while (!decoder.isComplete);
    expect(decoder.isSuccess, isTrue);
    expect(decoder.resultMessage, message);
  });

  test('fountain part cbor round trip', () {
    final part = FountainPart(
      seqNum: 12,
      seqLen: 8,
      messageLen: 100,
      checksum: 0x12345678,
      data: Uint8List.fromList([1, 5, 3, 3, 5]),
    );
    final cbor = part.toCbor();
    expect(FountainPart.fromCbor(cbor).toCbor(), cbor);
  });

  test('single-part ur', () {
    final ur = makeMessageUr(50);
    final encoded = UrEncoder.encodeSinglePart(ur);
    expect(
      encoded,
      'ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch',
    );
    final decoder = UrDecoder()..receivePart(encoded);
    expect(decoder.result!.type, 'bytes');
    expect(decoder.result!.cbor, ur.cbor);
  });

  test('ur encoder', () {
    final encoder = UrEncoder(makeMessageUr(256), maxFragmentLength: 30);
    expect([for (var i = 0; i < 20; i++) encoder.nextPartLowercase()], urEncoderExpected);
  });

  test('multipart ur', () {
    final ur = makeMessageUr(32767);
    final encoder = UrEncoder(ur, maxFragmentLength: 1000);
    final decoder = UrDecoder();
    do {
      decoder.receivePart(encoder.nextPart());
    } while (!decoder.isComplete);
    expect(decoder.result!.type, ur.type);
    expect(decoder.result!.cbor, ur.cbor);
  });
}
