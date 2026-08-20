import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';

/// Hand-written fake (no codegen) that returns a scripted sequence of event
/// pages from `getEventsByMint`, one per call. The last page repeats once the
/// script is exhausted so polling loops settle. Only [getEventsByMint] is
/// exercised by these tests; everything else routes through [noSuchMethod].
class _FakeApi implements MallowApiClient {
  _FakeApi(this._pages);

  final List<MarketActivityEventsPage> _pages;
  int calls = 0;

  @override
  Future<MarketActivityEventsPage> getEventsByMint(
    String mintAccount,
    EventsByMintRequest request,
  ) async {
    final page = _pages[calls < _pages.length ? calls : _pages.length - 1];
    calls++;
    return page;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MarketActivityEvent _saleEvent({required String mint, required String txId}) =>
    MarketActivityEvent(
      txId: txId,
      mintAccount: mint,
      type: MarketEventType.sale,
    );

void main() {
  const masterMint = '46TpaLV9iS9Js63nHn95amwpX5pcGL5NjGgYwDcGL8ia';
  const printMint = 'ARWrM9TRjCrw1qG5tjiS6W3v8h7aUscJBdP4r23Nufce';
  const buyTxId = 'sSC8q2HyARb6cx1kbWT4xRKV2FuCjskkEN2pPXfuyNJ7';

  group('printedMintForBuy', () {
    test('returns the matching sale event\'s own mint (the print)', () async {
      // The print mint differs from the master the feed is keyed on — proving
      // we read the event's mint, not the queried master mint.
      final repo = ArtworkEventsRepository(
        _FakeApi([
          MarketActivityEventsPage(
            result: [_saleEvent(mint: printMint, txId: buyTxId)],
          ),
        ]),
      );

      final result = await repo.printedMintForBuy(
        masterMint: masterMint,
        txId: buyTxId,
        pollDelay: Duration.zero,
      );

      expect(result, printMint);
    });

    test('polls until the event lands, ignoring unrelated rows', () async {
      final api = _FakeApi([
        // Attempt 1: only an unrelated event for a different tx.
        MarketActivityEventsPage(
          result: [_saleEvent(mint: 'other', txId: 'other-tx')],
        ),
        // Attempt 2: the buy event appears.
        MarketActivityEventsPage(
          result: [_saleEvent(mint: printMint, txId: buyTxId)],
        ),
      ]);
      final repo = ArtworkEventsRepository(api);

      final result = await repo.printedMintForBuy(
        masterMint: masterMint,
        txId: buyTxId,
        pollDelay: Duration.zero,
      );

      expect(result, printMint);
      expect(api.calls, 2);
    });

    test(
      'returns null after exhausting attempts when no event matches',
      () async {
        final repo = ArtworkEventsRepository(
          _FakeApi([const MarketActivityEventsPage()]),
        );

        final result = await repo.printedMintForBuy(
          masterMint: masterMint,
          txId: buyTxId,
          maxAttempts: 3,
          pollDelay: Duration.zero,
        );

        expect(result, isNull);
      },
    );
  });

  // Why this matters: the History tab renders provenance. An empty page means
  // "this artwork has never traded" — a claim about the chain. Swallowing a
  // failed request into an empty page makes the app assert that claim from a
  // dropped connection. The internal pollers *do* want the swallow (they
  // retry), so the two behaviours have to stay separate methods.
  group('failure propagation', () {
    test('fetchEvents rethrows so a caller can tell failed from empty', () {
      final repo = ArtworkEventsRepository(_ThrowingApi());

      expect(
        () => repo.fetchEvents(mintAccount: masterMint),
        throwsA(isA<Exception>()),
      );
    });

    test('getEvents still swallows, for the polling call sites', () async {
      final repo = ArtworkEventsRepository(_ThrowingApi());

      final page = await repo.getEvents(mintAccount: masterMint);

      expect(page.result, isEmpty);
    });
  });
}

/// Every `getEventsByMint` call fails — stands in for a dropped connection.
class _ThrowingApi implements MallowApiClient {
  @override
  Future<MarketActivityEventsPage> getEventsByMint(
    String mintAccount,
    EventsByMintRequest request,
  ) async => throw Exception('network down');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
