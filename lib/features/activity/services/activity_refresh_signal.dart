import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../di.dart';

/// App-wide "the activity feed is out of date" signal.
///
/// Mirrors [PortfolioRefreshSignal] for the "Recent activity" sheet: the
/// pending-EVM-tx tracker resolves a transaction in the background, and the
/// server row for it only appears after a refetch. The activity sheet's list
/// view (`activity_screen.dart`) subscribes and fires
/// `PaginationRefreshRequested` on its `PaginationBloc<api.Activity>`; when the
/// sheet is closed there is no listener and the signal is simply dropped — it
/// re-reads on open anyway.
@lazySingleton
class ActivityRefreshSignal {
  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<ActivityRefreshEvent> _controller =
      StreamController<ActivityRefreshEvent>.broadcast();

  Stream<ActivityRefreshEvent> get stream => _controller.stream;

  void requestRefresh({api.Activity? optimisticActivity}) {
    if (_controller.isClosed) return;
    _controller.add(
      ActivityRefreshEvent(optimisticActivity: optimisticActivity),
    );
  }

  @disposeMethod
  void dispose() => _controller.close();
}

/// A request to revalidate the activity feed, optionally carrying an activity
/// that was just completed locally. The activity list can render the latter
/// immediately while the server/indexer catches up.
class ActivityRefreshEvent {
  const ActivityRefreshEvent({this.optimisticActivity});

  final api.Activity? optimisticActivity;
}

/// Fire-and-forget activity refresh request, safe to call from anywhere.
///
/// No-ops when DI isn't configured (unit tests that don't bootstrap GetIt), so
/// producers can call it unconditionally.
void notifyActivityRefresh({api.Activity? optimisticActivity}) {
  if (sl.isRegistered<ActivityRefreshSignal>()) {
    sl<ActivityRefreshSignal>().requestRefresh(
      optimisticActivity: optimisticActivity,
    );
  }
}
