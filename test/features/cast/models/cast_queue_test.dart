import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/models/cast_display_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_media_type.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';

CastQueueItem item(String mint, {String? artist}) => CastQueueItem(
  mintAccount: mint,
  title: 'Title $mint',
  imageUrl: 'https://example.test/$mint.png',
  artistName: artist,
);

void main() {
  group('CastQueueItem.fromJson roundtrip', () {
    test('preserves required + optional fields and defaults', () {
      const original = CastQueueItem(
        mintAccount: 'mint-1',
        title: 'My Art',
        imageUrl: 'https://example.test/img.png',
        animationUrl: 'https://example.test/anim.mp4',
        artistName: 'Artist',
        artistUsername: 'artist',
        isVerified: true,
        isAdmin: true,
        mediaType: CastMediaType.video,
      );
      final round = CastQueueItem.fromJson(original.toJson());
      expect(round, original);
    });

    test('defaults isVerified/isAdmin/mediaType when absent', () {
      final round = CastQueueItem.fromJson({
        'mintAccount': 'm',
        'title': 't',
        'imageUrl': 'u',
      });
      expect(round.isVerified, isFalse);
      expect(round.isAdmin, isFalse);
      expect(round.mediaType, CastMediaType.unknown);
    });
  });

  group('CastQueueHelpers — currentItem/peek/edges', () {
    test('currentItem null when empty', () {
      const queue = CastQueue();
      expect(queue.currentItem, isNull);
      expect(queue.nextItem, isNull);
      expect(queue.previousItem, isNull);
      expect(queue.hasNext, isFalse);
      expect(queue.hasPrevious, isFalse);
      expect(queue.canSkipNext, isFalse);
      expect(queue.canSkipPrevious, isFalse);
    });

    test('clamps an out-of-range currentIndex when reading currentItem', () {
      // Use copyWith to bypass any constructor-side validation. The getter
      // is the layer that has to be safe — if a stale index sneaks in, the
      // UI should still render the last item rather than throw.
      final queue = CastQueue(items: [item('A'), item('B')], currentIndex: 99);
      expect(queue.currentItem?.mintAccount, 'B');
    });

    test('hasNext/hasPrevious reflect bounds without wrap', () {
      final queue = CastQueue(
        items: [item('A'), item('B'), item('C')],
        currentIndex: 1,
        repeatMode: CastRepeatMode.off,
      );
      expect(queue.hasNext, isTrue);
      expect(queue.hasPrevious, isTrue);
      expect(queue.canSkipNext, isTrue);
      expect(queue.canSkipPrevious, isTrue);
    });

    test('canSkip* require more than one item even with repeat-all', () {
      final solo = CastQueue(items: [item('A')]);
      expect(solo.canSkipNext, isFalse);
      expect(solo.canSkipPrevious, isFalse);
    });

    test('repeat-all enables wrap at the edges', () {
      final atEnd = CastQueue(
        items: [item('A'), item('B'), item('C')],
        currentIndex: 2,
      );
      expect(atEnd.hasNext, isFalse);
      expect(atEnd.canSkipNext, isTrue);
      expect(atEnd.nextItem?.mintAccount, 'A');

      final atStart = atEnd.copyWith(currentIndex: 0);
      expect(atStart.hasPrevious, isFalse);
      expect(atStart.canSkipPrevious, isTrue);
      expect(atStart.previousItem?.mintAccount, 'C');
    });

    test('repeat-off returns null peeks at edges', () {
      final atEnd = CastQueue(
        items: [item('A'), item('B')],
        currentIndex: 1,
        repeatMode: CastRepeatMode.off,
      );
      expect(atEnd.nextItem, isNull);
      final atStart = atEnd.copyWith(currentIndex: 0);
      expect(atStart.previousItem, isNull);
    });

    test('repeat-one does NOT enable manual skip wrap', () {
      // repeat-one is "stay on current"; manual skip must still be bounded.
      final atEnd = CastQueue(
        items: [item('A'), item('B')],
        currentIndex: 1,
        repeatMode: CastRepeatMode.one,
      );
      expect(atEnd.canSkipNext, isFalse);
      expect(atEnd.nextItem, isNull);
    });
  });

  group('withNextIndex / withPreviousIndex', () {
    test('advance with repeat-all wraps at edges', () {
      final atEnd = CastQueue(
        items: [item('A'), item('B'), item('C')],
        currentIndex: 2,
      );
      expect(atEnd.withNextIndex().currentIndex, 0);
      final atStart = atEnd.copyWith(currentIndex: 0);
      expect(atStart.withPreviousIndex().currentIndex, 2);
    });

    test('advance with repeat-off stops at edges', () {
      final atEnd = CastQueue(
        items: [item('A'), item('B')],
        currentIndex: 1,
        repeatMode: CastRepeatMode.off,
      );
      expect(atEnd.withNextIndex(), atEnd);
      final atStart = atEnd.copyWith(currentIndex: 0);
      expect(atStart.withPreviousIndex(), atStart);
    });

    test('empty queue is a no-op', () {
      const queue = CastQueue();
      expect(queue.withNextIndex(), queue);
      expect(queue.withPreviousIndex(), queue);
    });
  });

  group('withItemAdded', () {
    test('appends a new item', () {
      final q = const CastQueue().withItemAdded(item('A'));
      expect(q.items.map((it) => it.mintAccount), ['A']);
    });

    test('is a no-op for duplicates by mintAccount', () {
      // Keeps "Add to cast" idempotent — re-tapping the same artwork must
      // not pad the queue with copies.
      final q1 = const CastQueue().withItemAdded(item('A'));
      final q2 = q1.withItemAdded(item('A', artist: 'Other'));
      expect(q2, same(q1));
    });

    test('keeps originalItems in sync while shuffled', () {
      // The unshuffled view must keep growing alongside the live queue so
      // toggling shuffle off later does not drop newly-added items.
      final shuffled = CastQueue(
        items: [item('A')],
        originalItems: [item('A')],
        isShuffled: true,
      );
      final next = shuffled.withItemAdded(item('B'));
      expect(next.originalItems.map((it) => it.mintAccount), ['A', 'B']);
    });

    test('does NOT touch originalItems while not shuffled', () {
      final q = const CastQueue().withItemAdded(item('A'));
      expect(q.originalItems, isEmpty);
    });
  });

  group('withItemsAdded', () {
    test('appends only items with new mintAccounts', () {
      final base = CastQueue(items: [item('A'), item('B')]);
      final next = base.withItemsAdded([item('B'), item('C'), item('A')]);
      expect(next.items.map((it) => it.mintAccount), ['A', 'B', 'C']);
    });

    test('returns same instance when nothing was added', () {
      final base = CastQueue(items: [item('A')]);
      expect(base.withItemsAdded(const []), same(base));
      expect(base.withItemsAdded([item('A')]), same(base));
    });

    test('keeps originalItems in sync while shuffled', () {
      final shuffled = CastQueue(
        items: [item('A')],
        originalItems: [item('A')],
        isShuffled: true,
      );
      final next = shuffled.withItemsAdded([item('B'), item('C')]);
      expect(next.originalItems.map((it) => it.mintAccount), ['A', 'B', 'C']);
    });
  });

  group('withItemRemoved', () {
    test('removes and keeps currentIndex when below removal', () {
      final q = CastQueue(
        items: [item('A'), item('B'), item('C')],
      ).withItemRemoved(2);
      expect(q.items.map((it) => it.mintAccount), ['A', 'B']);
      expect(q.currentIndex, 0);
    });

    test('clamps currentIndex when current item was at the end', () {
      // After removing the playing item from the tail, we should keep
      // pointing at a valid slot (the new last item).
      final q = CastQueue(
        items: [item('A'), item('B'), item('C')],
        currentIndex: 2,
      ).withItemRemoved(2);
      expect(q.items.map((it) => it.mintAccount), ['A', 'B']);
      expect(q.currentIndex, 1);
    });

    test('resets to 0 when emptied', () {
      final q = CastQueue(items: [item('A')]).withItemRemoved(0);
      expect(q.items, isEmpty);
      expect(q.currentIndex, 0);
    });

    test('removes from originalItems by mintAccount while shuffled', () {
      // originalItems holds the unshuffled view. We must remove by mint, not
      // by index, since the indices differ between items and originalItems.
      final shuffled = CastQueue(
        items: [item('C'), item('A'), item('B')],
        originalItems: [item('A'), item('B'), item('C')],
        isShuffled: true,
      );
      final next = shuffled.withItemRemoved(0); // removes 'C' from items
      expect(next.items.map((it) => it.mintAccount), ['A', 'B']);
      expect(next.originalItems.map((it) => it.mintAccount), ['A', 'B']);
    });
  });

  group('withItemReordered', () {
    test('moves forward using the removal-adjusted onReorderItem index', () {
      // ReorderableListView.onReorderItem already adjusts newIndex for the
      // removed item. Moving A to index 2 therefore places it at the end.
      final q = CastQueue(
        items: [item('A'), item('B'), item('C')],
      ).withItemReordered(0, 2);
      expect(q.items.map((it) => it.mintAccount), ['B', 'C', 'A']);
    });

    test('moves backward without index compensation', () {
      final q = CastQueue(
        items: [item('A'), item('B'), item('C')],
      ).withItemReordered(2, 0);
      expect(q.items.map((it) => it.mintAccount), ['C', 'A', 'B']);
    });
  });

  group('shuffle toggle', () {
    test('shuffleOn snapshots, sets flag, and tracks playing item by mint', () {
      // Deterministic via length=1: shuffle is a no-op on order but must
      // still set the flag and seed originalItems.
      final q = CastQueue(items: [item('A')]).withShuffleOn();
      expect(q.isShuffled, isTrue);
      expect(q.originalItems.map((it) => it.mintAccount), ['A']);
      expect(q.currentItem?.mintAccount, 'A');
    });

    test('shuffleOn on empty preserves flag and clears originalItems', () {
      final q = const CastQueue().withShuffleOn();
      expect(q.isShuffled, isTrue);
      expect(q.originalItems, isEmpty);
    });

    test('shuffleOn preserves the playing item after reordering', () {
      // Even when shuffle moves the playing item to a different index, the
      // currentIndex must follow it so playback does not jump tracks.
      final base = CastQueue(
        items: [item('A'), item('B'), item('C'), item('D')],
        currentIndex: 2, // playing 'C'
      );
      final shuffled = base.withShuffleOn();
      expect(shuffled.currentItem?.mintAccount, 'C');
      expect(shuffled.originalItems.map((it) => it.mintAccount), [
        'A',
        'B',
        'C',
        'D',
      ]);
    });

    test(
      'shuffleOff restores originalItems and keeps the same playing mint',
      () {
        final shuffled = CastQueue(
          items: [item('C'), item('A'), item('B')],
          originalItems: [item('A'), item('B'), item('C')],
          isShuffled: true,
        );
        final restored = shuffled.withShuffleOff();
        expect(restored.isShuffled, isFalse);
        expect(restored.originalItems, isEmpty);
        expect(restored.items.map((it) => it.mintAccount), ['A', 'B', 'C']);
        expect(restored.currentItem?.mintAccount, 'C');
      },
    );

    test('shuffleOff falls back to index 0 when playing mint is missing', () {
      // Edge case: playing item was removed but isShuffled is still true.
      // We must not crash; fall back to the first item in the restored order.
      final shuffled = CastQueue(
        items: [item('A')], // 'X' (the "playing" mint) no longer exists
        originalItems: [item('A')],
        isShuffled: true,
      );
      // Force a mismatch by overriding currentItem mint via items list.
      // The mismatch case is hit by ensuring originalItems lacks the playing
      // mint — easier to construct by clearing items.
      final empty = shuffled.copyWith(items: const []);
      final restored = empty.withShuffleOff();
      expect(restored.currentIndex, 0);
    });

    test('shuffleOff with empty originalItems just clears flag', () {
      // Defensive path: no snapshot to restore, so the existing items
      // should remain in place.
      final q = CastQueue(
        items: [item('A')],
        isShuffled: true,
      ).withShuffleOff();
      expect(q.isShuffled, isFalse);
      expect(q.items.map((it) => it.mintAccount), ['A']);
    });
  });

  group('default field values', () {
    test('CastQueue defaults match documented playback defaults', () {
      const q = CastQueue();
      expect(q.items, isEmpty);
      expect(q.currentIndex, 0);
      expect(q.slideshowIntervalSeconds, 30);
      expect(q.isPaused, isFalse);
      expect(q.showQr, isTrue);
      expect(q.showCaption, isTrue);
      expect(q.isShuffled, isFalse);
      expect(q.repeatMode, CastRepeatMode.all);
      expect(q.displayType, CastDisplayType.fillScreen);
    });
  });
}
