import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/config/remote_config.dart';
import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/sort_options_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../artwork/services/ensure_signer.dart';
import '../../market/services/market_bloc.dart';
import '../../market/widgets/market_action_flow_sheet.dart';
import '../../market/widgets/market_pipeline_sheet_view.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/offers_inbox_bloc.dart';
import '../widgets/offers_artwork_group.dart';
import '../widgets/offers_auction_bid_card.dart';
import '../widgets/offers_blocked_disclosure.dart';
import '../widgets/offers_inbox_row.dart';

/// Offers screen: a merged feed of every active offer +
/// auction bid the session is involved in — both received (on the viewer's
/// art) and placed (by the viewer) — grouped by artwork, newest-first.
///
/// Accepting a received offer / cancelling a placed offer reuses the shared
/// [MarketActionFlowSheet] + [MarketBloc] pipeline. Because that pipeline
/// signs as the *active* wallet, the screen first re-points the global signer
/// to the item's `viewerAddress` (the owning wallet) — see [_onView].
class OffersScreen extends StatelessWidget {
  const OffersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) =>
              sl<OffersInboxBloc>()..add(const OffersInboxEvent.load()),
        ),
        BlocProvider(create: (_) => sl<MarketBloc>()),
        BlocProvider(
          create: (_) =>
              sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
        ),
      ],
      child: const _OffersView(),
    );
  }
}

class _OffersView extends StatefulWidget {
  const _OffersView();

  @override
  State<_OffersView> createState() => _OffersViewState();
}

class _OffersViewState extends State<_OffersView> {
  final _scrollController = ScrollController();

  /// 0 = Received (offers/bids on the viewer's art), 1 = Sent (the viewer's
  /// own offers/bids). The merged feed carries [api.OffersInboxDirection] on
  /// every item, so each tab is a client-side filter of the loaded feed.
  int _tabIndex = 0;

  static const _tabLabels = ['Received', 'Sent'];

  api.OffersInboxDirection get _activeDirection => _tabIndex == 0
      ? api.OffersInboxDirection.received
      : api.OffersInboxDirection.placed;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      context.read<OffersInboxBloc>().add(const OffersInboxEvent.loadMore());
    }
  }

  // ── Row actions ─────────────────────────────────────────────────────────

  /// True while a View tap is re-pointing the signer. The switch is a network
  /// round trip (see [_onView]), so the feed is barred and a loader shown for
  /// its duration rather than leaving the tapped row silently inert.
  bool _switchingSigner = false;

  /// Bids deep-link to the artwork (auctions settle automatically — there's no
  /// per-bid action). Offers re-point the signer to the owning wallet, then
  /// dispatch accept (received) / cancel (placed) through [MarketBloc].
  ///
  /// The re-point must **fully settle before the dispatch**: [MarketBloc]
  /// reads the authority off `AuthService.currentAddress` at build time
  /// (`MarketplaceActionFlow.prepare`), and that is synchronously nulled while
  /// the switch's `/v0/login` is in flight. [ensureSigner] awaits it via the
  /// atomic `SessionManager.selectSourceWallet`, so dispatching after it
  /// returns is what makes accepting an offer on art held by a non-active
  /// session wallet work at all.
  Future<void> _onView(api.OffersInboxItem item) async {
    if (item.kind == api.OffersInboxKind.bid) {
      return _openArtwork(item);
    }
    // A second tap while the first is still switching would race two switches.
    if (_switchingSigner) return;

    final isPlaced = item.direction == api.OffersInboxDirection.placed;
    // Kill-switch entry gate — this inbox is an independent signing host for
    // the same two builders the artwork detail screen dispatches, so it reads
    // the same two cells (🔓 offer-cancel stays separate so killing
    // offer-accept can't strand an escrowed bid). Before `_switchSigner`: the
    // switch is a `/v0/login` round trip, and making a user wait through one
    // only to be told the action is off is the wall exists to remove.
    if (await guardFlowDisabled(
      context,
      FlowKey.solana(isPlaced ? AppFlow.offerCancel : AppFlow.offerAccept),
    )) {
      return;
    }
    if (!mounted) return;
    // Snapshot the active signer so an abandoned confirm sheet restores it —
    // the re-point below persists app-wide.
    final previousSigner = activeSignerSnapshot();
    if (!await _switchSigner(item, isPlaced: isPlaced) || !mounted) return;
    if (await guardViewOnly(context) || !mounted) return;

    final bloc = context.read<MarketBloc>();
    switch (item.direction) {
      case api.OffersInboxDirection.received:
        bloc.add(
          MarketEvent.acceptOffer(
            mintAccount: item.asset,
            buyer: item.actorAddress,
            amount: MarketPrice(
              rawAmount: item.rawAmount,
              currencyMint: item.currencyMint,
            ),
          ),
        );
      case api.OffersInboxDirection.placed:
        bloc.add(
          MarketEvent.cancelOffer(
            mintAccount: item.asset,
            amount: MarketPrice(
              rawAmount: item.rawAmount,
              currencyMint: item.currencyMint,
            ),
          ),
        );
    }
    // Open the sheet without waiting for `TxFlowReady`: it hosts the
    // "Preparing transaction…" step while the bloc builds the accept/cancel
    // tx, then morphs to confirm. (The tap itself is *not* instant — the
    // signer switch above blocks on a login round trip, covered by
    // [_switchingSigner].)
    final actionType = isPlaced ? 'cancel-offer' : 'accept-offer';
    final completed = await _runMarketActionFlow(item, actionType);
    // Dismissed or failed before signing: undo the re-point so opening and
    // abandoning the sheet doesn't silently move the user's active wallet. A
    // signed accept/cancel leaves the signer put (as burn/transfer do).
    if (!completed) await restoreSigner(previousSigner);
  }

  /// Re-point the global signer to the item's `viewerAddress` — the wallet
  /// that holds the art (received) or placed the offer (placed) — so
  /// [MarketBloc] builds the tx as the right wallet. Returns false when the
  /// flow must not proceed (watch-only holder routed to import, or a failed
  /// switch), and keeps [_switchingSigner] up for the whole round trip.
  Future<bool> _switchSigner(
    api.OffersInboxItem item, {
    required bool isPlaced,
  }) async {
    setState(() => _switchingSigner = true);
    try {
      return await ensureSigner(
        context,
        item.viewerAddress,
        // The API echoes `viewerAddress` in its stored form — lowercased for
        // EVM — while wallets are stored EIP-55 checksummed. `evmHolder`
        // resolves the holder through
        // `SessionManager.sessionWalletForAddressCaseInsensitive`, so an
        // Ethereum row isn't stranded by the exact match *and* a watch-only
        // ETH holder is still routed to import instead of the default `0x`
        // no-op. (Solana and Tezos are unaffected — still exact.)
        evmHolder: isEthereumAddress(item.viewerAddress),
        // The default copy is artwork-holder phrasing, which reads wrong for
        // an offer the user placed from a watch-only wallet.
        watchOnlyMessage: isPlaced
            ? 'This offer was placed by a watch-only wallet in your account. '
                  'Import its private key to cancel it.'
            : null,
      );
    } finally {
      if (mounted) setState(() => _switchingSigner = false);
    }
  }

  /// Host the confirm + signing/broadcast/success pipeline for the accept /
  /// cancel action in one morphing modal route (no amount-entry step).
  /// Returns true when the action actually went through (the signer re-point
  /// stands), false when it was abandoned or failed (the caller restores it).
  Future<bool> _runMarketActionFlow(
    api.OffersInboxItem item,
    String actionType,
  ) async {
    final marketBloc = context.read<MarketBloc>();
    final tokenBalanceBloc = context.read<TokenBalanceBloc>();
    final title = formatArtworkName(
      name: item.artworkTitle,
      editionNumber: item.editionNumber,
    );
    final imageUrl = (item.artworkImageUrl?.isNotEmpty ?? false)
        ? item.artworkImageUrl
        : null;

    await showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: marketBloc,
        child: MarketActionFlowSheet(
          tokenBalanceBloc: tokenBalanceBloc,
          artworkTitle: title,
          artworkImageUrl: imageUrl,
          artistUsername: item.creatorUsername,
          // Opened immediately on tap, before the tx is built — the confirm
          // step renders now with these amounts (cost line shimmering) and
          // resolves in place on TxFlowReady.
          preview: MarketActionPreview(
            actionType: actionType,
            mintAccount: item.asset,
            totalCost: MarketPrice(
              rawAmount: item.rawAmount,
              currencyMint: item.currencyMint,
            ),
          ),
          pipelineBuilder: (_) => MarketPipelineSheetView(
            actionType: actionType,
            title: title,
            imageUrl: imageUrl,
            username: item.creatorUsername,
          ),
        ),
      ),
    );
    final state = marketBloc.state;
    final completed = state is TxFlowSuccess<MarketPrepData, MarketSuccessData>;
    if (!mounted) return completed;
    if (state is TxFlowFailure<MarketPrepData, MarketSuccessData>) {
      // A prepare failure (before confirm) pops the flow sheet itself, leaving
      // the bloc in Failure — surface the reason now. (A post-confirm error is
      // shown inside the pipeline step and ends in Idle once dismissed, so it
      // doesn't reach here.)
      //
      // A remote kill is not this error: [_onMarketState] already showed the
      // operator's copy in `FlowUnavailableSheet` and it reaches both the
      // pre- and post-confirm case, so a generic snackbar here would only
      // double up. The reset still runs — the screen stays open and idle.
      if (!state.failure.isFlowDisabled) {
        AppSnackBar.show(context, state.failure.message);
      }
      marketBloc.add(const MarketEvent.reset());
    } else if (state is TxFlowReady<MarketPrepData, MarketSuccessData> ||
        state is TxFlowPreparing<MarketPrepData, MarketSuccessData>) {
      // Dismissed before signing — reset so the stale payload doesn't linger.
      marketBloc.add(const MarketEvent.reset());
    }
    return completed;
  }

  void _onMarketState(BuildContext context, MarketState state) {
    // The flow sheet owns the prepare/confirm/sign/error display (and re-fires
    // `simulate` once the tx is ready); the screen only drops the resolved
    // offer from the inbox. (Prepare failures are surfaced by
    // _runMarketActionFlow once the sheet closes.)
    if (state is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      // Two `TxFlowSuccess` emissions land per action: the chain-confirmed one
      // (`indexed == null`) and the indexer ack (`indexed` true/false).
      // Refetching on the first would re-read pre-index truth and paint the
      // just-resolved offer back into the list, where its Accept/Cancel pill
      // re-prompts the signer against a closed PDA. Gate on the flip — the
      // same invalidate-after-checkTx rule the artwork screen uses.
      if (state.result.indexed == null) return;
      context.read<OffersInboxBloc>().add(const OffersInboxEvent.refresh());
    } else if (state is TxFlowFailure<MarketPrepData, MarketSuccessData> &&
        state.failure.isFlowDisabled) {
      // Kill switch. Presented here rather than in the post-sheet check
      // below because this fires for a *post-confirm* kill too, where the
      // pipeline step's generic "Transaction failed" is all the user would
      // otherwise see — and the operator's copy is the only thing that can say
      // whether their offer/funds are safe. The inbox stays open and idle.
      //
      // Deferred a frame: on a pre-confirm failure `MarketActionFlowSheet` pops
      // itself from its own listener on this same emission, and that
      // `Navigator.pop()` would take the explanation route if we pushed now.
      final failure = state.failure;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        handleFlowDisabled(this.context, failure);
      });
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────

  Future<void> _onRefresh() async {
    final bloc = context.read<OffersInboxBloc>();
    bloc.add(const OffersInboxEvent.refresh());
    // Wait for the refetch to *settle* — `isRefreshing` clearing — not merely
    // for any loaded state. The in-flight state is itself `OffersInboxLoaded`,
    // and a refresh that returns unchanged rows emits nothing else at all.
    await bloc.stream.firstWhere(
      (s) =>
          s is OffersInboxError || (s is OffersInboxLoaded && !s.isRefreshing),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BlocListener<MarketBloc, MarketState>(
      listenWhen: marketOffersListenWhen,
      listener: _onMarketState,
      child: Scaffold(
        backgroundColor: colors.bgPrimary,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                ),
                child: MallowUnderlineTabBar(
                  tabs: _tabLabels,
                  activeIndex: _tabIndex,
                  onTabSelected: (i) => setState(() => _tabIndex = i),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    BlocBuilder<OffersInboxBloc, OffersInboxState>(
                      builder: (context, state) => switch (state) {
                        OffersInboxInitial() => _centeredSpinner(colors),
                        OffersInboxError(:final message) => _centeredText(
                          colors,
                          message,
                        ),
                        OffersInboxLoaded() => _buildLoaded(context, state),
                      },
                    ),
                    if (_switchingSigner) _switchingOverlay(colors),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacingMd,
        bottom: MallowTheme.spacing20,
      ),
      child: Row(
        children: [
          TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: SvgPicture.asset(
                'assets/icons/arrow_left.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  colors.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              'Offers',
              style: MallowTheme.editorialSection.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoaded(BuildContext context, OffersInboxLoaded state) {
    final colors = context.mallowColors;
    final items = state.items;
    if (items == null) return _centeredSpinner(colors);

    // Client-side split of the merged, recency-ordered feed by direction — the
    // active tab shows only its side (Received / Sent). Load-more keeps growing
    // both buckets as further merged pages land.
    final tabItems = items
        .where((i) => i.direction == _activeDirection)
        .toList(growable: false);

    final emptyLabel = _tabIndex == 0
        ? 'No offers or bids received yet.'
        : 'No offers or bids sent yet.';

    // The active tab can be empty while its items sit on a not-yet-fetched page
    // of the merged feed (the other direction filled page 0). Keep paging until
    // this side has something or the feed is exhausted, rather than showing a
    // false "empty" — the SliverFillRemaining empty state leaves no scroll
    // extent for the usual near-bottom load-more trigger.
    if (tabItems.isEmpty && state.hasMore && !state.isLoadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<OffersInboxBloc>().add(const OffersInboxEvent.loadMore());
      });
    }

    return MallowRefreshIndicator(
      onRefresh: _onRefresh,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              MallowTheme.spacingLg,
              MallowTheme.spacing20,
              40,
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                // Disclosure sits above both the populated list and the empty
                // state: "every offer I have is from someone I blocked" is
                // exactly the case where the count must not disappear with
                // the rows.
                if (state.hiddenByBlockCount > 0)
                  SliverToBoxAdapter(
                    child: OffersBlockedDisclosure(
                      count: state.hiddenByBlockCount,
                    ),
                  ),
                tabItems.isEmpty
                    ? SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          // Still paging the merged feed for this direction
                          // → keep the spinner up instead of a premature
                          // empty message.
                          child: (state.hasMore || state.isLoadingMore)
                              ? _centeredSpinner(colors)
                              : Text(
                                  emptyLabel,
                                  style: MallowTheme.uiBody.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                        ),
                      )
                    : SliverList.list(
                        children: [
                          _sortControl(context, state.sort),
                          const SizedBox(height: MallowTheme.spacingLg),
                          ..._buildGroups(context, tabItems),
                          if (state.isLoadingMore) ...[
                            const SizedBox(height: MallowTheme.spacingMd),
                            _centeredSpinner(colors),
                          ],
                        ],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Lay the feed out as blocks separated by dividers. Auction bids with
  /// grouped bid data render as standalone
  /// self-contained [OffersAuctionBidCard]s (the artwork header lives inside
  /// the card). Everything else groups consecutive
  /// same-artwork items under an [OffersArtworkGroup] header (the feed is
  /// recency-ordered, so a header renders whenever the asset changes).
  List<Widget> _buildGroups(
    BuildContext context,
    List<api.OffersInboxItem> items,
  ) {
    final colors = context.mallowColors;
    final groups = <Widget>[];

    void addBlock(Widget block) {
      if (groups.isNotEmpty) {
        groups.add(
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: MallowTheme.spacingLg,
            ),
            child: Divider(height: 1, color: colors.dividerLight),
          ),
        );
      }
      groups.add(block);
    }

    var i = 0;
    while (i < items.length) {
      final item = items[i];
      if (_isAuctionCard(item)) {
        addBlock(
          OffersAuctionBidCard(item: item, onView: () => _openArtwork(item)),
        );
        i++;
        continue;
      }
      final asset = item.asset;
      final rowItems = <api.OffersInboxItem>[];
      while (i < items.length &&
          items[i].asset == asset &&
          !_isAuctionCard(items[i])) {
        rowItems.add(items[i]);
        i++;
      }
      addBlock(
        OffersArtworkGroup(
          item: rowItems.first,
          rows: [
            for (final item in rowItems)
              Padding(
                padding: const EdgeInsets.only(top: MallowTheme.spacingSm),
                child: OffersInboxRow(item: item, onView: () => _onView(item)),
              ),
          ],
        ),
      );
    }
    return groups;
  }

  bool _isAuctionCard(api.OffersInboxItem item) =>
      item.kind == api.OffersInboxKind.bid && item.auction != null;

  /// Deep-links to the artwork, then refetches the inbox once that screen
  /// pops.
  ///
  /// The artwork screen hosts its own [MarketBloc] and can resolve the very
  /// rows this feed is showing — settling an auction, accepting or cancelling
  /// an offer from the artwork side. Those flows complete on a route this
  /// screen's listener never sees, so without a refetch on return the settled
  /// auction / closed offer is still sitting in the list, and its action pill
  /// re-prompts the signer against an account that is already gone.
  ///
  /// Best-effort, and subject to indexer lag the same way the collection
  /// screen's post-edit refresh is: the pop may beat the indexer, in which
  /// case the row survives until the next refresh.
  Future<void> _openArtwork(api.OffersInboxItem item) async {
    // Read the bloc up front — `context` must not be touched after the await.
    final bloc = context.read<OffersInboxBloc>();
    await context.push(AppRoutes.artworkDetailPath(item.asset));
    if (!mounted) return;
    bloc.add(const OffersInboxEvent.refresh());
  }

  Widget _sortControl(BuildContext context, api.OffersInboxSort sort) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          final bloc = context.read<OffersInboxBloc>();
          final result = await showSortOptionsSheet(
            context,
            options: api.OffersInboxSort.values,
            currentSort: sort,
            labelFor: _sortLabel,
          );
          if (result != null && result != sort) {
            bloc.add(OffersInboxEvent.setSort(sort: result));
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/icons/arrows-sort.svg',
              width: 16,
              height: 16,
              colorFilter: ColorFilter.mode(
                colors.textPrimary,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingXs),
            Text(
              _sortLabel(sort),
              style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  /// Progress + tap barrier for the signer re-point. `selectSourceWallet`
  /// awaits a `/v0/login`, so a View tap can hang for seconds before the sheet
  /// opens; without this the row reads as unresponsive and a second tap starts
  /// a competing switch.
  Widget _switchingOverlay(MallowColors colors) => Positioned.fill(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ColoredBox(
        color: colors.bgPrimary.withValues(alpha: 0.7),
        child: _centeredSpinner(colors),
      ),
    ),
  );

  Widget _centeredSpinner(MallowColors colors) =>
      Center(child: MallowLoader(color: colors.textPrimary));

  Widget _centeredText(MallowColors colors, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      child: Text(
        text,
        style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        textAlign: TextAlign.center,
      ),
    ),
  );

  String _sortLabel(api.OffersInboxSort sort) => switch (sort) {
    api.OffersInboxSort.latest => 'Latest',
    api.OffersInboxSort.oldest => 'Oldest',
    api.OffersInboxSort.amount => 'Amount',
  };
}

/// `BlocListener.listenWhen` predicate for the [MarketBloc] emissions handled
/// by `_OffersViewState._onMarketState`. Exposed at top level so it can be
/// unit-tested without spinning up the screen.
///
/// A `runtimeType` comparison is wrong here: [MarketBloc] emits `TxFlowSuccess`
/// twice per action — chain-confirmed (`indexed == null`) then indexer-acked
/// (`indexed` flipped) — and both share a runtime type, so the acked emission
/// (the one the inbox refetch is gated on) would be swallowed. Mirrors
/// `marketArtworkListenWhen` in `artwork_detail_screen.dart`.
@visibleForTesting
bool marketOffersListenWhen(MarketState previous, MarketState current) {
  if (current is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
    if (previous is! TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      return true;
    }
    return previous.result.indexed != current.result.indexed;
  }
  return current is TxFlowFailure<MarketPrepData, MarketSuccessData>;
}
