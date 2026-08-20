import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/services/signing_copy.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/staking_bloc.dart';

/// Progress body for the stake/unstake/claim flow — drives the shared
/// [TransactionPipelineSheet] from [StakingBloc]'s `flow` state so the
/// preparing → signing → broadcasting → success/error progression is visible
/// (the stake sheet is a tall modal, so the old `ScaffoldMessenger` snackbars
/// rendered behind it and read as "no feedback").
///
/// Mirrors [MarketPipelineSheetView]: both consume the same
/// [TxFlow*]`<StakePrep, StakeSuccessData>` states. On success it refreshes
/// balances, holds the success body briefly, then pops and resets the form; on
/// error it stays mounted with Retry/Back; on cancel it pops silently; on a
/// kill-switch stop it pops so the host can explain it over the stake form.
class StakingPipelineSheetView extends StatefulWidget {
  const StakingPipelineSheetView({super.key});

  @override
  State<StakingPipelineSheetView> createState() =>
      _StakingPipelineSheetViewState();
}

class _StakingPipelineSheetViewState extends State<StakingPipelineSheetView> {
  // Guards against a terminal-state transition popping the sheet twice (e.g.
  // the success path's `reset()` re-firing the listener with `TxFlowIdle`).
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<StakingBloc, StakingState>(
      listenWhen: (a, b) => a.flow.runtimeType != b.flow.runtimeType,
      listener: (context, state) async {
        final flow = state.flow;
        if (flow is TxFlowSuccess<StakePrep, StakeSuccessData>) {
          // Pull the new on-chain balances behind the sheet, hold the success
          // body long enough to be perceptible, then pop + reset the form.
          context.read<TokenBalanceBloc>().add(
            const TokenBalanceEvent.refresh(),
          );
          await Future<void>.delayed(const Duration(milliseconds: 1400));
          if (!context.mounted || _popped) return;
          _popped = true;
          Navigator.of(context).pop();
          if (!context.mounted) return;
          context.read<StakingBloc>().add(const StakingEvent.reset());
        } else if (flow is TxFlowIdle<StakePrep, StakeSuccessData> ||
            (flow is TxFlowFailure<StakePrep, StakeSuccessData> &&
                (flow.failure.isCancelled || flow.failure.isFlowDisabled))) {
          // dismissError → reset → idle, a user-cancelled auth prompt, or a
          // kill-switch stop: pop without an error body. A kill is not a failed
          // transaction — offering Retry on a switched-off flow can only fail
          // again — so the host explains it over the (still open) stake form
          // once this sheet is gone.
          if (_popped) return;
          _popped = true;
          Navigator.of(context).pop();
          if (flow is TxFlowFailure<StakePrep, StakeSuccessData> &&
              !flow.failure.isFlowDisabled) {
            // Kills are reset by the host *after* it has read the failure off
            // the bloc to present it; resetting here would erase it first.
            context.read<StakingBloc>().add(const StakingEvent.reset());
          }
        }
      },
      builder: (context, state) {
        final flow = state.flow;
        final phase = switch (flow) {
          TxFlowSuccess<StakePrep, StakeSuccessData> _ =>
            TransactionPipelinePhase.success,
          // A kill is already dismissing this sheet (listener above) and is
          // presented as its own sheet over the stake form — rendering the
          // generic error body with its Retry action would flash the wrong
          // response during the pop animation.
          TxFlowFailure<StakePrep, StakeSuccessData>(:final failure)
              when !failure.isFlowDisabled =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final (label, sublabel) = _labelsFor(flow);
        final failure = flow is TxFlowFailure<StakePrep, StakeSuccessData>
            ? flow.failure
            : null;
        // Broadcast but never observed as confirmed before the blockhash
        // expired: indeterminate, not failed. A stake/unstake retry re-signs a
        // fresh transaction, so if the original lands too the user stakes (or
        // unstakes) twice — the retry affordance has to go, and the headline
        // must not claim a failure. Mirrors `SendPipelineView`.
        final unconfirmed = failure?.isUnconfirmed ?? false;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed
              ? 'Not confirmed yet'
              : (failure?.message ?? 'Transaction failed'),
          // Only for the unconfirmed case: the headline above carries the
          // message on every other failure, so setting this always would print
          // it twice.
          errorSublabel: unconfirmed ? failure?.message : null,
          onRetry: unconfirmed
              ? null
              : () =>
                    context.read<StakingBloc>().add(const StakingEvent.reset()),
          onClose: () =>
              context.read<StakingBloc>().add(const StakingEvent.reset()),
        );
      },
    );
  }

  (String, String?) _labelsFor(StakingFlowState flow) {
    if (flow is TxFlowSuccess<StakePrep, StakeSuccessData>) {
      return (flow.result.message, null);
    }
    if (flow is TxFlowSigning<StakePrep, StakeSuccessData>) {
      final stage = flow.stage;
      if (stage == null) {
        return (kExternalSigningLabel, kExternalSigningSublabel);
      }
      return (signingLabelForStage(stage), signingSublabelForStage(stage));
    }
    if (flow is TxFlowBroadcasting<StakePrep, StakeSuccessData>) {
      return (kConfirmingLabel, kConfirmingSublabelSolana);
    }
    // Preparing (and the brief idle before the first transition).
    return (kPreparingLabel, kPreparingSublabel);
  }
}
