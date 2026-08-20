import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../di.dart';

/// App-wide "the user's curations changed" signal.
///
/// Narrower sibling of `PortfolioRefreshSignal`: curation mutations (create,
/// rename, visibility, add/remove artwork) only invalidate the curation
/// groups on the My Art tab, so listeners refetch just those instead of the
/// whole portfolio.
///
/// [CurationRepository] fires [requestRefresh] (via [notifyCurationsRefresh])
/// after each successful mutation — curation endpoints are plain REST with no
/// indexer lag, so the awaited call itself is the ack. It's a broadcast
/// stream, so a missed signal (no live listener) is simply dropped — the next
/// fresh load reconciles.
@lazySingleton
class CurationsRefreshSignal {
  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<void> _controller = StreamController<void>.broadcast();

  Stream<void> get stream => _controller.stream;

  void requestRefresh() {
    if (_controller.isClosed) return;
    _controller.add(null);
  }

  @disposeMethod
  void dispose() => _controller.close();
}

/// Fire-and-forget curations refresh request, safe to call from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt).
void notifyCurationsRefresh() {
  if (sl.isRegistered<CurationsRefreshSignal>()) {
    sl<CurationsRefreshSignal>().requestRefresh();
  }
}
