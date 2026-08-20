import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

/// Wraps `POST /v0/events/byMint/:mintAccount`. Returns paged marketplace
/// activity for a mint — listings, sales, bids, offers, claims. Powers the
/// Activity tab on the artwork detail screen and the bid-history modal
/// (Phase 5 wiring).
@lazySingleton
class ArtworkEventsRepository {
  ArtworkEventsRepository(this._api);

  final api.MallowApiClient _api;

  /// Default [mode] is `provenance` — the historical sale chain for the
  /// asset. `currentListing` shows only events tied to the active listing;
  /// `all` returns everything.
  ///
  /// **Swallows failures into an empty page.** That is correct for the
  /// internal pollers below (they retry), and wrong for anything that renders:
  /// an empty page is indistinguishable from "this artwork has no history", so
  /// a flaky connection reads as missing provenance. UI callers use
  /// [fetchEvents] and surface the error.
  Future<api.MarketActivityEventsPage> getEvents({
    required String mintAccount,
    int page = 0,
    int? pageSize,
    api.EventMode mode = api.EventMode.provenance,
  }) async {
    try {
      return await fetchEvents(
        mintAccount: mintAccount,
        page: page,
        pageSize: pageSize,
        mode: mode,
      );
    } catch (e) {
      debugPrint('[ArtworkEventsRepository] getEvents failed: $e');
      return const api.MarketActivityEventsPage();
    }
  }

  /// [getEvents] without the swallow — throws on a failed fetch so the caller
  /// can tell "no history" from "couldn't load it". Provenance is a trust
  /// surface: silently showing an empty one is a fail-loud violation.
  Future<api.MarketActivityEventsPage> fetchEvents({
    required String mintAccount,
    int page = 0,
    int? pageSize,
    api.EventMode mode = api.EventMode.provenance,
  }) {
    return _api.getEventsByMint(
      mintAccount,
      api.EventsByMintRequest(page: page, pageSize: pageSize, mode: mode),
    );
  }

  /// Poll the activity feed until the event produced by [txId] is indexed.
  ///
  /// A market action's post-tx refresh fires when its marketplace *entry*
  /// lands (`checkMarketplaceEntry`), but the derived `/v0/events/byMint`
  /// row is indexed a strictly later step — so a History refetch gated on
  /// the entry alone misses the just-created list / updatePrice / offer row.
  /// Callers fire-and-forget this and trigger one final refetch once it
  /// resolves `true`. Returns `false` after [maxAttempts] polls (the event
  /// may still land later — the next manual refresh will surface it).
  Future<bool> waitForEvent({
    required String mintAccount,
    required String txId,
    int maxAttempts = 10,
    Duration pollDelay = const Duration(seconds: 1),
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future<void>.delayed(pollDelay);
      final page = await getEvents(
        mintAccount: mintAccount,
        pageSize: 100,
        mode: api.EventMode.all,
      );
      if (page.result.any((e) => e.txId == txId)) {
        debugPrint('[LIST-DEBUG] waitForEvent OK txId=$txId attempt=$attempt');
        return true;
      }
    }
    debugPrint('[LIST-DEBUG] waitForEvent gave up txId=$txId');
    return false;
  }

  /// Resolve the mint of the print bought from [masterMint] in the buy tx
  /// [txId], by polling the master edition's activity feed until the sale
  /// event lands and reading its own `mintAccount` (the print).
  ///
  /// The buy-edition tx builder partial-signs with an ephemeral print-mint
  /// key that does NOT match the mint that actually lands on-chain (a
  /// stale-blockhash rebuild swaps in a fresh key), so that response field
  /// can't be trusted to route to the new print. The indexed sale event is
  /// the reliable source. The event indexes a strictly later step than the
  /// print's own artwork record, so once it resolves the print's
  /// `getArtworkByMint` is queryable — callers can navigate without a 404.
  /// Returns null after [maxAttempts] polls (the buy still succeeded; the
  /// caller should just stay put).
  Future<String?> printedMintForBuy({
    required String masterMint,
    required String txId,
    int maxAttempts = 15,
    Duration pollDelay = const Duration(seconds: 1),
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future<void>.delayed(pollDelay);
      final page = await getEvents(
        mintAccount: masterMint,
        pageSize: 100,
        mode: api.EventMode.all,
      );
      for (final event in page.result) {
        if (event.txId != txId) continue;
        debugPrint(
          '[edition-buy] printedMintForBuy txId=$txId -> '
          '${event.mintAccount} attempt=$attempt',
        );
        return event.mintAccount;
      }
    }
    debugPrint('[edition-buy] printedMintForBuy gave up txId=$txId');
    return null;
  }
}
