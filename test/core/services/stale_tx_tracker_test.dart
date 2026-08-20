import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/stale_tx_tracker.dart';

void main() {
  group('StaleTxTracker', () {
    test('buildAndTrack returns the build result', () async {
      final tracker = StaleTxTracker<int>();

      final result = await tracker.buildAndTrack(() async => 42);

      expect(result, 42);
    });

    test('refreshIfStale returns null when nothing has been tracked', () async {
      final tracker = StaleTxTracker<int>();

      expect(await tracker.refreshIfStale(), isNull);
    });

    test('refreshIfStale returns null inside the staleness window', () async {
      // 100ms window so we can stay well inside it.
      final tracker = StaleTxTracker<int>(
        staleAfter: const Duration(milliseconds: 100),
      );
      var calls = 0;
      await tracker.buildAndTrack(() async {
        calls++;
        return calls;
      });

      // No real wait — should still be fresh.
      final fresh = await tracker.refreshIfStale();

      expect(fresh, isNull);
      // The rebuild closure must not have run a second time.
      expect(calls, 1);
    });

    test(
      'refreshIfStale rebuilds and returns fresh value once past the window',
      () async {
        final tracker = StaleTxTracker<int>(
          staleAfter: const Duration(milliseconds: 20),
        );
        var calls = 0;
        await tracker.buildAndTrack(() async {
          calls++;
          return calls;
        });

        await Future<void>.delayed(const Duration(milliseconds: 40));

        final fresh = await tracker.refreshIfStale();

        expect(fresh, 2);
        expect(calls, 2);
      },
    );

    test(
      'refreshIfStale refreshes the readyAt clock after a successful rebuild',
      () async {
        final tracker = StaleTxTracker<int>(
          staleAfter: const Duration(milliseconds: 30),
        );
        var calls = 0;
        await tracker.buildAndTrack(() async {
          calls++;
          return calls;
        });

        // Cross the stale window once — triggers a rebuild.
        await Future<void>.delayed(const Duration(milliseconds: 45));
        await tracker.refreshIfStale();
        expect(calls, 2);

        // Immediately ask again. The previous refresh should have reset the
        // clock, so this call must NOT rebuild.
        final second = await tracker.refreshIfStale();
        expect(second, isNull);
        expect(calls, 2);
      },
    );

    test(
      'clear drops tracked state so refreshIfStale becomes a no-op',
      () async {
        final tracker = StaleTxTracker<int>(
          staleAfter: const Duration(milliseconds: 10),
        );
        var calls = 0;
        await tracker.buildAndTrack(() async {
          calls++;
          return calls;
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));

        tracker.clear();
        final fresh = await tracker.refreshIfStale();

        expect(fresh, isNull);
        // Rebuild closure must not run after clear, even though we're past
        // the stale window.
        expect(calls, 1);
      },
    );

    test('refreshIfStale rethrows when the rebuild closure throws', () async {
      final tracker = StaleTxTracker<int>(
        staleAfter: const Duration(milliseconds: 10),
      );
      var calls = 0;
      await tracker.buildAndTrack(() async {
        calls++;
        // First build succeeds; subsequent rebuilds should throw.
        if (calls > 1) throw StateError('rebuild failed');
        return calls;
      });
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(tracker.refreshIfStale, throwsA(isA<StateError>()));
    });

    test(
      'a thrown rebuild does not advance readyAt, so the next call retries',
      () async {
        final tracker = StaleTxTracker<int>(
          staleAfter: const Duration(milliseconds: 10),
        );
        var calls = 0;
        await tracker.buildAndTrack(() async {
          calls++;
          if (calls == 2) throw StateError('first rebuild boom');
          return calls;
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));

        // First rebuild throws.
        await expectLater(tracker.refreshIfStale(), throwsA(isA<StateError>()));
        expect(calls, 2);

        // Because the failed rebuild didn't advance readyAt, the next call
        // must still consider the tx stale and try again (succeeding this
        // time). If we accidentally bumped readyAt on failure, refreshIfStale
        // would erroneously return null here.
        final fresh = await tracker.refreshIfStale();
        expect(fresh, 3);
        expect(calls, 3);
      },
    );

    test('buildAndTrack replaces the previously tracked closure', () async {
      final tracker = StaleTxTracker<String>(
        staleAfter: const Duration(milliseconds: 10),
      );

      await tracker.buildAndTrack(() async => 'first');
      await tracker.buildAndTrack(() async => 'second');
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final fresh = await tracker.refreshIfStale();

      expect(fresh, 'second');
    });
  });
}
