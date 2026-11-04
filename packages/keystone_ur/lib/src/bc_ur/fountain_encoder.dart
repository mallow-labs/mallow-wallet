// Dart port of src/fountain-encoder.cpp from the Blockchain Commons bc-ur
// reference implementation (https://github.com/BlockchainCommons/bc-ur,
// commit 4479fb8).
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../cbor_shape.dart';
import 'crc32.dart';
import 'fountain_utils.dart';

/// Thrown when a fountain part's CBOR header is malformed.
class InvalidFountainPart implements Exception {
  InvalidFountainPart(this.message);

  final String message;

  @override
  String toString() => 'InvalidFountainPart: $message';
}

/// One fountain-coded part: `[seqNum, seqLen, messageLen, checksum, data]`.
class FountainPart {
  FountainPart({
    required this.seqNum,
    required this.seqLen,
    required this.messageLen,
    required this.checksum,
    required this.data,
  });

  /// Parses the CBOR array carried in a multi-part UR body.
  ///
  /// Every header field must be an unsigned integer that fits in 32 bits, as
  /// in the reference implementation. Throws [InvalidFountainPart].
  factory FountainPart.fromCbor(List<int> bytes) {
    if (cborShapeError(bytes, maxDepth: 1) != null) {
      throw InvalidFountainPart('not a well-formed CBOR array');
    }
    final CborValue value;
    try {
      value = cborDecode(bytes);
    } on Object {
      throw InvalidFountainPart('not CBOR');
    }
    if (value is! CborList || value.length != 5 || value.tags.isNotEmpty) {
      throw InvalidFountainPart('expected a 5-element array');
    }
    int u32(CborValue v) {
      if (v is! CborSmallInt || v.tags.isNotEmpty || v.value < 0 || v.value > 0xFFFFFFFF) {
        throw InvalidFountainPart('header field is not a uint32');
      }
      return v.value;
    }

    final data = value[4];
    if (data is! CborBytes || data.tags.isNotEmpty) {
      throw InvalidFountainPart('data is not a byte string');
    }
    return FountainPart(
      seqNum: u32(value[0]),
      seqLen: u32(value[1]),
      messageLen: u32(value[2]),
      checksum: u32(value[3]),
      data: Uint8List.fromList(data.bytes),
    );
  }

  final int seqNum;
  final int seqLen;
  final int messageLen;
  final int checksum;
  final Uint8List data;

  Uint8List toCbor() => Uint8List.fromList(
    cborEncode(
      CborList([
        CborSmallInt(seqNum),
        CborSmallInt(seqLen),
        CborSmallInt(messageLen),
        CborSmallInt(checksum),
        CborBytes(data),
      ]),
    ),
  );

  /// The same human-readable form as bc-ur's `Part::description()`, for tests.
  String get description {
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'seqNum:$seqNum, seqLen:$seqLen, messageLen:$messageLen, '
        'checksum:$checksum, data:$hex';
  }
}

/// A rateless (Luby transform) fountain encoder.
///
/// The first [seqLen] parts are the message's fragments in order; every part
/// after that XORs a pseudo-random subset of them, so a receiver that missed
/// some frames can still complete from whichever parts it does catch.
class FountainEncoder {
  FountainEncoder(
    List<int> message,
    int maxFragmentLen, {
    int firstSeqNum = 0,
    int minFragmentLen = 10,
  }) : messageLen = message.length,
       checksum = crc32(message),
       _seqNum = firstSeqNum {
    if (message.isEmpty) throw ArgumentError('message must not be empty');
    if (maxFragmentLen < 1) throw ArgumentError('maxFragmentLen must be >= 1');
    fragmentLen = findNominalFragmentLength(message.length, minFragmentLen, maxFragmentLen);
    _fragments = partitionMessage(message, fragmentLen);
  }

  final int messageLen;
  final int checksum;
  late final int fragmentLen;
  late final List<Uint8List> _fragments;
  int _seqNum;

  /// The sequence number of the part most recently returned.
  int get seqNum => _seqNum;

  /// The number of pure fragments.
  int get seqLen => _fragments.length;

  /// True once the first [seqLen] parts — enough to rebuild the message —
  /// have been generated.
  bool get isComplete => _seqNum >= seqLen;

  /// True if the message fits in a single fragment.
  bool get isSinglePart => seqLen == 1;

  /// The smallest fragment length ≤ [maxFragmentLen] that splits the message
  /// into equal-ish fragments, searching fragment counts upward.
  ///
  /// The reference implementation asserts when no count up to
  /// `messageLen ~/ minFragmentLen` fits (for instance a message shorter than
  /// [minFragmentLen]). Here that case falls back to the smallest count that
  /// fits, `ceil(messageLen / maxFragmentLen)` — which is also what the search
  /// returns whenever it succeeds, so the two agree on every input the
  /// reference accepts.
  static int findNominalFragmentLength(int messageLen, int minFragmentLen, int maxFragmentLen) {
    final maxFragmentCount = messageLen ~/ minFragmentLen;
    for (var count = 1; count <= maxFragmentCount; count++) {
      final len = (messageLen + count - 1) ~/ count;
      if (len <= maxFragmentLen) return len;
    }
    final count = (messageLen + maxFragmentLen - 1) ~/ maxFragmentLen;
    return (messageLen + count - 1) ~/ count;
  }

  /// Splits [message] into [fragmentLen]-byte fragments, zero-padding the last.
  static List<Uint8List> partitionMessage(List<int> message, int fragmentLen) {
    final fragments = <Uint8List>[];
    for (var start = 0; start < message.length; start += fragmentLen) {
      final end = start + fragmentLen < message.length ? start + fragmentLen : message.length;
      fragments.add(Uint8List(fragmentLen)..setRange(0, end - start, message, start));
    }
    return fragments;
  }

  Uint8List _mix(List<int> indexes) {
    final result = Uint8List(fragmentLen);
    for (final i in indexes) {
      xorInto(result, _fragments[i]);
    }
    return result;
  }

  /// The next part. Sequence numbers wrap at 2^32 as in the reference; 0 is
  /// skipped, since part 0 does not exist.
  FountainPart nextPart() {
    _seqNum = (_seqNum + 1) & 0xFFFFFFFF;
    if (_seqNum == 0) _seqNum = 1;
    final indexes = chooseFragments(_seqNum, seqLen, checksum);
    return FountainPart(
      seqNum: _seqNum,
      seqLen: seqLen,
      messageLen: messageLen,
      checksum: checksum,
      data: _mix(indexes),
    );
  }
}
