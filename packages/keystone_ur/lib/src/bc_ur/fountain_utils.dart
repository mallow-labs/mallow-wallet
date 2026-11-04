// Dart port of src/random-sampler.cpp, src/fountain-utils.cpp and the
// `shuffled` template in src/fountain-utils.hpp from the Blockchain Commons
// bc-ur reference implementation (https://github.com/BlockchainCommons/bc-ur,
// commit 4479fb8).
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:typed_data';

import 'crc32.dart';
import 'xoshiro256.dart';

/// Walker's alias method, after Keith Schwarz's description
/// (https://www.keithschwarz.com/darts-dice-coins/), exactly as bc-ur builds
/// it — including its reversed index order, which the shared vectors pin.
class RandomSampler {
  factory RandomSampler(List<double> probs) {
    for (final p in probs) {
      if (p < 0) throw ArgumentError('negative probability');
    }
    var sum = 0.0;
    for (final p in probs) {
      sum += p;
    }
    if (!(sum > 0)) throw ArgumentError('probabilities sum to zero');

    final n = probs.length;
    final p = [for (final d in probs) d * n / sum];

    final s = <int>[];
    final l = <int>[];
    // At variance from Schwarz, bc-ur reverses the index order.
    for (var i = n - 1; i >= 0; i--) {
      if (p[i] < 1) {
        s.add(i);
      } else {
        l.add(i);
      }
    }

    final outProbs = Float64List(n);
    final aliases = Int32List(n);
    while (s.isNotEmpty && l.isNotEmpty) {
      final a = s.removeLast();
      final g = l.removeLast();
      outProbs[a] = p[a];
      aliases[a] = g;
      p[g] += p[a] - 1;
      if (p[g] < 1) {
        s.add(g);
      } else {
        l.add(g);
      }
    }
    while (l.isNotEmpty) {
      outProbs[l.removeLast()] = 1;
    }
    while (s.isNotEmpty) {
      // Can only happen through numeric instability.
      outProbs[s.removeLast()] = 1;
    }
    return RandomSampler._(outProbs, aliases);
  }

  RandomSampler._(this._probs, this._aliases);

  final Float64List _probs;
  final Int32List _aliases;

  /// Draws one index, consuming two doubles from [rng].
  int next(double Function() rng) {
    final r1 = rng();
    final r2 = rng();
    final n = _probs.length;
    final i = (n * r1).toInt();
    return r2 < _probs[i] ? i : _aliases[i];
  }
}

// The degree distribution depends only on seqLen, and every mixed part of one
// message shares it, so the last sampler is kept. Purely an optimisation: the
// sampler is deterministic, so the output is unchanged.
int? _cachedSeqLen;
RandomSampler? _cachedSampler;

/// Chooses how many fragments a mixed part combines (1..[seqLen]), with
/// probability proportional to 1/degree.
int chooseDegree(int seqLen, Xoshiro256 rng) {
  var sampler = _cachedSeqLen == seqLen ? _cachedSampler : null;
  if (sampler == null) {
    sampler = RandomSampler([for (var i = 1; i <= seqLen; i++) 1.0 / i]);
    _cachedSeqLen = seqLen;
    _cachedSampler = sampler;
  }
  return sampler.next(rng.nextDouble) + 1;
}

/// bc-ur's `shuffled`: repeatedly removes a random remaining element.
///
/// [take] stops after that many picks, yielding exactly the prefix the full
/// shuffle would have produced.
List<T> shuffled<T>(List<T> items, Xoshiro256 rng, {int? take}) {
  final remaining = List<T>.of(items);
  final count = take ?? items.length;
  final result = <T>[];
  while (remaining.isNotEmpty && result.length < count) {
    final index = rng.nextInt(0, remaining.length - 1);
    result.add(remaining.removeAt(index));
  }
  return result;
}

/// The sorted fragment indexes that part [seqNum] of a [seqLen]-fragment
/// message with CRC-32 [checksum] mixes together.
///
/// Parts 1..[seqLen] are the pure fragments, in order. Every later part is a
/// pseudo-random XOR of fragments, seeded from (seqNum, checksum), so encoder
/// and decoder agree without transmitting the index set.
List<int> chooseFragments(int seqNum, int seqLen, int checksum) {
  if (seqNum <= seqLen) {
    return [seqNum - 1];
  }
  final seed = Uint8List(8)
    ..setRange(0, 4, uint32ToBytes(seqNum))
    ..setRange(4, 8, uint32ToBytes(checksum));
  final rng = Xoshiro256.fromBytes(seed);
  final degree = chooseDegree(seqLen, rng);
  return _shuffledRangeSorted(seqLen, rng, degree);
}

/// The first [take] picks of [shuffled] over `0..n-1`, returned sorted.
///
/// Every decoder frame recomputes its fragment set, so this runs per scanned
/// QR code. [shuffled] removes from a list, which costs O(n) per pick and
/// dominates receive time on large messages. Here a Fenwick tree over the
/// remaining values finds the pick-th smallest in O(log n), drawing from [rng]
/// exactly as [shuffled] does, so the chosen set is identical.
List<int> _shuffledRangeSorted(int n, Xoshiro256 rng, int take) {
  // tree[i] counts the remaining values in its Fenwick range (1-based).
  final tree = Int32List(n + 1);
  for (var i = 1; i <= n; i++) {
    tree[i] += 1;
    final parent = i + (i & -i);
    if (parent <= n) tree[parent] += tree[i];
  }
  var topStep = 1;
  while (topStep * 2 <= n) {
    topStep *= 2;
  }
  final taken = Uint8List(n);
  final count = take < n ? take : n;
  for (var remaining = n; remaining > n - count; remaining--) {
    var rank = rng.nextInt(0, remaining - 1);
    var pos = 0;
    for (var step = topStep; step > 0; step >>= 1) {
      final next = pos + step;
      if (next <= n && tree[next] <= rank) {
        pos = next;
        rank -= tree[next];
      }
    }
    // pos is now the 0-based value holding that rank.
    taken[pos] = 1;
    for (var i = pos + 1; i <= n; i += i & -i) {
      tree[i] -= 1;
    }
  }
  return [
    for (var i = 0; i < n; i++)
      if (taken[i] == 1) i,
  ];
}

/// XORs [b] into [a] in place. Both must be the same length.
void xorInto(Uint8List a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    a[i] ^= b[i];
  }
}
