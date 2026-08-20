import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../di.dart';

/// Payload for [ArtworkHiddenSignal]: the toggled mint and its new hidden state.
typedef ArtworkHiddenChange = ({String mintAccount, bool isHidden});

/// App-wide "an owned artwork was hidden/unhidden from the viewer's profile"
/// signal.
///
/// Sibling of [ArtworkRemovalSignal]: where that drops an item that left the
/// session's wallets, this flips the `isHidden` flag in place on every mounted
/// owned-art view (portfolio grids, own-profile grids) so the corner "hidden"
/// badge and the "..." menu's Hide/Unhide row update optimistically the instant
/// the `/v0/hide` write returns — no waiting for a refetch. Unlike a transfer,
/// hide is a pure DB write with no indexer ack, so a later refresh reconciles
/// cheaply if the optimistic flip was wrong (the write threw and was reverted).
///
/// The payload carries the mint and its new state; subscribers update the
/// matching item. It's a broadcast stream, so a missed signal (no live
/// listener) is simply dropped — the next fresh load reconciles from the
/// server's `isOwnerHidden`.
@lazySingleton
class ArtworkHiddenSignal {
  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<ArtworkHiddenChange> _controller =
      StreamController<ArtworkHiddenChange>.broadcast();

  Stream<ArtworkHiddenChange> get stream => _controller.stream;

  void requestUpdate(String mintAccount, {required bool isHidden}) {
    if (_controller.isClosed) return;
    _controller.add((mintAccount: mintAccount, isHidden: isHidden));
  }

  @disposeMethod
  void dispose() => _controller.close();
}

/// Fire-and-forget hidden-state change, safe to call from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt), so
/// producers can call it unconditionally without guarding each site.
void notifyArtworkHidden(String mintAccount, {required bool isHidden}) {
  if (sl.isRegistered<ArtworkHiddenSignal>()) {
    sl<ArtworkHiddenSignal>().requestUpdate(mintAccount, isHidden: isHidden);
  }
}
