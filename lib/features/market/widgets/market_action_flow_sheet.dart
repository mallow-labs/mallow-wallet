import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../shared/widgets/mallow_sheet.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/market_bloc.dart';
import 'market_confirmation_sheet.dart';

/// Hosts a market action's optional amount-entry step, its confirmation step,
/// and the in-flight pipeline step inside a *single* modal route, morphing
/// between them in place (cross-fade + resize) instead of dismissing one sheet
/// and presenting another.
///
/// Steps, driven by [MarketBloc] state + two flags:
/// 1. **Entry** (optional) — [entryBuilder] renders the amount sheet
///    (MakeOfferSheet / PlaceBidSheet). Its CTA reports the [MarketPrice] via
///    `onNext`; the flow keeps it mounted with its CTA spinning (`isSubmitting`)
///    while [onSubmit] dispatches the prepare event, then advances on
///    `TxFlowReady`. Omit [entryBuilder] for actions with no amount input
///    (buy / accept-offer / cancel-* / settle).
/// 2. **Confirm** — [MarketConfirmationSheet]. Its confirm tap dispatches
///    `confirmAndSign` and advances in place (no pop). A host with no entry
///    step may open this sheet immediately on tap (before the bloc reaches
///    `TxFlowReady`) by supplying [preview]: the confirm step renders right
///    away with its "You'll receive"/cost line shimmering, then resolves in
///    place once the prepared amounts arrive.
/// 3. **Pipeline** — [pipelineBuilder] renders the signing/broadcasting/
///    success/error step (the host's `_MarketPipelineSheetView`), which pops
///    the whole route when it reaches a terminal state.
///
/// Provide the ambient [MarketBloc] via a `BlocProvider.value` above this
/// widget so every step shares one instance.
class MarketActionFlowSheet extends StatefulWidget {
  const MarketActionFlowSheet({
    required this.pipelineBuilder,
    required this.tokenBalanceBloc,
    super.key,
    this.entryBuilder,
    this.onSubmit,
    this.preview,
    this.artworkTitle,
    this.artworkImageUrl,
    this.artistUsername,
    this.artistName,
    this.creatorAddress,
    this.nsfw = false,
    this.isCollection = false,
    this.escrowedOfferAmount,
    this.editionMintFeeLamports = 0,
  });

  /// Builds the entry-step sheet, wired with the advance callback and the
  /// in-flight flag. Null for actions with no amount input.
  final Widget Function(ValueChanged<MarketPrice> onNext, bool isSubmitting)?
  entryBuilder;

  /// For no-entry actions opened immediately on tap: the amounts the confirm
  /// step renders while the tx is still being prepared (the cost line shimmers
  /// until `TxFlowReady` supplies the resolved [MarketPrepData]). Null for
  /// hosts that wait for `TxFlowReady` before opening the sheet.
  final MarketActionPreview? preview;

  /// Dispatches the prepare event (`makeOfferV2` / `placeBid`) for the entered
  /// price. Required when [entryBuilder] is non-null.
  final void Function(MarketPrice price)? onSubmit;

  /// Builds the pipeline step shown once the user confirms.
  final WidgetBuilder pipelineBuilder;

  /// Forwarded to [MarketConfirmationSheet] — passed explicitly because the
  /// modal route doesn't inherit the screen-scoped provider.
  final TokenBalanceBloc tokenBalanceBloc;

  final String? artworkTitle;
  final String? artworkImageUrl;
  final String? artistUsername;
  final String? artistName;
  final String? creatorAddress;

  /// Moderation flag forwarded to the confirmation header — blurs the preview
  /// (with an eye-icon reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  /// Marks the confirmed asset as a collection NFT — forwarded to
  /// [MarketConfirmationSheet] so the burn step switches to collection copy
  /// ("Burn Collection" + the member-NFTs-survive disclaimer). Only meaningful
  /// for the burn action; harmless (default `false`) for every other action.
  final bool isCollection;

  /// The signer's existing (already-escrowed) offer, when this flow is an
  /// *update* of it. Forwarded to [MarketConfirmationSheet] so its balance gate
  /// requires only the delta. Null for a first offer and every other action.
  final MarketPrice? escrowedOfferAmount;

  /// Per-print rent + protocol fee an edition buy spends in SOL. Forwarded to
  /// [MarketConfirmationSheet]'s balance gate; zero for every action that
  /// mints nothing.
  final int editionMintFeeLamports;

  @override
  State<MarketActionFlowSheet> createState() => _MarketActionFlowSheetState();
}

class _MarketActionFlowSheetState extends State<MarketActionFlowSheet> {
  /// Entry step confirmed (the amount was submitted). No effect for actions
  /// with no entry step.
  bool _submitted = false;

  /// The amount the user submitted in the entry step — used as the confirm
  /// step's cost while its tx is still preparing (it matches what the prepared
  /// `TxFlowReady` will report). Null for no-entry actions.
  MarketPrice? _submittedPrice;

  /// Confirm step confirmed — morph to the pipeline step.
  bool _confirmed = false;

  /// True when the sheet was opened before the bloc reached `TxFlowReady` (an
  /// immediate-open host, or an entry flow). Those render the confirm step
  /// while the tx is still preparing, so the confirm sheet's post-mount
  /// `simulate` fires too early (a no-op) — we re-fire it on the first
  /// `TxFlowReady` instead (see [_firedReadySimulate]). Hosts that open the
  /// sheet already at `TxFlowReady` let the confirm sheet's own mount drive it.
  late final bool _openedPreReady;

  /// Guards [_openedPreReady]'s simulate re-fire to once.
  bool _firedReadySimulate = false;

  @override
  void initState() {
    super.initState();
    _openedPreReady =
        context.read<MarketBloc>().state
            is! TxFlowReady<MarketPrepData, MarketSuccessData>;
  }

  void _onNext(MarketPrice price) {
    if (_submitted) return;
    // Dismiss the keyboard so the sheet can settle to the confirm step's height
    // without the entry field's view-insets padding fighting the resize.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitted = true;
      _submittedPrice = price;
    });
    widget.onSubmit?.call(price);
  }

  @override
  Widget build(BuildContext context) {
    final hasEntry = widget.entryBuilder != null;
    final preview = widget.preview;
    // Amount the confirm step shows while the tx is still preparing: the
    // submitted entry amount, else the no-entry preview amount.
    final previewCost = _submittedPrice ?? preview?.totalCost;
    return BlocConsumer<MarketBloc, MarketState>(
      listenWhen: (prev, current) => prev.runtimeType != current.runtimeType,
      listener: (context, state) {
        if (!_confirmed &&
            state is TxFlowFailure<MarketPrepData, MarketSuccessData>) {
          // A *prepare* failure (before confirm) closes the flow; the host
          // screen surfaces the error. Post-confirm failures stay in the
          // pipeline step.
          Navigator.of(context).pop();
        } else if (_openedPreReady &&
            !_firedReadySimulate &&
            state is TxFlowReady<MarketPrepData, MarketSuccessData>) {
          // Sheet opened before the tx existed, so the confirm sheet's
          // mount-time simulate was a no-op — run it now (settle/accept-offer
          // resolve their "You'll receive" from it; others use its warning).
          _firedReadySimulate = true;
          context.read<MarketBloc>().add(const MarketEvent.simulate());
        }
      },
      builder: (context, state) {
        final ready = state is TxFlowReady<MarketPrepData, MarketSuccessData>
            ? state.data
            : null;
        final Widget child;
        if (_confirmed) {
          child = KeyedSubtree(
            key: const ValueKey('pipeline'),
            child: widget.pipelineBuilder(context),
          );
        } else if (ready != null && (!hasEntry || _submitted)) {
          // Tx ready — show the confirm step with the resolved amounts.
          child = _confirmSheet(
            actionType: ready.actionType,
            mintAccount: ready.mintAccount,
            totalCost: ready.totalCost,
            estimatedFeeLamports: ready.estimatedFeeLamports,
          );
        } else if (hasEntry && !_submitted) {
          // Entry flow, amount not yet submitted — show the amount sheet.
          child = KeyedSubtree(
            key: const ValueKey('entry'),
            child: widget.entryBuilder!(_onNext, _submitted),
          );
        } else if (preview != null && previewCost != null) {
          // Tx still preparing (no-entry opened immediately, or entry just
          // submitted): show the *same* confirm step now, with the preview /
          // submitted amount. The bloc is pre-`TxFlowReady`, so
          // MarketConfirmationSheet shimmers its cost line until the branch
          // above swaps in the resolved values in place (same 'confirm' key —
          // no re-mount, no display swap).
          child = _confirmSheet(
            actionType: preview.actionType,
            mintAccount: preview.mintAccount,
            totalCost: previewCost,
            estimatedFeeLamports: 0,
          );
        } else {
          // No ready data and nothing to preview (a host that waits for
          // TxFlowReady before opening — see the artwork screen's buy/cancel
          // paths). Hold a zero-height frame until Ready swaps in confirm.
          child = const SizedBox.shrink(key: ValueKey('pending'));
        }
        return SheetStepSwitcher(child: child);
      },
    );
  }

  /// The confirm step, keyed so the preparing (preview) and ready renders morph
  /// in place rather than cross-fading as two separate children.
  Widget _confirmSheet({
    required String actionType,
    required String mintAccount,
    required MarketPrice totalCost,
    required int estimatedFeeLamports,
  }) {
    return MarketConfirmationSheet(
      key: const ValueKey('confirm'),
      actionType: actionType,
      mintAccount: mintAccount,
      totalCost: totalCost,
      estimatedFeeLamports: estimatedFeeLamports,
      tokenBalanceBloc: widget.tokenBalanceBloc,
      isCollection: widget.isCollection,
      artworkTitle: widget.artworkTitle,
      artworkImageUrl: widget.artworkImageUrl,
      artistUsername: widget.artistUsername,
      artistName: widget.artistName,
      creatorAddress: widget.creatorAddress,
      nsfw: widget.nsfw,
      escrowedOfferAmount: widget.escrowedOfferAmount,
      editionMintFeeLamports: widget.editionMintFeeLamports,
      onConfirmed: () => setState(() => _confirmed = true),
    );
  }
}

/// Identifies the action a [MarketActionFlowSheet] is about to confirm so it
/// can render the confirm step *while the tx is still preparing* (cost line
/// shimmering) instead of waiting for `TxFlowReady`. [totalCost] is the amount
/// the confirm step shows during that window — pass it for no-entry actions
/// (it should match what the prepared tx will report, so the shimmer resolves
/// without a jump); leave it null for entry flows, where the amount the user
/// submitted is used instead.
class MarketActionPreview {
  const MarketActionPreview({
    required this.actionType,
    required this.mintAccount,
    this.totalCost,
  });

  final String actionType;
  final String mintAccount;
  final MarketPrice? totalCost;
}
