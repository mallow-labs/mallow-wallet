import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/balance_check.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/mint_bloc.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../sheets/mint_confirmation_sheet.dart';
import '../steps/categorization_step.dart';
import '../steps/details_step.dart';
import '../steps/edition_supply_step.dart';
import '../steps/review_step.dart';
import '../steps/royalties_step.dart';
import '../steps/upload_step.dart';
import '../widgets/mint_progress_bar.dart';
import '../widgets/mint_source_wallet_line.dart';

/// Host screen for the mint flow (1/1 artwork or editions).
///
/// Hosts an [IndexedStack] driven by [MintBloc.state.step]. The back
/// button navigates within the flow until step 0, where it pops the
/// route. The close `X` always prompts a confirm dialog before exiting.
/// The [mintType] toggles header copy and reveals the edition-supply
/// step between Royalties and Review.
class Mint1Of1Screen extends StatelessWidget {
  const Mint1Of1Screen({super.key, this.mintType = MintCreateType.oneOfOne});

  final MintCreateType mintType;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<MintBloc>(
          create: (_) => sl<MintBloc>()
            ..add(MintEvent.setMintType(mintType))
            ..add(const MintEvent.started()),
        ),
        BlocProvider<TokenBalanceBloc>(
          create: (_) =>
              sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
        ),
      ],
      child: const _Mint1Of1View(),
    );
  }
}

class _Mint1Of1View extends StatelessWidget {
  const _Mint1Of1View();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: BlocBuilder<MintBloc, MintState>(
          buildWhen: (prev, next) =>
              prev.step != next.step ||
              prev.mintType != next.mintType ||
              prev.pipelineStatus != next.pipelineStatus,
          builder: (context, state) {
            final title = switch (state.mintType) {
              MintCreateType.editions => 'New editions',
              MintCreateType.collection => 'New collection',
              _ => 'New 1/1 artwork',
            };
            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MallowHeader(
                    title: title,
                    onBack: () => _handleBack(context, state),
                    actions: [
                      _CloseAction(onPressed: () => _confirmDiscard(context)),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacing20),
                  MintProgressBar(fraction: state.progressFraction),
                  const SizedBox(height: MallowTheme.spacing20),
                  Expanded(
                    child: IndexedStack(
                      index: state.step.index,
                      children: const [
                        UploadStep(),
                        DetailsStep(),
                        CategorizationStep(),
                        RoyaltiesStep(),
                        EditionSupplyStep(),
                        ReviewStep(),
                      ],
                    ),
                  ),
                  // TODO(phase 6): overlay gradient fade-mask behind the CTA
                  // to match the existing send/swap flow treatment.
                  const _MintFooter(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleBack(BuildContext context, MintState state) {
    if (state.step.index > 0) {
      context.read<MintBloc>().add(const MintEvent.back());
    } else {
      context.pop();
    }
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final shouldDiscard = await showConfirmSheet(
      context,
      title: 'Discard this mint?',
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

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
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
            color: colors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Source-wallet line (review step only) stacked above the flow's CTA.
///
/// The line lives here rather than inside [ReviewStep] so the switch can
/// disable the mint button: the picker commits a durable signer change and the
/// creator/fee re-derivation lands after it, so confirming mid-switch would
/// mint under a creator the review screen hasn't caught up to yet.
class _MintFooter extends StatefulWidget {
  const _MintFooter();

  @override
  State<_MintFooter> createState() => _MintFooterState();
}

class _MintFooterState extends State<_MintFooter> {
  bool _switching = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.step != next.step ||
          prev.userPubkey != next.userPubkey ||
          prev.isEdit != next.isEdit,
      builder: (context, state) {
        // Create-only. An edit's authority is the asset's existing update
        // authority, and `MintBloc._onSourceWalletChanged` discards the event
        // in edit mode — so offering Switch here would durably re-point the
        // user's app-wide signer to a wallet that is not the update authority,
        // for no effect on the form.
        final showSource =
            state.step == MintStep.review &&
            state.userPubkey.isNotEmpty &&
            !state.isEdit;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showSource)
              MintSourceWalletLine(
                address: state.userPubkey,
                onSwitchingChanged: (value) {
                  if (mounted) setState(() => _switching = value);
                },
              ),
            _BottomCta(blocked: _switching),
          ],
        );
      },
    );
  }
}

class _BottomCta extends StatelessWidget {
  const _BottomCta({this.blocked = false});

  /// True while a source-wallet switch is in flight — the CTA must not commit
  /// a mint whose creator and fee estimate are mid-re-derivation.
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.step != next.step ||
          prev.canGoNext != next.canGoNext ||
          prev.mintType != next.mintType,
      builder: (context, state) {
        final isReview = state.step == MintStep.review;
        final fallbackLabel = isReview
            ? switch (state.mintType) {
                MintCreateType.editions => 'Mint Editions',
                MintCreateType.collection => 'Mint Collection',
                _ => 'Mint Artwork',
              }
            : 'Next';
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
                      paymentMint: TokenBalance.solMint,
                      requiredRawAmount: state.costBreakdown.totalLamports,
                      balanceState: balanceState,
                      includeGasReserve: false,
                    )
                  : const BalanceCheckResult.sufficient();
              return MallowButton(
                label: fallbackLabel,
                isFullWidth: true,
                enabled: state.canGoNext && !blocked,
                onPressed: () {
                  if (isReview) {
                    if (!ensureSufficientBalance(context, result)) return;
                    context.read<MintBloc>()
                      ..add(const MintEvent.requestMint())
                      ..add(const MintEvent.simulateTxCost());
                    showMintConfirmationSheet(context);
                  } else {
                    context.read<MintBloc>().add(const MintEvent.next());
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
