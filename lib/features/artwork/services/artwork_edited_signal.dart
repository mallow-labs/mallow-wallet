import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../di.dart';

/// App-wide "this artwork's indexed row changed — refetch it" signal.
///
/// Sibling of `PortfolioRefreshSignal` / `CurationsRefreshSignal`. Two kinds
/// of change reach it, because both invalidate exactly the same set of
/// **browse/list** surfaces:
///
///  1. **Metadata edits** (`editNft` / `editCollection`) — thumbnail, name,
///     description, collection membership.
///  2. **Money actions** (list / update / cancel / buy / offer / accept /
///     bid / settle) — the price and listing badge every grid tile renders.
///
/// Without (2) the artwork *detail* screen reloaded fresh while the home
/// rails, collection grids, curation grids and profile grids kept showing the
/// pre-action price — the webapp invalidates its artwork queries on both
/// (`queryInvalidation` `invalidateAssetQueries`,
/// called from `useListArtwork` / `useBuyNow` / the edit flows alike). The
/// portfolio (My Art) surfaces refresh via `PortfolioRefreshSignal`, which
/// fires from the same indexer-ack points.
///
/// Producers fire [requestRefresh] (via [notifyArtworkEdited]) **only once
/// the indexer has acked** the tx — `MintBloc._onIndexedAck`,
/// `MarketBloc._onIndexedAck`, `FixedPriceBloc._onIndexedAck`,
/// `AuctionBloc._onIndexedAck`. Firing earlier (e.g. on route pop) re-reads
/// stale pre-action server state, the bug the pre-existing best-effort
/// refetches suffered from. The payload is the affected mint account so a
/// subscriber can ignore unrelated mints. It's a broadcast stream, so a
/// missed signal (no live listener) is simply dropped — the next fresh load
/// reconciles.
@lazySingleton
class ArtworkEditedSignal {
  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void requestRefresh(String mintAccount) {
    if (_controller.isClosed) return;
    _controller.add(mintAccount);
  }

  @disposeMethod
  void dispose() => _controller.close();
}

/// Fire-and-forget "refetch this artwork everywhere" request, safe to call
/// from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt), so
/// producers can call it unconditionally without guarding each site.
void notifyArtworkEdited(String mintAccount) {
  if (sl.isRegistered<ArtworkEditedSignal>()) {
    sl<ArtworkEditedSignal>().requestRefresh(mintAccount);
  }
}
