import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/services/signing_copy.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../artwork/services/ensure_signer.dart';
import '../../portfolio/services/portfolio_bloc.dart' show PortfolioArtwork;
import '../../search/widgets/search_input.dart';
import '../services/manage_collection_artworks_bloc.dart';

/// Full-screen "add artworks to a collection" flow. Shows the signer's owned
/// (non-printable) artworks as a searchable checklist; confirming builds and
/// signs the membership tx(s) via `POST /v2/tx/nft/edit-collection-artworks`.
///
/// Reached from the collection screen / edit-collection context and from the
/// post-create success sheet ("Add artworks").
class ManageCollectionArtworksScreen extends StatelessWidget {
  const ManageCollectionArtworksScreen({
    required this.collectionMint,
    this.collectionName,
    super.key,
  });

  final String collectionMint;
  final String? collectionName;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ManageCollectionArtworksBloc>(
      create: (_) =>
          sl<ManageCollectionArtworksBloc>()
            ..add(ManageCollectionArtworksEvent.started(collectionMint)),
      child: _ManageArtworksView(collectionName: collectionName),
    );
  }
}

class _ManageArtworksView extends StatelessWidget {
  const _ManageArtworksView({this.collectionName});

  final String? collectionName;

  @override
  Widget build(BuildContext context) {
    return BlocListener<
      ManageCollectionArtworksBloc,
      ManageCollectionArtworksState
    >(
      // Fires once, when the load resolves the collection's update authority.
      // Gate a watch-only authority here (route to import + leave the screen),
      // but do NOT re-point the active signer yet: opening then abandoning the
      // screen must not silently switch wallets. The actual switch to the
      // authority is deferred to the bloc's pre-sign step in `_onSubmit`, which
      // is the single authoritative re-point. Mirrors `edit_nft_screen`.
      listenWhen: (prev, next) =>
          prev.authority == null && next.authority != null,
      listener: (context, state) =>
          _ensureAuthoritySigner(context, state.authority),
      child: _buildScaffold(context),
    );
  }

  Future<void> _ensureAuthoritySigner(
    BuildContext context,
    String? authority,
  ) async {
    final canProceed = await ensureSignerAvailable(
      context,
      authority,
      watchOnlyMessage:
          'This collection is administered by a watch-only wallet in your '
          'account. Import its private key to sign for it.',
    );
    if (!canProceed && context.mounted) {
      context.pop();
    }
  }

  Widget _buildScaffold(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MallowHeader(
                title: collectionName == null || collectionName!.isEmpty
                    ? 'Add artworks'
                    : 'Add to ${collectionName!}',
                onBack: () => context.pop(),
              ),
              const SizedBox(height: MallowTheme.spacing20),
              SearchInput(
                autofocus: false,
                hintText: 'Search artworks',
                onChanged: (value) => context
                    .read<ManageCollectionArtworksBloc>()
                    .add(ManageCollectionArtworksEvent.queryChanged(value)),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              const Expanded(child: _ArtworkChecklist()),
              const _SubmitBar(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtworkChecklist extends StatelessWidget {
  const _ArtworkChecklist();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<
      ManageCollectionArtworksBloc,
      ManageCollectionArtworksState
    >(
      buildWhen: (prev, next) =>
          prev.isLoading != next.isLoading ||
          prev.loadError != next.loadError ||
          prev.artworks != next.artworks ||
          prev.query != next.query ||
          prev.selected != next.selected,
      builder: (context, state) {
        if (state.isLoading) {
          return const Center(child: MallowLoadingIndicator());
        }
        if (state.loadError != null) {
          return Center(
            child: Text(
              state.loadError!,
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          );
        }
        final artworks = state.filtered;
        if (artworks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(MallowTheme.spacing20),
              child: Text(
                state.query.trim().isNotEmpty
                    ? 'No artworks match your search'
                    : "This collection has no artworks, and you don't own any "
                          'to add yet',
                textAlign: TextAlign.center,
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: artworks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final artwork = artworks[index];
            return _ArtworkCheckRow(
              artwork: artwork,
              isSelected: state.selected.contains(artwork.mintAccount),
              onTap: () => context.read<ManageCollectionArtworksBloc>().add(
                ManageCollectionArtworksEvent.toggled(artwork.mintAccount),
              ),
            );
          },
        );
      },
    );
  }
}

class _ArtworkCheckRow extends StatelessWidget {
  const _ArtworkCheckRow({
    required this.artwork,
    required this.isSelected,
    required this.onTap,
  });

  final PortfolioArtwork artwork;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final hasCollection =
        artwork.collectionName != null && artwork.collectionName!.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceMuted),
                  if (artwork.imageUrl.isNotEmpty)
                    MallowArtworkMedia(
                      imageUrl: artwork.imageUrl,
                      nsfw: artwork.nsfw,
                      logicalSize: 52,
                      width: 52,
                      height: 52,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatArtworkName(
                    name: artwork.title,
                    editionNumber: artwork.editionNumber,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasCollection ? artwork.collectionName! : artwork.supplyLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _Checkbox(isSelected: isSelected),
        ],
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: isSelected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isSelected ? colors.accent : colors.divider,
          width: 2,
        ),
      ),
      child: isSelected
          ? Center(
              child: MallowSvgIcon(
                'assets/icons/checkmark.svg',
                width: 14,
                height: 14,
                color: colors.textOnAccent,
              ),
            )
          : null,
    );
  }
}

class _SubmitBar extends StatelessWidget {
  const _SubmitBar();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<
      ManageCollectionArtworksBloc,
      ManageCollectionArtworksState
    >(
      buildWhen: (prev, next) =>
          prev.selected != next.selected ||
          prev.memberMints != next.memberMints ||
          prev.txStatus != next.txStatus,
      builder: (context, state) {
        final add = state.added.length;
        final remove = state.removed.length;
        final label = add == 0 && remove == 0
            ? 'Add artworks'
            : add > 0 && remove > 0
            ? 'Save changes'
            : remove > 0
            ? 'Remove $remove artwork${remove == 1 ? '' : 's'}'
            : 'Add $add artwork${add == 1 ? '' : 's'}';
        return Padding(
          padding: EdgeInsets.only(
            top: MallowTheme.spacingMd,
            bottom:
                MediaQuery.of(context).padding.bottom + MallowTheme.spacingMd,
          ),
          child: MallowButton(
            label: label,
            isFullWidth: true,
            enabled: state.canSubmit,
            onPressed: () => _submit(context),
          ),
        );
      },
    );
  }

  void _submit(BuildContext context) {
    final bloc = context.read<ManageCollectionArtworksBloc>()
      ..add(const ManageCollectionArtworksEvent.submit());
    // Kill switch: a stop from the signing backstop closes the pipeline
    // sheet without an error body (see [_AddArtworksPipelineSheetState]), so
    // present the operator's copy here, over this screen — which stays open with
    // the user's selection intact. Read before the reset below, which clears it.
    void presentKillIfAny() {
      final failure = bloc.state.txFailure;
      if (failure == null || !context.mounted) return;
      handleFlowDisabled(
        context,
        failure,
        flow: const FlowKey.solana(AppFlow.collectionArtworksEdit),
      );
    }

    // In the error phase the sheet allows a barrier tap / swipe-down, both of
    // which bypass its `onClose` — so without this, `dismissError` never fires,
    // `txStatus` stays `error`, and the submit button (gated on
    // `txStatus == idle`) is permanently disabled with no retry path. Reset on
    // whatever close path. Idempotent with `onClose`: that handler dispatches
    // `dismissError` before popping, so the state is already `idle` here and the
    // guard skips the redundant dispatch.
    unawaited(
      showTransactionPipelineSheet(
        context: context,
        builder: (_) => BlocProvider<ManageCollectionArtworksBloc>.value(
          value: bloc,
          child: const _AddArtworksPipelineSheet(),
        ),
      ).whenComplete(() {
        presentKillIfAny();
        if (bloc.state.txStatus == ManageArtworksTxStatus.error) {
          bloc.add(const ManageCollectionArtworksEvent.dismissError());
        }
      }),
    );
  }
}

/// Pipeline body for the add-to-collection tx, driven by the bloc's
/// [ManageArtworksTxStatus]. Pops itself (and the screen) on success; on a
/// dismissed error it just closes the sheet.
class _AddArtworksPipelineSheet extends StatefulWidget {
  const _AddArtworksPipelineSheet();

  @override
  State<_AddArtworksPipelineSheet> createState() =>
      _AddArtworksPipelineSheetState();
}

class _AddArtworksPipelineSheetState extends State<_AddArtworksPipelineSheet> {
  /// Guards the kill-switch pop below against a second `Navigator.pop()` — that
  /// would take this screen's route instead of the (already popped) sheet.
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<
      ManageCollectionArtworksBloc,
      ManageCollectionArtworksState
    >(
      listenWhen: (prev, next) => prev.txStatus != next.txStatus,
      listener: (context, state) {
        // A kill is not a failed update: the error body's hardcoded "Could not
        // update collection" drops the operator's message and its Retry can only
        // fail again. Close the sheet (leaving the failure on the bloc) and let
        // [_SubmitBar._submit] explain it over this screen.
        if (state.txStatus == ManageArtworksTxStatus.error &&
            (state.txFailure?.isFlowDisabled ?? false)) {
          if (_popped) return;
          _popped = true;
          Navigator.of(context).pop();
        }
      },
      buildWhen: (prev, next) =>
          prev.txStatus != next.txStatus || prev.txStage != next.txStage,
      builder: (context, state) {
        final phase = switch (state.txStatus) {
          ManageArtworksTxStatus.success => TransactionPipelinePhase.success,
          // A kill is already dismissing this sheet (listener above): don't
          // flash the generic failure over the operator's actual reason.
          ManageArtworksTxStatus.error
              when !(state.txFailure?.isFlowDisabled ?? false) =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final (label, sublabel) = _labelsFor(state);
        // Broadcast, never observed as confirmed before the blockhash expired:
        // indeterminate, not failed. The membership change may well have
        // applied, and `retry` re-signs a fresh set of update transactions
        // over a selection we can no longer describe. Mirrors
        // `SendPipelineView`.
        final unconfirmed = state.txFailure?.isUnconfirmed ?? false;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed
              ? 'Not confirmed yet'
              : 'Could not update collection',
          // The failure message — `sublabel` isn't rendered in the error body,
          // so without this the reason was dropped entirely.
          errorSublabel: phase == TransactionPipelinePhase.error
              ? state.txError
              : null,
          successAction: phase == TransactionPipelinePhase.success
              ? TransactionSuccessAction(
                  primaryLabel: 'Done',
                  onPrimary: () {
                    Navigator.of(context).pop();
                    context.pop();
                  },
                )
              : null,
          onRetry: unconfirmed
              ? null
              : () => context.read<ManageCollectionArtworksBloc>().add(
                  const ManageCollectionArtworksEvent.retry(),
                ),
          onClose: () {
            context.read<ManageCollectionArtworksBloc>().add(
              const ManageCollectionArtworksEvent.dismissError(),
            );
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  (String, String?) _labelsFor(ManageCollectionArtworksState state) {
    final stage = state.txStage;
    final isSigningStage =
        stage != null &&
        (stage.startsWith(kLocalSigningLabel) ||
            stage.startsWith(kExternalSigningLabel) ||
            stage.startsWith(kLedgerSigningStage));
    if (state.txStatus == ManageArtworksTxStatus.signing && isSigningStage) {
      return (signingLabelForStage(stage), signingSublabelForStage(stage));
    }
    return switch (state.txStatus) {
      ManageArtworksTxStatus.success => ('Collection updated', null),
      ManageArtworksTxStatus.broadcasting => (
        kConfirmingLabel,
        kConfirmingSublabelSolana,
      ),
      ManageArtworksTxStatus.error => (
        'Could not update collection',
        state.txError,
      ),
      _ => (state.txStage ?? kPreparingLabel, null),
    };
  }
}
