import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/signing_copy.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../portfolio/models/token_balance.dart';
import '../services/send_bloc.dart';

/// Pipeline body for the send flow — mirrors the mint/edit pipeline so the
/// signing → broadcasting → success/error progression renders in the shared
/// [TransactionPipelineSheet]. Success surfaces "Done" + "View transaction"
/// actions; the latter opens the user's preferred explorer via [launchUrl].
class SendPipelineView extends StatelessWidget {
  const SendPipelineView({
    required this.token,
    required this.chain,
    super.key,
    this.onResetToInput,
  });

  final TokenBalance? token;

  /// The chain the send is on. Required because [token] is null for a *native*
  /// selection (SOL/ETH/XTZ collapse to the no-token code path in [SendBloc]),
  /// so the token cannot answer "which chain" for exactly the sends that need
  /// it most — a native ETH send is the pending-tx tracker's whole reason to
  /// exist.
  final Chain chain;

  /// When provided, the view morphs back to the input steps via this callback
  /// after an error is dismissed (the bloc returns to `SendInput`) instead of
  /// popping the route — used when hosted as an in-place step of the send
  /// sheet. When null, the view pops its own route (standalone use).
  final VoidCallback? onResetToInput;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SendBloc, SendState>(
      listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
      listener: (context, state) {
        // After the user dismisses an error via "Back", the bloc returns to
        // SendInput — morph back to the input steps (or, standalone, tear down
        // the route) so they land back on the form with their typed values.
        if (state is SendInput) {
          final reset = onResetToInput;
          if (reset != null) {
            reset();
          } else {
            Navigator.of(context).pop();
          }
        }
      },
      builder: (context, state) {
        final phase = switch (state) {
          SendSuccess _ => TransactionPipelinePhase.success,
          SendError _ => TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final symbol = token?.symbol ?? _nativeSymbol(chain);
        final (label, sublabel) = _labelsFor(state, symbol);
        // Once an EVM send is registered with the pending-transaction tracker it
        // owns confirmation (and the speed-up / cancel actions), so the user
        // doesn't have to sit out the 60 s wait — "Done" leaves the flow and
        // the transaction reappears in Pending until it resolves. Solana and
        // Tezos have no such tracker: leaving early there would drop the only
        // confirmation the user gets, so the affordance stays EVM-only.
        //
        // [SendBroadcasting.pendingRegistered] — not the state itself — is the
        // gate: broadcasting is entered *before* the raw transaction is sent, and
        // leaving during that window pops the bloc's provider, so a failing
        // `sendRawTransaction` would surface nowhere and no Pending entry would
        // exist. The user would believe a lost transaction was in flight.
        //
        // Gated on [chain], not `token.isEvm`: a native ETH send arrives here
        // with a null token, so asking the token would withhold Done from the
        // one send the tracker exists for.
        final canExitEarly =
            state is SendBroadcasting &&
            state.pendingRegistered &&
            chain == Chain.ethereum;
        // The indeterminate end state: broadcast, never observed as confirmed
        // before the blockhash expired. "Transaction failed" would be a lie
        // (it may still land) and an enabled "Try again" is the double-send
        // trap, so the headline changes and the retry affordance goes away —
        // the message points the user at Activity / the explorer instead.
        final unconfirmed = state is SendError && state.unconfirmed;
        // The one failure the user can actually act on: the transaction never
        // landed before its blockhash expired, which is a bidding problem, not
        // a retry problem — retrying at the same priority fee reproduces it.
        // Link straight into the global setting, mirroring the webapp's
        // "Try increasing your Transaction Priority fee" affordance. Withheld
        // at Turbo, where there is nothing left to raise. Priority fees are a
        // Solana-only recovery, so other chains must not inherit this CTA just
        // because they share the unconfirmed error state.
        final canRaiseFee =
            chain == Chain.solana &&
            unconfirmed &&
            sl<PriorityFeeService>().ceilingLamports <
                PriorityFeeTier.turbo.lamports;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed ? 'Not confirmed yet' : 'Transaction failed',
          // The failure message — `sublabel` isn't rendered in the error body
          // and `errorTitle` stays the generic headline, so without this the
          // reason was dropped entirely. (A kill never reaches here: the send
          // sheet presents it and resets out of the pipeline.)
          errorSublabel: state is SendError ? state.message : null,
          errorActionLabel: canRaiseFee ? 'Increase priority fee' : null,
          onErrorAction: canRaiseFee
              ? () => context.push(AppRoutes.priorityFee)
              : null,
          progressActionLabel: canExitEarly ? 'Done' : null,
          onProgressAction: canExitEarly
              ? () => Navigator.of(context).pop()
              : null,
          successAction: state is SendSuccess
              ? TransactionSuccessAction(
                  primaryLabel: 'View transaction',
                  onPrimary: () => _openExplorer(state.explorerUrl),
                  secondaryLabel: 'Done',
                  // Pops only the pipeline sheet — the send sheet host
                  // observes the success state and closes itself.
                  onSecondary: () => Navigator.of(context).pop(),
                )
              : null,
          onRetry: unconfirmed
              ? null
              : () => context.read<SendBloc>().add(const SendEvent.reset()),
          onClose: () => context.read<SendBloc>().add(const SendEvent.reset()),
        );
      },
    );
  }

  (String, String?) _labelsFor(SendState state, String symbol) {
    if (state is SendSuccess) {
      return ('Transaction sent', null);
    }
    if (state is SendSigning) {
      // Ledger keeps its approval prompt once the tx reaches the hardware
      // wallet; local and external wallets use their corresponding shared
      // copy below.
      if (state.onLedger) {
        return (kExternalSigningLabel, kLedgerSigningSublabel);
      }
      if (state.isLocal) {
        return (kLocalSigningLabel, kLocalSigningSublabel);
      }
      return (kExternalSigningLabel, kExternalSigningSublabel);
    }
    if (state is SendBroadcasting) {
      // Send is multi-chain: Solana lands in a slot or two, EVM/Tezos don't.
      return (kConfirmingLabel, confirmingSublabelForChain(chain));
    }
    // Action-specific label (the token being sent); shared preparing subtitle.
    return ('Sending $symbol…', kPreparingSublabel);
  }

  /// Symbol for a send with no token row — the native coin of [chain].
  static String _nativeSymbol(Chain chain) => switch (chain) {
    Chain.solana => 'SOL',
    Chain.ethereum => 'ETH',
    Chain.tezos => 'XTZ',
  };

  Future<void> _openExplorer(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  }
}
