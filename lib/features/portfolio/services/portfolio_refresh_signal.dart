import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../di.dart';

/// App-wide "the owner's art set changed" signal.
///
/// The My Art (portfolio) tab is rendered by [YourArtScreen]'s [PortfolioBloc],
/// which stays mounted underneath any pushed detail/flow route. Mutating an
/// artwork from one of those routes — buy/mint (add), edit/list (edit), or
/// transfer/burn/sale (remove) — must refetch the portfolio so the change is
/// reflected when the user pops back.
///
/// Producers fire [requestRefresh] (via [notifyPortfolioRefresh]) from the
/// point where the mutation's indexer ack has landed (`checkTx` / `checkEntry`)
/// — refreshing earlier would re-read the stale pre-mutation server state.
/// [PortfolioBloc] subscribes and refetches on each signal. It's a broadcast
/// stream, so a missed signal (no live listener) is simply dropped — the next
/// fresh load reconciles.
@lazySingleton
class PortfolioRefreshSignal {
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

/// Fire-and-forget portfolio refresh request, safe to call from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt), so
/// producers can call it unconditionally from bloc handlers and flow callbacks
/// without guarding each site.
void notifyPortfolioRefresh() {
  if (sl.isRegistered<PortfolioRefreshSignal>()) {
    sl<PortfolioRefreshSignal>().requestRefresh();
  }
}
