import 'package:flutter/widgets.dart';

/// Attaches an "approaching the bottom" listener to an existing
/// [ScrollController] that fires [onLoadMore] when the viewport reaches the
/// trigger threshold and [canLoadMore] returns true.
///
/// Encapsulates the recurring pattern of
/// `position.pixels >= maxScrollExtent - viewportDimension * ratio` and the
/// `canLoadMore` re-entry guard that screens kept forgetting.
///
/// Use [attach] in `initState` and [detach] in `dispose`. The controller is
/// owned by the caller — this helper does not dispose it.
class PaginationScrollListener {
  PaginationScrollListener({
    required this.controller,
    required this.onLoadMore,
    required this.canLoadMore,
    this.viewportTriggerRatio = 1.0,
  });

  final ScrollController controller;
  final VoidCallback onLoadMore;
  final bool Function() canLoadMore;

  /// How many viewport-heights from the bottom should trigger a load. 1.0
  /// means "one viewport away" — kicks in well before the user sees the
  /// bottom indicator. Same as the previous bespoke check across screens.
  final double viewportTriggerRatio;

  void attach() => controller.addListener(_onScroll);
  void detach() => controller.removeListener(_onScroll);

  void _onScroll() {
    if (!controller.hasClients) return;
    if (!canLoadMore()) return;
    final position = controller.position;
    if (position.pixels >=
        position.maxScrollExtent -
            position.viewportDimension * viewportTriggerRatio) {
      onLoadMore();
    }
  }
}
