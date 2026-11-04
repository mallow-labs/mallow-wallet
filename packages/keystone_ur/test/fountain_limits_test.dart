import 'dart:math';
import 'dart:typed_data';

import 'package:keystone_ur/keystone_ur.dart';
import 'package:keystone_ur/src/bc_ur/fountain_decoder.dart';
import 'package:keystone_ur/src/bc_ur/fountain_encoder.dart';
import 'package:keystone_ur/src/bc_ur/fountain_utils.dart';
import 'package:test/test.dart';

void main() {
  test('equal-degree equations cannot exceed the mixed-part count cap', () {
    const fragments = 32;
    final encoder = FountainEncoder(Uint8List(fragments * 10), 10);
    final decoder = FountainDecoder();
    var fed = 0;
    for (var attempts = 0; fed < 200 && attempts < 10000; attempts++) {
      final part = encoder.nextPart();
      if (part.seqNum <= fragments ||
          chooseFragments(part.seqNum, fragments, part.checksum).length != 2) {
        continue;
      }
      decoder.receivePart(part);
      fed++;
      expect(decoder.storedMixedPartCount, lessThanOrEqualTo(2 * fragments + 32));
      expect(decoder.storedMixedIndexCount, decoder.storedMixedPartCount * 2);
    }
    expect(fed, 200);
    expect(decoder.storedMixedPartCount, 2 * fragments + 32);
    expect(decoder.receivedFragmentCount, 0);

    // Hitting a cap must not prevent pure fragments from completing a scan.
    final pureEncoder = FountainEncoder(Uint8List(fragments * 10), 10);
    while (!decoder.isComplete) {
      decoder.receivePart(pureEncoder.nextPart());
      expect(decoder.storedMixedIndexCount, lessThanOrEqualTo(64 * fragments));
    }
    expect(decoder.resultMessage, Uint8List(fragments * 10));
  });

  test('large equations stay within the index budget and cheap to receive', () {
    const fragments = 2048;
    const checksum = 1;
    final parts = <FountainPart>[];
    // Restrict degree to this range so equations overwhelmingly do not contain
    // each other. Zero data keeps this a storage test without a real payload.
    for (var seq = fragments + 1; parts.length < 300 && seq < 20000; seq++) {
      final degree = chooseFragments(seq, fragments, checksum).length;
      if (degree < fragments ~/ 2 || degree > fragments * 3 ~/ 4) continue;
      parts.add(
        FountainPart(
          seqNum: seq,
          seqLen: fragments,
          messageLen: fragments * 34,
          checksum: checksum,
          data: Uint8List(34),
        ),
      );
    }
    expect(parts, hasLength(300));
    final decoder = FountainDecoder();
    for (final part in parts.take(200)) {
      decoder.receivePart(part);
      expect(decoder.storedMixedPartCount, lessThanOrEqualTo(2 * fragments + 32));
      expect(decoder.storedMixedIndexCount, lessThanOrEqualTo(131072));
    }
    expect(decoder.storedMixedIndexCount, greaterThan(131072 - fragments * 3 ~/ 4));
    final storedCount = decoder.storedMixedPartCount;
    final storedIndexes = decoder.storedMixedIndexCount;
    final watch = Stopwatch()..start();
    for (final part in parts.skip(200)) {
      decoder.receivePart(part);
    }
    watch.stop();
    expect(decoder.storedMixedPartCount, storedCount);
    expect(decoder.storedMixedIndexCount, storedIndexes);
    // Average over many frames to tolerate scheduler pauses on shared hosts.
    // Ten milliseconds leaves ample headroom for fragment choice and hashing.
    expect(watch.elapsedMicroseconds / 100, lessThan(10000));
    expect(decoder.receivedFragmentCount, 0);
  });

  test('large streams decode with shuffled frames and 30 percent dropped', () {
    for (final fragments in [128, 512, 2048]) {
      for (var seed = 0; seed < 4; seed++) {
        final rng = Random(seed);
        final message = Uint8List.fromList(List.generate(fragments * 10, (_) => rng.nextInt(256)));
        final encoder = FountainEncoder(message, 10);
        final decoder = FountainDecoder();
        final pure = [for (var i = 0; i < fragments; i++) encoder.nextPart()]..shuffle(rng);
        var peakParts = 0;
        var peakIndexes = 0;
        void feed(FountainPart part) {
          if (rng.nextDouble() < 0.3) return;
          decoder.receivePart(part);
          peakParts = max(peakParts, decoder.storedMixedPartCount);
          peakIndexes = max(peakIndexes, decoder.storedMixedIndexCount);
        }

        for (final part in pure) {
          feed(part);
        }
        var sent = fragments;
        while (!decoder.isComplete && sent < fragments * 20) {
          final batch = [for (var i = 0; i < 4; i++) encoder.nextPart()]..shuffle(rng);
          for (final part in batch) {
            feed(part);
          }
          sent += batch.length;
        }
        expect(decoder.isSuccess, isTrue, reason: '$fragments fragments, seed $seed');
        expect(decoder.resultMessage, message);
        // Healthy streams should have substantial margin under both caps.
        expect(peakParts, lessThan(fragments));
        expect(peakIndexes, lessThan(min(64 * fragments, 131072) ~/ 2));
      }
    }
  });

  test('mixed equations containing only known fragments are ignored', () {
    final encoder = FountainEncoder(Uint8List(40), 10);
    final decoder = FountainDecoder();
    for (var i = 0; i < 3; i++) {
      decoder.receivePart(encoder.nextPart());
    }
    var checked = false;
    for (var i = 0; i < 100; i++) {
      final part = encoder.nextPart();
      final indexes = chooseFragments(part.seqNum, part.seqLen, part.checksum);
      if (indexes.length < 2 || !indexes.every((index) => index < 3)) continue;
      expect(decoder.receivePart(part), isTrue);
      expect(decoder.receivedFragmentCount, 3);
      expect(decoder.storedMixedPartCount, 0);
      expect(decoder.storedMixedIndexCount, 0);
      checked = true;
      break;
    }
    expect(checked, isTrue);
    decoder.receivePart(FountainEncoder(Uint8List(40), 10, firstSeqNum: 3).nextPart());
    expect(decoder.isSuccess, isTrue);
  });

  test('fountain checksum failure remains terminal for every later part', () {
    final encoder = FountainEncoder(Uint8List(30), 10);
    final decoder = FountainDecoder();
    decoder.receivePart(encoder.nextPart());
    decoder.receivePart(encoder.nextPart());
    final corrupted = encoder.nextPart()..data[0] = 1;
    final throwsDecode = throwsA(isA<UrDecodeException>());
    expect(() => decoder.receivePart(corrupted), throwsDecode);
    expect(decoder.isFailure, isTrue);
    expect(decoder.resultMessage, isNull);
    expect(() => decoder.receivePart(corrupted), throwsDecode);
    expect(() => decoder.receivePart(encoder.nextPart()), throwsDecode);
  });
}
