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
import '../services/fixed_price_bloc.dart';
import '../steps/pricing_step.dart';
import '../steps/review_step.dart';

/// Host screen for the fixed-price listing flow. Mirrors
/// [AuctionFormScreen] in shape — a [BlocProvider] wrapping an
/// [IndexedStack] of step screens with the [MintProgressBar],
/// [MallowHeader], and bottom CTA driven by [FixedPriceState].
///
/// Once the user taps **List Artwork** on the review step the active
/// pipeline (build-tx → approval → broadcast → success/error) is shown
/// inside a non-dismissible bottom sheet driven by [TransactionPipelineSheet]
/// so the underlying review stays visible behind it. On success the
/// sheet shows a **View listing** primary CTA (navigates to the
/// freshly-listed artwork) and a **Done** secondary that pops back to
/// wherever the flow was entered.
class FixedPriceFormScreen extends StatelessWidget {
  const FixedPriceFormScreen({this.mintAccount, this.preselected, super.key});

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
        BlocProvider<FixedPriceBloc>(
          create: (_) => sl<FixedPriceBloc>()
            ..add(
              FixedPriceEvent.started(
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
      child: const _FixedPriceFormView(),
    );
  }
}

class _FixedPriceFormView extends StatefulWidget {
  const _FixedPriceFormView();

  @override
  State<_FixedPriceFormView> createState() => _FixedPriceFormViewState();
}

class _FixedPriceFormViewState extends State<_FixedPriceFormView> {
  /// True while the pipeline sheet route is on the navigator. Used to
  /// avoid double-opening when the bloc emits multiple non-idle status
  /// changes, and to avoid a stray pop when the sheet was already
  /// dismissed (manually via the error close button, for example).
  bool _sheetOpen = false;

  void _onFlowChanged(BuildContext context, FixedPriceState state) {
    final flow = state.flow;

    // Terminal analytics — fires once per flow-type transition (the listener
    // is gated on `flow.runtimeType` changing, so the indexer-ack
    // success→success re-emit is excluded). collection_id isn't resolved in
    // this flow (only the mint + update authority are), so it's omitted per
    // taxonomy rather than substituting the item mint.
    if (flow is TxFlowSuccess<void, FixedPriceSuccessData>) {
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.listingCreated,
          txType: TxType.listArtwork,
          signature: flow.signature,
          properties: {
            AnalyticsProp.usdValue: sl<TokenPriceService>().usdValueOfRaw(
              state.price,
              state.currencyMint,
            ),
          },
          entryPoint: state.entryFromArtworkDetail
              ? EntryPoint.artworkDetail
              : EntryPoint.marketplace,
        ),
      );
    } else if (flow is TxFlowFailure<void, FixedPriceSuccessData> &&
        flow.failure.isFlowDisabled) {
      // Kill switch: show the operator's copy over the pipeline sheet
      // instead of `listing_failed` + a bare "Listing failed" — an operator
      // pausing listing creation is not a failed listing and must not be
      // counted as one. The form stays mounted with every field intact;
      // closing the pipeline sheet returns the user to the review step.
      //
      // Deferred a frame so the (possibly not-yet-open) pipeline sheet pushed
      // below lands *under* the explanation rather than on top of it.
      final failure = flow.failure;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        handleFlowDisabled(
          this.context,
          failure,
          flow: const FlowKey.solana(AppFlow.fixedPriceCreate),
        );
      });
    } else if (flow is TxFlowFailure<void, FixedPriceSuccessData>) {
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.listingFailed,
          txType: TxType.listArtwork,
          // No signature: the listing never reached a confirmed broadcast.
          isOnchainTx: false,
          properties: {
            AnalyticsProp.usdValue: sl<TokenPriceService>().usdValueOfRaw(
              state.price,
              state.currencyMint,
            ),
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
      // success, where it presents the View listing / Done CTAs); we tear
      // it down imperatively from this listener on idle, or from those CTAs
      // on success.
      unawaited(
        showTransactionPipelineSheet(
          context: context,
          builder: (sheetContext) => BlocProvider.value(
            value: context.read<FixedPriceBloc>(),
            child: const _FixedPricePipelineSheet(),
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
        child: BlocConsumer<FixedPriceBloc, FixedPriceState>(
          listenWhen: (prev, next) =>
              prev.flow.runtimeType != next.flow.runtimeType,
          listener: _onFlowChanged,
          buildWhen: (prev, next) =>
              prev.step != next.step ||
              prev.entryFromArtworkDetail != next.entryFromArtworkDetail ||
              prev.canGoNext != next.canGoNext ||
              prev.progressFraction != next.progressFraction ||
              prev.flow.runtimeType != next.flow.runtimeType,
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
                    title: 'New Fixed Price Sale',
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

  Widget _buildStep(FixedPriceStep step) {
    return switch (step) {
      FixedPriceStep.selectArtwork => const _SelectArtworkStepHost(),
      FixedPriceStep.pricing => const PricingStep(),
      FixedPriceStep.additionalOptions => const _AdditionalOptionsStepHost(),
      FixedPriceStep.review => const ReviewStep(),
    };
  }

  void _handleBack(BuildContext context, FixedPriceState state) {
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx > 0) {
      context.read<FixedPriceBloc>().add(const FixedPriceEvent.back());
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

/// Bridges [FixedPriceState] into the shared [TransactionPipelineSheet] body.
class _FixedPricePipelineSheet extends StatelessWidget {
  const _FixedPricePipelineSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      buildWhen: (prev, next) => prev.flow != next.flow,
      builder: (context, state) {
        final flow = state.flow;
        final phase = switch (flow) {
          TxFlowSuccess() => TransactionPipelinePhase.success,
          TxFlowFailure() => TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final failure = flow is TxFlowFailure<void, FixedPriceSuccessData>
            ? flow.failure
            : null;
        // Broadcast but never observed as confirmed before the blockhash
        // expired: indeterminate, not failed. `requestList` rebuilds and
        // re-signs a fresh listing transaction, so a blind retry against a
        // transaction that may still land is exactly what the confirmation
        // contract forbids. Mirrors `SendPipelineView`.
        final unconfirmed = failure?.isUnconfirmed ?? false;
        final sublabel = switch (flow) {
          TxFlowSuccess() => 'Your artwork is now listed for sale.',
          TxFlowSigning(:final stage) => signingSublabelForStage(stage),
          TxFlowBroadcasting() => kConfirmingSublabelSolana,
          _ => kPreparingSublabel,
        };
        return TransactionPipelineSheet(
          phase: phase,
          label: switch (flow) {
            TxFlowSuccess() => 'Listed for sale',
            TxFlowSigning(:final stage) => signingLabelForStage(stage),
            TxFlowBroadcasting(:final label) => label ?? 'Listing artwork…',
            _ => 'Working…',
          },
          sublabel: sublabel,
          successAction: flow is TxFlowSuccess
              ? TransactionSuccessAction(
                  primaryLabel: 'View listing',
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
                  // transition through `TxFlowIdle`, which the form's listener
                  // treats as a signal to pop the sheet — closing the very
                  // sheet we're retrying from.
                  context.read<FixedPriceBloc>().add(
                    const FixedPriceEvent.requestList(),
                  );
                },
          onClose: () {
            context.read<FixedPriceBloc>().add(
              const FixedPriceEvent.dismissError(),
            );
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
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      buildWhen: (prev, next) =>
          prev.step != next.step ||
          prev.canGoNext != next.canGoNext ||
          (prev.flow is TxFlowIdle) != (next.flow is TxFlowIdle),
      builder: (context, state) {
        final isPipelineActive = state.flow is! TxFlowIdle;
        final isReview = state.step == FixedPriceStep.review;
        final fallbackLabel = isReview ? 'List Artwork' : 'Next';
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
                    context.read<FixedPriceBloc>().add(
                      const FixedPriceEvent.requestList(),
                    );
                  } else {
                    context.read<FixedPriceBloc>().add(
                      const FixedPriceEvent.next(),
                    );
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

/// Wires the shared [SelectArtworkStep] up to [FixedPriceBloc]. Selecting
/// an artwork dispatches `selectArtwork` then `next` to advance the flow.
class _SelectArtworkStepHost extends StatelessWidget {
  const _SelectArtworkStepHost();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      buildWhen: (prev, next) =>
          prev.selectedArtwork?.mintAccount !=
          next.selectedArtwork?.mintAccount,
      builder: (context, state) {
        final bloc = context.read<FixedPriceBloc>();
        return SelectArtworkStep(
          selectedMint: state.selectedArtwork?.mintAccount,
          nonPrintableOnly: false,
          onSelected: (artwork) {
            bloc.add(FixedPriceEvent.selectArtwork(artwork));
            bloc.add(const FixedPriceEvent.next());
          },
        );
      },
    );
  }
}

/// Wires the shared [AdditionalOptionsStep] up to [FixedPriceBloc].
class _AdditionalOptionsStepHost extends StatelessWidget {
  const _AdditionalOptionsStepHost();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FixedPriceBloc, FixedPriceState>(
      buildWhen: (prev, next) =>
          prev.showVerifiedSellerOptions != next.showVerifiedSellerOptions ||
          prev.includePhysical != next.includePhysical ||
          prev.physical != next.physical ||
          prev.includeRewards != next.includeRewards ||
          prev.rewardsDescription != next.rewardsDescription ||
          prev.askForShippingAddress != next.askForShippingAddress,
      builder: (context, state) {
        final bloc = context.read<FixedPriceBloc>();
        return AdditionalOptionsStep(
          showVerifiedSellerOptions: state.showVerifiedSellerOptions,
          includePhysical: state.includePhysical,
          physical: state.physical,
          includeRewards: state.includeRewards,
          rewardsDescription: state.rewardsDescription,
          askForShippingAddress: state.askForShippingAddress,
          showPhysicalUnlockPrice: false,
          onIncludePhysicalChanged: (v) =>
              bloc.add(FixedPriceEvent.setIncludePhysical(v)),
          onPhysicalChanged: (v) => bloc.add(FixedPriceEvent.setPhysical(v)),
          onIncludeRewardsChanged: (v) =>
              bloc.add(FixedPriceEvent.setIncludeRewards(v)),
          onRewardsDescriptionChanged: (v) =>
              bloc.add(FixedPriceEvent.setRewardsDescription(v)),
          onAskForShippingAddressChanged: (v) =>
              bloc.add(FixedPriceEvent.setAskForShippingAddress(v)),
        );
      },
    );
  }
}
