// Dart port of src/xoshiro256.cpp from the Blockchain Commons bc-ur reference
// implementation (https://github.com/BlockchainCommons/bc-ur, commit 4479fb8).
//
// xoshiro256** 1.0 was written in 2018 by David Blackman and Sebastiano Vigna
// (vigna@acm.org) and dedicated to the public domain (CC0 1.0,
// http://creativecommons.org/publicdomain/zero/1.0/).
//
// The seeding and the next_double / next_int / next_data helpers are
// Copyright © 2020 by Blockchain Commons, LLC, licensed under the BSD-2-Clause
// Plus Patent License (SPDX-License-Identifier: BSD-2-Clause-Patent). See this
// package's LICENSE and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'crc32.dart';

/// The xoshiro256** PRNG, seeded exactly as BCR-2020-005 specifies (from the
/// SHA-256 of a seed byte string), so that the fountain encoder and decoder on
/// both sides of a QR link agree on which fragments every part mixes.
///
/// Requires 64-bit integer arithmetic: this runs on the Dart VM and AOT
/// (iOS, Android, desktop), not on the web, where `int` is a double.
class Xoshiro256 {
  /// Seeds from the 32 bytes of [seed] directly (four big-endian `uint64`s).
  Xoshiro256.fromSeed(List<int> seed) {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
    }
    for (var i = 0; i < 4; i++) {
      var v = 0;
      for (var n = 0; n < 8; n++) {
        v = (v << 8) | (seed[i * 8 + n] & 0xFF);
      }
      _s[i] = v;
    }
  }

  /// Seeds from SHA-256([bytes]) — bc-ur's `Xoshiro256(const ByteVector&)`.
  factory Xoshiro256.fromBytes(List<int> bytes) => Xoshiro256.fromSeed(sha256.convert(bytes).bytes);

  /// Seeds from SHA-256 of the UTF-8 bytes of [s].
  factory Xoshiro256.fromString(String s) => Xoshiro256.fromBytes(utf8.encode(s));

  /// Seeds from SHA-256 of [crc] as four big-endian bytes.
  factory Xoshiro256.fromCrc32(int crc) => Xoshiro256.fromBytes(uint32ToBytes(crc));

  final List<int> _s = List<int>.filled(4, 0);

  static int _rotl(int x, int k) => (x << k) | (x >>> (64 - k));

  /// The next raw 64-bit output, as a Dart `int` holding the same 64 bits
  /// (values ≥ 2^63 read as negative).
  int next() {
    final result = _rotl(_s[1] * 5, 7) * 9;
    final t = _s[1] << 17;

    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2];
    _s[0] ^= _s[3];

    _s[2] ^= t;

    _s[3] = _rotl(_s[3], 45);

    return result;
  }

  /// `next() / 2^64` as a double in [0, 1).
  ///
  /// The C++ original converts the unsigned 64-bit output to a double (one
  /// round-to-nearest) and divides by 2^64 (exact). Splitting the value into
  /// two exact 32-bit halves and adding them performs that same single
  /// rounding, so the result is bit-identical.
  double nextDouble() {
    final x = next();
    final hi = (x >>> 32).toDouble();
    final lo = (x & 0xFFFFFFFF).toDouble();
    return (hi * 4294967296.0 + lo) / 18446744073709551616.0;
  }

  /// A uniformly distributed integer in [low, high], inclusive.
  int nextInt(int low, int high) => (nextDouble() * (high - low + 1)).toInt() + low;

  /// A uniformly distributed byte.
  int nextByte() => nextInt(0, 255);

  /// [count] pseudo-random bytes.
  Uint8List nextData(int count) {
    final result = Uint8List(count);
    for (var i = 0; i < count; i++) {
      result[i] = nextByte();
    }
    return result;
  }
}
