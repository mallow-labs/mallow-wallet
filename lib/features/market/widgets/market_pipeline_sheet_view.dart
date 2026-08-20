import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/services/signing_copy.dart';
import '../../../shared/widgets/artwork_subject_header.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../services/market_bloc.dart';

/// Drives the unified [TransactionPipelineSheet] from [MarketBloc] state for
/// every market action. Auto-pops on success after a short pause; on error
/// stays mounted with Retry/Back affordances.
///
/// The header is supplied as primitives ([title]/[imageUrl]/[username]) rather
/// than an artwork object so the view is reusable across screens (artwork
/// detail, Offers) that don't share an artwork model.
class MarketPipelineSheetView extends StatefulWidget {
  const MarketPipelineSheetView({
    required this.actionType,
    super.key,
    this.title,
    this.imageUrl,
    this.username,
    this.nsfw = false,
  });

  final String actionType;

  /// Subject shown as the sheet header (image + "Title / @artist") so the user
  /// keeps sight of what they're transacting on while the pipeline runs.
  /// With [title] null the sheet falls back to panel-only.
  final String? title;
  final String? imageUrl;
  final String? username;

  /// Moderation flag for the header preview — blurs it (with an eye-icon
  /// reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  @override
  State<MarketPipelineSheetView> createState() =>
      _MarketPipelineSheetViewState();
}

class _MarketPipelineSheetViewState extends State<MarketPipelineSheetView> {
  // Guards against the success-path `reset()` re-triggering this listener
  // with `TxFlowIdle` and popping a second route — which would pop the
  // host screen instead of the (already-popped) sheet.
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MarketBloc, MarketState>(
      listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
      listener: (context, state) async {
        if (state is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
          // Brief pause so the success body is perceptible, then pop.
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (!context.mounted || _popped) return;
          _popped = true;
          Navigator.of(context).pop();
          if (!context.mounted) return;
          context.read<MarketBloc>().add(const MarketEvent.reset());
        } else if (state is TxFlowIdle<MarketPrepData, MarketSuccessData>) {
          // dismissError → reset → back to idle. Pop the sheet.
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
        final title = widget.title;
        final failure =
            state is TxFlowFailure<MarketPrepData, MarketSuccessData>
            ? state.failure
            : null;
        // The indeterminate end state: broadcast, never observed as confirmed
        // before the blockhash expired. "Transaction failed" would be a lie (it
        // may still land) and an enabled "Try again" is the double-send trap —
        // a market retry re-prepares the action on the backend, so it is a
        // *fresh* purchase (new blockhash, new ephemeral print-mint signer) and
        // both can settle on-chain. Mirrors `SendPipelineView`.
        final unconfirmed = failure?.isUnconfirmed ?? false;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed ? 'Not confirmed yet' : 'Transaction failed',
          // Subject centered above its "Title / @artist" line, mirroring the
          // confirm sheet so the action keeps its visual subject through
          // signing → success.
          // The failure message — `sublabel` isn't rendered in the error body
          // and `errorTitle` stays the generic headline, so without this the
          // reason was dropped entirely.
          errorSublabel: failure?.message,
          header: title == null
              ? null
              : ArtworkSubjectHeader(
                  title: title,
                  imageUrl: widget.imageUrl,
                  username: widget.username,
                  nsfw: widget.nsfw,
                ),
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
      return _successLabels(state.result.actionType);
    }
    if (state is TxFlowSigning<MarketPrepData, MarketSuccessData>) {
      final stage = state.stage;
      if (stage == null) {
        return (kExternalSigningLabel, kExternalSigningSublabel);
      }
      return (signingLabelForStage(stage), signingSublabelForStage(stage));
    }
    if (state is TxFlowBroadcasting<MarketPrepData, MarketSuccessData>) {
      // Buy/offer keep their action-specific *label* per the Figma spec;
      // everything else keeps the generic confirming line. The
      // subtitle is shared in every case — the confirmation wait is the same
      // wait regardless of which action started it.
      if (widget.actionType == 'buy') {
        return ('Buying artwork…', kConfirmingSublabelSolana);
      }
      if (widget.actionType == 'offer') {
        return ('Placing offer…', kConfirmingSublabelSolana);
      }
      return (kConfirmingLabel, kConfirmingSublabelSolana);
    }
    if (state is TxFlowPreparing<MarketPrepData, MarketSuccessData>) {
      return (kPreparingLabel, kPreparingSublabel);
    }
    return ('Working…', null);
  }

  (String, String?) _successLabels(String actionType) {
    return switch (actionType) {
      'buy' => ('Success!', 'The artwork is now yours'),
      'offer' => ('Offer submitted', null),
      'bid' => ('Bid placed', null),
      'cancel-offer' => ('Offer cancelled', null),
      // Mirrors the webapp's accept-offer success toast.
      'accept-offer' => ('Artwork sold!', null),
      'cancel-listing' => ('Listing cancelled', null),
      'update-listing' => ('Listing updated', null),
      'cancel-auction' => ('Auction cancelled', null),
      'reclaim-auction' => ('NFT reclaimed', null),
      'settle-auction' => ('Auction settled', null),
      _ => ('Transaction complete', null),
    };
  }
}
