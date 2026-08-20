import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';

/// App-wide toast for a pending EVM transaction that just resolved.
///
/// A tracked transaction outlives the flow that sent it — the send pipeline's
/// early exit, a backgrounded app, even a restart — so the outcome has to
/// surface wherever the user happens to be, not on the screen that started it.
///
/// Mounting this also [PendingEvmTxTracker.start]s the watcher: it lives in the
/// unlocked branch of the app shell, which is exactly the "app start, session
/// unlocked" moment polling should begin at. The tracker's own lifecycle
/// observer pauses it in the background from there.
class PendingTxResolutionListener extends StatefulWidget {
  const PendingTxResolutionListener({required this.child, super.key});

  final Widget child;

  @override
  State<PendingTxResolutionListener> createState() =>
      _PendingTxResolutionListenerState();
}

class _PendingTxResolutionListenerState
    extends State<PendingTxResolutionListener> {
  StreamSubscription<PendingTxResolution>? _sub;

  @override
  void initState() {
    super.initState();
    final tracker = sl<PendingEvmTxTracker>();
    _sub = tracker.resolutions.listen(_onResolution);
    tracker.start();
  }

  void _onResolution(PendingTxResolution resolution) {
    // The root navigator's context sits below the Navigator; this widget's own
    // context is above it in the MaterialApp.router builder and has no overlay
    // to insert into.
    final navContext = AppRoutes.rootNavigatorKey.currentContext;
    if (navContext == null) return;
    AppSnackBar.show(
      navContext,
      switch (resolution.kind) {
        PendingTxResolutionKind.confirmed => 'Transaction confirmed',
        PendingTxResolutionKind.reverted => 'Transaction failed',
        PendingTxResolutionKind.cancelled => 'Transaction cancelled',
        PendingTxResolutionKind.replaced => 'Transaction replaced',
      },
      type: switch (resolution.kind) {
        PendingTxResolutionKind.confirmed => AppSnackBarType.success,
        PendingTxResolutionKind.reverted => AppSnackBarType.error,
        PendingTxResolutionKind.cancelled ||
        PendingTxResolutionKind.replaced => AppSnackBarType.info,
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
