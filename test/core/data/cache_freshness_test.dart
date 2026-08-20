import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/cache_freshness.dart';

void main() {
  group('CacheFreshness.nowEpochSeconds', () {
    test('returns Unix seconds aligned with DateTime.now()', () {
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final now = CacheFreshness.nowEpochSeconds();
      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Loose bounds — the test only verifies units, not wall-clock precision.
      expect(now, greaterThanOrEqualTo(before));
      expect(now, lessThanOrEqualTo(after));
    });
  });

  group('CacheFreshness.fromEpochSeconds', () {
    test(
      'round-trips with nowEpochSeconds (no millisecond bits lost twice)',
      () {
        const seconds = 1_700_000_000;
        final dt = CacheFreshness.fromEpochSeconds(seconds);
        expect(dt.millisecondsSinceEpoch, seconds * 1000);
      },
    );
  });

  group('CacheFreshness.isStale', () {
    test('null cachedAt is always stale (cache miss)', () {
      expect(CacheFreshness.isStale(null, const Duration(minutes: 5)), isTrue);
    });

    test('cachedAt within the TTL is fresh', () {
      final cachedAt = DateTime.now().subtract(const Duration(seconds: 10));
      expect(
        CacheFreshness.isStale(cachedAt, const Duration(minutes: 5)),
        isFalse,
      );
    });

    test('cachedAt older than the TTL is stale', () {
      final cachedAt = DateTime.now().subtract(const Duration(minutes: 10));
      expect(
        CacheFreshness.isStale(cachedAt, const Duration(minutes: 5)),
        isTrue,
      );
    });

    test('cachedAt in the future (clock skew) is treated as fresh', () {
      // `isBefore(now - ttl)` is false for any future timestamp, which is the
      // documented behaviour — a forward-skewed cache is at worst over-fresh,
      // never spuriously stale.
      final cachedAt = DateTime.now().add(const Duration(hours: 1));
      expect(
        CacheFreshness.isStale(cachedAt, const Duration(minutes: 5)),
        isFalse,
      );
    });

    test('a cachedAt slightly inside the TTL window is still fresh', () {
      // The five cache-backed repos depend on `.isBefore`, not `<=`, so a
      // cachedAt that's 1ms inside the window must remain fresh.
      const ttl = Duration(minutes: 5);
      final cachedAt = DateTime.now()
          .subtract(ttl)
          .add(const Duration(seconds: 5));
      expect(CacheFreshness.isStale(cachedAt, ttl), isFalse);
    });
  });

  group('CacheFreshness.pruneCutoffEpoch', () {
    test('returns Unix seconds for now - retention', () {
      const retention = Duration(hours: 24);
      final before =
          DateTime.now().subtract(retention).millisecondsSinceEpoch ~/ 1000;
      final cutoff = CacheFreshness.pruneCutoffEpoch(retention);
      final after =
          DateTime.now().subtract(retention).millisecondsSinceEpoch ~/ 1000;
      expect(cutoff, greaterThanOrEqualTo(before));
      expect(cutoff, lessThanOrEqualTo(after));
    });

    test('zero retention is roughly equal to now', () {
      final cutoff = CacheFreshness.pruneCutoffEpoch(Duration.zero);
      final now = CacheFreshness.nowEpochSeconds();
      // Off-by-one is acceptable across a millisecond boundary.
      expect((cutoff - now).abs(), lessThanOrEqualTo(1));
    });
  });
}
