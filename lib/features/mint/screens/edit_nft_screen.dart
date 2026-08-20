import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' show MintCreateType;

import '../../../di.dart';
import '../../artwork/services/ensure_signer.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
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

/// Host screen for the edit-NFT and edit-collection flows.
///
/// Mounts [MintBloc] in edit mode (via [MintEvent.startedForEdit]) and
/// reuses the same step widgets as the create flow. The bloc handles
/// pre-population and the pipeline branch to the edit endpoints.
///
/// [isCollection] marks an edit-collection flow: the bloc forces the
/// collection form variant and routes the tx through the webapp-parity
/// `editTarget=parent_collection` body.
class EditNftScreen extends StatelessWidget {
  const EditNftScreen({
    required this.mintAccount,
    this.isCollection = false,
    super.key,
  });

  final String mintAccount;
  final bool isCollection;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<MintBloc>(
      create: (_) => sl<MintBloc>()
        ..add(
          MintEvent.startedForEdit(
            mintAccount: mintAccount,
            isCollection: isCollection,
          ),
        ),
      child: const _EditNftView(),
    );
  }
}

class _EditNftView extends StatelessWidget {
  const _EditNftView();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BlocListener<MintBloc, MintState>(
      // Fires once, when the prefill resolves the asset's update authority.
      // Gate a watch-only authority here (route to import + leave the screen),
      // but do NOT re-point the active signer yet: opening then abandoning the
      // edit must not silently switch wallets. The actual switch to the update
      // authority is deferred to the mint bloc's pre-sign step in
      // `_onConfirmMint`, which is the single authoritative re-point.
      listenWhen: (prev, next) =>
          prev.editUpdateAuthority == null && next.editUpdateAuthority != null,
      listener: (context, state) =>
          _ensureEditSigner(context, state.editUpdateAuthority),
      child: Scaffold(
        backgroundColor: colors.bgPrimary,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: BlocBuilder<MintBloc, MintState>(
            buildWhen: (prev, next) =>
                prev.step != next.step ||
                prev.mintType != next.mintType ||
                prev.pipelineStatus != next.pipelineStatus,
            builder: (context, state) {
              final isCollection = state.mintType == MintCreateType.collection;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MallowHeader(
                      title: isCollection ? 'Edit collection' : 'Edit artwork',
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
                    const _BottomCta(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _ensureEditSigner(
    BuildContext context,
    String? updateAuthority,
  ) async {
    final canProceed = await ensureSignerAvailable(context, updateAuthority);
    if (!canProceed && context.mounted) {
      context.pop();
    }
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
      title: 'Discard edits?',
      message: 'Your changes will be lost.',
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

class _BottomCta extends StatelessWidget {
  const _BottomCta();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.step != next.step ||
          prev.canGoNext != next.canGoNext ||
          prev.mintType != next.mintType,
      builder: (context, state) {
        final isReview = state.step == MintStep.review;
        final label = isReview
            ? (state.mintType == MintCreateType.collection
                  ? 'Update collection'
                  : 'Update artwork')
            : 'Next';
        final enabled = state.canGoNext;
        return Padding(
          padding: EdgeInsets.only(
            top: MallowTheme.spacingMd,
            bottom:
                MediaQuery.of(context).padding.bottom + MallowTheme.spacingMd,
          ),
          child: MallowButton(
            label: label,
            isFullWidth: true,
            enabled: enabled,
            onPressed: () {
              if (isReview) {
                context.read<MintBloc>()
                  ..add(const MintEvent.requestMint())
                  ..add(const MintEvent.simulateTxCost());
                showMintConfirmationSheet(context);
              } else {
                context.read<MintBloc>().add(const MintEvent.next());
              }
            },
          ),
        );
      },
    );
  }
}
