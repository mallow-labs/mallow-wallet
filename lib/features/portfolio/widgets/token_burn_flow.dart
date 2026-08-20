import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../data/session_portfolio_aggregator.dart';
import '../models/token_balance.dart';
import '../services/token_balance_bloc.dart';
import '../services/token_burn_bloc.dart';
import 'token_burn_confirm_sheet.dart';

import '../../../shared/utils/chain.dart';

/// End-to-end fungible-token burn flow: prepare → confirm → pipeline →
/// success, all in a **single** modal route that morphs the confirm step into
/// the in-flight pipeline step in place (no dismiss/re-present). Mirrors
/// [runBurnArtworkFlow] for NFTs. Provides its own transient [TokenBurnBloc] so
/// callers don't need a [BlocProvider] in scope.
///
/// On confirmed success the passed [tokenBalanceBloc] is refreshed so the now-
/// closed token disappears from the portfolio. Returns `true` only after the
/// on-chain burn confirms.
///
/// Entry gate for `solana:token-burn`. Gated in
/// the shared helper so every caller inherits it.
Future<bool> runTokenBurnFlow(
  BuildContext context, {
  required TokenBalance token,
  required TokenBalanceBloc tokenBalanceBloc,
}) async {
  // Before [_resolveBurnSource]: a killed burn must not re-point the user's
  // active signer at another wallet on its way to refusing.
  if (await guardFlowDisabled(
    context,
    const FlowKey.solana(AppFlow.tokenBurn),
  )) {
    return false;
  }
  if (!context.mounted) return false;

  // Point the signer at a wallet that actually holds the mint *before* building
  // the tx — see [_resolveBurnSource].
  final source = await _resolveBurnSource(context, token);
  if (source == null || !context.mounted) return false;

  final bloc = TokenBurnBloc(sl(), sl(), sl(), sl(), sl());

  try {
    // Kick off the tx build and show the flow immediately — the confirm step
    // renders shimmers while the bloc is in [TxFlowPreparing] and fills in once
    // the tx is built + simulated. The confirm step pops the whole flow if
    // preparing fails, leaving the bloc in [TxFlowFailure] (surfaced below).
    bloc.add(TokenBurnPrepareRequested(source));

    await showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => BlocProvider<TokenBurnBloc>.value(
        value: bloc,
        child: _TokenBurnFlowSheet(
          token: source,
          tokenBalanceBloc: tokenBalanceBloc,
        ),
      ),
    );

    // The route is closed; inspect the terminal bloc state.
    final state = bloc.state;
    if (state is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>) {
      // A *preparing* failure lands here (the confirm step popped before
      // morphing to the pipeline), and so does a kill caught by the signing
      // backstop (the pipeline step pops for those instead of showing its
      // generic "Burn failed" body). Every other post-confirm failure is shown
      // inside the pipeline step and reset to idle on Back, so it doesn't reach
      // here.
      if (context.mounted &&
          !handleFlowDisabled(
            context,
            state.failure,
            // The operator's message over the surface the burn was launched
            // from, which stays open and untouched — never a snackbar,
            // which is a failure notice and easy to miss.
            flow: const FlowKey.solana(AppFlow.tokenBurn),
          )) {
        AppSnackBar.show(context, state.failure.message);
      }
      return false;
    }

    final succeeded = state is TxFlowSuccess<TokenBurnPrep, TokenBurnSuccess>;
    if (succeeded) {
      // The token account is closed — refresh so it drops off the portfolio.
      tokenBalanceBloc.add(const TokenBalanceEvent.refresh());
    }
    return succeeded;
  } finally {
    await bloc.close();
  }
}

/// Re-point the active signer at a session wallet that actually holds [token]'s
/// mint, and narrow the burn to that wallet's holding.
///
/// The tokens tab aggregates a Profile session's Solana wallets into one row per
/// mint, but a burn only ever destroys the **active** wallet's holding: burning
/// a row funded by another session wallet otherwise fails the tx build outright
/// ("This wallet holds no token account for …") before the confirm sheet's own
/// "Switch" line is ever reachable — the sheet pops on a prepare failure.
///
/// Which wallet is chosen is [pickFundingSource]'s shared active-wins /
/// largest-holder policy, and the user can still switch from the confirm sheet.
/// Candidates come from [SessionPortfolioAggregator.sendSourcesForMint], which
/// is already filtered to **signable** session wallets on the chain — a
/// watch-only holder can't burn — so [SessionManager.selectSourceWallet] is
/// called directly rather than through `ensureSigner`, whose
/// watch-only/delegate/EVM resolution is a no-op here. The switch is durable,
/// matching the confirm sheet's own "Switch" and every other source-wallet flow.
///
/// Returns the token to burn, [SendSourceCandidate.narrow]ed to the **selected**
/// wallet's balance. Returns null when the switch failed and the flow should
/// abort. Falls back to the unchanged [token] (build against the active wallet,
/// as before) only when no session wallet holds the mint, or when the session or
/// the balance cache can't be read at all.
Future<TokenBalance?> _resolveBurnSource(
  BuildContext context,
  TokenBalance token,
) async {
  final SendSourceCandidate holder;
  final bool needsSwitch;
  try {
    // Independent reads — the address lookup doesn't feed the candidate scan.
    final (active, candidates) = await (
      sl<WalletManager>().getAddress(),
      sl<SessionPortfolioAggregator>().sendSourcesForMint(
        chain: Chain.solana,
        mint: token.mint,
      ),
    ).wait;
    final picked = pickFundingSource(
      candidates,
      activeAddress: active,
      isNative: token.isNative,
    );
    if (picked == null) return token;
    holder = picked;
    needsSwitch = holder.wallet.address != active;
  } catch (_) {
    // No resolvable active wallet / balance cache — leave the burn pointed at
    // the active wallet rather than blocking a flow the user already opened.
    return token;
  }

  if (needsSwitch) {
    try {
      await sl<SessionManager>().selectSourceWallet(holder.wallet);
    } catch (_) {
      if (context.mounted) {
        AppSnackBar.show(
          context,
          "Couldn't switch to the wallet that holds this token. "
          'Please try again.',
        );
      }
      return null;
    }
  }

  return holder.narrow(token);
}

/// Single-route host for the token-burn flow: the confirm step morphs into the
/// pipeline step in place once the user confirms. Dismissal during the
/// in-flight pipeline is blocked by [TransactionPipelineSheet]'s own
/// `PopScope`; the confirm step stays freely dismissible (cancel / drag = back
/// out).
class _TokenBurnFlowSheet extends StatefulWidget {
  const _TokenBurnFlowSheet({
    required this.token,
    required this.tokenBalanceBloc,
  });

  final TokenBalance token;
  final TokenBalanceBloc tokenBalanceBloc;

  @override
  State<_TokenBurnFlowSheet> createState() => _TokenBurnFlowSheetState();
}

class _TokenBurnFlowSheetState extends State<_TokenBurnFlowSheet> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    return SheetStepSwitcher(
      child: _confirmed
          ? const _TokenBurnPipelineView(key: ValueKey('pipeline'))
          : KeyedSubtree(
              key: const ValueKey('confirm'),
              child: TokenBurnConfirmSheet(
                token: widget.token,
                tokenBalanceBloc: widget.tokenBalanceBloc,
                onConfirmed: () => setState(() => _confirmed = true),
              ),
            ),
    );
  }
}

/// Pipeline view for the burn lifecycle. Auto-pops on success after a short
/// visible-success delay; on error stays mounted so the user can retry/close.
class _TokenBurnPipelineView extends StatefulWidget {
  const _TokenBurnPipelineView({super.key});

  @override
  State<_TokenBurnPipelineView> createState() => _TokenBurnPipelineViewState();
}

class _TokenBurnPipelineViewState extends State<_TokenBurnPipelineView> {
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TokenBurnBloc, TokenBurnState>(
      listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
      listener: (context, state) async {
        if (state is TxFlowSuccess<TokenBurnPrep, TokenBurnSuccess>) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (!context.mounted || _popped) return;
          _popped = true;
          Navigator.of(context).pop();
        } else if (state is TxFlowIdle<TokenBurnPrep, TokenBurnSuccess>) {
          if (_popped) return;
          _popped = true;
          Navigator.of(context).pop();
        } else if (state is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess> &&
            state.failure.isFlowDisabled) {
          // A kill is not a failed burn: the error body's hardcoded "Burn
          // failed" title drops the operator's message entirely and its Retry
          // can only fail again. Close the flow (leaving the bloc in its
          // failure state) and let [runTokenBurnFlow] explain it over the
          // calling surface.
          if (_popped) return;
          _popped = true;
          Navigator.of(context).pop();
        }
      },
      builder: (context, state) {
        final phase = switch (state) {
          TxFlowSuccess<TokenBurnPrep, TokenBurnSuccess>() =>
            TransactionPipelinePhase.success,
          // A kill is already dismissing this step (listener above): don't flash
          // "Burn failed" over the operator's actual reason during the pop.
          TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>(:final failure)
              when !failure.isFlowDisabled =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final (label, sublabel) = _labelsFor(state);
        final failure = state is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>
            ? state.failure
            : null;
        // Broadcast, never observed as confirmed before the blockhash expired:
        // indeterminate, not failed. "Burn failed" is a lie the user acts on —
        // the tokens may well be gone — and a retry re-signs a fresh burn of
        // the same amount, so if the original lands too the user burns twice.
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
              : () => context.read<TokenBurnBloc>().add(
                  const TokenBurnResetRequested(),
                ),
          onClose: () => context.read<TokenBurnBloc>().add(
            const TokenBurnResetRequested(),
          ),
        );
      },
    );
  }

  (String, String?) _labelsFor(TokenBurnState state) {
    if (state is TxFlowSuccess<TokenBurnPrep, TokenBurnSuccess>) {
      return ('Token burned', null);
    }
    if (state is TxFlowSigning<TokenBurnPrep, TokenBurnSuccess>) {
      final stage = state.stage;
      if (stage == null) {
        return (kExternalSigningLabel, kExternalSigningSublabel);
      }
      return (signingLabelForStage(stage), signingSublabelForStage(stage));
    }
    if (state is TxFlowBroadcasting<TokenBurnPrep, TokenBurnSuccess>) {
      return (kConfirmingLabel, kConfirmingSublabelSolana);
    }
    return ('Working…', null);
  }
}
