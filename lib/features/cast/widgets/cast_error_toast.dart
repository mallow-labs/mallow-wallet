import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../services/cast_bloc.dart';
import 'cast_error_view.dart';

/// Shows a [CastError] as a global toast when no cast surface is on screen to
/// show it inline.
///
/// The inline [CastErrorView] only exists inside the cast sheets and Now
/// Playing. A session that drops while the user is browsing — receiver asleep,
/// off the network, taken over by another sender — therefore rendered nothing
/// at all: the now-casting bar simply vanished, which reads as "nothing
/// happened" rather than "casting stopped, here's why".
///
/// Suppression of the duplicate is driven by [CastErrorView.isPresenting],
/// i.e. by whether the error is *actually rendered* right now, not by a list
/// of routes that are assumed to render it. Two ways this could have been done
/// and why they lose:
///  • gating on the mid-session-drop transition (`CastActive` → `CastError`)
///    alone does not work — that drop most often happens *with* the queue
///    sheet or Now Playing open, which is exactly when the inline view shows;
///  • enumerating cast routes needs hand-maintained knowledge of which
///    surfaces render the error, and silently double-reports the day a new one
///    is added.
///
/// The check is deferred to the end of the frame because the bloc notifies
/// this listener and the open sheet's `BlocBuilder` in the same emission: at
/// listener time the sheet is only marked dirty, so its [CastErrorView] has
/// not mounted yet. By the post-frame callback it has.
class CastErrorToastListener extends StatelessWidget {
  const CastErrorToastListener({
    required this.child,
    this.overlayContext = castToastOverlayContext,
    super.key,
  });

  final Widget child;

  /// Resolves the context the toast is inserted from. Injectable so tests can
  /// supply one without standing up the app's router.
  final BuildContext? Function() overlayContext;

  @override
  Widget build(BuildContext context) {
    return BlocListener<CastBloc, CastState>(
      // Only the transition into a failure. Repeat/identical states are
      // already filtered by the bloc; this additionally keeps a follow-up
      // error from re-toasting while the first one is still up.
      listenWhen: (prev, curr) => prev is! CastError && curr is CastError,
      listener: (context, state) {
        if (state is! CastError) return;
        final bloc = context.read<CastBloc>();
        final message = state.message;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // A cast surface rendered the failure inline — it carries the same
          // message plus a "Try again"; a toast on top of it is noise.
          if (CastErrorView.isPresenting) return;
          // Recovered inside the frame (e.g. the user hit retry) — don't
          // announce a failure the bloc has already left.
          if (bloc.state is! CastError) return;
          final target = overlayContext();
          if (target == null || !target.mounted) return;
          AppSnackBar.show(target, message, type: AppSnackBarType.error);
        });
      },
      child: child,
    );
  }
}

/// A [BuildContext] that can reach the root [Overlay] from app scope.
///
/// [AppSnackBar.show] resolves `Overlay.of(context, rootOverlay: true)`, which
/// walks *ancestors* — and the root navigator's own context has none, because
/// the overlay is the navigator's descendant. `rootNavigatorKey.currentContext`
/// therefore throws rather than showing a toast. The top route's
/// [ModalRoute.subtreeContext] does sit inside an overlay entry, so it
/// resolves. `popUntil` with an always-true predicate pops nothing — it is the
/// only public read of the current route.
BuildContext? castToastOverlayContext() {
  final navigator = AppRoutes.rootNavigatorKey.currentState;
  if (navigator == null) return null;
  BuildContext? context;
  navigator.popUntil((route) {
    context = route is ModalRoute ? route.subtreeContext : null;
    return true;
  });
  return context;
}
