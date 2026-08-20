import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/signing_copy.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/generic_confirmation_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/fee_details_disclosure.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../../shared/widgets/tx_cost_summary.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/data/user_profile_repository.dart';
import '../../profile/screens/collection_screen.dart';
import '../services/mint_bloc.dart';

/// Drives the full mint pipeline UI from cost review through success/error.
///
/// Both phases live in a **single** modal route ([_MintFlowSheet]) so
/// confirming morphs the review step into the pipeline step in place
/// (cross-fade + resize) instead of popping the review sheet and presenting a
/// separate pipeline route:
/// 1. **Cost review** — [_MintCostReviewSheet] shows the breakdown +
///    Confirm/Cancel.
/// 2. **Pipeline** — on Confirm the mint event is dispatched and the step
///    swaps to [_MintPipelineSheet], staying mounted across `uploading →
///    buildingTx → awaitingApproval → broadcasting → finalizing →
///    success/error`.
Future<void> showMintConfirmationSheet(BuildContext context) async {
  final bloc = context.read<MintBloc>();
  final isEdit = bloc.state.isEdit;
  await showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: _MintFlowSheet(isEdit: isEdit),
    ),
  );
  // A kill caught by the signing backstop closed the flow without an error body
  // ([_MintPipelineSheet] pops instead of showing its generic "Mint failed",
  // whose Retry could only fail again). Explain it here, over the mint form —
  // which stays open with every step's input intact — then clear the pipeline
  // so a later attempt starts from idle.
  final failure = bloc.state.pipelineFailure;
  if (failure == null || !context.mounted) return;
  if (handleFlowDisabled(
    context,
    failure,
    flow: FlowKey.solana(bloc.flowCell),
  )) {
    bloc.add(const MintEvent.dismissError());
  }
}

/// Single-route host for the mint flow: the review step morphs into the
/// pipeline step in place once the user confirms. Dismissal during the
/// in-flight pipeline is blocked by [TransactionPipelineSheet]'s own
/// `PopScope`; the review step stays freely dismissible (barrier tap / drag /
/// back = cancel).
class _MintFlowSheet extends StatefulWidget {
  const _MintFlowSheet({required this.isEdit});

  final bool isEdit;

  @override
  State<_MintFlowSheet> createState() => _MintFlowSheetState();
}

class _MintFlowSheetState extends State<_MintFlowSheet> {
  bool _confirmed = false;

  void _onConfirm() {
    if (_confirmed) return;
    // Swap to the pipeline step immediately and kick off the mint. The
    // pipeline body renders `progress` for the brief idle frame before the
    // bloc moves to `uploading`, so there's no flash back to the review step.
    setState(() => _confirmed = true);
    context.read<MintBloc>().add(const MintEvent.confirmMint());
  }

  @override
  Widget build(BuildContext context) {
    return SheetStepSwitcher(
      child: _confirmed
          ? const _MintPipelineSheet(key: ValueKey('pipeline'))
          : KeyedSubtree(
              key: const ValueKey('review'),
              child: _MintCostReviewSheet(
                isEdit: widget.isEdit,
                onConfirm: _onConfirm,
                onCancel: () => Navigator.of(context).pop(),
              ),
            ),
    );
  }
}

class _MintCostReviewSheet extends StatelessWidget {
  const _MintCostReviewSheet({
    required this.isEdit,
    required this.onConfirm,
    required this.onCancel,
  });

  final bool isEdit;

  /// Advances the flow to the pipeline step (no route change).
  final VoidCallback onConfirm;

  /// Dismisses the whole flow.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.costBreakdown != next.costBreakdown ||
          prev.simulatedTxCostLamports != next.simulatedTxCostLamports ||
          prev.isSimulatingTxCost != next.isSimulatingTxCost,
      builder: (context, state) {
        final breakdown = state.costBreakdown;
        // Both flows collapse the Metaplex fee, account-rent, and
        // tx-fee rows into one "Solana and protocol fees" line whose
        // value is the simulated SOL delta minus the mallow fee. The
        // static breakdown sum is the fallback while the simulation
        // is in flight or after it fails.
        final mallowLamports = breakdown.mallowFeeLamports;
        final staticOtherLamports =
            breakdown.protocolFeeLamports +
            breakdown.rentLamports +
            breakdown.txFeeLamports;
        final simulatedTotal = state.simulatedTxCostLamports;
        final simulatedOther = simulatedTotal == null
            ? null
            : (simulatedTotal - mallowLamports)
                  .clamp(0, simulatedTotal)
                  .toInt();
        final showLoader = state.isSimulatingTxCost && simulatedTotal == null;
        final otherLamports = simulatedOther ?? staticOtherLamports;
        final totalLamports = mallowLamports + otherLamports;
        return GenericConfirmationSheet(
          title: isEdit ? 'Confirm edit' : 'Confirm mint',
          confirmLabel: 'Confirm',
          onConfirm: onConfirm,
          onCancel: onCancel,
          showHandle: false,
          backgroundColor: colors.bgSurface,
          topRadius: MallowTheme.popupRadius,
          gapBeforeButtons: MallowTheme.spacing20,
          // Same cost design as Confirm Purchase: the aggregate total stays
          // visible while the per-line breakdown collapses into the shared
          // "Fee details" disclosure.
          body: [
            TxCostSummary(
              card: false,
              lines: [
                if (showLoader)
                  TxCostLine.shimmer(label: 'Total cost')
                else
                  TxCostLine.lamports(
                    label: 'Total cost',
                    lamports: totalLamports,
                    sign: '-',
                    valueColor: colors.error,
                  ),
              ],
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            FeeDetailsDisclosure(
              child: TxCostSummary(
                card: false,
                lineStyle: MallowTheme.uiCaption,
                lines: [
                  TxCostLine.lamports(
                    label: 'mallow fee',
                    lamports: mallowLamports,
                  ),
                  if (showLoader)
                    TxCostLine.shimmer(label: 'Solana and protocol fees')
                  else
                    TxCostLine.lamports(
                      label: 'Solana and protocol fees',
                      lamports: otherLamports,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The pipeline step of [_MintFlowSheet]: renders the in-flight / success /
/// error body from the bloc's pipeline state. Reuses the shared
/// [TransactionPipelineSheet] chrome (same `bgSurface` + radius as the review
/// step, so the morph is seamless).
class _MintPipelineSheet extends StatelessWidget {
  const _MintPipelineSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MintBloc, MintState>(
      listenWhen: (prev, next) => prev.pipelineStatus != next.pipelineStatus,
      listener: (context, state) {
        // A kill is not a failed mint: the error body's hardcoded "Mint failed"
        // drops the operator's message and its Retry can only fail again. Close
        // the flow (leaving the failure on the bloc) and let
        // [showMintConfirmationSheet] explain it over the mint form.
        // Returns before the analytics below so the kill never lands as
        // `mint_failed` — `flow_disabled_hit` is its event.
        if (state.pipelineStatus == MintPipelineStatus.error &&
            (state.pipelineFailure?.isFlowDisabled ?? false)) {
          Navigator.of(context).pop();
          return;
        }

        // Terminal mint analytics — this listener fires once per pipeline-status
        // change, so each fires exactly once. Edits reuse this pipeline but are
        // not mints, so they're excluded. The failure kind isn't mapped to a
        // `FailureReason` here → unknown.
        if (!state.isEdit) {
          if (state.pipelineStatus == MintPipelineStatus.success) {
            unawaited(
              sl<AnalyticsService>().trackTransaction(
                AnalyticsEvent.mintCompleted,
                txType: TxType.mint,
                signature: state.mintSignature,
                properties: {
                  AnalyticsProp.collectionId: state.collection?.mintAccount,
                  AnalyticsProp.usdValue: null,
                },
                entryPoint: EntryPoint.marketplace,
              ),
            );
          } else if (state.pipelineStatus == MintPipelineStatus.error) {
            unawaited(
              sl<AnalyticsService>().trackTransaction(
                AnalyticsEvent.mintFailed,
                txType: TxType.mint,
                // A mint that confirmed on-chain and then failed to finalize is
                // reported as success, so a failure here has no signature.
                isOnchainTx: false,
                properties: {
                  AnalyticsProp.collectionId: state.collection?.mintAccount,
                  AnalyticsProp.reason: FailureReason.unknown.wire,
                },
                entryPoint: EntryPoint.marketplace,
              ),
            );
          }
        }

        // Close the whole flow when the bloc returns to idle (after
        // dismissError) — there's no separate review route to fall back to,
        // so the user lands on the mint form.
        if (state.pipelineStatus == MintPipelineStatus.idle) {
          Navigator.of(context).pop();
        }
      },
      buildWhen: (prev, next) =>
          prev.pipelineStatus != next.pipelineStatus ||
          prev.pipelineStage != next.pipelineStage ||
          prev.pipelineError != next.pipelineError ||
          prev.pipelineFailure != next.pipelineFailure ||
          prev.mintAccount != next.mintAccount ||
          prev.mintType != next.mintType ||
          prev.name != next.name,
      builder: (context, state) {
        final phase = switch (state.pipelineStatus) {
          MintPipelineStatus.success => TransactionPipelinePhase.success,
          // A kill is already dismissing this sheet (listener above): don't
          // flash "Mint failed" over the operator's actual reason.
          MintPipelineStatus.error
              when !(state.pipelineFailure?.isFlowDisabled ?? false) =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        // Broadcast but never observed as confirmed before the blockhash
        // expired: indeterminate, not failed. `retryMint` re-runs the whole
        // pipeline against a freshly-built transaction, so if the original
        // lands the creator pays the mint twice and ends up with two NFTs —
        // the retry affordance has to go. Mirrors `SendPipelineView`.
        final unconfirmed = state.pipelineFailure?.isUnconfirmed ?? false;
        final isCollection = state.mintType == MintCreateType.collection;
        final isEdit = state.isEdit;
        final fallbackName = isCollection ? 'Your collection' : 'Your artwork';
        final name = state.name.trim().isEmpty ? fallbackName : state.name;
        final successLabel = isEdit
            ? '’$name’ updated successfully'
            : '’$name’ minted successfully';
        final successSublabel = isEdit
            ? null
            : (isCollection
                  ? 'Congratulations on starting a new collection!'
                  : 'Congratulations on a new masterpiece!');
        final sublabel = phase == TransactionPipelinePhase.success
            ? successSublabel
            : _sublabelFor(state.pipelineStatus, state.pipelineStage);
        return TransactionPipelineSheet(
          phase: phase,
          label: phase == TransactionPipelinePhase.success
              ? successLabel
              : state.pipelineStatus == MintPipelineStatus.awaitingApproval
              ? signingLabelForStage(state.pipelineStage)
              : (state.pipelineStage ?? _fallbackLabel(state.pipelineStatus)),
          sublabel: sublabel,
          // Finalizing keeps its own (longer, indexer-specific) reassurance
          // sequence; null on every other step lets the sheet derive the
          // shared one, which only fires on the Solana confirming subtitle.
          sublabelCycle: state.pipelineStatus == MintPipelineStatus.finalizing
              ? _kFinalizingReassurance
              : null,
          errorTitle: unconfirmed
              ? 'Not confirmed yet'
              : (isEdit ? 'Update failed' : 'Mint failed'),
          // The failure message — `sublabel` isn't rendered in the error body,
          // so without this the reason was dropped entirely.
          errorSublabel: phase == TransactionPipelinePhase.error
              ? state.pipelineError
              : null,
          successAction: phase == TransactionPipelinePhase.success
              // A freshly-minted collection leads with "Add artworks" so the
              // creator can populate it straight away; "View collection" moves
              // to the secondary slot. Every other success keeps the plain
              // view/done pair.
              ? (isCollection && !isEdit
                    ? TransactionSuccessAction(
                        primaryLabel: 'Add artworks',
                        onPrimary: () =>
                            _openAddArtworks(context, state, name: name),
                        secondaryLabel: 'View collection',
                        onSecondary: () => _openSuccess(
                          context,
                          state,
                          isCollection: isCollection,
                        ),
                      )
                    : TransactionSuccessAction(
                        primaryLabel: isCollection
                            ? 'View collection'
                            : 'View artwork',
                        onPrimary: () => _openSuccess(
                          context,
                          state,
                          isCollection: isCollection,
                        ),
                        secondaryLabel: 'Done',
                        onSecondary: () {
                          Navigator.of(context).pop();
                          context.pop();
                        },
                      ))
              : null,
          onRetry: unconfirmed
              ? null
              : () => context.read<MintBloc>().add(const MintEvent.retryMint()),
          onClose: () =>
              context.read<MintBloc>().add(const MintEvent.dismissError()),
        );
      },
    );
  }
}

void _openSuccess(
  BuildContext context,
  MintState state, {
  required bool isCollection,
}) {
  final mint = state.mintAccount;
  if (isCollection) {
    _openCollection(context, mint);
  } else {
    Navigator.of(context).pop();
    context.pop();
    if (mint != null && mint.isNotEmpty) {
      context.goToArtwork(mint);
    }
  }
}

/// Cycled under "Finalizing…" every 10 s. That step waits on the indexer
/// (`checkTx`, then `checkEntry` — ~22 s of polling before either gives up,
/// capped at [mintIndexedAckTimeout]) *and* the backend finalize call (capped
/// at [mintFinalizeWaitTimeout]), so a backed-up indexer can hold this screen
/// for a minute-plus with nothing on screen moving. The transaction is already
/// confirmed on-chain by the time this status is entered — hence copy that
/// reassures rather than warns.
const _kFinalizingReassurance = <String>[
  'Still working on it…',
  'Just a moment more…',
  'Your transaction is confirmed — finishing up',
  'Nearly there, thanks for your patience',
];

String _fallbackLabel(MintPipelineStatus status) {
  return switch (status) {
    MintPipelineStatus.uploading => 'Uploading media…',
    MintPipelineStatus.buildingTx => kPreparingLabel,
    MintPipelineStatus.awaitingApproval => kExternalSigningLabel,
    MintPipelineStatus.broadcasting => kConfirmingLabel,
    MintPipelineStatus.finalizing => 'Finalizing…',
    _ => 'Working…',
  };
}

String? _sublabelFor(MintPipelineStatus status, String? stage) {
  return switch (status) {
    // Local signers don't have an external wallet to tap — the bloc
    // surfaces this by setting the stage to the local signing label
    // (vs the external approval label for Ledger / social wallets), so the
    // subtitle reassures rather than instructing them to approve in a wallet.
    MintPipelineStatus.awaitingApproval => signingSublabelForStage(stage),
    MintPipelineStatus.broadcasting => kConfirmingSublabelSolana,
    _ => kPreparingSublabel,
  };
}

/// Pops the pipeline sheet and the mint flow, then opens the add-artworks
/// screen for the freshly-minted collection so the creator can populate it.
void _openAddArtworks(
  BuildContext context,
  MintState state, {
  required String name,
}) {
  final mint = state.mintAccount;
  // Capture the router before the pops invalidate this context.
  final router = GoRouter.of(context);

  Navigator.of(context).pop();
  context.pop();

  if (mint == null || mint.isEmpty) return;
  unawaited(
    router.push(
      '${AppRoutes.collectionArtworksPath(mint)}'
      '?name=${Uri.encodeQueryComponent(name)}',
    ),
  );
}

/// Pops the pipeline sheet and the mint flow, fetches the current user's
/// profile, and pushes [CollectionScreen] for the freshly-minted collection.
/// Mirrors the navigation used from the user profile screen so the collection
/// renders with the same widget regardless of entry point.
Future<void> _openCollection(BuildContext context, String? mint) async {
  final rootNavigator = Navigator.of(context, rootNavigator: true);
  final mintState = context.read<MintBloc>().state;
  final address = sl<AuthService>().currentAddress;

  Navigator.of(context).pop();
  context.pop();

  if (mint == null || mint.isEmpty || address == null || address.isEmpty) {
    return;
  }

  try {
    final profile = await sl<UserProfileRepository>().getUserProfile(address);
    if (!rootNavigator.mounted) return;
    final group = ArtGroup(
      id: mint,
      type: ArtGroupType.collection,
      name: mintState.name,
      thumbnailUrl: mintState.banner?.ipfsUrl,
      artworkCount: 0,
      collectionMint: mint,
    );
    unawaited(
      rootNavigator.push(
        MaterialPageRoute<void>(
          builder: (_) => CollectionScreen(group: group, profile: profile),
        ),
      ),
    );
  } catch (_) {
    // Best-effort: silently fail and leave the user on whatever screen
    // they returned to after the pops.
  }
}
