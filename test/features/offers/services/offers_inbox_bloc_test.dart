import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/features/offers/data/offers_inbox_repository.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_balance.dart';
import 'package:mallow_wallet/features/offers/models/bid_refund_deposit.dart';

/// Records every getInbox call so tests can assert what the bloc requested
/// (owners aggregation, sort, page), and serves a page-indexed response.
class _RecordingInboxRepo implements OffersInboxRepository {
  _RecordingInboxRepo(
    this._byPage, {
    this.refunds = const [],
    this.refundFailure,
    this.refundReader,
    this.inboxReader,
  });
  final List<BidRefundBalance> refunds;

  @override
  Future<List<BidRefundDeposit>> getBidRefundDeposits(
    Iterable<String> owners,
  ) => throw StateError(
    'Deposit discovery must not run while loading the inbox',
  );
  final Object? refundFailure;
  final Future<List<BidRefundBalance>> Function()? refundReader;
  final Future<api.OffersInboxPage> Function()? inboxReader;
  int refundCalls = 0;

  final api.OffersInboxPage Function(int page) _byPage;
  final calls =
      <({Iterable<String> owners, api.OffersInboxSort sort, int page})>[];

  @override
  Future<List<BidRefundBalance>> getBidRefunds(Iterable<String> owners) async {
    refundCalls++;
    if (refundFailure != null) throw refundFailure!;
    return refundReader != null ? await refundReader!() : List.of(refunds);
  }

  @override
  Future<api.OffersInboxPage> getInbox({
    required Iterable<String> owners,
    api.OffersInboxSort sort = api.OffersInboxSort.latest,
    int page = 0,
    int pageSize = 30,
  }) async {
    calls.add((owners: owners, sort: sort, page: page));
    return inboxReader != null ? await inboxReader!() : _byPage(page);
  }
}

/// Supplies the current session owner keys and their chain-bearing wallet rows.
class _FakeSession extends Fake implements SessionManager {
  _FakeSession(this.apiOwnerAddresses);
  @override
  final List<String> apiOwnerAddresses;
  @override
  List<WalletInfo> get sessionWallets => apiOwnerAddresses
      .map(
        (address) => WalletInfo(
          id: address,
          address: address,
          name: address,
          walletType: WalletType.hd,
          chain: 'solana',
        ),
      )
      .toList();
}

void main() {
  api.OffersInboxItem item(String asset) => api.OffersInboxItem(
    kind: api.OffersInboxKind.offer,
    direction: api.OffersInboxDirection.received,
    asset: asset,
    artworkTitle: asset,
    actorAddress: 'ACTOR',
    viewerAddress: 'W1',
    rawAmount: 1,
    currencyMint: 'So11111111111111111111111111111111111111112',
  );

  // An auction-bid row carrying an [api.AuctionInfo] whose [endsAt]/status the
  // backend already stamped — used to prove the bloc re-derives liveness from
  // `endsAt` rather than trusting the server-sent `status`.
  api.OffersInboxItem auctionItem(
    String asset, {
    required DateTime endsAt,
    required api.AuctionStatus status,
  }) => api.OffersInboxItem(
    kind: api.OffersInboxKind.bid,
    direction: api.OffersInboxDirection.placed,
    asset: asset,
    artworkTitle: asset,
    actorAddress: 'ACTOR',
    viewerAddress: 'W1',
    rawAmount: 1,
    currencyMint: 'So11111111111111111111111111111111111111112',
    endTime: endsAt,
    auction: api.AuctionInfo(status: status, endTime: endsAt),
  );

  final session = _FakeSession(const ['W1', 'W2']);

  OffersInboxBloc build(api.OffersInboxPage Function(int) byPage) =>
      OffersInboxBloc(_RecordingInboxRepo(byPage), session);

  test(
    'live refund survives an empty auction feed and refresh removes a withdrawn claim',
    () async {
      final balance = BidRefundBalance(
        bidder: 'W1',
        refund: const api.BidRefund(
          claim: 'CLAIM',
          mint: 'CURRENCY',
          amount: '2000000',
        ),
      );
      final refunds = [balance];
      final repo = _RecordingInboxRepo(
        (_) => const api.OffersInboxPage(result: []),
        refunds: refunds,
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      final loaded =
          await bloc.stream.firstWhere(
                (state) =>
                    state is OffersInboxLoaded && state.bidRefunds.isNotEmpty,
              )
              as OffersInboxLoaded;
      expect(loaded.items, isEmpty);
      expect(loaded.bidRefunds.single.bidder, 'W1');
      refunds.clear();
      bloc.add(const OffersInboxEvent.refresh());
      final refreshed =
          await bloc.stream.firstWhere(
                (state) =>
                    state is OffersInboxLoaded &&
                    !state.isRefreshing &&
                    state.bidRefunds.isEmpty,
              )
              as OffersInboxLoaded;
      expect(refreshed.bidRefunds, isEmpty);
      await bloc.close();
    },
  );
  test(
    'refund read failure stays visible instead of claiming there is no balance',
    () async {
      final repo = _RecordingInboxRepo(
        (_) => const api.OffersInboxPage(result: []),
        refundFailure: Exception('Refund network unavailable'),
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      final loaded =
          await bloc.stream.firstWhere(
                (state) =>
                    state is OffersInboxLoaded && state.bidRefundError != null,
              )
              as OffersInboxLoaded;
      expect(loaded.bidRefundError, contains('unavailable'));
      await bloc.close();
    },
  );
  test(
    'refund withdrawal remains reachable when the artwork inbox fails',
    () async {
      const balance = BidRefundBalance(
        bidder: 'W1',
        refund: api.BidRefund(claim: 'CLAIM', mint: 'CURRENCY', amount: '42'),
      );
      final repo = _RecordingInboxRepo(
        (_) => throw Exception('Inbox unavailable'),
        refunds: [balance],
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      final loaded =
          await bloc.stream.firstWhere((state) => state is OffersInboxLoaded)
              as OffersInboxLoaded;
      expect(loaded.bidRefunds.single.bidder, 'W1');
      expect(loaded.inboxError, contains('Inbox unavailable'));
      await bloc.close();
    },
  );

  test('inbox renders before a slow refund scan finishes', () async {
    final refunds = Completer<List<BidRefundBalance>>();
    final repo = _RecordingInboxRepo(
      (_) => api.OffersInboxPage(result: [item('ART')]),
      refundReader: () => refunds.future,
    );
    final bloc = OffersInboxBloc(repo, session);
    bloc.add(const OffersInboxEvent.load());
    final loaded =
        await bloc.stream.firstWhere((s) => s is OffersInboxLoaded)
            as OffersInboxLoaded;
    expect(loaded.items!.single.asset, 'ART');
    expect(refunds.isCompleted, isFalse);
    expect(repo.refundCalls, 1);
    refunds.complete([]);
    await bloc.close();
  });

  test(
    'older inbox and refund responses cannot restore a withdrawn claim',
    () async {
      const balance = BidRefundBalance(
        bidder: 'W1',
        refund: api.BidRefund(claim: 'CLAIM', mint: 'CURRENCY', amount: '42'),
      );
      final oldInbox = Completer<api.OffersInboxPage>();
      final oldRefunds = Completer<List<BidRefundBalance>>();
      var inboxCalls = 0;
      var refundCalls = 0;
      final repo = _RecordingInboxRepo(
        (_) => const api.OffersInboxPage(result: []),
        inboxReader: () => ++inboxCalls == 1
            ? oldInbox.future
            : Future.value(api.OffersInboxPage(result: [item('NEW')])),
        refundReader: () =>
            ++refundCalls == 1 ? oldRefunds.future : Future.value([]),
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      // Wait for both first reads to start, then simulate the post-withdraw ack.
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OffersInboxEvent.refresh());
      await bloc.stream.firstWhere((s) => s is OffersInboxLoaded);
      oldInbox.complete(api.OffersInboxPage(result: [item('OLD')]));
      oldRefunds.complete([balance]);
      await bloc.close();
      final state = bloc.state as OffersInboxLoaded;
      expect(state.items!.single.asset, 'NEW');
      expect(state.bidRefunds, isEmpty);
    },
  );

  for (final refundFails in [false, true]) {
    test(
      'failed load-more preserves concurrent refund ${refundFails ? 'error' : 'balance'}',
      () async {
        const balance = BidRefundBalance(
          bidder: 'W1',
          refund: api.BidRefund(claim: 'CLAIM', mint: 'CURRENCY', amount: '42'),
        );
        final refunds = Completer<List<BidRefundBalance>>();
        final nextPage = Completer<api.OffersInboxPage>();
        var inboxCalls = 0;
        final repo = _RecordingInboxRepo(
          (_) => throw StateError('Unexpected synchronous page read'),
          refundReader: () => refunds.future,
          inboxReader: () => ++inboxCalls == 1
              ? Future.value(
                  api.OffersInboxPage(result: [item('ART')], nextPage: 1),
                )
              : nextPage.future,
        );
        final bloc = OffersInboxBloc(repo, session);
        addTearDown(bloc.close);
        final initial = bloc.stream.firstWhere((s) => s is OffersInboxLoaded);
        bloc.add(const OffersInboxEvent.load());
        await initial;
        final loading = bloc.stream.firstWhere(
          (s) => s is OffersInboxLoaded && s.isLoadingMore,
        );
        bloc.add(const OffersInboxEvent.loadMore());
        await loading;
        final refundUpdate = bloc.stream.firstWhere(
          (s) =>
              s is OffersInboxLoaded &&
              (refundFails
                  ? s.bidRefundError != null
                  : s.bidRefunds.isNotEmpty),
        );
        if (refundFails) {
          refunds.completeError(Exception('Refund unavailable'));
        } else {
          refunds.complete([balance]);
        }
        await refundUpdate;
        final finished = bloc.stream.firstWhere(
          (s) => s is OffersInboxLoaded && !s.isLoadingMore,
        );
        nextPage.completeError(Exception('Next page unavailable'));
        final current = await finished as OffersInboxLoaded;
        expect(current.items!.single.asset, 'ART');
        expect(current.hasMore, isTrue);
        if (refundFails) {
          expect(current.bidRefundError, contains('Refund unavailable'));
        } else {
          expect(current.bidRefunds, [balance]);
          expect(current.bidRefundError, isNull);
        }
        expect(repo.refundCalls, 1);
      },
    );
  }

  test('sort and load-more preserve refunds without repeating scans', () async {
    const balance = BidRefundBalance(
      bidder: 'W1',
      refund: api.BidRefund(claim: 'CLAIM', mint: 'CURRENCY', amount: '42'),
    );
    final repo = _RecordingInboxRepo(
      (_) => api.OffersInboxPage(result: [item('ART')], nextPage: 1),
      refunds: [balance],
    );
    final bloc = OffersInboxBloc(repo, session);
    bloc.add(const OffersInboxEvent.load());
    await bloc.stream.firstWhere(
      (s) => s is OffersInboxLoaded && s.bidRefunds.isNotEmpty,
    );
    final states = <OffersInboxState>[];
    final sub = bloc.stream.listen(states.add);
    bloc.add(const OffersInboxEvent.setSort(sort: api.OffersInboxSort.amount));
    await bloc.stream.firstWhere(
      (s) => s is OffersInboxLoaded && !s.isRefreshing,
    );
    expect(
      states.whereType<OffersInboxLoaded>().every(
        (s) => s.bidRefunds.single == balance,
      ),
      isTrue,
    );
    bloc.add(const OffersInboxEvent.loadMore());
    await bloc.stream.firstWhere(
      (s) => s is OffersInboxLoaded && !s.isLoadingMore,
    );
    expect(repo.refundCalls, 1);
    await sub.cancel();
    await bloc.close();
  });

  test(
    'artwork-only refresh skips refunds and errors retain the selected sort',
    () async {
      const balance = BidRefundBalance(
        bidder: 'W1',
        refund: api.BidRefund(claim: 'CLAIM', mint: 'CURRENCY', amount: '42'),
      );
      var fail = false;
      final repo = _RecordingInboxRepo(
        (_) => fail
            ? throw Exception('Inbox unavailable')
            : const api.OffersInboxPage(result: []),
        refunds: [balance],
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && s.bidRefunds.isNotEmpty,
      );
      bloc.add(const OffersInboxEvent.refresh(refreshRefunds: false));
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && !s.isRefreshing,
      );
      expect(repo.refundCalls, 1);
      fail = true;
      bloc.add(
        const OffersInboxEvent.setSort(sort: api.OffersInboxSort.amount),
      );
      final error =
          await bloc.stream.firstWhere(
                (s) => s is OffersInboxLoaded && s.inboxError != null,
              )
              as OffersInboxLoaded;
      expect(error.sort, api.OffersInboxSort.amount);
      expect(error.bidRefunds, [balance]);
      expect(repo.refundCalls, 1);
      await bloc.close();
    },
  );

  test(
    'total network failure is an error, including after changing sort',
    () async {
      final repo = _RecordingInboxRepo(
        (_) => throw Exception('Inbox unavailable'),
        refundFailure: Exception('Refund unavailable'),
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      expect(
        await bloc.stream.firstWhere((s) => s is OffersInboxError),
        isA<OffersInboxError>().having(
          (s) => s.message,
          'message',
          contains('Inbox unavailable'),
        ),
      );
      bloc.add(
        const OffersInboxEvent.setSort(sort: api.OffersInboxSort.amount),
      );
      await bloc.stream.firstWhere((s) => s is OffersInboxError);
      expect(repo.calls.last.sort, api.OffersInboxSort.amount);
      await bloc.close();
    },
  );

  group('load', () {
    blocTest<OffersInboxBloc, OffersInboxState>(
      'exposes the page-0 items returned by the inbox endpoint',
      build: () => build((_) => api.OffersInboxPage(result: [item('ART')])),
      act: (bloc) => bloc.add(const OffersInboxEvent.load()),
      verify: (bloc) =>
          expect((bloc.state as OffersInboxLoaded).items, hasLength(1)),
    );

    test('scopes owners to the CURRENT SESSION wallets (active account or '
        'profile), not every wallet on the device', () async {
      final repo = _RecordingInboxRepo(
        (_) => api.OffersInboxPage(result: [item('ART')]),
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && s.items != null,
      );
      expect(repo.calls.single.owners.toSet(), {'W1', 'W2'});
      await bloc.close();
    });

    blocTest<OffersInboxBloc, OffersInboxState>(
      'keeps hasMore true while the server reports a next page',
      build: () =>
          build((_) => api.OffersInboxPage(result: [item('ART')], nextPage: 1)),
      act: (bloc) => bloc.add(const OffersInboxEvent.load()),
      verify: (bloc) =>
          expect((bloc.state as OffersInboxLoaded).hasMore, isTrue),
    );
  });

  group('loadMore', () {
    blocTest<OffersInboxBloc, OffersInboxState>(
      'appends the next page and stops paging once the server omits nextPage',
      build: () => build(
        (page) => page == 0
            ? api.OffersInboxPage(result: [item('A')], nextPage: 1)
            : api.OffersInboxPage(result: [item('B')]),
      ),
      act: (bloc) async {
        bloc.add(const OffersInboxEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is OffersInboxLoaded && s.items != null,
        );
        bloc.add(const OffersInboxEvent.loadMore());
      },
      verify: (bloc) {
        final state = bloc.state as OffersInboxLoaded;
        expect(state.items!.map((i) => i.asset), ['A', 'B']);
        expect(state.hasMore, isFalse);
      },
    );
  });

  group('ended auctions', () {
    // The indexer DELETES a settled/cancelled auction's row (there is no
    // `settled` column), so a row that still exists with `endsAt` in the past
    // is ended-but-unsettled and must never render as live/bid-able — tapping
    // bid on it builds a doomed transaction. The backend stamps `status` from
    // its own clock, so we defend against a stale `live` by re-deriving from
    // `endsAt`.
    blocTest<OffersInboxBloc, OffersInboxState>(
      'coerces a past-endsAt auction to complete even when the server still '
      'reports it live (settle deletes the row, so this row is ended-unsettled)',
      build: () => build(
        (_) => api.OffersInboxPage(
          result: [
            auctionItem(
              'PAST',
              endsAt: DateTime.now().subtract(const Duration(hours: 1)),
              status: api.AuctionStatus.live,
            ),
          ],
        ),
      ),
      act: (bloc) => bloc.add(const OffersInboxEvent.load()),
      verify: (bloc) {
        final item = (bloc.state as OffersInboxLoaded).items!.single;
        expect(item.auction!.status, api.AuctionStatus.complete);
      },
    );

    // The `endsAt` check runs against the DEVICE clock, which routinely drifts
    // by a minute or two. Coercing a live auction to complete is the worse
    // error (mislabelled card, premature win/claim chips on a sale still
    // taking bids), so the guard only fires once the row is comfortably past
    // `endsAt` — a barely-past row is treated as still live.
    blocTest<OffersInboxBloc, OffersInboxState>(
      'leaves a barely-past-endsAt auction live (the device clock may simply '
      'be running fast)',
      build: () => build(
        (_) => api.OffersInboxPage(
          result: [
            auctionItem(
              'JUST_ENDED',
              endsAt: DateTime.now().subtract(const Duration(seconds: 30)),
              status: api.AuctionStatus.live,
            ),
          ],
        ),
      ),
      act: (bloc) => bloc.add(const OffersInboxEvent.load()),
      verify: (bloc) {
        final item = (bloc.state as OffersInboxLoaded).items!.single;
        expect(item.auction!.status, api.AuctionStatus.live);
      },
    );

    blocTest<OffersInboxBloc, OffersInboxState>(
      'leaves a future-endsAt auction live (still active and bid-able)',
      build: () => build(
        (_) => api.OffersInboxPage(
          result: [
            auctionItem(
              'FUTURE',
              endsAt: DateTime.now().add(const Duration(hours: 1)),
              status: api.AuctionStatus.live,
            ),
          ],
        ),
      ),
      act: (bloc) => bloc.add(const OffersInboxEvent.load()),
      verify: (bloc) {
        final item = (bloc.state as OffersInboxLoaded).items!.single;
        expect(item.auction!.status, api.AuctionStatus.live);
      },
    );
  });

  group('refresh', () {
    // Pull-to-refresh holds the indicator until the bloc emits a settled
    // state, so the refetch MUST be observable even when the server returns
    // the very same page. `OffersInboxLoaded` compares its items deeply and
    // `Bloc.emit` swallows a state equal to the current one — without the
    // `isRefreshing` flip the terminal emission is dropped, the screen's
    // `stream.firstWhere` never fires, and the loader spins forever.
    test('emits a settling state even when the page is unchanged, so the '
        'pull-to-refresh indicator can retract', () async {
      final bloc = build((_) => api.OffersInboxPage(result: [item('ART')]));
      bloc.add(const OffersInboxEvent.load());
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && s.items != null,
      );

      final settled = bloc.stream
          .firstWhere(
            (s) =>
                s is OffersInboxError ||
                (s is OffersInboxLoaded && !s.isRefreshing),
          )
          .timeout(const Duration(seconds: 5));
      bloc.add(const OffersInboxEvent.refresh());

      expect(await settled, isA<OffersInboxLoaded>());
      expect((bloc.state as OffersInboxLoaded).isRefreshing, isFalse);
      await bloc.close();
    });

    test(
      'marks the state refreshing while keeping the rendered rows',
      () async {
        final bloc = build((_) => api.OffersInboxPage(result: [item('ART')]));
        bloc.add(const OffersInboxEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is OffersInboxLoaded && s.items != null,
        );

        final refreshing = bloc.stream
            .firstWhere((s) => s is OffersInboxLoaded && s.isRefreshing)
            .timeout(const Duration(seconds: 5));
        bloc.add(const OffersInboxEvent.refresh());

        expect(((await refreshing) as OffersInboxLoaded).items, hasLength(1));
        await bloc.close();
      },
    );
  });

  group('setSort', () {
    test('refetches from page 0 with the new sort (ordering is server-side, '
        'since raw amounts span currencies)', () async {
      final repo = _RecordingInboxRepo(
        (_) => api.OffersInboxPage(result: [item('ART')]),
      );
      final bloc = OffersInboxBloc(repo, session);
      bloc.add(const OffersInboxEvent.load());
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && s.items != null,
      );
      bloc.add(
        const OffersInboxEvent.setSort(sort: api.OffersInboxSort.amount),
      );
      await bloc.stream.firstWhere(
        (s) => s is OffersInboxLoaded && !s.isRefreshing,
      );
      expect(repo.calls.last.sort, api.OffersInboxSort.amount);
      expect(repo.calls.last.page, 0);
      expect(
        (bloc.state as OffersInboxLoaded).sort,
        api.OffersInboxSort.amount,
      );
      await bloc.close();
    });
  });
}
