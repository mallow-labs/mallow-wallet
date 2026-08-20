import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/data/mallow_market.dart';
import '../../../core/models/account.dart' show WalletInfo;
import '../../../core/network/auth_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/token_metadata_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/tx_landed_slots.dart';
import '../../../core/realtime/market_realtime_service.dart';
import '../../../core/realtime/models/market_invalidation.dart';
import '../../../core/router/app_router.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/utils/asset_url.dart';
import '../../../core/utils/image_fallback.dart';
import '../../../core/utils/mallow_image.dart';
import '../../../core/utils/mux.dart';
import '../../../core/utils/reduce_motion.dart';
import '../../../di.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/artwork_mappers.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/price_format.dart' show stripTrailingZeros;
import '../../../shared/utils/user_display.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/animated_tab_content.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/artwork_info/artwork_info_tabs.dart';
import '../../../shared/widgets/artwork_info/artwork_info_view_data.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_image_cache_manager.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/new_curation_sheet.dart';
import '../../../shared/widgets/nsfw_obscured.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/tappable.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../cast/models/cast_media_type.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../market/data/whitelist_eligibility_repository.dart';
import '../../market/services/analytics_failure_reason.dart';
import '../../market/services/edition_buy_routing.dart';
import '../../market/services/market_bloc.dart';
import '../../market/widgets/market_pipeline_sheet_view.dart';
import '../../portfolio/services/portfolio_bloc.dart'
    show ArtGroup, ArtGroupType, PortfolioArtwork;
import '../../profile/screens/collection_screen.dart';
import '../../profile/screens/curation_screen.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../curations/data/curation_repository.dart';
import '../../curations/services/curation_attribution_store.dart';
import '../../market/widgets/make_offer_sheet.dart';
import '../../market/widgets/market_action_flow_sheet.dart';
import '../../market/widgets/market_confirmation_sheet.dart';
import '../../market/widgets/place_bid_sheet.dart';
import '../../market/widgets/set_price_sheet.dart';
import '../../market/widgets/update_listing_sheet.dart';
import '../../mint/pickers/category_picker_sheet.dart';
import '../../profile/data/user_profile_repository.dart';
import '../../profile/models/user_profile.dart';
import '../../raffle/data/raffle_repository.dart';
import '../../sale/services/edition_mint_fees.dart';
import '../../raffle/services/raffle_bloc.dart';
import '../../raffle/widgets/raffle_ticket_sheet.dart';
import '../data/artwork_events_repository.dart';
import '../data/artwork_repository.dart';
import '../data/market_account_repository.dart';
import '../data/market_listing_repository.dart';
import '../data/offer_repository.dart';
import '../models/on_chain_asset.dart';
import '../../search/services/recently_viewed_recorder.dart';
import '../services/artwork_action_state.dart';
import '../services/artwork_bloc.dart';
import '../services/artwork_download_actions.dart';
import '../services/artwork_hide_actions.dart';
import '../services/ensure_signer.dart';
import '../services/artwork_permission_service.dart';
import '../widgets/add_to_curation_sheet.dart';
import '../widgets/artwork_context_menu_sheet.dart';
import '../widgets/burn_artwork_flow.dart';
import '../widgets/transfer_artwork_flow.dart';
import '../widgets/history_section.dart';
import '../widgets/offers_section.dart';
import '../widgets/collection_curation_row.dart';
import '../widgets/curated_in_sheet.dart';
import '../widgets/sheets/artwork_auction_bid_sheet.dart';
import '../widgets/sheets/artwork_auction_claim_sheet.dart';
import '../widgets/sheets/artwork_auction_owner_sheet.dart';
import '../widgets/sheets/artwork_buy_edition_sheet.dart';
import '../widgets/sheets/artwork_buy_sheet.dart';
import '../widgets/sheets/artwork_connect_wallet_sheet.dart';
import '../widgets/sheets/artwork_external_link_sheet.dart';
import '../widgets/sheets/artwork_owner_listed_sheet.dart';
import '../widgets/sheets/artwork_owner_sheet.dart';
import '../widgets/sheets/artwork_raffle_sheet.dart';
import '../widgets/sheets/artwork_unclaimed_raffle_sheet.dart';
import '../widgets/sheets/artwork_unlisted_viewer_sheet.dart';

part 'artwork_detail_screen/action_sheet.dart';
part 'artwork_detail_screen/actions.dart';
part 'artwork_detail_screen/detail_body.dart';
part 'artwork_detail_screen/artwork_image.dart';
part 'artwork_detail_screen/header_delegate.dart';
part 'artwork_detail_screen/debug_banner.dart';
part 'artwork_detail_screen/dots_menu_launcher.dart';
part 'artwork_detail_screen/loaders.dart';
part 'artwork_detail_screen/market_pipeline_sheet.dart';
part 'artwork_detail_screen/measure_size.dart';
part 'artwork_detail_screen/scroll_content.dart';

/// Sentinel program id emitted by `MarketRealtimeService` after a reconnect
/// so consumers refetch and close any gap that opened during the outage.
const _kSyntheticReconnect = '__synthetic_reconnect__';

class ArtworkDetailScreen extends StatelessWidget {
  const ArtworkDetailScreen({
    required this.mintAccount,
    super.key,
    this.heroTag,
  });

  final String mintAccount;

  /// Shared-element tag supplied by the tile that opened this screen (passed via
  /// the route's `extra`). When present the artwork image flies in from that
  /// tile; when absent (deep link, notification, search) the image still uses a
  /// per-mint fallback tag for the image → fullscreen-viewer flight.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => sl<MarketBloc>()),
        BlocProvider(create: (context) => sl<RaffleBloc>()),
        BlocProvider(
          create: (context) =>
              sl<ArtworkBloc>()
                ..add(ArtworkEvent.load(mintAccount: mintAccount)),
        ),
        BlocProvider(
          create: (_) =>
              sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
        ),
      ],
      child: _ArtworkDetailView(mintAccount: mintAccount, heroTag: heroTag),
    );
  }
}

class _ArtworkDetailView extends StatefulWidget {
  const _ArtworkDetailView({required this.mintAccount, this.heroTag});

  final String mintAccount;
  final Object? heroTag;

  @override
  State<_ArtworkDetailView> createState() => _ArtworkDetailViewState();
}

class _ArtworkDetailViewState extends State<_ArtworkDetailView> {
  // Fallback bottom padding used for the very first frame, before the
  // persistent action sheet has been measured. After layout, the real
  // rendered height is captured into [_measuredSheetHeight] and used
  // instead — sheet variants differ in height (raffle / edition / owner
  // sheets are taller than the basic buy sheet), so a single fixed
  // constant left tall sheets clipping the bottom of the scroll content.
  static const _fallbackSheetHeight = 200.0;
  double? _measuredSheetHeight;

  /// Resolved mallow usernames for creator / update-authority addresses.
  final Map<String, String?> _creatorUsernames = {};

  /// Every wallet linked to any of the creator / update-authority mallow
  /// users above. Populated from `UserProfile.linkedAddresses` so a creator
  /// connected via any of their linked wallets passes the cast/share gate.
  final Set<String> _creatorLinkedAddresses = <String>{};
  List<String>? _loadedCreatorAddresses;

  /// On-chain permissions; null until the DAS lookup completes.
  ArtworkPermissions? _permissions;
  bool _permissionsLoading = false;

  /// Whether the connected wallet has a live offer on the loaded artwork.
  /// Drives the "Make offer" ↔ "Cancel offer" toggle in the buy /
  /// unlisted-viewer sheets.
  bool _userOwnOffer = false;
  String? _userOwnOfferLoadedFor;

  /// The connected wallet's active offer amount, when one is loaded — passed
  /// to `cancelOffer` so the confirm sheet's "Total returned" includes the
  /// refunded amount. Null until the offer loader resolves (or after the
  /// optimistic post-offer flip), in which case cancel falls back to
  /// rent-only.
  MarketPrice? _userOwnOfferAmount;

  /// The wallet that actually placed the loaded offer. The own-offer lookup is
  /// session-wide (A1b), so the maker need not be the active signer — cancel
  /// passes this to `ensureSigner` so `CancelOfferTxRequest.buyer` is the
  /// wallet the Offer PDA is keyed by. Null when no offer is loaded.
  String? _userOwnOfferBuyer;

  /// Highest active offer on the loaded artwork — feeds the owner sheet's
  /// accept panel and the unlisted-viewer sheet's
  /// offer panel. Loaded once per mint when the
  /// indexer reports offers; cleared on offer invalidations.
  OfferRender? _highestOffer;
  String? _highestOfferLoadedFor;

  /// Dedupe key for the listing/bid-currency DAS lookup. The resolved value
  /// itself lives in `TokenMetadataService`'s cache, not here — this only
  /// tracks which mint we've already asked for.
  String? _currencyMetadataLoadedFor;

  /// Live edition wallet-cap + allowlist state. Populated for buy-now
  /// edition listings. Null when not applicable.
  EditionPurchaseStats? _editionStats;
  String? _editionStatsLoadedFor;

  /// The two halves of the ON-CHAIN whitelist phase for the connected
  /// wallet: the Merkle wallet allowlist behind
  /// `_editionStats.whitelistConfig.walletsRoot`, and the holder-only token
  /// gate on the same config. Either one qualifies the buyer. Null means
  /// "unknown" — still in flight, or the check failed — and never blocks the
  /// buy. See [WhitelistEligibilityRepository] and [isWhitelistPhaseBlocked].
  bool? _editionOnChainAllowlisted;
  bool? _editionHoldsGatingNft;

  /// DAS-derived edition state — `isPrintableMasterEdition` + live supply.
  /// Drives the dispatcher's `BuyEditionSheet` ↔ `BuySheet` routing and
  /// the progress bar on the edition sheet. Phase 9.
  EditionLiveState? _editionLive;
  String? _editionLiveLoadedFor;

  /// Live raffle PDA snapshot, keyed by raffle account. See
  /// `_maybeLoadRaffleLive`.
  RaffleLiveState? _raffleLive;
  String? _raffleLiveLoadedFor;

  /// Signature of an edition buy whose print we should route to once the
  /// pipeline sheet closes. Captured on the edition-buy `TxFlowSuccess` and
  /// consumed in `_showMarketPipelineSheet`'s completion. The real print mint
  /// isn't known here — the tx builder's ephemeral key doesn't match the mint
  /// that lands on-chain — so the handler resolves it from the indexed sale
  /// event ([_navigateToBoughtPrint]). The push is deferred to sheet-close so
  /// it lands after the success sheet dismisses (not behind it). Null for
  /// every other action.
  String? _pendingEditionBuySig;

  /// Active per-mint subscription on `MarketRealtimeService`. Refetches
  /// fire on any tx affecting this mint — auction bids, listing changes,
  /// raffle ticket purchases, edition mints — so the screen stays in
  /// parity with the webapp's on-account-change behavior without polling.
  StreamSubscription<MarketInvalidation>? _realtimeSub;

  /// [ArtworkBloc.transientErrors] — one-shot failures (a reverted like) that
  /// leave no trace in the rendered state.
  StreamSubscription<String>? _transientErrorSub;
  String? _realtimeMint;

  /// Mints with an in-flight `checkTx` poll. Populated the moment a
  /// market action confirms on-chain (`TxFlowSuccess` first emission)
  /// and cleared once the indexer acks the tx (`TxFlowSuccess` `indexed`
  /// flips). While set, the action sheet is hidden so the user can't
  /// re-tap a stale CTA against pre-index server state. Listing-management
  /// actions (update / cancel) bypass this gate — they apply an optimistic
  /// update via [_pendingPriceUpdates] / [_pendingCancellations] so the
  /// sheet refreshes in place instead. Edition buys also bypass it via
  /// [_applyOptimisticEditionBuy] — the listing stays live until the last
  /// print, so the sheet should remain visible for follow-up purchases.
  final Set<String> _pendingIndexerMints = <String>{};

  /// Pending listing-price update keyed by mint, captured when the user
  /// confirms a new price on [UpdateListingSheet]. Stored as the RAW on-chain
  /// amount (listing currency's smallest unit) and replayed onto the loaded
  /// artwork via `ArtworkEvent.optimisticListingUpdate` once the matching
  /// `TxFlowSuccess` lands so the bottom sheet shows the new price without
  /// waiting for the indexer — correct for SOL and non-9-decimal mints alike.
  final Map<String, double> _pendingPriceUpdates = <String, double>{};

  /// Buyer address for a pending accept-offer, keyed by mint. Replayed as an
  /// `ArtworkEvent.optimisticRelinquishOwnership` on `TxFlowSuccess` so the
  /// ex-owner's sheet flips to the unlisted viewer state immediately.
  final Map<String, String> _pendingAcceptOfferBuyer = <String, String>{};

  /// Signatures of in-flight offer / cancel-offer actions. While non-empty, an
  /// (early) invalidation must not clear the offer loader keys — that would
  /// revert the optimistic Make↔Cancel flip before it indexes.
  /// Cleared on the tx's indexed-ack, which then reconciles against server truth.
  final Set<String> _pendingOfferSigs = <String>{};

  /// Mints whose owner just tapped "Cancel listing" — applied
  /// optimistically on `TxFlowSuccess` so the sheet flips to the
  /// unlisted-owner state without the indexer round-trip.
  final Set<String> _pendingCancellations = <String>{};

  /// Mints where the connected wallet just tapped "Claim NFT" as the auction
  /// winner. Captured at dispatch — while the auction metadata is still intact
  /// — because the account-close socket event can existence-reconcile the
  /// auction away (nulling `currentBidder`) before `TxFlowSuccess` lands, which
  /// would defeat the live-artwork winner check in [claimsOwnershipAfter] and
  /// drop the sheet into the generic indexer-hide gate (a blink-hidden →
  /// re-resolve flicker instead of a straight flip to "List artwork"). Same
  /// dispatch-time capture the accept-offer flow uses ([_pendingAcceptOfferBuyer]).
  final Set<String> _pendingSettleClaim = <String>{};

  /// Winning bidder keyed by mint, captured when the auction seller taps
  /// "Settle" on a won auction. The mirror of [_pendingSettleClaim] for the
  /// seller side — the NFT leaves them for this winner, so the sheet flips to
  /// the unlisted "Make offer" viewer state. Captured at dispatch for the same
  /// race reason (the socket reconcile can null `seller`/`currentBidder` before
  /// the success handler runs [settledWonAuctionWinner]).
  final Map<String, String> _pendingSettleRelinquish = <String, String>{};

  /// Mints the connected wallet just claimed (auction win) or reclaimed
  /// (no-bid auction) — flipped optimistically to owner-unlisted on
  /// `TxFlowSuccess` via `ArtworkEvent.optimisticClaimOwnership`, with
  /// `canList` forced true so the "List artwork" sheet shows immediately.
  /// Tracked so the `indexed`-flip reconcile keeps that optimistic
  /// permission instead of nulling it (a lagging DAS read would otherwise
  /// momentarily hide the just-earned List CTA).
  final Set<String> _pendingClaims = <String>{};

  /// Dedup key for the action-state debug logger so the same resolution
  /// doesn't spam the console on every rebuild.
  String? _lastDebugKey;

  /// True while a `MarketBloc` confirmation/pipeline sheet pushed from this
  /// screen is on-screen. The [BlocConsumer.listenWhen] below fires on every
  /// distinct `TxFlowReady` payload (so simulation refreshes propagate);
  /// without this guard the listener body would push a second sheet on top
  /// of the open one on each within-`TxFlowReady` re-emit.
  bool _marketSheetActive = false;

  /// One-shot timer that fires when the live auction's `endsAt` passes, so the
  /// screen re-resolves the bid/owner sheet into the claim/settle sheet at the
  /// end instant. Owned by the screen rather than the live-panel ticker because
  /// that ticker is unmounted whenever the sheet is hidden (e.g. the
  /// [_pendingIndexerMints] gate after the high bidder's own bid) — leaving
  /// nothing to notice the clock crossing `endsAt`. See
  /// [_scheduleAuctionEndCheck].
  Timer? _auctionEndTimer;

  /// The `endsAt` the [_auctionEndTimer] is currently scheduled for, so a
  /// rebuild with an unchanged deadline doesn't churn the timer.
  DateTime? _scheduledAuctionEnd;

  /// Last market action prepared through [MarketBloc] (from the most recent
  /// `TxFlowReady`). Captured so the terminal `TxFlowFailure` — which carries
  /// no action type — can still classify the failed analytics event.
  String? _lastMarketActionType;

  /// USD value of the last prepared market action's total cost, resolved from
  /// the cached token price at `TxFlowReady` time. Rides on the completed /
  /// failed analytics event (null when no price is cached).
  double? _lastMarketUsd;

  @override
  void initState() {
    super.initState();
    // Subscribe-first: open the invalidation subscription from the
    // known mint in initState — before the first loaded build() — so an
    // invalidation that fires during the initial `/byMint` fetch isn't missed
    // (the socket doesn't replay).
    _maybeStartRealtime(widget.mintAccount);
    // Like failures revert to the pre-tap state, so they can't be observed
    // from the state stream — the bloc reports them out-of-band.
    _transientErrorSub = context.read<ArtworkBloc>().transientErrors.listen((
      message,
    ) {
      if (!mounted) return;
      AppSnackBar.show(context, message, type: AppSnackBarType.error);
    });
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _transientErrorSub?.cancel();
    _auctionEndTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ArtworkBloc, ArtworkState>(
      // Record into "Recently viewed" the first time the artwork resolves (and
      // again only if the screen is reused for a different mint).
      listenWhen: (prev, curr) =>
          curr is ArtworkLoaded &&
          (prev is! ArtworkLoaded ||
              prev.artwork.mintAccount != curr.artwork.mintAccount),
      listener: (context, state) {
        final artwork = (state as ArtworkLoaded).artwork;
        RecentlyViewedRecorder.recordArtwork(
          mintAccount: artwork.mintAccount,
          title: artwork.title,
          thumbnailUrl: artwork.imageUrl,
          artistUsername: artwork.artistUsername,
          editionNumber: artwork.editionNumber,
        );
      },
      child: BlocBuilder<ArtworkBloc, ArtworkState>(
        builder: (context, artworkState) {
          return BlocListener<RaffleBloc, RaffleState>(
            listener: _onRaffleStateChanged,
            child: BlocConsumer<MarketBloc, MarketState>(
              // Fire on:
              //  - any TxFlowReady transition where the prep payload changes
              //    (entering TxFlowReady, OR a within-TxFlowReady re-emit such
              //    as simulation finishing and updating fee/payer-delta data —
              //    the sheet rebuilds off these via its own bloc listener),
              //  - any TxFlowSuccess emission (initial confirm AND the
              //    follow-up `copyWith(indexed: …)` once `checkTx` resolves —
              //    the indexed flip drives the deferred server refresh),
              //  - any TxFlowFailure.
              // `_marketSheetActive` keeps the listener body idempotent so
              // within-TxFlowReady re-emits don't stack a second sheet on top.
              listenWhen: marketArtworkListenWhen,
              listener: (context, state) {
                if (state is TxFlowReady<MarketPrepData, MarketSuccessData>) {
                  final ready = state.data;
                  // Capture before the `_marketSheetActive` early return below
                  // (offer/bid open their sheet before this Ready lands, so the
                  // return would otherwise skip the capture). Feeds the
                  // completed/failed analytics events at the terminal states.
                  _lastMarketActionType = ready.actionType;
                  _lastMarketUsd = sl<TokenPriceService>().usdValueOfRaw(
                    ready.totalCost.rawAmount,
                    ready.totalCost.effectiveCurrencyMint,
                  );
                  if (_marketSheetActive) {
                    // Simulation refresh — the open sheet listens to bloc
                    // state directly and will pick up the new prep data.
                    return;
                  }
                  // Listing-management actions skip the confirmation sheet —
                  // the user already pressed an explicit, dedicated button
                  // (e.g. "Cancel listing") and a second confirm step adds
                  // friction without value. The unified pipeline sheet
                  // drives the signing/broadcasting/success/error UI.
                  if (_skipsConfirmation(ready.actionType)) {
                    context.read<MarketBloc>().add(
                      const MarketEvent.confirmAndSign(),
                    );
                    _showMarketPipelineSheet(ready.actionType);
                    return;
                  }
                  if (artworkState is ArtworkLoaded) {
                    _showConfirmationSheet(ready, artworkState.artwork);
                  }
                } else if (state
                    is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
                  final success = state.result;
                  debugPrint(
                    '[LIST-DEBUG] artwork market-success '
                    'action=${success.actionType} mint=${success.mintAccount} '
                    'indexed=${success.indexed} sig=${state.signature} '
                    'sheetActive=$_marketSheetActive '
                    '@${DateTime.now().toIso8601String()}',
                  );
                  if (success.indexed == null) {
                    // First (chain-confirmed) emission — fire the completed
                    // analytics event once here (the `indexed` flip re-emit is
                    // excluded by the `indexed == null` gate). NFT identity is
                    // the collection, never the per-item mint.
                    final loaded = artworkState is ArtworkLoaded
                        ? artworkState.artwork
                        : null;
                    switch (success.actionType) {
                      case 'buy':
                        unawaited(
                          sl<AnalyticsService>().trackTransaction(
                            AnalyticsEvent.purchaseCompleted,
                            txType: TxType.buyArtwork,
                            signature: state.signature,
                            properties: {
                              AnalyticsProp.collectionId:
                                  loaded?.collectionMint,
                              AnalyticsProp.usdValue: _lastMarketUsd,
                              AnalyticsProp.source: _curationSource(
                                success.mintAccount,
                              ),
                            },
                            entryPoint: EntryPoint.artworkDetail,
                          ),
                        );
                      case 'offer':
                        unawaited(
                          sl<AnalyticsService>().trackTransaction(
                            AnalyticsEvent.offerMade,
                            txType: TxType.makeOffer,
                            signature: state.signature,
                            properties: {
                              AnalyticsProp.collectionId:
                                  loaded?.collectionMint,
                              AnalyticsProp.usdValue: _lastMarketUsd,
                            },
                            entryPoint: EntryPoint.artworkDetail,
                          ),
                        );
                      case 'bid':
                        unawaited(
                          sl<AnalyticsService>().trackTransaction(
                            AnalyticsEvent.bidPlaced,
                            txType: TxType.placeBid,
                            signature: state.signature,
                            properties: {
                              AnalyticsProp.auctionId:
                                  loaded?.auctionMetadata?.auctionAccount,
                              AnalyticsProp.usdValue: _lastMarketUsd,
                            },
                            entryPoint: EntryPoint.artworkDetail,
                          ),
                        );
                    }
                    // First emission — chain confirmed, indexer still
                    // catching up. The pipeline sheet already shows the
                    // action-specific success label, so no snackbar needed.
                    // Every optimistic dispatch is tagged with this signature so
                    // the ArtworkBloc journal can self-drop it once a
                    // fresh byMint read reflects the action.
                    final signature = state.signature;
                    // Raise the bloc's chain floor to the slot our tx landed in
                    // (recorded during confirmation). Any on-chain read whose
                    // view slot predates it must not clear state — the
                    // slot-precise successor to the wall-clock grace window.
                    final landedSlot = sl<TxLandedSlots>().slotFor(signature);
                    if (landedSlot != null) {
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.chainActionLanded(slot: landedSlot),
                      );
                    }
                    final pendingPriceRaw = _pendingPriceUpdates.remove(
                      success.mintAccount,
                    );
                    final wasCancellation = _pendingCancellations.remove(
                      success.mintAccount,
                    );
                    final acceptOfferBuyer = _pendingAcceptOfferBuyer.remove(
                      success.mintAccount,
                    );
                    // Dispatch-time settle-auction outcome (captured before the
                    // socket reconcile could clear the auction metadata). Always
                    // remove so the pins can't leak; the `&&` currentAddress
                    // guard keeps the `me!` in the claim branch safe.
                    final settleClaim =
                        _pendingSettleClaim.remove(success.mintAccount) &&
                        sl<AuthService>().currentAddress != null;
                    final settleRelinquishWinner = _pendingSettleRelinquish
                        .remove(success.mintAccount);
                    if (success.actionType == 'update-listing' &&
                        pendingPriceRaw != null) {
                      // Listing-management path — keep the sheet visible
                      // and flip it to the new (raw) price in place.
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.optimisticListingUpdate(
                          newPriceRaw: pendingPriceRaw,
                          signature: signature,
                        ),
                      );
                    } else if (success.actionType == 'cancel-listing' &&
                        wasCancellation) {
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.optimisticListingUpdate(
                          cancelled: true,
                          signature: signature,
                        ),
                      );
                      // While the listing was active the on-chain owner was
                      // the marketplace escrow, so cached `canList` is
                      // false. Clear it so the next rebuild refetches and
                      // the "List artwork" sheet appears for the now-
                      // unlisted owner.
                      setState(() => _permissions = null);
                    } else if (success.actionType == 'buy' &&
                        artworkState is ArtworkLoaded &&
                        _isEditionMasterArtwork(artworkState.artwork)) {
                      // Edition buy — listing stays live until the last
                      // print, so keep the sheet visible and bump live
                      // supply + per-wallet buy count optimistically. The
                      // sheet's existing "Sold out" / "Wallet limit
                      // reached" branches handle the disabled states once
                      // the increment crosses those thresholds.
                      _applyOptimisticEditionBuy();
                      // Stash the buy signature so we route to the bought print
                      // once the pipeline success sheet closes. The print mint
                      // is resolved from the indexed sale event at that point —
                      // the tx builder's ephemeral key doesn't match the mint
                      // that actually lands on-chain.
                      _pendingEditionBuySig = state.signature;
                    } else if (success.actionType == 'buy') {
                      // 1/1 buy: the buyer takes ownership and the
                      // listing clears, so flip to owner-unlisted immediately —
                      // the buyer sees "List artwork" with no dead-sheet gap
                      // instead of the old indexer hide-gate.
                      final me = sl<AuthService>().currentAddress;
                      if (me != null) {
                        _pendingClaims.add(success.mintAccount);
                        context.read<ArtworkBloc>().add(
                          ArtworkEvent.optimisticClaimOwnership(
                            owner: me,
                            signature: signature,
                          ),
                        );
                        setState(() {
                          _permissions = ArtworkPermissions(
                            canTransfer: true,
                            canEdit: false,
                            canBurn: false,
                            canList: true,
                            // Carry the resolved on-chain royalty forward: this
                            // optimistic value is a RESOLVED read as far as the
                            // Details tab is concerned, so dropping the bps
                            // would flip a Core/pNFT plugin royalty to a
                            // confident "0%" the instant the buy succeeds.
                            onChainRoyaltyBps: _permissions?.onChainRoyaltyBps,
                          );
                        });
                      } else {
                        setState(
                          () => _pendingIndexerMints.add(success.mintAccount),
                        );
                      }
                    } else if (success.actionType == 'offer' ||
                        success.actionType == 'cancel-offer') {
                      // Flip the make ↔ update/cancel affordance immediately
                      // — post-offer the sheet should show Update/Cancel right
                      // away. Keep the sheet visible — no indexer
                      // gate — and pin the loader key so the pre-index
                      // backend read can't revert the optimistic value.
                      // Track the signature so an early invalidation can't clear
                      // the pin before the tx indexes; the indexed ack below
                      // re-opens it for reconciliation.
                      final me = sl<AuthService>().currentAddress;
                      final madeOffer = success.actionType == 'offer';
                      _pendingOfferSigs.add(signature);
                      setState(() {
                        _userOwnOffer = madeOffer;
                        // The amount isn't known from the success payload; the
                        // chain reconcile below fills it in within a beat, and
                        // the indexed-ack reload reconciles server-side truth.
                        _userOwnOfferAmount = null;
                        // A just-made offer's buyer IS the signer; a cancel
                        // keeps the resolved maker so the reconcile poll reads
                        // the right Offer PDA (A1b).
                        if (madeOffer) _userOwnOfferBuyer = me;
                        // Pinned on the same session-set key the loader uses,
                        // or the widened lookup re-runs and reverts the flip.
                        _userOwnOfferLoadedFor = _userOwnOfferKey(
                          success.mintAccount,
                        );
                      });
                      // Confirm the flip against the canonical Offer PDA — on
                      // make-offer this also recovers the on-chain amount so a
                      // follow-up cancel shows the refunded value immediately.
                      unawaited(
                        _reconcileOwnOffer(
                          mintAccount: success.mintAccount,
                          expectPresent: success.actionType == 'offer',
                          signature: signature,
                        ),
                      );
                    } else if (settleClaim ||
                        claimsOwnershipAfter(
                          actionType: success.actionType,
                          currentAddress: sl<AuthService>().currentAddress,
                          artwork: artworkState is ArtworkLoaded
                              ? artworkState.artwork
                              : null,
                        )) {
                      // The connected wallet just took possession of the NFT —
                      // an auction win it claimed, or a no-bid auction the
                      // seller reclaimed. Flip the artwork to owner + unlisted
                      // and force `canList` so the "List artwork" sheet appears
                      // immediately, instead of gating behind the indexer (which
                      // would leave an empty slot until byMint + DAS catch up).
                      final me = sl<AuthService>().currentAddress!;
                      _pendingClaims.add(success.mintAccount);
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.optimisticClaimOwnership(
                          owner: me,
                          signature: signature,
                        ),
                      );
                      setState(() {
                        _permissions = ArtworkPermissions(
                          canTransfer: true,
                          canEdit: false,
                          canBurn: false,
                          canList: true,
                          // Same as the buy branch above — the Royalties row
                          // reads this as a resolved read, so the on-chain bps
                          // has to survive the optimistic flip.
                          onChainRoyaltyBps: _permissions?.onChainRoyaltyBps,
                        );
                      });
                    } else if ((settledWonAuctionWinner(
                              actionType: success.actionType,
                              currentAddress: sl<AuthService>().currentAddress,
                              artwork: artworkState is ArtworkLoaded
                                  ? artworkState.artwork
                                  : null,
                            ) ??
                            settleRelinquishWinner)
                        case final winner?) {
                      // Seller just settled a won auction — the NFT leaves them
                      // for the winning bidder. Optimistically hand ownership to
                      // the winner so the seller resolves to the unlisted
                      // "Make offer" viewer sheet immediately, instead of gating
                      // behind the indexer (which can mis-resolve the stale-owner
                      // seller to an empty no-sheet state).
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.optimisticRelinquishOwnership(
                          newOwner: winner,
                          signature: signature,
                        ),
                      );
                      // Ownership moved away — the cached "can list" permission
                      // (false while escrow held the NFT) is now irrelevant; drop
                      // it so the viewer sheet isn't held back by a stale read.
                      setState(() => _permissions = null);
                    } else if (success.actionType == 'accept-offer' &&
                        acceptOfferBuyer != null) {
                      // The owner accepted an offer — the NFT leaves for the
                      // buyer, so the ex-owner is now a plain viewer.
                      // Hand ownership to the buyer so the sheet flips to the
                      // unlisted "Make offer" viewer state at once, with no
                      // empty-sheet gap.
                      context.read<ArtworkBloc>().add(
                        ArtworkEvent.optimisticRelinquishOwnership(
                          newOwner: acceptOfferBuyer,
                          signature: signature,
                        ),
                      );
                      setState(() => _permissions = null);
                    } else if (success.actionType == 'bid') {
                      // Place bid: keep the sheet visible — the
                      // account-socket overlay + snapshot prime flip it to "You
                      // are the highest bidder" within a beat, so there's no need
                      // to hide it behind the indexer gate.
                    } else {
                      // Other actions: gate the sheet so a stale CTA
                      // doesn't lure a re-tap against pre-index state.
                      setState(() {
                        _pendingIndexerMints.add(success.mintAccount);
                      });
                    }
                  } else {
                    // checkTx resolved — server-truth refetch + clear the
                    // optimistic gate. Webapp parity: invalidate-after-
                    // checkTx semantics (`useBuyNowEA`).
                    // A just-claimed mint already holds an optimistic
                    // owner-with-`canList` state; keep it rather than nulling
                    // permissions, since a lagging DAS re-read could briefly
                    // return `canList=false` and hide the just-earned List CTA.
                    final wasClaim = _pendingClaims.remove(success.mintAccount);
                    // The tx has indexed — release the offer-flip pin so the
                    // reload below reconciles against server truth, which now
                    // reflects the offer/cancel.
                    _pendingOfferSigs.remove(state.signature);
                    setState(() {
                      _pendingIndexerMints.remove(success.mintAccount);
                      // Drop the edition + offer cache keys so build()
                      // re-runs the fetchers and reconciles against server
                      // truth (overwriting the optimistic flips applied on
                      // the first emission).
                      _editionLiveLoadedFor = null;
                      _raffleLiveLoadedFor = null;
                      _editionStatsLoadedFor = null;
                      _userOwnOfferLoadedFor = null;
                      _highestOfferLoadedFor = null;
                      // Other ownership-transferring actions (buy, accept-offer)
                      // change `canList` too. Permissions are derived from the
                      // on-chain owner via DAS and cached once; drop them so
                      // build() re-checks and the now-owner gets the "List
                      // artwork" sheet instead of an empty slot.
                      if (!wasClaim) _permissions = null;
                    });
                    debugPrint(
                      '[LIST-DEBUG] artwork indexed-flip → ArtworkRefresh '
                      'action=${success.actionType} mint=${success.mintAccount} '
                      'wasClaim=$wasClaim @${DateTime.now().toIso8601String()}',
                    );
                    context.read<ArtworkBloc>().add(
                      const ArtworkEvent.refresh(),
                    );
                    // checkEntry acks on the marketplace entry, which is
                    // indexed before the derived event-log row — so this
                    // refresh can re-mount History without the new event.
                    // Poll the feed and refetch once it lands.
                    _reconcileHistory(success.mintAccount, state.signature);
                  }
                } else if (state
                    is TxFlowFailure<MarketPrepData, MarketSuccessData>) {
                  // Drop every dispatch-time optimism pin for this mint — the
                  // tx never landed, so their captured intent is stale and must
                  // not be replayed onto a later, unrelated success for the same
                  // mint. The failure state carries no mint, but this screen is
                  // single-mint, so `widget.mintAccount` is the key. (Pins
                  // captured inside the success handler — `_pendingClaims`,
                  // `_pendingOfferSigs` — never exist at failure time.)
                  _pendingPriceUpdates.remove(widget.mintAccount);
                  _pendingCancellations.remove(widget.mintAccount);
                  _pendingAcceptOfferBuyer.remove(widget.mintAccount);
                  _pendingSettleClaim.remove(widget.mintAccount);
                  _pendingSettleRelinquish.remove(widget.mintAccount);
                  // Kill switch before anything else. This listener fires
                  // for EVERY `TxFlowFailure` — pre- and post-confirm — so it is
                  // the single mid-flow presenter for all of this screen's market
                  // actions. On a kill the screen stays open and idle: the stale
                  // optimism pins above are still dropped (the tx never landed),
                  // but no failure analytics and no error snackbar — the
                  // operator's copy is the whole response.
                  //
                  // Deferred a frame on purpose: on a *pre-confirm* failure
                  // `MarketActionFlowSheet` pops itself from its own listener on
                  // this same emission, and its `Navigator.pop()` would take the
                  // explanation route instead if we pushed synchronously here.
                  if (state.failure.isFlowDisabled) {
                    final failure = state.failure;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      handleFlowDisabled(this.context, failure);
                    });
                    return;
                  }
                  // Only `buy` maps to a failed analytics event here (offer /
                  // bid have no failure event in the taxonomy). The failure
                  // state carries no action type, so use the one captured at
                  // the last `TxFlowReady`.
                  if (_lastMarketActionType == 'buy') {
                    final loaded = artworkState is ArtworkLoaded
                        ? artworkState.artwork
                        : null;
                    unawaited(
                      sl<AnalyticsService>().trackTransaction(
                        AnalyticsEvent.purchaseFailed,
                        txType: TxType.buyArtwork,
                        // No signature: the failure state carries none, and a
                        // confirmed buy would have emitted success instead.
                        isOnchainTx: false,
                        properties: {
                          AnalyticsProp.collectionId: loaded?.collectionMint,
                          AnalyticsProp.usdValue: _lastMarketUsd,
                          AnalyticsProp.reason: analyticsFailureReason(
                            state.failure,
                          ).wire,
                        },
                        entryPoint: EntryPoint.artworkDetail,
                      ),
                    );
                  }
                  AppSnackBar.show(context, state.failure.message);
                }
              },
              builder: (context, marketState) {
                // Persistent action sheets only need to spin during the
                // tx-prepare phase. The unified pipeline sheet owns the
                // signing/broadcasting/success/error UI for every flow,
                // including the auto-confirm management actions.
                final isMarketLoading =
                    marketState
                        is TxFlowPreparing<MarketPrepData, MarketSuccessData>;
                final loaded = artworkState is ArtworkLoaded
                    ? artworkState.artwork
                    : null;
                if (loaded != null) {
                  _maybeLoadPermissions(loaded);
                  _maybeLoadUserOwnOffer(loaded.mintAccount);
                  _maybeLoadHighestOffer(loaded);
                  _maybeLoadCurrencyMetadata(loaded);
                  _maybeLoadEditionStats(loaded);
                  _maybeLoadEditionLive(loaded.mintAccount);
                  _maybeLoadRaffleLive(loaded);
                  _maybeStartRealtime(loaded.mintAccount);
                  _scheduleAuctionEndCheck(loaded);
                } else if (_realtimeSub != null) {
                  _stopRealtime();
                }

                final currentAddress = sl<AuthService>().currentAddress;
                final actionState = loaded == null
                    ? const ArtworkNoAction()
                    : resolveArtworkActionState(
                        artwork: loaded,
                        currentAddress: currentAddress,
                        creatorLinkedAddresses: _creatorLinkedAddresses,
                        sessionAddresses: sl<SessionManager>().sessionAddresses,
                        permissions: _permissions,
                        userOwnOffer: _userOwnOffer,
                        editionState: _editionLive,
                        raffleState: _raffleLive,
                        currencyStatus: sl<TokenMetadataService>().statusOf(
                          _pricingMint(loaded),
                          chain: loaded.chain,
                        ),
                      );
                if (loaded != null) {
                  _debugLogActionState(loaded, currentAddress, actionState);
                }
                // Optimistic gate: hide the action sheet while the indexer
                // catches up so the user doesn't re-tap a stale CTA. The
                // sheet returns once `TxFlowSuccess` `indexed` flips and the
                // ArtworkBloc refresh pulls the post-tx truth.
                //
                // Exception: a just-ended auction. `ArtworkAuctionClaimAction`
                // is a fresh *time-based* CTA (Claim / Settle / Make offer),
                // not the stale pre-index CTA this gate guards against — and the
                // gating wallet is usually the high bidder whose own bid is mid-
                // index. Suppressing here would dismiss the sheet right as the
                // auction ends and never surface the claim actions until the
                // bid finally indexes, so the ended state bypasses the gate.
                final isPendingIndexer =
                    loaded != null &&
                    _pendingIndexerMints.contains(loaded.mintAccount) &&
                    actionState is! ArtworkAuctionClaimAction;
                final sheet = (loaded == null || isPendingIndexer)
                    ? null
                    : _buildArtworkActionSheet(
                        context: context,
                        state: actionState,
                        artwork: loaded,
                        isMarketLoading: isMarketLoading,
                        creatorUsernames: _creatorUsernames,
                        editionStats: _editionStats,
                        editionLive: _editionLive,
                        editionOnChainAllowlisted: _editionOnChainAllowlisted,
                        editionHoldsGatingNft: _editionHoldsGatingNft,
                        onBuy: _onBuy,
                        onMakeOffer: _onMakeOffer,
                        onCancelOffer: _onCancelOffer,
                        highestOffer: _highestOffer,
                        onAcceptHighestOffer: _onAcceptHighestOffer,
                        onListUnlisted: _onListUnlisted,
                        onSendArtwork: _handleTransfer,
                        onUpdateListing: _onUpdateListing,
                        onPlaceBid: _onPlaceBid,
                        onCancelAuction: _onCancelAuction,
                        onSettleAuction: _onSettleAuction,
                        onAuctionEnded: _onAuctionEnded,
                        onBuyRaffleTickets: _onBuyRaffleTickets,
                        onCancelRaffle: _onCancelRaffle,
                        onClaimRaffleNft: _onClaimRaffleNft,
                        onClaimRaffleProceeds: _onClaimRaffleProceeds,
                      );
                // Reserve enough room below the scroll for the sticky sheet.
                // The sheet's frame already includes the device bottom inset
                // (home indicator + cast bar height when active — both ride
                // on `MediaQuery.padding.bottom` via the root
                // `CastBarMediaQueryInset`), so the measured height covers
                // both. Falls back to [_fallbackSheetHeight] + bottom inset
                // for the very first frame before measurement lands. With no
                // sheet there's nothing to clear the inset, so pad by it
                // directly to keep the History/Offers content off the home
                // indicator / cast bar.
                final stickyHeight = sheet != null
                    ? (_measuredSheetHeight ??
                          _fallbackSheetHeight +
                              MediaQuery.of(context).padding.bottom)
                    : MediaQuery.of(context).padding.bottom;

                return Scaffold(
                  backgroundColor: context.mallowColors.bgPrimary,
                  body: Stack(
                    children: [
                      _buildScrollContent(
                        context,
                        artworkState,
                        bottomPad: stickyHeight,
                      ),
                      if (sheet != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _MeasureSize(
                            onChange: (size) {
                              if (!mounted) return;
                              if (_measuredSheetHeight == size.height) return;
                              setState(
                                () => _measuredSheetHeight = size.height,
                              );
                            },
                            child: AnimatedSheetReveal(child: sheet),
                          ),
                        ),
                      if (kDebugMode && loaded != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: MediaQuery.of(context).padding.top + 48,
                          child: _ActionStateDebugBanner(
                            artwork: loaded,
                            currentAddress: currentAddress,
                            permissions: _permissions,
                            creatorLinkedAddresses: _creatorLinkedAddresses,
                            actionState: actionState,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// `BlocConsumer.listenWhen` predicate for the [MarketBloc] emissions handled
/// by `_ArtworkDetailViewState`. Exposed at top level so it can be unit-tested
/// without spinning up the screen widget — the listener body is the only
/// piece of behavior that requires a `BuildContext`. Fires on:
///  * transition INTO `TxFlowReady`, OR a `TxFlowReady → TxFlowReady`
///    re-emit with a changed payload (simulation resolving and populating
///    fee / payer-delta data — the open confirmation sheet rebuilds off
///    this via its own bloc listener; the screen listener is guarded
///    against pushing a second sheet on top by `_marketSheetActive`),
///  * any transition into `TxFlowSuccess`, AND a `TxFlowSuccess →
///    TxFlowSuccess` re-emit where `indexed` flipped (the deferred server
///    refresh is gated on that flip),
///  * any `TxFlowFailure`.
/// Whether [currentAddress] takes possession of the NFT as a result of a
/// just-confirmed auction [actionType], so the screen can optimistically flip
/// the bottom sheet to owner-unlisted ("List artwork") without waiting for the
/// indexer. Exposed at top level for unit testing.
///
///  * `cancel-auction` / `reclaim-auction` — the seller reclaims the NFT
///    (cancelling an active auction, or reclaiming after a no-bid expiry),
///    so the caller always becomes the owner.
///  * `settle-auction` — fired by both the winner ("Claim NFT") and a seller
///    settling an auction with bids. Only the winner takes ownership; the
///    seller's NFT goes to the winner. The winner is the high bidder, so the
///    caller owns it iff it is the current high bidder.
@visibleForTesting
bool claimsOwnershipAfter({
  required String actionType,
  required String? currentAddress,
  required ArtworkDetails? artwork,
}) {
  if (currentAddress == null) return false;
  switch (actionType) {
    case 'cancel-auction':
    case 'reclaim-auction':
      return true;
    case 'settle-auction':
      return artwork?.auctionMetadata?.currentBidder == currentAddress;
    default:
      return false;
  }
}

/// Returns the winning bidder's address when [currentAddress] is the seller who
/// just settled a *won* auction (so the NFT leaves them for the winner), else
/// null. The complement of [claimsOwnershipAfter] for `settle-auction`: the
/// winner takes ownership, the seller relinquishes it. Used to optimistically
/// flip the seller's bottom sheet to the unlisted "Make offer" viewer state.
/// Exposed at top level for unit testing.
@visibleForTesting
String? settledWonAuctionWinner({
  required String actionType,
  required String? currentAddress,
  required ArtworkDetails? artwork,
}) {
  if (actionType != 'settle-auction' || currentAddress == null) return null;
  final auction = artwork?.auctionMetadata;
  final winner = auction?.currentBidder;
  if (auction == null || winner == null) return null;
  // Seller (not the winner) settling an auction that drew bids.
  if (auction.seller != currentAddress) return null;
  if (winner == currentAddress) return null;
  if (auction.bidCount <= 0) return null;
  return winner;
}

@visibleForTesting
bool marketArtworkListenWhen(MarketState previous, MarketState current) {
  if (current is TxFlowReady<MarketPrepData, MarketSuccessData>) {
    if (previous is! TxFlowReady<MarketPrepData, MarketSuccessData>) {
      return true;
    }
    return previous.data != current.data;
  }
  if (current is TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
    if (previous is! TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      return true;
    }
    return previous.result.indexed != current.result.indexed;
  }
  return current is TxFlowFailure<MarketPrepData, MarketSuccessData>;
}
