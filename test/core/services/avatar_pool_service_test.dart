import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/avatar_palette.dart';
import 'package:mallow_wallet/core/services/avatar_pool_service.dart';

/// The expected per-colour counts for an even split of [kAvatarPoolSize] across
/// the six hues (28 over 6 → 5,5,5,5,4,4).
Map<int, int> _distribution(List<String> seeds) {
  final counts = <int, int>{};
  for (final seed in seeds) {
    final bucket = avatarColorIndex(seed);
    counts[bucket] = (counts[bucket] ?? 0) + 1;
  }
  return counts;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('avatar_pool_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test(
    'generates 28 distinct seeds evenly spread across the 6 colours',
    () async {
      final svc = AvatarPoolService.forTest(cacheDir: tmp);
      final pool = await svc.candidates(inUse: const {});

      expect(pool, hasLength(kAvatarPoolSize));
      expect(pool.toSet(), hasLength(kAvatarPoolSize)); // all distinct

      // Why: the feature's headline ask is an *even* distribution of the 6 hues,
      // not whatever a random hash happens to produce — so every colour must hit
      // its exact quota.
      final counts = _distribution(pool);
      expect(counts.values.toList()..sort(), [4, 4, 5, 5, 5, 5]);
      expect(counts.keys, containsAll(List.generate(6, (i) => i)));
    },
  );

  test('reuses the persisted pool instead of re-rolling each open', () async {
    final first = await AvatarPoolService.forTest(
      cacheDir: tmp,
    ).candidates(inUse: const {});

    // A fresh instance over the same dir (cold in-memory state) must return the
    // identical pool — that's the whole point of "generate once, cache/reuse".
    final second = await AvatarPoolService.forTest(
      cacheDir: tmp,
    ).candidates(inUse: const {});

    expect(second, first);
  });

  test(
    'replaces a candidate once it has been chosen, keeping the spread',
    () async {
      final svc = AvatarPoolService.forTest(cacheDir: tmp);
      final pool = await svc.candidates(inUse: const {});
      final chosen = pool.first;

      // Simulate that seed being assigned to an account: it must drop out and be
      // replaced by a freshly generated one of the same colour, staying even.
      final next = await svc.candidates(inUse: {chosen});

      expect(next, isNot(contains(chosen)));
      expect(next, hasLength(kAvatarPoolSize));
      expect(_distribution(next).values.toList()..sort(), [4, 4, 5, 5, 5, 5]);
      // The other 27 are retained, not re-rolled wholesale.
      final retained = pool.where((s) => s != chosen).where(next.contains);
      expect(retained, hasLength(kAvatarPoolSize - 1));
    },
  );
}
