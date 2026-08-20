import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/services/signing_copy.dart';
import '../../../di.dart';
import '../../market/services/analytics_failure_reason.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../market/services/market_bloc.dart';
import '../../market/widgets/market_action_flow_sheet.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import 'portfolio_removal_refresh.dart';

/// End-to-end burn flow callable from any screen that holds a
/// [PortfolioArtwork] reference. Provides its own transient [MarketBloc] so
/// callers don't need a [BlocProvider] in scope.
///
/// Walks the same readyToSign → confirmation sheet → pipeline sheet → success
/// loop that [artwork_detail_screen] uses for market actions. Returns `true`
/// only after the on-chain burn confirms (chain success; indexer ack happens
/// later — caller refreshes its data sources on a `true` return).
///
/// [isCollection] marks [artwork] as a collection NFT (the caller passes a
/// facade built from the collection's mint/name/image): the burn event
/// skips the print-edition lookup and the sheets switch to collection copy.
Future<bool> runBurnArtworkFlow(
  BuildContext context, {
  required PortfolioArtwork artwork,
  bool isCollection = false,
}) async {
  // Kill-switch entry gate — in the shared helper
  // so the ~5 other burn call sites inherit it, reading the same `nft-burn`
  // cell the signing backstop checks.
  if (await guardFlowDisabled(context, const FlowKey.solana(AppFlow.nftBurn))) {
    return false;
  }
  if (!context.mounted) return false;
  final marketBloc = sl<MarketBloc>();
  // Burn doesn't need a balance check (it isn't in MarketConfirmationSheet's
  // `_balanceCheckedActions`), but the sheet still requires a TokenBalanceBloc
  // so the dependency is explicit at compile time. A fresh factory instance
  // is fine here — its state is never read for burn.
  final tokenBalanceBloc = sl<TokenBalanceBloc>();
  // Captures whether the bloc ever reached MarketSuccess before the pipeline
  // view dispatches `reset()` (which would otherwise erase the success state
  // before we get to inspect it).
  var succeeded = false;
  final stateSub = marketBloc.stream.listen((s) {
    // Kill switch. Presented from here — the one listener that spans the
    // whole flow — rather than from the terminal check below, because the gate
    // fires at *sign* time, so the kill lands while the pipeline step is open
    // and its generic "Burn failed" is otherwise all the user sees. The
    // operator's copy is the only thing that can say whether the asset survived.
    // The flow stays open and idle; the terminal check skips its duplicate.
    if (s is TxFlowFailure<MarketPrepData, MarketSuccessData> &&
        s.failure.isFlowDisabled) {
      final failure = s.failure;
      // Deferred a frame: `MarketActionFlowSheet` / the pipeline view pop
      // themselves from their own listeners on some emissions, and a
      // `Navigator.pop()` racing our push would take the explanation route.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        handleFlowDisabled(
          context,
          failure,
          flow: const FlowKey.solana(AppFlow.nftBurn),
        );
      });
      return;
    }
    // `!succeeded` gate: the bloc can re-emit TxFlowSuccess (the indexed
    // flip), and we only want to kick off one refresh poll per burn.
    if (s is TxFlowSuccess<MarketPrepData, MarketSuccessData> && !succeeded) {
      succeeded = true;
      // The artwork is destroyed. The bloc's own indexer ack can't reach this
      // (soon-closed) transient bloc, so refetch My Art directly once the
      // indexer reflects the burn — gated on ownership re-indexing, not just
      // the `checkTx` ack (which lands first). See [refreshMyArtAfterRemoval].
      unawaited(
        refreshMyArtAfterRemoval(
          mint: artwork.mintAccount,
          signature: s.signature,
        ),
      );
    }
  });

  try {
    // Kick off the tx build and show the flow immediately — the confirm step
    // renders shimmers while the bloc is in [TxFlowPreparing] and fills in once
    // the tx is built + simulated, instead of leaving the Burn tap unresponsive
    // until [TxFlowReady]. Mirrors [runTokenBurnFlow] and every other market
    // action (all hosted by [MarketActionFlowSheet]). The flow sheet pops the
    // whole route if preparing fails, leaving the bloc in [TxFlowFailure]
    // (surfaced below).
    marketBloc.add(
      MarketEvent.burn(
        mintAccount: artwork.mintAccount,
        isCollection: isCollection,
      ),
    );

    await showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => BlocProvider<MarketBloc>.value(
        value: marketBloc,
        child: MarketActionFlowSheet(
          tokenBalanceBloc: tokenBalanceBloc,
          isCollection: isCollection,
          artworkTitle: formatArtworkName(
            name: artwork.title,
            editionNumber: artwork.editionNumber,
          ),
          artworkImageUrl: artwork.imageUrl.isNotEmpty
              ? artwork.imageUrl
              : null,
          artistUsername: artwork.artistUsername,
          artistName: artwork.artistName,
          creatorAddress: artwork.updateAuth,
          // Burn collects no payment — gas only — so the confirm step renders
          // straight away (fee shimmering) while the tx builds, then resolves
          // in place on TxFlowReady.
          preview: MarketActionPreview(
            actionType: 'burn',
            mintAccount: artwork.mintAccount,
            totalCost: MarketPrice.zero(),
          ),
          pipelineBuilder: (_) => _BurnPipelineView(isCollection: isCollection),
        ),
      ),
    );

    // The route is closed; inspect the terminal bloc state. Only a *preparing*
    // failure lands here as [TxFlowFailure] — the flow sheet popped before
    // morphing to the pipeline. Post-confirm failures are shown inside the
    // pipeline step and reset to idle on close, so they don't reach here.
    final state = marketBloc.state;
    if (state is TxFlowFailure<MarketPrepData, MarketSuccessData>) {
      // A remote kill already got the shared explanation sheet from [stateSub]
      // above (it can only arrive post-confirm, so it reaches here only when the
      // user swipe-dismissed the pipeline error without resetting). No snackbar
      // and no `burn_failed` event: a kill is an operator action, not a burn
      // failure, and logging it would corrupt the burn-failure rate.
      if (state.failure.isFlowDisabled) return false;
      // Prepare (tx-build) failure — never broadcast. asset_kind / collection
      // aren't resolved to the UI here, so they're omitted per taxonomy.
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.burnFailed,
          txType: TxType.burnArtwork,
          // Prepare failure — nothing was broadcast, so there is no signature.
          isOnchainTx: false,
          properties: {
            AnalyticsProp.reason: analyticsFailureReason(state.failure).wire,
          },
          entryPoint: EntryPoint.artworkDetail,
        ),
      );
      if (context.mounted) {
        AppSnackBar.show(context, state.failure.message);
      }
      return false;
    }

    return succeeded;
  } finally {
    await stateSub.cancel();
    await marketBloc.close();
    await tokenBalanceBloc.close();
  }
}

/// Burn-specific clone of the market pipeline view used by the artwork detail
/// screen. Auto-pops on success after a short visible-success delay; on error
/// stays mounted so the user can retry or close.
class _BurnPipelineView extends StatefulWidget {
  const _BurnPipelineView({super.key, this.isCollection = false});

  final bool isCollection;

  @override
  State<_BurnPipelineView> createState() => _BurnPipelineViewState();
}

class _BurnPipelineViewState extends State<_BurnPipelineView> {
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MarketBloc, MarketState>(
      listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
      listener: (context, state) async {
        if (state is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
          // Fires once (this listener is gated on runtimeType change, so the
          // indexer-ack success re-emit is excluded). asset_kind / collection
          // aren't resolved to the UI here, so they're omitted per taxonomy.
          unawaited(
            sl<AnalyticsService>().trackTransaction(
              AnalyticsEvent.burnCompleted,
              txType: TxType.burnArtwork,
              signature: state.signature,
              entryPoint: EntryPoint.artworkDetail,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (!context.mounted || _popped) return;
          _popped = true;
          Navigator.of(context).pop();
        } else if (state is TxFlowFailure<MarketPrepData, MarketSuccessData>) {
          // Post-confirm (sign/broadcast) failure. A remote kill is excluded: it
          // is reported by `flow_disabled_hit` and must not inflate the
          // burn-failure rate. `runBurnArtworkFlow`'s stream listener owns
          // presenting it.
          if (state.failure.isFlowDisabled) return;
          unawaited(
            sl<AnalyticsService>().trackTransaction(
              AnalyticsEvent.burnFailed,
              txType: TxType.burnArtwork,
              // Sign/broadcast failure — the state carries no signature.
              isOnchainTx: false,
              properties: {
                AnalyticsProp.reason: analyticsFailureReason(
                  state.failure,
                ).wire,
              },
              entryPoint: EntryPoint.artworkDetail,
            ),
          );
        } else if (state is TxFlowIdle<MarketPrepData, MarketSuccessData>) {
          if (_popped) return;
          _popped = true;
          Navigator.of(context).pop();
        }
      },
      builder: (context, state) {
        final phase = switch (state) {
          TxFlowSuccess<MarketPrepData, MarketSuccessData> _ =>
            TransactionPipelinePhase.success,
          TxFlowFailure<MarketPrepData, MarketSuccessData> _ =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final (label, sublabel) = _labelsFor(state);
        final failure =
            state is TxFlowFailure<MarketPrepData, MarketSuccessData>
            ? state.failure
            : null;
        // Broadcast, never observed as confirmed before the blockhash expired:
        // indeterminate, not failed. "Burn failed" is a lie the user acts on —
        // the asset may well be gone. Re-burning an already-burned asset does
        // fail harmlessly on-chain, so the retry isn't a double-spend trap
        // here, but it is a wasted signature over a claim we can't make.
        // Mirrors `SendPipelineView`.
        final unconfirmed = failure?.isUnconfirmed ?? false;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed ? 'Not confirmed yet' : 'Burn failed',
          // The failure message — `sublabel` isn't rendered in the error body,
          // so without this the reason was dropped entirely.
          errorSublabel: failure?.message,
          onRetry: unconfirmed
              ? null
              : () => context.read<MarketBloc>().add(const MarketEvent.reset()),
          onClose: () =>
              context.read<MarketBloc>().add(const MarketEvent.reset()),
        );
      },
    );
  }

  (String, String?) _labelsFor(MarketState state) {
    if (state is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      return (
        widget.isCollection ? 'Collection burned' : 'Artwork burned',
        null,
      );
    }
    if (state is TxFlowSigning<MarketPrepData, MarketSuccessData>) {
      final stage = state.stage;
      if (stage == null) {
        return (kExternalSigningLabel, kExternalSigningSublabel);
      }
      return (signingLabelForStage(stage), signingSublabelForStage(stage));
    }
    if (state is TxFlowBroadcasting<MarketPrepData, MarketSuccessData>) {
      return (kConfirmingLabel, kConfirmingSublabelSolana);
    }
    if (state is TxFlowPreparing<MarketPrepData, MarketSuccessData>) {
      return (kPreparingLabel, kPreparingSublabel);
    }
    return ('Working…', null);
  }
}
