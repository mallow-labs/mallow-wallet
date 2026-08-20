import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../di.dart';

/// App-wide "an owned artwork left the session's wallets" signal.
///
/// Immediate-mode sibling of `PortfolioRefreshSignal`: where that fires a full
/// refetch once the indexer has acked (a few seconds later), this fires the
/// instant the on-chain transfer/burn confirms so every mounted view that
/// renders the owned item can drop it *optimistically* — no waiting for the
/// backend to re-index ownership. The delayed `PortfolioRefreshSignal` refetch
/// still runs afterwards as the source of truth and reconciles any mistake
/// (e.g. a transfer that never actually left the wallet re-appears).
///
/// The payload is the removed mint account; subscribers `removeWhere` by it.
///
/// Fired from [refreshMyArtAfterRemoval] (the shared success path of the
/// transfer and burn flows) via [notifyArtworkRemoved]. A transfer to another
/// wallet *in the current session* does NOT fire it — the portfolio aggregates
/// across all session wallets, so the asset is still owned by the viewer and
/// must stay on screen. Burns always fire it.
///
/// It's a broadcast stream, so a missed signal (no live listener) is simply
/// dropped — the next fresh load reconciles.
@lazySingleton
class ArtworkRemovalSignal {
  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void requestRemoval(String mintAccount) {
    if (_controller.isClosed) return;
    _controller.add(mintAccount);
  }

  @disposeMethod
  void dispose() => _controller.close();
}

/// Fire-and-forget optimistic-removal request, safe to call from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt), so
/// producers can call it unconditionally without guarding each site.
void notifyArtworkRemoved(String mintAccount) {
  if (sl.isRegistered<ArtworkRemovalSignal>()) {
    sl<ArtworkRemovalSignal>().requestRemoval(mintAccount);
  }
}
