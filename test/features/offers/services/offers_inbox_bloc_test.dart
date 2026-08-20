import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/offers/data/offers_inbox_repository.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';

/// Records every getInbox call so tests can assert what the bloc requested
/// (owners aggregation, sort, page), and serves a page-indexed response.
class _RecordingInboxRepo implements OffersInboxRepository {
  _RecordingInboxRepo(this._byPage);

  final api.OffersInboxPage Function(int page) _byPage;
  final calls =
      <({Iterable<String> owners, api.OffersInboxSort sort, int page})>[];

  @override
  Future<api.OffersInboxPage> getInbox({
    required Iterable<String> owners,
    api.OffersInboxSort sort = api.OffersInboxSort.latest,
    int page = 0,
    int pageSize = 30,
  }) async {
    calls.add((owners: owners, sort: sort, page: page));
    return _byPage(page);
  }
}

/// Stands in for the current session. The bloc reads only `apiOwnerAddresses`
/// (the active Account's / Profile's wallet addresses, normalised for the
/// backend's owner index, NOT every wallet on the device), so the fake serves
/// that list verbatim rather than re-deriving it from wallets — re-deriving
/// would mirror the production accessor and could never disagree with it.
class _FakeSession extends Fake implements SessionManager {
  _FakeSession(this.apiOwnerAddresses);
  @override
  final List<String> apiOwnerAddresses;
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
        (s) => s is OffersInboxLoaded && s.items != null,
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
