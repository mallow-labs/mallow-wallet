import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/pagination/drain_pages.dart';
import 'package:mallow_wallet/shared/pagination/pagination_bloc.dart';

/// A list screen holds only the pages the user scrolled past. Bulk actions that
/// mean "all of them" used to read that prefix: a 90-artwork group downloaded
/// the 20 rows in memory and reported success, which is indistinguishable from
/// having downloaded the group. [drainPages] is what makes "all" mean all.
void main() {
  /// A feed of [total] items served [pageSize] at a time, recording the pages
  /// it was asked for.
  ({Future<PaginatedPage<int>> Function(int) fetch, List<int> requested}) feed({
    required int total,
    int pageSize = 20,
  }) {
    final requested = <int>[];
    return (
      requested: requested,
      fetch: (int page) async {
        requested.add(page);
        final start = page * pageSize;
        final items = [
          for (var i = start; i < start + pageSize && i < total; i++) i,
        ];
        return PaginatedPage(items: items, hasMore: start + pageSize < total);
      },
    );
  }

  test('collects every page, not just the first', () async {
    final f = feed(total: 90);

    final all = await drainPages(f.fetch);

    expect(all, hasLength(90));
    expect(all.first, 0);
    expect(all.last, 89);
    expect(f.requested, [0, 1, 2, 3, 4]);
  });

  test('stops at the first page that reports no more', () async {
    final f = feed(total: 20);

    expect(await drainPages(f.fetch), hasLength(20));
    // Exactly one request: a feed that says it is done must not be re-probed.
    expect(f.requested, [0]);
  });

  test('preserves feed order across page boundaries', () async {
    final f = feed(total: 45);

    expect(await drainPages(f.fetch), List.generate(45, (i) => i));
  });

  test('an empty feed drains to an empty list', () async {
    final f = feed(total: 0);

    expect(await drainPages(f.fetch), isEmpty);
    expect(f.requested, [0]);
  });

  test('shouldStop abandons the walk between pages', () async {
    // Cancelling a batch must not have to wait out the rest of the feed.
    final f = feed(total: 200);
    var cancelled = false;

    final all = await drainPages((page) {
      // Cancel once the second page has been asked for.
      if (page >= 1) cancelled = true;
      return f.fetch(page);
    }, shouldStop: () => cancelled);

    expect(all, hasLength(40));
    expect(f.requested, [0, 1]);
  });

  test('a failing page propagates instead of returning a short list', () async {
    // Swallowing the error here would hand the caller a partial list that looks
    // complete — the exact failure mode this replaced.
    expect(
      drainPages<int>((page) async {
        if (page == 2) throw Exception('network');
        return PaginatedPage(items: [page], hasMore: true);
      }),
      throwsException,
    );
  });

  group('drainPagesWhilePreparing', () {
    /// Runs [body] with a real BuildContext from a tap handler — the snackbar
    /// inserts an overlay entry, which cannot happen during build.
    Future<T?> run<T>(
      WidgetTester tester,
      Future<T?> Function(BuildContext) body,
    ) async {
      late Future<T?> pending;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => pending = body(context),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      final result = await pending;
      await tester.pump();
      return result;
    }

    testWidgets('returns every page, not the loaded prefix', (tester) async {
      final f = feed(total: 90);

      final items = await run(
        tester,
        (context) => drainPagesWhilePreparing(context, f.fetch),
      );

      expect(items, hasLength(90));
    });

    testWidgets('returns null when the walk fails', (tester) async {
      // Null is load-bearing: the caller must cast/download NOTHING rather than
      // silently proceed with whatever pages happened to arrive.
      final items = await run(
        tester,
        (context) => drainPagesWhilePreparing<int>(context, (page) async {
          if (page == 1) throw Exception('network');
          return const PaginatedPage(items: [1], hasMore: true);
        }),
      );

      expect(items, isNull);
    });
  });
}
