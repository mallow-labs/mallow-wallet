import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../market/services/analytics_failure_reason.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/balance_check.dart';
import '../../../shared/widgets/additional_options_step.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../../shared/widgets/select_artwork_step.dart';
import '../../../shared/widgets/tappable.dart';
import '../../mint/widgets/mint_progress_bar.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../sell/listing_flow_navigation.dart';
import '../services/auction_bloc.dart';
import '../steps/auction_review_step.dart';
import '../steps/pricing_step.dart';
import '../steps/timing_step.dart';

/// Whether [prev] and [next] differ in their [TxFlow] subtype.
///
/// The pipeline listener and shell rebuild gate on this instead of full
/// state equality so an indexer-ack `success → success` re-emit — where
/// [AuctionSuccessData.indexed] flips null→true, leaving the states
/// Equatable-distinct but the same runtimeType — does NOT re-invoke the
/// listener (which would stack a duplicate sheet). Matches
/// `fixed_price_form_screen.dart`.
@visibleForTesting
bool auctionFlowTypeChanged(AuctionState prev, AuctionState next) =>
    prev.flow.runtimeType != next.flow.runtimeType;

/// Host screen for the auction-listing flow.
///
/// Mirrors the shape of `mint_1of1_screen.dart`: a single [BlocProvider]
/// wraps an [IndexedStack] of step screens, with the [MintProgressBar],
/// [MallowHeader], and bottom CTA driven by [AuctionState].
///
/// Once the user taps **List artwork** on the review step the active
/// pipeline (build-tx → approval → broadcast → success/error) is shown
/// inside a non-dismissible bottom sheet driven by [TransactionPipelineSheet]
/// so the underlying review stays visible behind it. On success the
/// sheet shows a **View auction** primary CTA (navigates to the
/// freshly-listed artwork) and a **Done** secondary that pops back to
/// wherever the flow was entered.
class AuctionFormScreen extends StatelessWidget {
  const AuctionFormScreen({this.mintAccount, this.preselected, super.key});

  /// When supplied, the select-artwork step is skipped and the flow lands
  /// on pricing. The artwork itself is fetched by the bloc via DAS so we
  /// only need the mint here.
  final String? mintAccount;

  /// Optional in-memory artwork preview; saves a refetch when entering
  /// from the artwork detail screen.
  final PortfolioArtwork? preselected;

  @override
  Widget build(BuildContext context) {
    // Provides TokenBalanceBloc locally because this screen is pushed as a
    // top-level GoRoute outside the TabNavigator shell, so the bloc the
    // TabNavigator provides isn't in scope here.
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuctionBloc>(
          create: (_) => sl<AuctionBloc>()
            ..add(
              AuctionEvent.started(
                mintAccount: mintAccount,
                artwork: preselected,
              ),
            ),
        ),
        BlocProvider<TokenBalanceBloc>(
          create: (_) =>
              sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
        ),
      ],
      child: const _AuctionFormView(),
    );
  }
}

class _AuctionFormView extends StatefulWidget {
  const _AuctionFormView();

  @override
  State<_AuctionFormView> createState() => _AuctionFormViewState();
}

class _AuctionFormViewState extends State<_AuctionFormView> {
  /// True while the pipeline sheet route is on the navigator. Used to
  /// avoid double-opening when the bloc emits multiple non-idle flow
  /// changes, and to avoid a stray pop when the sheet was already
  /// dismissed (manually via the error close button, for example).
  bool _sheetOpen = false;

  void _onFlowChanged(BuildContext context, AuctionState state) {
    final flow = state.flow;

    // Terminal analytics — creating an auction is a listing. Fires once per
    // flow-type transition (the listener is gated on `flow.runtimeType`
    // changing, so the indexer-ack success→success re-emit is excluded).
    // collection_id isn't resolved in this flow, so it's omitted per taxonomy
    // rather than substituting the item mint.
    if (flow is TxFlowSuccess<void, AuctionSuccessData>) {
      // Guard the price lookup — analytics must not hard-depend on a registered
      // TokenPriceService (it may be absent in tests); null usd_value is fine.
      final priceService = sl.isRegistered<TokenPriceService>()
          ? sl<TokenPriceService>()
          : null;
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.listingCreated,
          txType: TxType.listArtwork,
          signature: flow.signature,
          properties: {
            AnalyticsProp.usdValue: priceService?.usdValueOfRaw(
              state.reservePrice,
              state.bidMint,
            ),
          },
          entryPoint: state.entryFromArtworkDetail
              ? EntryPoint.artworkDetail
              : EntryPoint.marketplace,
        ),
      );
    } else if (flow is TxFlowFailure<void, AuctionSuccessData> &&
        flow.failure.isFlowDisabled) {
      // Kill switch: show the operator's copy over the pipeline sheet
      // instead of `listing_failed` + a bare "Listing failed" — an operator
      // pausing auction creation is not a failed listing and must not be
      // counted as one. The form itself stays mounted with every field
      // intact; closing the pipeline sheet returns the user to the review step.
      //
      // Deferred a frame so the (possibly not-yet-open) pipeline sheet pushed
      // below lands *under* the explanation rather than on top of it.
      final failure = flow.failure;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        handleFlowDisabled(
          this.context,
          failure,
          flow: const FlowKey.solana(AppFlow.auctionCreate),
        );
      });
    } else if (flow is TxFlowFailure<void, AuctionSuccessData>) {
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.listingFailed,
          txType: TxType.listArtwork,
          // No signature: the listing never reached a confirmed broadcast.
          isOnchainTx: false,
          properties: {
            AnalyticsProp.reason: analyticsFailureReason(flow.failure).wire,
          },
          entryPoint: state.entryFromArtworkDetail
              ? EntryPoint.artworkDetail
              : EntryPoint.marketplace,
        ),
      );
    }

    // User dismissed an error → flow back to idle. Pop the sheet so
    // the underlying review step is interactable again.
    if (flow is TxFlowIdle) {
      if (_sheetOpen) Navigator.of(context).pop();
      return;
    }

    if (!_sheetOpen) {
      _sheetOpen = true;
      // Fire-and-forget: the sheet stays up across flow changes (including
      // success, where it presents the View auction / Done CTAs); we tear
      // it down imperatively from this listener on idle, or from those CTAs
      // on success.
      unawaited(
        showTransactionPipelineSheet(
          context: context,
          builder: (sheetContext) => BlocProvider.value(
            value: context.read<AuctionBloc>(),
            child: const _AuctionPipelineSheet(),
          ),
        ).whenComplete(() => _sheetOpen = false),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: BlocConsumer<AuctionBloc, AuctionState>(
          // Gate on the flow subtype, not full equality, so the indexer-ack
          // success re-emit doesn't re-invoke the listener and re-open the
          // sheet. The success sheet still rebuilds on the flip via its own
          // BlocBuilder. See [auctionFlowTypeChanged].
          listenWhen: auctionFlowTypeChanged,
          listener: _onFlowChanged,
          buildWhen: (prev, next) =>
              prev.step != next.step ||
              prev.entryFromArtworkDetail != next.entryFromArtworkDetail ||
              prev.canGoNext != next.canGoNext ||
              prev.progressFraction != next.progressFraction ||
              auctionFlowTypeChanged(prev, next),
          builder: (context, state) {
            final isPipelineActive = state.flow is! TxFlowIdle;
            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MallowHeader(
                    title: 'New Auction',
                    onBack: isPipelineActive
                        ? null
                        : () => _handleBack(context, state),
                    actions: [
                      _CloseAction(
                        onPressed: isPipelineActive
                            ? null
                            : () => _confirmDiscard(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacing20),
                  MintProgressBar(fraction: state.progressFraction),
                  const SizedBox(height: MallowTheme.spacing20),
                  Expanded(
                    child: IndexedStack(
                      index: state.visibleSteps
                          .indexOf(state.step)
                          .clamp(0, state.visibleSteps.length - 1),
                      children: state.visibleSteps
                          .map(_buildStep)
                          .toList(growable: false),
                    ),
                  ),
                  const _BottomCta(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStep(AuctionStep step) {
    return switch (step) {
      AuctionStep.selectArtwork => const _SelectArtworkStepHost(),
      AuctionStep.pricing => const PricingStep(),
      AuctionStep.timing => const TimingStep(),
      AuctionStep.additionalOptions => const _AdditionalOptionsStepHost(),
      AuctionStep.review => const AuctionReviewStep(),
    };
  }

  void _handleBack(BuildContext context, AuctionState state) {
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx > 0) {
      context.read<AuctionBloc>().add(const AuctionEvent.back());
    } else {
      context.pop();
    }
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final shouldDiscard = await showConfirmSheet(
      context,
      title: 'Discard this listing?',
      message: 'Your progress will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (shouldDiscard == true && context.mounted) {
      context.pop();
    }
  }
}

class _CloseAction extends StatelessWidget {
  const _CloseAction({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final disabled = onPressed == null;
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: MallowSvgIcon(
            'assets/icons/x.svg',
            width: 20,
            height: 20,
            color: disabled
                ? colors.textPrimary.withValues(alpha: 0.3)
                : colors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Bridges [AuctionState.flow] into the shared [TransactionPipelineSheet] body.
class _AuctionPipelineSheet extends StatelessWidget {
  const _AuctionPipelineSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) => prev.flow != next.flow,
      builder: (context, state) {
        final flow = state.flow;
        final phase = switch (flow) {
          TxFlowSuccess() => TransactionPipelinePhase.success,
          TxFlowFailure() => TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final label = switch (flow) {
          TxFlowSuccess() => 'Auction live',
          TxFlowSigning(:final stage) => signingLabelForStage(stage),
          TxFlowBroadcasting() => 'Listing artwork…',
          _ => 'Working…',
        };
        final sublabel = switch (flow) {
          TxFlowSuccess() => 'Your auction is now live.',
          TxFlowSigning(:final stage) => signingSublabelForStage(stage),
          TxFlowBroadcasting() => kConfirmingSublabelSolana,
          _ => kPreparingSublabel,
        };
        final failure = flow is TxFlowFailure<void, AuctionSuccessData>
            ? flow.failure
            : null;
        // Broadcast, never observed as confirmed before the blockhash expired:
        // indeterminate, not failed. `requestList` builds and signs a *fresh*
        // listing transaction, so retrying an unconfirmed listing can put the
        // same artwork on the block twice. Mirrors `SendPipelineView`.
        final unconfirmed = failure?.isUnconfirmed ?? false;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          successAction: flow is TxFlowSuccess
              ? TransactionSuccessAction(
                  primaryLabel: 'View auction',
                  onPrimary: () => viewListedArtwork(
                    context,
                    entryFromArtworkDetail: state.entryFromArtworkDetail,
                    mint: state.selectedArtwork?.mintAccount,
                  ),
                  secondaryLabel: 'Done',
                  onSecondary: () => dismissListingFlowToOrigin(
                    context,
                    entryFromArtworkDetail: state.entryFromArtworkDetail,
                  ),
                )
              : null,
          errorTitle: unconfirmed ? 'Not confirmed yet' : 'Listing failed',
          // The failure message — `sublabel` isn't rendered in the error body,
          // so without this the reason was dropped entirely.
          errorSublabel: failure?.message,
          onRetry: unconfirmed
              ? null
              : () {
                  // `requestList` clears the error and emits `TxFlowPreparing`
                  // in one step. Going through `dismissError` first would
                  // transition through idle, which the form's listener treats
                  // as a signal to pop the sheet — closing the very sheet
                  // we're retrying from.
                  context.read<AuctionBloc>().add(
                    const AuctionEvent.requestList(),
                  );
                },
          onClose: () {
            context.read<AuctionBloc>().add(const AuctionEvent.dismissError());
          },
        );
      },
    );
  }
}

class _BottomCta extends StatelessWidget {
  const _BottomCta();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) =>
          prev.step != next.step ||
          prev.canGoNext != next.canGoNext ||
          prev.flow.runtimeType != next.flow.runtimeType,
      builder: (context, state) {
        final isPipelineActive = state.flow is! TxFlowIdle;
        final isReview = state.step == AuctionStep.review;
        final fallbackLabel = isReview ? 'List artwork' : 'Next';
        return Padding(
          padding: EdgeInsets.only(
            top: MallowTheme.spacingMd,
            bottom:
                MediaQuery.of(context).padding.bottom + MallowTheme.spacingMd,
          ),
          child: BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
            builder: (context, balanceState) {
              final result = isReview
                  ? checkBalance(
                      paymentMint: null,
                      requiredRawAmount: 0,
                      balanceState: balanceState,
                    )
                  : const BalanceCheckResult.sufficient();
              return _PillCta(
                label: fallbackLabel,
                enabled: state.canGoNext && !isPipelineActive,
                onPressed: () {
                  if (isReview) {
                    if (!ensureSufficientBalance(context, result)) return;
                    context.read<AuctionBloc>().add(
                      const AuctionEvent.requestList(),
                    );
                  } else {
                    context.read<AuctionBloc>().add(const AuctionEvent.next());
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _PillCta extends StatelessWidget {
  const _PillCta({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: enabled ? colors.accent : colors.textTertiary,
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        child: Tappable(
          onTap: enabled ? onPressed : null,
          child: Center(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: colors.textOnAccent,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wires the shared [SelectArtworkStep] up to [AuctionBloc]. Selecting an
/// artwork dispatches `selectArtwork` then `next` to advance the flow.
class _SelectArtworkStepHost extends StatelessWidget {
  const _SelectArtworkStepHost();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) =>
          prev.selectedArtwork?.mintAccount !=
          next.selectedArtwork?.mintAccount,
      builder: (context, state) {
        final bloc = context.read<AuctionBloc>();
        return SelectArtworkStep(
          selectedMint: state.selectedArtwork?.mintAccount,
          nonPrintableOnly: true,
          onSelected: (artwork) {
            bloc.add(AuctionEvent.selectArtwork(artwork));
            bloc.add(const AuctionEvent.next());
          },
        );
      },
    );
  }
}

/// Wires the shared [AdditionalOptionsStep] up to [AuctionBloc].
class _AdditionalOptionsStepHost extends StatelessWidget {
  const _AdditionalOptionsStepHost();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuctionBloc, AuctionState>(
      buildWhen: (prev, next) =>
          prev.showVerifiedSellerOptions != next.showVerifiedSellerOptions ||
          prev.includePhysical != next.includePhysical ||
          prev.physical != next.physical ||
          prev.includeRewards != next.includeRewards ||
          prev.rewardsDescription != next.rewardsDescription ||
          prev.askForShippingAddress != next.askForShippingAddress,
      builder: (context, state) {
        final bloc = context.read<AuctionBloc>();
        return AdditionalOptionsStep(
          showVerifiedSellerOptions: state.showVerifiedSellerOptions,
          includePhysical: state.includePhysical,
          physical: state.physical,
          includeRewards: state.includeRewards,
          rewardsDescription: state.rewardsDescription,
          askForShippingAddress: state.askForShippingAddress,
          showPhysicalUnlockPrice: true,
          onIncludePhysicalChanged: (v) =>
              bloc.add(AuctionEvent.setIncludePhysical(v)),
          onPhysicalChanged: (v) => bloc.add(AuctionEvent.setPhysical(v)),
          onIncludeRewardsChanged: (v) =>
              bloc.add(AuctionEvent.setIncludeRewards(v)),
          onRewardsDescriptionChanged: (v) =>
              bloc.add(AuctionEvent.setRewardsDescription(v)),
          onAskForShippingAddressChanged: (v) =>
              bloc.add(AuctionEvent.setAskForShippingAddress(v)),
        );
      },
    );
  }
}
