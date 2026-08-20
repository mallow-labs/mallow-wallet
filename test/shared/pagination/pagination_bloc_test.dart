import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/pagination/pagination_bloc.dart';

/// Test fetcher that records page requests and resolves on a per-page
/// completer so we can deliberately hold a page open and inject re-entry.
class _RecordingFetcher {
  final List<int> calls = [];
  final Map<int, Completer<PaginatedPage<int>>> _completers = {};

  Future<PaginatedPage<int>> call(int page) {
    calls.add(page);
    return (_completers[page] ??= Completer<PaginatedPage<int>>()).future;
  }

  void complete(int page, {required List<int> items, required bool hasMore}) {
    _completers[page]!.complete(PaginatedPage(items: items, hasMore: hasMore));
  }

  void fail(int page, Object error) {
    _completers[page]!.completeError(error);
  }
}

void main() {
  group('PaginationBloc', () {
    test('emits Loading -> Loaded on first load', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      final states = <PaginationState<int>>[];
      bloc.stream.listen(states.add);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1, 2, 3], hasMore: true);
      await Future<void>.delayed(Duration.zero);

      expect(states.first, isA<PaginationLoading<int>>());
      expect(states.last, isA<PaginationLoaded<int>>());
      final loaded = states.last as PaginationLoaded<int>;
      expect(loaded.items, [1, 2, 3]);
      expect(loaded.hasMore, isTrue);
      expect(loaded.isLoadingMore, isFalse);
    });

    test('loadMore appends items and increments page', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1, 2], hasMore: true);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const PaginationLoadMoreRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(1, items: [3, 4], hasMore: false);
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as PaginationLoaded<int>;
      expect(state.items, [1, 2, 3, 4]);
      expect(state.hasMore, isFalse);
      expect(fetcher.calls, [0, 1]);
    });

    test('rejects re-entrant loadMore while a page is in flight', () async {
      // Regression guard for the double-load scroll-edge bug — the listener
      // fires repeatedly while the user holds the scroll position at the
      // bottom, but only the first dispatched event should produce a fetch.
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1], hasMore: true);
      await Future<void>.delayed(Duration.zero);

      // Fire three loadMore events back-to-back while page 1 is still in
      // flight. Only one fetch should be issued.
      bloc.add(const PaginationLoadMoreRequested());
      bloc.add(const PaginationLoadMoreRequested());
      bloc.add(const PaginationLoadMoreRequested());
      await Future<void>.delayed(Duration.zero);

      expect(fetcher.calls, [0, 1]);

      fetcher.complete(1, items: [2], hasMore: false);
      await Future<void>.delayed(Duration.zero);

      // Once the first fetch resolves with hasMore=false, the queued events
      // see hasMore=false and short-circuit. No extra fetches.
      expect(fetcher.calls, [0, 1]);
    });

    test('rejects loadMore when hasMore is false', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1], hasMore: false);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const PaginationLoadMoreRequested());
      await Future<void>.delayed(Duration.zero);

      expect(fetcher.calls, [0]);
    });

    test('preserves items on loadMore error and exposes the error', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1, 2], hasMore: true);
      await Future<void>.delayed(Duration.zero);

      bloc.add(const PaginationLoadMoreRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.fail(1, StateError('network down'));
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as PaginationLoaded<int>;
      expect(state.items, [1, 2]);
      expect(state.isLoadingMore, isFalse);
      expect(state.loadMoreError, isA<StateError>());
    });

    test('refresh flags in-flight and emits even when the page is '
        'identical', () async {
      // Pull-to-refresh holds its indicator by awaiting isRefreshing
      // clearing. Without the flagged interim emission, a refetch returning
      // identical data would be equality-suppressed by the bloc and the
      // await would hang the indicator forever.
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      fetcher.complete(0, items: [1, 2], hasMore: true);
      await Future<void>.delayed(Duration.zero);

      final states = <PaginationState<int>>[];
      bloc.stream.listen(states.add);

      // The fetcher replays page 0's completed future — the refetched page
      // is byte-identical to what's already loaded.
      bloc.add(const PaginationRefreshRequested());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(states, hasLength(2));
      expect((states[0] as PaginationLoaded<int>).isRefreshing, isTrue);
      final done = states[1] as PaginationLoaded<int>;
      expect(done.isRefreshing, isFalse);
      expect(done.items, [1, 2]);
      expect(fetcher.calls, [0, 0]);
    });

    test('refresh failure keeps current items and clears the flag', () async {
      var calls = 0;
      final bloc = PaginationBloc<int>(
        fetchPage: (page) async {
          calls++;
          if (calls == 1) {
            return const PaginatedPage(items: [1, 2], hasMore: true);
          }
          throw StateError('network down');
        },
      );
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);

      bloc.add(const PaginationRefreshRequested());
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as PaginationLoaded<int>;
      expect(state.items, [1, 2]);
      expect(state.isRefreshing, isFalse);
      expect(state.loadMoreError, isA<StateError>());
    });

    test('seeds with initialItems and skips network', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(
        fetchPage: fetcher.call,
        initialItems: [10, 20, 30],
      );
      addTearDown(bloc.close);

      final loaded = bloc.state as PaginationLoaded<int>;
      expect(loaded.items, [10, 20, 30]);
      expect(loaded.hasMore, isFalse);

      bloc.add(const PaginationLoadMoreRequested());
      await Future<void>.delayed(Duration.zero);
      expect(fetcher.calls, isEmpty);
    });

    test('PaginationItemsSeeded seeds Initial state', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      expect(bloc.state, isA<PaginationInitial<int>>());

      bloc.add(const PaginationItemsSeeded([7, 8, 9], hasMore: true));
      await Future<void>.delayed(Duration.zero);

      final loaded = bloc.state as PaginationLoaded<int>;
      expect(loaded.items, [7, 8, 9]);
      expect(loaded.hasMore, isTrue);
      expect(fetcher.calls, isEmpty);
    });

    test('PaginationItemsSeeded is dropped once a fetch has started', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(fetchPage: fetcher.call);
      addTearDown(bloc.close);

      bloc.add(const PaginationLoadRequested());
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, isA<PaginationLoading<int>>());

      // Late cache seed should not clobber the in-flight fetch.
      bloc.add(const PaginationItemsSeeded([1, 2]));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, isA<PaginationLoading<int>>());

      fetcher.complete(0, items: [100], hasMore: false);
      await Future<void>.delayed(Duration.zero);
      final loaded = bloc.state as PaginationLoaded<int>;
      expect(loaded.items, [100]);
    });

    test('removeWhere drops matching items', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(
        fetchPage: fetcher.call,
        initialItems: [1, 2, 3, 4],
      );
      addTearDown(bloc.close);

      bloc.removeWhere((x) => x.isEven);
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as PaginationLoaded<int>;
      expect(state.items, [1, 3]);
    });

    // updateWhere backs the optimistic hide/unhide flip: matching items are
    // replaced in place (badge toggles) while the list order/length is kept.
    test('updateWhere replaces only matching items in place', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(
        fetchPage: fetcher.call,
        initialItems: [1, 2, 3, 4],
      );
      addTearDown(bloc.close);

      bloc.updateWhere((x) => x.isEven, (x) => x * 10);
      await Future<void>.delayed(Duration.zero);

      final state = bloc.state as PaginationLoaded<int>;
      expect(state.items, [1, 20, 3, 40]);
    });

    // A no-op update (transform returns the identical value) must NOT emit a
    // new state — an identity emit would rebuild every tile for nothing.
    test('updateWhere does not emit when nothing changes', () async {
      final fetcher = _RecordingFetcher();
      final bloc = PaginationBloc<int>(
        fetchPage: fetcher.call,
        initialItems: [1, 2, 3],
      );
      addTearDown(bloc.close);

      final emitted = <PaginationState<int>>[];
      bloc.stream.listen(emitted.add);

      // Predicate matches nothing → no replacement occurs.
      bloc.updateWhere((x) => x > 100, (x) => x * 10);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isEmpty);
      expect((bloc.state as PaginationLoaded<int>).items, [1, 2, 3]);
    });
  });
}
