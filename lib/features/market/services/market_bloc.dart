import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/network/das_api_service.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/network/v2_fallback.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/marketplace_action_flow.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/stale_tx_tracker.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/data/mallow_tokens.dart' show solMint;
import '../../artwork/data/market_account_repository.dart';
import '../../artwork/models/on_chain_asset.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/artwork_permission_service.dart';
import '../../curations/services/curation_attribution_store.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../../sale/services/direct_proceeds.dart';
import '../../sale/services/marketplace_config_service.dart';
import '../../sale/services/proceeds_calculator.dart'
    show computeProceedsSplits, kMallowFeeAddress;
import '../models/market_price.dart';
import 'can_accept_offer.dart';
import 'edition_buy_routing.dart';

export '../../../core/services/transaction_flow_state.dart';
export '../models/market_price.dart' show MarketPrice;

part 'market_bloc.freezed.dart';

// Sentinel for copyWith — lets callers pass explicit null without conflating
// "leave unchanged" with "set to null".
const Object _sentinel = Object();

/// Market `actionType`s that change the connected wallet's own art (ownership
/// or listing state shown on the My Art tab), so their indexer ack triggers a
/// portfolio refetch. `burn` removes art too but runs through a transient
/// [MarketBloc] that's closed before its ack lands, so the burn flow signals
/// directly instead (see `burn_artwork_flow.dart`).
const _portfolioAffectingActions = {
  'buy',
  'accept-offer',
  'cancel-listing',
  'update-listing',
  'cancel-auction',
  'reclaim-auction',
  'settle-auction',
};

@freezed
sealed class MarketEvent with _$MarketEvent {
  /// [pricePerUnit] is the per-unit listing price (raw atomic amount +
  /// currency mint) — used purely for the confirmation sheet's display
  /// total. The actual lamport/atomic amount is already baked into the
  /// server-built compiled tx, so passing the wrong value here only
  /// mis-renders the UI; it won't affect the on-chain transfer. The
  /// bloc multiplies by [quantity] to get the total cost.
  ///
  /// **[buyerSetsPrice] is the one exception to that.** It mirrors the
  /// listing's SYOP ("set your own price") flag; when true, [pricePerUnit] is
  /// the buyer's *entered* amount and IS sent on the wire as `maxPrice`. A SYOP
  /// listing's on-chain price is 0 and both v2 builders default `maxPrice` to
  /// `listing.price` (the fixed-price builder's
  /// `req.max_price.unwrap_or(listing.price)`),
  /// so leaving it off pays the artist nothing. A missing or non-positive
  /// entered amount fails the prepare instead of buying at 0 (webapp
  /// `BuyEditionModal` refuses the same way).
  ///
  /// [isPrintableMasterEdition] is the *authoritative* answer to "does this buy
  /// mint a print?" — the caller resolves it with
  /// [resolvePrintableMasterEdition] from the live DAS edition state / the
  /// server's `isMasterEdition` flag, which is the same signal (and the same
  /// priority order) the action sheet routes on. Null falls back to
  /// [supplyType], which cannot tell a secondary `edition-print` from a master
  /// — so pass it wherever the edition state is on hand.
  const factory MarketEvent.buy({
    required String mintAccount,
    required SupplyType supplyType,
    @Default(1) int quantity,
    MarketPrice? pricePerUnit,
    @Default(false) bool buyerSetsPrice,
    bool? isPrintableMasterEdition,
  }) = MarketBuy;

  /// Place a bid on an active auction. Distinct from [MarketMakeOfferV2]
  /// (offers on unlisted artworks). [amount] is in the listing's
  /// currency atomic units.
  const factory MarketEvent.placeBid({
    required String mintAccount,
    required MarketPrice amount,
  }) = MarketPlaceBid;

  /// Make an offer on an unlisted or buy-now artwork via dedicated
  /// `getMakeOfferTx` route. [amount] is in the listing's currency atomic
  /// units.
  const factory MarketEvent.makeOfferV2({
    required String mintAccount,
    required MarketPrice amount,
    @Default(true) bool oneOfOneOnly,
  }) = MarketMakeOfferV2;

  /// Cancel an active offer the connected wallet placed. [amount] is the
  /// offer's escrowed value (in its currency's atomic units) so the confirm
  /// sheet's "Total returned" reflects the refunded amount on top of the
  /// reclaimed PDA rent. Null falls back to rent-only when the amount isn't
  /// known to the caller.
  const factory MarketEvent.cancelOffer({
    required String mintAccount,
    MarketPrice? amount,
  }) = MarketCancelOffer;

  /// Accept [buyer]'s offer on [mintAccount] as the owner. Builds the
  /// seller-signed `acceptOffer` (or `delistAndAcceptOffer`) tx via
  /// `POST /v2/tx/offers/accept`. [amount] is the offer's value in
  /// its currency's atomic units — used for the success UI only; the
  /// proceeds are inflow, so no balance gate applies.
  /// [disablePrimarySplit] mirrors the listing's flag: when true (the default,
  /// matching webapp's `AcceptNftOfferModal`), a primary sale is split like a
  /// secondary one — creators get only their royalty %, the seller keeps the
  /// rest. The confirmation sheet's "Direct all proceeds to creators" toggle
  /// re-dispatches with `false` to route the full primary split to creators.
  const factory MarketEvent.acceptOffer({
    required String mintAccount,
    required String buyer,
    required MarketPrice amount,
    @Default(true) bool disablePrimarySplit,
  }) = MarketAcceptOffer;

  /// Re-prepare the pending accept-offer with a flipped split, driven by the
  /// confirmation sheet's "Direct all proceeds to creators" toggle. Re-uses the
  /// mint/buyer/amount captured when [MarketAcceptOffer] first ran (see
  /// [_pendingAcceptArgs]) so the sheet sends only the new value — it doesn't
  /// rebuild the full event from display-only prep fields (`totalCost`). A
  /// failed re-prepare reverts to the previous ready tx rather than tearing the
  /// sheet down.
  const factory MarketEvent.setAcceptOfferSplit({
    required bool disablePrimarySplit,
  }) = MarketSetAcceptOfferSplit;

  /// Cancel a buy-now listing (delistNft / delistEditions branched
  /// server-side). Phase 4.
  const factory MarketEvent.cancelListing({required String mintAccount}) =
      MarketCancelListing;

  /// Update the listing's price (the on-chain `updateListing` ix is
  /// price-only — currency / end time / buyer-sets-price aren't mutable).
  /// [newPrice] is in the listing's currency atomic units.
  const factory MarketEvent.updateListing({
    required String mintAccount,
    required MarketPrice newPrice,
  }) = MarketUpdateListing;

  /// Cancel an active auction (no bids) OR reclaim NFT after a no-bid
  /// expiry. Phase 5. Both dispatch the same on-chain `cancelAuction` ix;
  /// [reclaim] only picks the user-facing copy — `true` for the post-expiry
  /// reclaim ("Reclaim NFT"), `false` for cancelling a still-active auction.
  const factory MarketEvent.cancelAuction({
    required String mintAccount,
    @Default(false) bool reclaim,
  }) = MarketCancelAuction;

  /// Settle an ended auction. Single ix covers BOTH seller-payout AND
  /// winner-NFT-transfer — the wallet sends `caller = currentAddress` and
  /// the program does the right thing.
  ///
  /// [winningBid] is the gross escrowed bid (raw amount + bid mint). It's
  /// supplied ONLY when the connected wallet is the auction seller and the
  /// auction drew bids — it triggers the simulation-derived net-proceeds
  /// breakdown on the confirmation sheet. The winner-claim path (same ix) and
  /// no-bid reclaim leave it null, so the sheet shows the gas-only row.
  const factory MarketEvent.settleAuction({
    required String mintAccount,
    MarketPrice? winningBid,
  }) = MarketSettleAuction;

  /// Burn an owned NFT (or Core Collection master). Resolves token
  /// standard + print-edition info from DAS / artwork lookup, then
  /// dispatches to `POST /v2/tx/assets/burn`.
  ///
  /// [isCollection] marks the mint as a collection NFT: it skips the
  /// print-edition artwork lookup (collection NFTs aren't in the artwork
  /// index, so `getArtworkByMint` would 404 for legacy standards).
  const factory MarketEvent.burn({
    required String mintAccount,
    @Default(false) bool isCollection,
  }) = MarketBurn;

  const factory MarketEvent.simulate() = MarketSimulate;
  const factory MarketEvent.confirmAndSign() = MarketConfirmAndSign;
  const factory MarketEvent.reset() = MarketReset;

  /// Internal — emitted by the background `_runCheckTx` poll once the
  /// indexer acks the tx (or gives up). Drives the [MarketSuccessData.indexed]
  /// flag listeners watch to trigger their server-truth refetch.
  const factory MarketEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = MarketIndexedAck;
}

/// Seller's net-proceeds breakdown for a seller-side payout (auction settle or
/// accept-offer), all in the escrowed amount's currency ([currencyMint]) as raw
/// atomic units. Populated only when the connected wallet is the seller; the
/// confirmation sheet renders it as an earnings headline plus a "Fee details"
/// disclosure (gross − mallow fee − royalties).
///
/// [grossBidRaw] / [currencyMint] are known at prep time. The amounts the
/// seller actually nets ([sellerEarningsRaw], [marketFeeRaw],
/// [royaltiesToOthersRaw]) are derived from the tx **simulation** — fee bps
/// can't be re-derived reliably client-side (discount tokens, stale
/// listingFees) — so they stay null until [isResolved] flips.
///
/// [royaltiesToOthersRaw] is `gross − mallowFee − earnings`: it's whatever
/// reaches OTHER creators. Any royalty the seller earns as a creator lands in
/// the seller's own token account, so it's already inside [sellerEarningsRaw].
class SettleProceeds extends Equatable {
  const SettleProceeds({
    required this.grossBidRaw,
    required this.currencyMint,
    this.sellerEarningsRaw,
    this.marketFeeRaw,
    this.royaltiesToOthersRaw,
  });

  final int grossBidRaw;
  final String? currencyMint;
  final int? sellerEarningsRaw;
  final int? marketFeeRaw;
  final int? royaltiesToOthersRaw;

  /// True once the simulation has resolved the actual on-chain amounts.
  bool get isResolved => sellerEarningsRaw != null;

  SettleProceeds copyWith({
    int? sellerEarningsRaw,
    int? marketFeeRaw,
    int? royaltiesToOthersRaw,
  }) => SettleProceeds(
    grossBidRaw: grossBidRaw,
    currencyMint: currencyMint,
    sellerEarningsRaw: sellerEarningsRaw ?? this.sellerEarningsRaw,
    marketFeeRaw: marketFeeRaw ?? this.marketFeeRaw,
    royaltiesToOthersRaw: royaltiesToOthersRaw ?? this.royaltiesToOthersRaw,
  );

  @override
  List<Object?> get props => [
    grossBidRaw,
    currencyMint,
    sellerEarningsRaw,
    marketFeeRaw,
    royaltiesToOthersRaw,
  ];
}

/// What one DAS read of a seller-side payout's asset answers: whether to offer
/// the "Direct all proceeds to creators" toggle, plus the primary/secondary
/// classification and on-chain royalties the arithmetic proceeds fallback is
/// computed from. [seller] / [royalties] are null when the read failed — the
/// only state in which no fallback can be produced.
typedef _ProceedsGate = ({
  bool showOption,
  String? seller,
  bool isSecondary,
  ResolvedRoyalties? royalties,
});

/// Accounts + gross the settle simulation inspects to resolve seller proceeds.
/// For an SPL bid mint these are the seller's and mallow fee account's
/// associated token accounts (token-amount deltas); for a native-SOL bid mint
/// they're the seller and fee wallet addresses (lamport deltas). Internal
/// plumbing — the confirmation sheet only reads [SettleProceeds].
class SettleSimInputs extends Equatable {
  const SettleSimInputs({
    required this.sellerAccount,
    required this.feeAccount,
    required this.isNative,
    required this.grossRaw,
  });

  final String sellerAccount;
  final String feeAccount;
  final bool isNative;
  final int grossRaw;

  @override
  List<Object?> get props => [sellerAccount, feeAccount, isNative, grossRaw];
}

/// Data the confirmation sheet needs once the tx is built.
///
/// [transactionsBase64] is an ordered list of base64-encoded compiled
/// transactions. Single-tx flows emit a one-element list. Multi-tx flows
/// (edition buys with `quantity > 1`) emit one entry per print.
/// Simulation only runs against the first tx.
///
/// [totalCost] carries the listing's currency mint alongside the raw
/// atomic amount so the confirmation sheet can render the correct
/// symbol + decimals.
class MarketPrepData extends Equatable {
  const MarketPrepData({
    required this.transactionsBase64,
    required this.mintAccount,
    required this.actionType,
    required this.flow,
    required this.totalCost,
    required this.estimatedFeeLamports,
    this.mallowFeeLamports,
    this.settleProceeds,
    this.settleSimInputs,
    this.settleProceedsFallback,
    this.disablePrimarySplit = false,
    this.showDirectProceedsOption = false,
    this.hasSetupTx = false,
    this.isSimulating = false,
    this.simulationResult,
    this.simulatedPayerLamportsDelta,
  });

  final List<String> transactionsBase64;
  final String mintAccount;
  final String actionType;

  /// Kill-switch cell for the action this payload was prepared for. Distinct
  /// from [actionType], which is display/refresh plumbing and cannot tell a
  /// 1/1 buy from an edition buy (both are `'buy'`).
  final AppFlow flow;

  final MarketPrice totalCost;
  final int estimatedFeeLamports;

  /// Flat "mallow fee" (the on-chain per-print `feeConfig.printFee`, times
  /// quantity) the buyer pays on top of the listing price. Set only on the
  /// edition-buy path; null for every other action (1/1 buys, bids, offers,
  /// etc.) so the confirmation sheet only renders the extra line for editions.
  final int? mallowFeeLamports;

  /// Seller's settle-auction proceeds breakdown — non-null only on the
  /// seller-with-bids settle path; null for winner-claim / no-bid settles and
  /// every other action. Its amounts stay null until [_onSimulate] resolves
  /// them from the simulation.
  final SettleProceeds? settleProceeds;

  /// Inspection inputs the settle simulation uses to resolve [settleProceeds];
  /// paired with it (both set on the seller-with-bids path, both null
  /// otherwise).
  final SettleSimInputs? settleSimInputs;

  /// Already-resolved [SettleProceeds] computed as pure arithmetic from the
  /// on-chain royalties + marketplace fee bps (webapp `getProceedsSplits`),
  /// used when the simulation can't answer.
  ///
  /// The simulation stays the *preferred* source — it reflects the fee the
  /// program will actually charge, including a discount token the client can't
  /// see. But it needs three RPC round-trips against a chain that can be
  /// unreachable, and without a fallback "You'll receive" simply never resolved
  /// while the user was being asked to confirm an irreversible sale. Null when
  /// the royalty/fee inputs couldn't be read, which is the only case that still
  /// shimmers indefinitely.
  final SettleProceeds? settleProceedsFallback;

  /// Current value of the accept-offer's `disablePrimarySplit` flag (see
  /// [MarketAcceptOffer]). Drives the toggle's checked state. Meaningful only
  /// when [showDirectProceedsOption] is true.
  final bool disablePrimarySplit;

  /// Whether the accept-offer sheet should show the "Direct all proceeds to
  /// creators" toggle. Mirrors webapp's `showDirectProceedsOption`: a primary
  /// sale with creator shares where the seller isn't the first creator.
  final bool showDirectProceedsOption;

  /// True when [transactionsBase64] leads with a prerequisite **setup**
  /// transaction rather than the action itself — today only the edition buy's
  /// on-chain-allowlist `initProofs` tx (`BuyEditionTxsResponse.setupTx`).
  ///
  /// Only [_onSimulate] cares: neither transaction can be usefully simulated
  /// here. The setup tx's lamport delta is rent for the `proofs` PDA, not the
  /// purchase, and the buy tx behind it reads an account that does not exist
  /// until the setup lands, so it fails simulation for a reason that isn't a
  /// problem. Skipping leaves the breakdown on its static fee estimate instead
  /// of showing a confidently wrong number or a false failure banner.
  final bool hasSetupTx;

  final bool isSimulating;
  final SimulationResult? simulationResult;

  /// Signed net change in the payer's lamport balance under simulation,
  /// when known. Positive means the user gains SOL (e.g. rent reclaim
  /// on a burn); negative means they spend SOL beyond just the network
  /// fee. Already includes the deducted tx fee.
  final int? simulatedPayerLamportsDelta;

  MarketPrepData copyWith({
    List<String>? transactionsBase64,
    String? mintAccount,
    String? actionType,
    AppFlow? flow,
    MarketPrice? totalCost,
    int? estimatedFeeLamports,
    int? mallowFeeLamports,
    SettleProceeds? settleProceeds,
    SettleSimInputs? settleSimInputs,
    SettleProceeds? settleProceedsFallback,
    bool? disablePrimarySplit,
    bool? showDirectProceedsOption,
    bool? hasSetupTx,
    bool? isSimulating,
    Object? simulationResult = _sentinel,
    Object? simulatedPayerLamportsDelta = _sentinel,
  }) => MarketPrepData(
    transactionsBase64: transactionsBase64 ?? this.transactionsBase64,
    mintAccount: mintAccount ?? this.mintAccount,
    actionType: actionType ?? this.actionType,
    flow: flow ?? this.flow,
    totalCost: totalCost ?? this.totalCost,
    estimatedFeeLamports: estimatedFeeLamports ?? this.estimatedFeeLamports,
    mallowFeeLamports: mallowFeeLamports ?? this.mallowFeeLamports,
    settleProceeds: settleProceeds ?? this.settleProceeds,
    settleSimInputs: settleSimInputs ?? this.settleSimInputs,
    settleProceedsFallback:
        settleProceedsFallback ?? this.settleProceedsFallback,
    disablePrimarySplit: disablePrimarySplit ?? this.disablePrimarySplit,
    showDirectProceedsOption:
        showDirectProceedsOption ?? this.showDirectProceedsOption,
    hasSetupTx: hasSetupTx ?? this.hasSetupTx,
    isSimulating: isSimulating ?? this.isSimulating,
    simulationResult: identical(simulationResult, _sentinel)
        ? this.simulationResult
        : simulationResult as SimulationResult?,
    simulatedPayerLamportsDelta:
        identical(simulatedPayerLamportsDelta, _sentinel)
        ? this.simulatedPayerLamportsDelta
        : simulatedPayerLamportsDelta as int?,
  );

  @override
  List<Object?> get props => [
    transactionsBase64,
    flow,
    mintAccount,
    actionType,
    totalCost,
    estimatedFeeLamports,
    mallowFeeLamports,
    settleProceeds,
    settleSimInputs,
    settleProceedsFallback,
    disablePrimarySplit,
    showDirectProceedsOption,
    hasSetupTx,
    isSimulating,
    simulationResult,
    simulatedPayerLamportsDelta,
  ];
}

/// Domain data the success sheet needs.
class MarketSuccessData extends Equatable {
  const MarketSuccessData({
    required this.explorerUrl,
    required this.actionType,
    required this.mintAccount,
    this.indexed,
  });

  final String explorerUrl;
  final String actionType;
  final String mintAccount;

  /// Indexer-ack flag — `null` while polling, `true` on ack, `false` after
  /// retries exhaust. Listeners apply local optimistic flips immediately and
  /// refetch when this flips.
  final bool? indexed;

  MarketSuccessData copyWith({Object? indexed = _sentinel}) =>
      MarketSuccessData(
        explorerUrl: explorerUrl,
        actionType: actionType,
        mintAccount: mintAccount,
        indexed: identical(indexed, _sentinel)
            ? this.indexed
            : indexed as bool?,
      );

  @override
  List<Object?> get props => [explorerUrl, actionType, mintAccount, indexed];
}

/// Generic alias for the unified flow state with market-specific payloads.
typedef MarketState = TransactionFlowState<MarketPrepData, MarketSuccessData>;

@injectable
class MarketBloc extends Bloc<MarketEvent, MarketState> {
  MarketBloc(
    this._api,
    this._apiV2,
    this._walletManager,
    this._rpcService,
    this._authService,
    this._dasApi,
    this._flow,
    this._priceService,
    this._feeConfig,
    this._marketplaceConfig,
    this._marketAccounts,
    this._curationAttribution,
  ) : super(const TxFlowIdle()) {
    on<MarketBuy>(_onBuy);
    on<MarketPlaceBid>(_onPlaceBid);
    on<MarketMakeOfferV2>(_onMakeOfferV2);
    on<MarketCancelOffer>(_onCancelOffer);
    on<MarketAcceptOffer>(_onAcceptOffer);
    on<MarketSetAcceptOfferSplit>(_onSetAcceptOfferSplit);
    on<MarketCancelListing>(_onCancelListing);
    on<MarketUpdateListing>(_onUpdateListing);
    on<MarketCancelAuction>(_onCancelAuction);
    on<MarketSettleAuction>(_onSettleAuction);
    on<MarketBurn>(_onBurn);
    on<MarketSimulate>(_onSimulate);
    on<MarketConfirmAndSign>(_onConfirmAndSign);
    on<MarketReset>(_onReset);
    on<MarketIndexedAck>(_onIndexedAck);
  }

  final MallowApiClient _api;
  final MallowApiV2Client _apiV2;
  final WalletManager _walletManager;
  final SolanaRpcService _rpcService;
  final AuthService _authService;
  final DasApiService _dasApi;
  final MarketplaceActionFlow _flow;
  final TokenPriceService _priceService;
  final FeeConfig _feeConfig;
  final MarketplaceConfigService _marketplaceConfig;

  /// On-chain `Listing` / `AuctionConfig` PDA reads — the authoritative
  /// listing state the accept-offer pre-flight gate is derived from.
  final MarketAccountRepository _marketAccounts;

  /// Which curation surfaced the artwork, if any. Read here rather than at the
  /// dispatch sites so every buy entry point — artwork detail, the SYOP sheet,
  /// any future dispatcher — carries the attribution without wiring.
  final CurationAttributionStore _curationAttribution;

  /// Stale-blockhash recovery for server-co-signed tx batches.
  final _txTracker = StaleTxTracker<List<String>>();

  /// Signature of an optimistic success whose `reset()` we deferred because
  /// its indexer ack was still in flight. The pipeline sheet pops ~800ms after
  /// the `indexed=null` success and resets — but the entry-indexing poll lands
  /// seconds later, so resetting then would drop the ack on an idle state and
  /// the screen would never see the `indexed` flip (no post-tx refresh, no
  /// pending-indexer gate clear → the bid sheet stays hidden). We hold the
  /// reset until [_onIndexedAck] applies the flip, then go idle. Keyed by
  /// signature so a reset for a superseded success can't idle a newer flow.
  String? _pendingResetSig;

  /// Args from the last [MarketAcceptOffer] so a [MarketSetAcceptOfferSplit]
  /// toggle can re-prepare the tx without the sheet reconstructing the event
  /// from display-only prep fields (`totalCost` is documented display-only, and
  /// the buyer would otherwise have to be round-tripped through the prep).
  ({String mint, String buyer, MarketPrice amount})? _pendingAcceptArgs;

  /// Generation token for accept-offer prepares — an equivalent of a
  /// `restartable()` transformer without the extra dependency. Bumped
  /// synchronously at the start of each prepare (before any await), so an older
  /// prepare that resumes after its DAS/build awaits detects it lost the race
  /// (its captured gen != the latest) and aborts without emitting a stale
  /// TxFlowReady. Combined with emitting TxFlowPreparing up front, this also
  /// guarantees a Confirm tap during a re-prepare can't sign the pre-toggle tx.
  int _acceptPrepGen = 0;

  /// Adapts [MarketState] (which *is* a [TransactionFlowState]) to the
  /// shared [MarketplaceActionFlow] lifecycle callbacks.
  ActionFlowSink<MarketPrepData, MarketSuccessData> _sink(
    Emitter<MarketState> emit,
  ) => txFlowSink<MarketPrepData, MarketSuccessData>(
    (next) => _emitFlow(emit, next),
  );

  /// Emit [next], first flushing the indexer ack of an optimistic success this
  /// emission would abandon.
  ///
  /// [_onIndexedAck] drops an ack that lands once the state moved on
  /// (`state is! TxFlowSuccess`), which is right — but it means a *second*
  /// action started before the first ack arrives (accept an offer, then open
  /// another market flow) strands the first flow on `indexed == null` forever.
  /// Every consumer gates its post-tx refetch on that flip — the offers inbox
  /// refresh (`offers_screen._onMarketState`) and the artwork screen's
  /// `_pendingIndexerMints` clear + `ArtworkRefresh` — so the just-resolved row
  /// keeps a live Accept/Cancel pill re-prompting against a closed Offer PDA
  /// until a manual pull-to-refresh. [_onReset] already defends the
  /// reset-lands-first case; this defends the new-flow case.
  ///
  /// `indexed: false` is the honest value (the poll never came back) and is
  /// what the poll-timeout ack would have carried; both consumers treat
  /// `true`/`false` identically — refetch server truth. Flipping here also
  /// guarantees exactly ONE flip per flow: the real ack, if it still lands,
  /// now hits [_onIndexedAck]'s `state is! TxFlowSuccess` drop path.
  void _emitFlow(Emitter<MarketState> emit, MarketState next) {
    final current = state;
    if (current is TxFlowSuccess<MarketPrepData, MarketSuccessData> &&
        current.result.indexed == null &&
        next is! TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      debugPrint(
        '[LIST-DEBUG] MarketBloc pending ack FLUSHED (superseded by '
        '${next.runtimeType}) → indexed=false '
        'action=${current.result.actionType} sig=${current.signature} '
        '@${DateTime.now().toIso8601String()}',
      );
      emit(
        TxFlowSuccess(
          signature: current.signature,
          result: current.result.copyWith(indexed: false),
        ),
      );
      if (_portfolioAffectingActions.contains(current.result.actionType)) {
        notifyPortfolioRefresh();
      }
      // A reset deferred for this success can never be honored now (its ack
      // will be dropped), and [next] supersedes the idle it wanted anyway.
      _pendingResetSig = null;
    }
    emit(next);
  }

  /// Builds the ready-payload every prepare handler emits — the per-action
  /// `totalCost` / `actionType` differ, the rest is identical.
  MarketPrepData _prep(
    List<String> txs, {
    required String mintAccount,
    required String actionType,
    required AppFlow flow,
    required MarketPrice totalCost,
    int? mallowFeeLamports,
    SettleProceeds? settleProceeds,
    SettleSimInputs? settleSimInputs,
    SettleProceeds? settleProceedsFallback,
    bool disablePrimarySplit = false,
    bool showDirectProceedsOption = false,
    bool hasSetupTx = false,
  }) => MarketPrepData(
    transactionsBase64: txs,
    mintAccount: mintAccount,
    actionType: actionType,
    flow: flow,
    totalCost: totalCost,
    estimatedFeeLamports: _feeConfig.baseTxFeeLamports,
    mallowFeeLamports: mallowFeeLamports,
    settleProceeds: settleProceeds,
    settleSimInputs: settleSimInputs,
    settleProceedsFallback: settleProceedsFallback,
    disablePrimarySplit: disablePrimarySplit,
    showDirectProceedsOption: showDirectProceedsOption,
    hasSetupTx: hasSetupTx,
  );

  Future<void> _onBuy(MarketBuy event, Emitter<MarketState> emit) async {
    final perUnit = event.pricePerUnit ?? MarketPrice.zero();
    // The per-unit amount travels on the wire as `maxPrice` — a slippage
    // ceiling, not the amount charged: the program fills at `listing.price` and
    // fails if that exceeds the ceiling.
    //
    // * SYOP listings: the buyer's *entered* amount, without which the builder
    //   falls back to the listing's on-chain price of 0 and the artist is paid
    //   nothing.
    // * Every other buy: the price the sheet showed the buyer — the
    //   *indexed* one. Omitting it let the backend settle at whatever
    //   `listing.price` read at build time, so a price raised in the window
    //   between the indexer snapshot and the build was charged silently, with
    //   no ceiling at all. Webapp parity: `useBuyNow` passes
    //   `maxPrice: price.toNumber()` on the edition path and hands `buyNft` the
    //   listing it read itself on the 1/1 path.
    //
    // A zero-or-absent price on a non-SYOP buy sends nothing, keeping the
    // backend's `unwrap_or(listing.price)`: `artwork.price` is null-coalesced
    // to 0 by the caller, and a 0 ceiling would refuse every paid listing.
    //
    // Only an *absent* price is refused, matching the webapp's single check
    // (`BuyEditionModal.onBuyClick`: `buyerUIPrice == null` → "Please enter a
    // price"). An entered `0` is allowed through and settles at 0 — a SYOP
    // seller opted into naming no floor, so that is their outcome, not a bug.
    // This is why the null test is on `event.pricePerUnit` and not on
    // `perUnit`/`maxPrice`, which collapse absent and zero into the same value.
    if (event.buyerSetsPrice && event.pricePerUnit == null) {
      _emitFlow(
        emit,
        const TxFlowFailure(
          AppFailure.unknown('Please enter a price for this listing'),
        ),
      );
      return;
    }
    final maxPrice = event.buyerSetsPrice || perUnit.rawAmount > 0
        ? perUnit.rawAmount.round()
        : null;
    // Which builder this buy goes to. Resolved through the shared
    // [resolvePrintableMasterEdition] so the builder and the action sheet
    // that routed the tap read ONE decision — `supplyType` alone routes a
    // secondary `edition-print` (the most common secondary purchase) into the
    // master-edition print builder, which is not what the user tapped.
    final printsEdition = resolvePrintableMasterEdition(
      supplyType: event.supplyType,
      isMasterEdition: event.isPrintableMasterEdition,
    );
    // Flat per-print "mallow fee" (feeConfig.printFee × quantity) shown as
    // its own line in the confirmation sheet. Captured inside `build` for the
    // edition path only — null for 1/1 buys, which carry no print fee.
    int? mallowFeeLamports;
    // True when the v2 edition builder returned an `initProofs` setup tx
    // (on-chain wallet allowlist, buyer's `proofs` PDA missing). Captured here
    // like [mallowFeeLamports] so a stale-blockhash rebuild re-derives it from
    // the fresh response instead of carrying a stale flag.
    var hasSetupTx = false;
    await _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      // The v2 fixed-price / edition builders now take the buyer explicitly
      // (requireWallet defaults to true, so `me` is the caller's address).
      build: (me) async {
        if (!printsEdition) {
          // All non-print buys — a 1/1, or a secondary edition print being
          // re-sold — SOL or SPL-token (e.g. USDC) listings, use the v2
          // fixed-price builder, which returns a valid versioned (v0) tx and
          // settles in the listing's own currency. The v1 `getBuySingleTx`
          // builder was stale (the validator rejected its tx at simulate with
          // `NotEnoughAccountKeys`) and has since been dropped from the API.
          final response = await _apiV2.buyFixedPriceTx(
            BuyFixedPriceTxRequest(
              buyer: me,
              asset: event.mintAccount,
              maxPrice: maxPrice,
              // Null unless the buyer opened this artwork from a curation
              // inside the attribution TTL; the builder then writes a
              // `curation:<SLUG>` memo the indexer credits the curator with.
              curationShareSlug: _curationAttribution.shareSlugFor(
                event.mintAccount,
              ),
            ),
          );
          return [response.result.tx];
        } else {
          // Read the on-chain print fee (mallow fee) so the confirmation
          // sheet can show it as its own line — same source the webapp reads
          // (`feeConfig.printFee`, see useBuyNow). Falls back to the
          // default inside the service on RPC failure, so this never blocks
          // the buy.
          final fees = await _marketplaceConfig.get();
          mallowFeeLamports = fees.printFeeLamports * event.quantity;
          // Edition buys: prefer the v2 builder. It settles in the listing's
          // own currency, SOL or SPL alike, so the remaining 400 the v1 plural
          // builder covers is the off-chain-Merkle-denied edition. On-chain
          // wallet allowlists ARE handled by v2, via `setupTx`.
          try {
            final response = await _apiV2.buyEditionTx(
              BuyEditionTxsRequest(
                buyer: me,
                masterEdition: event.mintAccount,
                quantity: event.quantity,
                maxPrice: maxPrice,
                curationShareSlug: _curationAttribution.shareSlugFor(
                  event.mintAccount,
                ),
                targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
              ),
            );
            // `setupTx` creates the buyer's on-chain-allowlist `proofs`
            // PDA, which every `result` tx READS — they fail if broadcast
            // first. [TransactionExecutor] signs/sends/**confirms** each tx
            // in the batch before starting the next, so putting the setup tx
            // first IS the confirmation barrier, and a setup failure aborts
            // the buy without ever broadcasting a print. Absent (the only
            // shape today's deployed backend emits) leaves the batch byte-for-
            // byte what it was, with no extra prompt or send.
            final setupTx = response.setupTx;
            hasSetupTx = setupTx != null;
            return [?setupTx, ...response.result.map((e) => e.tx)];
          } on DioException catch (e) {
            if (!e.isV2DeferralFallback) rethrow;
            hasSetupTx = false;
            final response = await _api.getBuyEditionTxs(
              GetBuyEditionTxsRequest(
                masterEditionMintAccount: event.mintAccount,
                quantity: event.quantity,
                maxPrice: maxPrice,
              ),
            );
            return response.result.map((e) => e.tx).toList(growable: false);
          }
        }
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'buy',
        // Fixed-price buys and edition-print buys are separate builders, hence
        // separate cells — the shared `'buy'` actionType can't distinguish
        // them. Same [printsEdition] the builder branched on, so the cell
        // always names the builder that actually ran.
        flow: printsEdition ? AppFlow.editionBuy : AppFlow.fixedPriceBuy,
        hasSetupTx: hasSetupTx,
        totalCost: MarketPrice(
          rawAmount: perUnit.rawAmount * event.quantity,
          currencyMint: perUnit.currencyMint,
        ),
        mallowFeeLamports: mallowFeeLamports,
      ),
      errorPrefix: 'Failed to prepare transaction',
    );
  }

  Future<void> _onPlaceBid(MarketPlaceBid event, Emitter<MarketState> emit) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.bidTx(
          BidTxRequest(
            bidder: me,
            asset: event.mintAccount,
            bidAmount: event.amount.rawAmount.toInt(),
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'bid',
        flow: AppFlow.auctionBid,
        totalCost: event.amount,
      ),
      errorPrefix: 'Failed to prepare bid',
    );
  }

  Future<void> _onMakeOfferV2(
    MarketMakeOfferV2 event,
    Emitter<MarketState> emit,
  ) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.createOfferTx(
          CreateOfferTxRequest(
            buyer: me,
            asset: event.mintAccount,
            price: event.amount.rawAmount.toInt(),
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
            oneOfOneOnly: event.oneOfOneOnly,
            currencyMint: event.amount.currencyMint,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'offer',
        flow: AppFlow.offerCreate,
        totalCost: event.amount,
      ),
      errorPrefix: 'Failed to prepare offer',
    );
  }

  Future<void> _onCancelOffer(
    MarketCancelOffer event,
    Emitter<MarketState> emit,
  ) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.cancelOfferTx(
          CancelOfferTxRequest(
            buyer: me,
            asset: event.mintAccount,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'cancel-offer',
        flow: AppFlow.offerCancel,
        totalCost: event.amount ?? MarketPrice.zero(),
      ),
      errorPrefix: 'Failed to prepare cancel offer',
    );
  }

  Future<void> _onAcceptOffer(
    MarketAcceptOffer event,
    Emitter<MarketState> emit,
  ) async {
    _pendingAcceptArgs = (
      mint: event.mintAccount,
      buyer: event.buyer,
      amount: event.amount,
    );
    _emitFlow(emit, const TxFlowPreparing());
    // Pre-flight eligibility, the equivalent of the webapp's
    // `canAcceptOffer` + `useAcceptOffer`'s click-time invariants. Both hosts
    // (artwork detail sheet, offers inbox) dispatch behind nothing but the
    // kill switch and the signer switch, and the backend re-checks neither
    // buyer≠seller nor the frozen bit. Same posture as the burn gate: refuse
    // here, with the reason, rather than surface a raw builder/simulation
    // error.
    final asset = await _resolveAcceptOfferGate(event, emit);
    if (asset == null) return;
    // Initial prepare: a build failure is terminal — the sheet's pre-confirm
    // listener pops it and the host surfaces the error — so there's no prior
    // ready tx to fall back to.
    return _prepareAcceptOffer(
      emit,
      disablePrimarySplit: event.disablePrimarySplit,
      previousPrep: null,
      // The confirmation sheet drives the first simulation once it mounts on
      // the initial ready — the bloc only re-fires it on a toggle re-prepare,
      // where no UI dispatcher does.
      simulateOnReady: false,
      // Reuse the DAS read the gate already paid for.
      asset: asset,
    );
  }

  /// Run the accept-offer eligibility gate. Returns the fetched [DigitalAsset]
  /// when the accept may proceed (so the prepare doesn't re-fetch it), or null
  /// after emitting the refusal / lookup failure.
  ///
  /// Reads three authoritative sources in one round-trip window — DAS for
  /// owner + frozen, the `Listing` PDA and the `AuctionConfig` PDA for the
  /// listing state the webapp reads via the Anchor client
  /// (`useListingState`, `useAcceptOffer`).
  ///
  /// An **undetermined** account read (transport / decode failure — see
  /// [OnChainReadStatus.unknown]) is fed to the predicate as its permissive
  /// value, so a flaky network never invents a refusal. The DAS read is the
  /// exception: without an owner there is nothing to gate on, so it fails
  /// closed exactly as the burn gate does.
  Future<DigitalAsset?> _resolveAcceptOfferGate(
    MarketAcceptOffer event,
    Emitter<MarketState> emit,
  ) async {
    final me = _authService.currentAddress;
    if (me == null || me.isEmpty) {
      emit(const TxFlowFailure(AppFailure.unknown('No wallet connected')));
      return null;
    }

    final (assetResult, listingRead, auctionRead) = await (
      Result.guard(() => _dasApi.getAsset(event.mintAccount)),
      _marketAccounts.readListing(event.mintAccount),
      _marketAccounts.readAuctionConfig(event.mintAccount),
    ).wait;

    if (assetResult case ResultFailure(:final error)) {
      _txTracker.clear();
      emit(TxFlowFailure(error.prefixedWith('Failed to prepare accept offer')));
      return null;
    }
    final asset = assetResult.valueOrNull!;

    final hasListing = listingRead.status == OnChainReadStatus.present;
    final hasAuction = auctionRead.status == OnChainReadStatus.present;
    // Only the mallow market/auction programs are readable this way, so this
    // resolves to unlisted / buy-now / auction. Every other `ListingType`
    // (raffle, gumball, airdrop, store, jellybean) escrows the asset away from
    // the seller, so it is already refused by the ownership arm.
    final listingType = hasAuction
        ? ListingType.auction
        : hasListing
        ? ListingType.buyNow
        : ListingType.unlisted;

    final refusal = acceptOfferRefusal(
      isUserOwner: asset.owner == me,
      isOwnOffer: event.buyer == me,
      auctionCurrentBidder: auctionRead.account?.highestBidder,
      listingType: listingType,
      isFrozen:
          asset.frozen ||
          asset.freezeDelegateFrozen ||
          asset.permanentFreezeDelegateFrozen,
      // Undetermined ⇒ assume a listing exists, so an unreadable Listing PDA
      // can't turn a legitimately-frozen listed asset into a refusal.
      hasMallowListing: listingRead.status != OnChainReadStatus.absent,
    );
    if (refusal != null) {
      emit(TxFlowFailure(AppFailure.unknown(refusal.message)));
      return null;
    }
    return asset;
  }

  /// Re-prepare the accept-offer with a flipped split when the confirmation
  /// sheet's "Direct all proceeds to creators" toggle fires. Re-uses the args
  /// captured by [_onAcceptOffer]; on a transient build failure it reverts to
  /// the previous ready tx instead of failing (a TxFlowFailure would pop the
  /// sheet and destroy a valid, signable accept — the user only tapped a
  /// display toggle).
  Future<void> _onSetAcceptOfferSplit(
    MarketSetAcceptOfferSplit event,
    Emitter<MarketState> emit,
  ) {
    if (_pendingAcceptArgs == null) return Future.value();
    final current = state;
    final previousPrep =
        current is TxFlowReady<MarketPrepData, MarketSuccessData>
        ? current.data
        : null;
    return _prepareAcceptOffer(
      emit,
      disablePrimarySplit: event.disablePrimarySplit,
      previousPrep: previousPrep,
      simulateOnReady: true,
    );
  }

  /// Shared accept-offer prepare used by both the initial [MarketAcceptOffer]
  /// and the [MarketSetAcceptOfferSplit] toggle re-prepare.
  ///
  /// Accepting an offer pays the seller the offer amount minus the mallow fee
  /// and creator royalties — the same on-chain split as an auction settle — so
  /// it resolves the proceeds display + simulation inputs (amounts fill in from
  /// the simulation in [_onSimulate]) and the "Direct all proceeds to creators"
  /// gate (only meaningful on a primary sale with creator shares; see webapp's
  /// AcceptNftOfferModal). Both lookups run in one round-trip window and each
  /// swallows its own errors.
  ///
  /// [previousPrep] non-null marks a toggle re-prepare: a failure reverts to it
  /// rather than emitting TxFlowFailure.
  ///
  /// [asset] is the DAS record the eligibility gate already fetched — passed
  /// through so the initial prepare doesn't pay for a second `getAsset`. Null
  /// on the toggle re-prepare, which refetches.
  Future<void> _prepareAcceptOffer(
    Emitter<MarketState> emit, {
    required bool disablePrimarySplit,
    required MarketPrepData? previousPrep,
    required bool simulateOnReady,
    DigitalAsset? asset,
  }) async {
    final args = _pendingAcceptArgs;
    if (args == null) return;

    // R1: leave TxFlowReady *synchronously* — before the DAS/proceeds awaits —
    // so a Confirm tap during a re-prepare fails [_onConfirmAndSign]'s
    // TxFlowReady guard and can't sign the pre-toggle tx. Bumping the
    // generation here also orders concurrent prepares (R2): an older prepare
    // resuming past an await sees a newer [_acceptPrepGen] and aborts.
    final gen = ++_acceptPrepGen;
    _emitFlow(emit, const TxFlowPreparing<MarketPrepData, MarketSuccessData>());

    final (proceedsResult, gate) = await (
      _resolveProceedsInputs(args.amount),
      _resolveDirectProceedsGate(args.mint, asset: asset),
    ).wait;
    if (gen != _acceptPrepGen) return; // superseded by a newer toggle.
    final (proceeds, simInputs) = proceedsResult;
    final showDirectProceeds = gate.showOption;
    // The arithmetic proceeds the sheet falls back to when the simulation
    // can't answer. Computed from the same classification + royalties the gate
    // already read, under the split the tx is actually being built with.
    final proceedsFallback = await _estimateSettleProceeds(
      base: proceeds,
      gate: gate,
      disablePrimarySplit: disablePrimarySplit,
    );
    if (gen != _acceptPrepGen) return;

    // A guarded sink drops emits from a superseded prepare and translates the
    // outcome into the toggle-aware behavior (re-simulate on ready, revert on
    // failure) rather than the default direct emit.
    final sink = ActionFlowSink<MarketPrepData, MarketSuccessData>(
      onPreparing: () {
        if (gen == _acceptPrepGen) {
          emit(const TxFlowPreparing<MarketPrepData, MarketSuccessData>());
        }
      },
      onReady: (prep) {
        if (gen != _acceptPrepGen) return;
        emit(TxFlowReady<MarketPrepData, MarketSuccessData>(prep));
        // R3: on a toggle re-prepare the freshly rebuilt tx carries no
        // simulation and no UI dispatcher re-fires simulate — so drive it from
        // the bloc. The "You'll receive" breakdown resolves in place. (The
        // initial prepare leaves this to the confirmation sheet's own mount.)
        if (simulateOnReady) add(const MarketEvent.simulate());
      },
      onSigning: (_) {},
      onBroadcasting: () {},
      onSuccess: (_, _) {},
      onFailure: (failure) {
        if (gen != _acceptPrepGen) return;
        // R5: a toggle re-prepare that fails must not pop the sheet — revert to
        // the previous signable ready (previous split + checkbox value). The
        // initial prepare (previousPrep == null) still fails terminally.
        //
        // A remote kill is the exception: reverting would swallow it silently
        // (no state change the host can present from) and hand the user back a
        // Confirm button that the signing backstop will refuse anyway. Emit the
        // failure so the host shows the operator's copy. The retry
        // affordance the revert exists for is deliberate for every *other*
        // failure — a flaky prepare must not cost the user their toggle.
        if (previousPrep != null && !failure.isFlowDisabled) {
          emit(TxFlowReady<MarketPrepData, MarketSuccessData>(previousPrep));
        } else {
          emit(TxFlowFailure<MarketPrepData, MarketSuccessData>(failure));
        }
      },
    );

    await _flow.prepare(
      sink: sink,
      tracker: _txTracker,
      build: (me) async {
        // The seller ([me]) is verified server-side as the asset owner; the
        // body carries the offer's buyer. A mallow listing on the asset is
        // delisted in the same tx.
        final response = await _apiV2.acceptOfferTx(
          AcceptOfferTxRequest(
            seller: me,
            buyer: args.buyer,
            asset: args.mint,
            enablePrimarySplit: !disablePrimarySplit,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: args.mint,
        actionType: 'accept-offer',
        flow: AppFlow.offerAccept,
        // Inflow for the seller — keep the offer amount around for the UI
        // but no payment is collected from the wallet.
        totalCost: args.amount,
        settleProceeds: proceeds,
        settleSimInputs: simInputs,
        settleProceedsFallback: proceedsFallback,
        disablePrimarySplit: disablePrimarySplit,
        showDirectProceedsOption: showDirectProceeds,
      ),
      errorPrefix: 'Failed to prepare accept offer',
    );
  }

  /// Whether the accept-offer sheet should surface the "Direct all proceeds to
  /// creators" toggle. Delegates to the shared parity helpers
  /// (`direct_proceeds.dart`): shown only on a primary sale — webapp
  /// `isSecondaryMarket`, i.e. `primarySaleHappened` for token-metadata
  /// standards and owner-vs-collection-update-authority for Core — carrying
  /// creator royalty shares where the seller isn't the first creator (the split
  /// is a no-op otherwise).
  ///
  /// For a grouped Core asset it fetches the parent collection so BOTH the
  /// classification and the royalty shares can fall back to the collection's
  /// plugin: Helius DAS does not merge collection plugins into
  /// `getAsset(mint)`, so a Core asset whose Royalties plugin lives on its
  /// collection returns empty creators here while the backend's settlement
  /// (`fetch_core_royalty_creators`) still pays those collection creators. A
  /// collection-fetch failure degrades to asset-only computation. Returns
  /// false (toggle hidden) on any lookup failure — a safe default that leaves
  /// the offer accepting with its `disablePrimarySplit` default.
  ///
  /// [asset] short-circuits the `getAsset` when the eligibility gate already
  /// read it for this same mint.
  ///
  /// The same read answers the proceeds question too: the classification and
  /// the on-chain royalties it resolves are also what
  /// [_estimateSettleProceeds] needs to compute the
  /// arithmetic proceeds the sheet falls back to when the simulation can't
  /// answer. They ride back on the record so neither caller pays for a second
  /// `getAsset`. Callers that only want the estimate (auction settle, which has
  /// no toggle) ignore `showOption`.
  Future<_ProceedsGate> _resolveDirectProceedsGate(
    String mint, {
    DigitalAsset? asset,
  }) async {
    const none = (
      showOption: false,
      seller: null,
      isSecondary: false,
      royalties: null,
    );
    final seller = _authService.currentAddress;
    if (seller == null) return none;
    try {
      final resolved = asset ?? await _dasApi.getAsset(mint);
      // Only grouped Core assets classify off / read royalties from the parent
      // collection; token-metadata standards read everything from the asset, so
      // never pay for the extra round-trip. Mirrors `resolveListingContext`.
      DigitalAsset? collection;
      if (resolved.tokenStandard == TokenStandard.core &&
          resolved.collectionKey != null) {
        try {
          collection = await _dasApi.getAsset(resolved.collectionKey!);
        } catch (_) {
          // Non-fatal: fall back to asset-only classification + royalties.
        }
      }
      final isSecondary = isSecondaryMarketOf(resolved, collection: collection);
      final royalties = resolveOnChainRoyalties(
        resolved,
        collection: collection,
      );
      return (
        showOption: showDirectProceedsOptionOf(
          isSecondary: isSecondary,
          seller: seller,
          shares: royalties.shares,
        ),
        seller: seller,
        isSecondary: isSecondary,
        royalties: royalties,
      );
    } catch (_) {
      return none;
    }
  }

  /// Pure-arithmetic seller proceeds — the webapp's only source
  /// (`getProceedsSplits`, rendered by `ProceedsInfo`), and mobile's fallback
  /// when the settle simulation can't resolve the real deltas.
  ///
  /// Splits are keyed by address, so any royalty the seller earns *as a
  /// creator* is already inside their row — the same accounting the simulated
  /// path produces (the payout lands in the seller's own account), which is why
  /// royalties-to-others stays `gross − fee − earnings`.
  ///
  /// Fee bps come from the on-chain marketplace config, matching webapp
  /// `marketMarketplaceConfig.feeConfig`. That config read never throws (it
  /// returns the documented defaults), so the estimate is producible whenever
  /// [gate] resolved — a failed royalty read is the one case that still leaves
  /// the sheet shimmering, since guessing a royalty is worse than not showing
  /// one.
  Future<SettleProceeds?> _estimateSettleProceeds({
    required SettleProceeds? base,
    required _ProceedsGate gate,
    required bool disablePrimarySplit,
  }) async {
    final seller = gate.seller;
    final royalties = gate.royalties;
    if (base == null || seller == null || royalties == null) return null;
    final fees = await _marketplaceConfig.get();
    final splits = computeProceedsSplits(
      seller: seller,
      priceRaw: base.grossBidRaw,
      isSecondary: gate.isSecondary,
      royaltyShares: royalties.shares,
      royaltyBps: royalties.royaltyBps,
      primaryFeeBps: fees.primaryBps,
      secondaryFeeBps: fees.secondaryBps,
      disablePrimarySplit: disablePrimarySplit,
    );
    var earnings = 0;
    var marketFee = 0;
    for (final split in splits) {
      if (split.address == kMallowFeeAddress) {
        marketFee += split.amountRaw;
      } else if (split.address == seller) {
        earnings += split.amountRaw;
      }
    }
    final royaltiesToOthers = base.grossBidRaw - marketFee - earnings;
    return base.copyWith(
      sellerEarningsRaw: earnings,
      marketFeeRaw: marketFee,
      royaltiesToOthersRaw: royaltiesToOthers < 0 ? 0 : royaltiesToOthers,
    );
  }

  Future<void> _onCancelListing(
    MarketCancelListing event,
    Emitter<MarketState> emit,
  ) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.cancelFixedPriceTx(
          CancelFixedPriceTxRequest(
            seller: me,
            asset: event.mintAccount,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'cancel-listing',
        flow: AppFlow.fixedPriceCancel,
        totalCost: MarketPrice.zero(),
      ),
      errorPrefix: 'Failed to prepare cancel',
    );
  }

  Future<void> _onUpdateListing(
    MarketUpdateListing event,
    Emitter<MarketState> emit,
  ) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.updateFixedPriceTx(
          UpdateFixedPriceTxRequest(
            seller: me,
            asset: event.mintAccount,
            newPrice: event.newPrice.rawAmount.toInt(),
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'update-listing',
        flow: AppFlow.fixedPriceUpdate,
        totalCost: event.newPrice,
      ),
      errorPrefix: 'Failed to prepare update',
    );
  }

  Future<void> _onCancelAuction(
    MarketCancelAuction event,
    Emitter<MarketState> emit,
  ) {
    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.cancelAuctionTx(
          CancelAuctionTxRequest(
            seller: me,
            asset: event.mintAccount,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: event.reclaim ? 'reclaim-auction' : 'cancel-auction',
        // Both branches are the same on-chain `cancelAuction` ix.
        flow: AppFlow.auctionCancel,
        totalCost: MarketPrice.zero(),
      ),
      errorPrefix: 'Failed to prepare cancel',
    );
  }

  Future<void> _onSettleAuction(
    MarketSettleAuction event,
    Emitter<MarketState> emit,
  ) async {
    // Emit preparing BEFORE the pre-flight below, which costs an ATA
    // resolution + a DAS read (~a second). The artwork screen opens the
    // confirm sheet the moment Settle is tapped, and the sheet picks its
    // layout off the flow state: anything other than preparing/ready renders
    // the gas-only "Network fee" row, so leaving the bloc idle through that
    // window flashed a fee line where the shimmering "You'll receive" belongs.
    // Same reason `_onAcceptOffer` emits up front before its gate.
    _emitFlow(emit, const TxFlowPreparing());
    // Seller-with-bids settle: prepare the proceeds display (gross known now,
    // amounts resolved later from the simulation in _onSimulate). Winner-claim
    // and no-bid paths carry no winning bid and fall through to the
    // network-fee-only sheet.
    final (proceeds, simInputs) = await _resolveProceedsInputs(
      event.winningBid,
    );
    // Arithmetic fallback for "You'll receive" when the simulation can't
    // answer. Only the seller-with-bids path pays for the DAS read — the
    // winner-claim / no-bid settles carry no proceeds row at all.
    //
    // `disablePrimarySplit: false` mirrors auction *creation*'s default
    // (`AuctionState.disablePrimarySplit`, webapp `createAuctionArgs`): the
    // flag lives on the auction the seller already created and isn't readable
    // here, so the estimate assumes the default the app itself lists with. The
    // simulation, when it succeeds, still overrides this with the real split.
    final proceedsFallback = proceeds == null
        ? null
        : await _estimateSettleProceeds(
            base: proceeds,
            gate: await _resolveDirectProceedsGate(event.mintAccount),
            disablePrimarySplit: false,
          );

    return _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      build: (me) async {
        final response = await _apiV2.settleAuctionTx(
          SettleAuctionTxRequest(
            authority: me,
            asset: event.mintAccount,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'settle-auction',
        flow: AppFlow.auctionSettle,
        totalCost: MarketPrice.zero(),
        settleProceeds: proceeds,
        settleSimInputs: simInputs,
        settleProceedsFallback: proceedsFallback,
      ),
      errorPrefix: 'Failed to prepare settle',
    );
  }

  /// Resolves the seller-proceeds display + simulation inputs for a seller-side
  /// payout (auction settle, accept-offer): the escrowed [gross] amount is
  /// split on-chain into mallow fee + creator royalties + the seller's
  /// earnings, which [_simulateSettle] resolves from the tx simulation later
  /// (fee bps can't be re-derived reliably client-side). Returns nulls — the
  /// sheet falls back to a gas-only row / gross display — when there's no
  /// connected seller, the amount is missing/zero, or the inspection accounts
  /// can't be resolved.
  Future<(SettleProceeds?, SettleSimInputs?)> _resolveProceedsInputs(
    MarketPrice? gross,
  ) async {
    final seller = _authService.currentAddress;
    if (gross == null || gross.rawAmount <= 0 || seller == null) {
      return (null, null);
    }
    final grossRaw = gross.rawAmount.round();
    final mint = gross.currencyMint ?? solMint;
    final isNative = mint == solMint;
    try {
      // SPL payouts land in associated token accounts; native-SOL payouts pay
      // lamports straight to the wallet addresses.
      final sellerAccount = isNative
          ? seller
          : await _rpcService.resolveAssociatedTokenAccount(
              owner: seller,
              mint: mint,
            );
      final feeAccount = isNative
          ? kMallowFeeAddress
          : await _rpcService.resolveAssociatedTokenAccount(
              owner: kMallowFeeAddress,
              mint: mint,
            );
      return (
        SettleProceeds(grossBidRaw: grossRaw, currencyMint: gross.currencyMint),
        SettleSimInputs(
          sellerAccount: sellerAccount,
          feeAccount: feeAccount,
          isNative: isNative,
          grossRaw: grossRaw,
        ),
      );
    } catch (_) {
      // Couldn't resolve the inspection accounts — fall back rather than
      // blocking the action.
      return (null, null);
    }
  }

  Future<void> _onBurn(MarketBurn event, Emitter<MarketState> emit) async {
    _emitFlow(emit, const TxFlowPreparing());
    final me = _authService.currentAddress;
    if (me == null || me.isEmpty) {
      emit(const TxFlowFailure(AppFailure.unknown('No wallet connected')));
      return;
    }

    final assetResult = await Result.guard(
      () => _dasApi.getAsset(event.mintAccount),
    );
    if (assetResult case ResultFailure(:final error)) {
      _txTracker.clear();
      emit(TxFlowFailure(error.prefixedWith('Failed to prepare burn')));
      return;
    }
    final asset = assetResult.valueOrNull!;

    const supported = {
      TokenStandard.nft,
      TokenStandard.pnft,
      TokenStandard.core,
      TokenStandard.coreCollection,
    };
    if (!supported.contains(asset.tokenStandard)) {
      emit(
        const TxFlowFailure(
          AppFailure.unknown('Burning is not supported for this asset type.'),
        ),
      );
      return;
    }

    // Webapp BurnModal parity: re-check the burn gate right before building
    // the tx. The menu's DAS snapshot can be stale — the collection may have
    // gained members or the asset been frozen since the sheet opened — and
    // failing here beats surfacing a raw simulation error later.
    DigitalAsset? collectionAsset;
    if (asset.tokenStandard == TokenStandard.core &&
        asset.collectionKey != null) {
      try {
        collectionAsset = await _dasApi.getAsset(asset.collectionKey!);
      } catch (_) {
        // Non-fatal: collection-level freeze/delegates just aren't consulted.
      }
    }
    if (!ArtworkPermissionService.canBurnAsset(
      asset,
      user: me,
      collection: collectionAsset,
    )) {
      // Printed Core master editions get the webapp's specific copy; the
      // generic line covers every other refused gate.
      final isPrintedMaster =
          asset.tokenStandard == TokenStandard.coreCollection &&
          asset.hasMasterEditionPlugin &&
          (asset.currentSize ?? 0) > 0;
      final subject = event.isCollection ? 'collection' : 'NFT';
      emit(
        TxFlowFailure(
          AppFailure.unknown(
            isPrintedMaster
                ? 'Cannot burn, editions have already been printed for '
                      'this master edition'
                : 'You cannot burn this $subject',
          ),
        ),
      );
      return;
    }

    await _flow.prepare(
      sink: _sink(emit),
      tracker: _txTracker,
      // `me` is resolved above and the builder also needs the resolved
      // asset metadata, so it builds with the captured address.
      requireWallet: false,
      build: (_) async {
        // Collection membership and printed-edition parentage are resolved
        // on-chain by the builder, so neither is sent.
        final response = await _apiV2.getBurnTx(
          BurnTxRequest(
            authority: me,
            asset: event.mintAccount,
            tokenStandard: asset.tokenStandard.apiValue,
            targetPriorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return [response.result.tx];
      },
      toPrep: (txs, _) => _prep(
        txs,
        mintAccount: event.mintAccount,
        actionType: 'burn',
        flow: AppFlow.nftBurn,
        totalCost: MarketPrice.zero(),
      ),
      errorPrefix: 'Failed to prepare burn',
    );
  }

  Future<void> _onConfirmAndSign(
    MarketConfirmAndSign event,
    Emitter<MarketState> emit,
  ) async {
    final current = state;
    if (current is! TxFlowReady<MarketPrepData, MarketSuccessData>) return;

    final prep = current.data;

    final isLocal = await _walletManager.isLocalSigner();

    final outflowMint = prep.totalCost.effectiveCurrencyMint;
    final outflowRaw = prep.totalCost.rawAmount;
    final usdOutflow = outflowRaw == 0
        ? 0.0
        : _priceService.usdValueOfRaw(outflowRaw, outflowMint);

    await _flow.execute(
      sink: _sink(emit),
      tracker: _txTracker,
      txsBase64: prep.transactionsBase64,
      usdValue: usdOutflow,
      flow: FlowKey.solana(prep.flow),
      // Every marketplace action writes an entry record (buy→sale,
      // offer/bid, cancel/update→delist/relist, settle→sale) that the
      // artwork screen reads off `/byMint`, so gate the post-tx refresh on
      // the entry landing — otherwise the refetch races the entry-indexing
      // lag and reads stale pre-action state. `burn` is the exception: it
      // destroys the token and produces no marketplace entry, so it stays
      // on the tx-level ack alone (gating it would poll a never-landing
      // entry until the retries exhaust).
      requireEntry: prep.actionType != 'burn',
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(MarketEvent.indexedAck(signature: sig, ok: ok)),
      stageFor: (index, total, ledger) {
        final progress = total > 1 ? ' (${index + 1}/$total)' : '';
        if (ledger) return '$kLedgerSigningStage$progress';
        return isLocal ? '$kLocalSigningLabel$progress' : null;
      },
      toSuccess: (signature) => MarketSuccessData(
        explorerUrl: 'https://orbmarkets.io/tx/$signature',
        actionType: prep.actionType,
        mintAccount: prep.mintAccount,
      ),
    );
  }

  void _onIndexedAck(MarketIndexedAck event, Emitter<MarketState> emit) {
    final current = state;
    if (current is! TxFlowSuccess<MarketPrepData, MarketSuccessData>) {
      debugPrint(
        '[LIST-DEBUG] MarketBloc indexedAck DROPPED (state=${current.runtimeType}, '
        'not TxFlowSuccess — sheet likely auto-reset before the indexer poll '
        'landed) sig=${event.signature} ok=${event.ok} '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }
    if (current.signature != event.signature) {
      debugPrint(
        '[LIST-DEBUG] MarketBloc indexedAck DROPPED (signature mismatch '
        'have=${current.signature} got=${event.signature}) '
        '@${DateTime.now().toIso8601String()}',
      );
      return;
    }
    debugPrint(
      '[LIST-DEBUG] MarketBloc indexedAck APPLIED → indexed=${event.ok} '
      'action=${current.result.actionType} sig=${event.signature} '
      '@${DateTime.now().toIso8601String()}',
    );
    emit(
      TxFlowSuccess(
        signature: current.signature,
        result: current.result.copyWith(indexed: event.ok),
      ),
    );
    // The owner's art set / listing state changed now that the indexer acked
    // (buy → owned, accept-offer/settle → sold, list/update/cancel → badge):
    // refetch My Art. Offers / bids / cancel-offer don't touch the owner's
    // own art, so they're excluded. Fire regardless of `event.ok` — a timed-
    // out poll doesn't mean it failed, and a refetch only re-reads the truth.
    if (_portfolioAffectingActions.contains(current.result.actionType)) {
      notifyPortfolioRefresh();
    }
    // Every market action changes the price / listing badge that browse and
    // list surfaces render for this mint (home rails, collection + curation
    // grids, profile grids). They aren't subscribed to the detail screen's
    // refetch, so without this they keep serving the pre-action price.
    notifyArtworkEdited(current.result.mintAccount);

    // Honor a reset that was deferred while this success awaited its ack. The
    // `indexed` flip above is emitted first, so listeners (the artwork screen's
    // post-tx refresh + pending-indexer gate clear) see it before this idle
    // tears the flow down. Matched by signature so a reset for a superseded
    // success can't idle a newer flow.
    if (_pendingResetSig == current.signature) {
      _pendingResetSig = null;
      _txTracker.clear();
      emit(const TxFlowIdle());
    }
  }

  void _onReset(MarketReset event, Emitter<MarketState> emit) {
    final current = state;
    // Defer a reset that lands while an optimistic success is still awaiting
    // its indexer ack — keep the success state alive so the in-flight ack can
    // flip `indexed` and drive the screen's post-tx refresh + gate clear. The
    // deferred idle is applied in [_onIndexedAck] once the flip is emitted.
    if (current is TxFlowSuccess<MarketPrepData, MarketSuccessData> &&
        current.result.indexed == null) {
      _pendingResetSig = current.signature;
      debugPrint(
        '[LIST-DEBUG] MarketBloc reset DEFERRED until indexedAck '
        'sig=${current.signature} @${DateTime.now().toIso8601String()}',
      );
      return;
    }
    _pendingResetSig = null;
    _txTracker.clear();
    emit(const TxFlowIdle());
  }

  Future<void> _onSimulate(
    MarketSimulate event,
    Emitter<MarketState> emit,
  ) async {
    final current = state;
    if (current is! TxFlowReady<MarketPrepData, MarketSuccessData>) return;

    final prep = current.data;
    // A batch that leads with a prerequisite setup tx has nothing simulatable:
    // see [MarketPrepData.hasSetupTx]. Leaving `isSimulating` false and the
    // result null falls the breakdown back to the static fee estimate, which is
    // the same path an un-simulated action already takes.
    if (prep.hasSetupTx) return;
    emit(
      TxFlowReady(
        prep.copyWith(
          isSimulating: true,
          simulationResult: null,
          simulatedPayerLamportsDelta: null,
        ),
      ),
    );

    // Seller settle: resolve the proceeds breakdown from the simulation
    // (token/lamport deltas), since fee bps can't be re-derived reliably
    // client-side.
    final settleInputs = prep.settleSimInputs;
    if (settleInputs != null) {
      try {
        await _simulateSettle(prep, settleInputs, emit);
      } catch (_) {
        // A throwing balance read / simulate would otherwise leave the sheet
        // shimmering forever (the handler dies with `isSimulating: true`).
        // Land on the arithmetic fallback instead — same treatment as a
        // simulation that ran and couldn't answer.
        _emitSettleFallback(emit);
      }
      return;
    }

    // Burns refund SOL (rent reclaim) and edition buys spend SOL on rent +
    // protocol fees beyond the print fee — both need the payer's net lamport
    // delta to show an accurate breakdown. Other buys/offers skip the extra
    // pre-balance roundtrip.
    final inspectPayer =
        prep.actionType == 'burn' || prep.mallowFeeLamports != null
        ? _authService.currentAddress
        : null;

    final sim = await _rpcService.simulateWithDelta(
      address: inspectPayer,
      simulate: (inspect) => _rpcService.simulateEncodedTransaction(
        prep.transactionsBase64.first,
        inspectAccounts: inspect,
      ),
    );

    // Re-read to ensure we're still in the ready state.
    final post = state;
    if (post is! TxFlowReady<MarketPrepData, MarketSuccessData>) return;

    emit(
      TxFlowReady(
        post.data.copyWith(
          isSimulating: false,
          simulationResult: sim.result,
          simulatedPayerLamportsDelta: sim.lamportsDelta,
        ),
      ),
    );
  }

  /// Stops the "You'll receive" shimmer on the arithmetic estimate after the
  /// simulation threw. No [SimulationResult] is recorded — nothing came back —
  /// so the sheet shows the estimate without a false success banner.
  void _emitSettleFallback(Emitter<MarketState> emit) {
    final post = state;
    if (post is! TxFlowReady<MarketPrepData, MarketSuccessData>) return;
    emit(
      TxFlowReady(
        post.data.copyWith(
          isSimulating: false,
          settleProceeds: post.data.settleProceedsFallback,
        ),
      ),
    );
  }

  /// Resolves the seller's settle proceeds from a tx simulation: how much the
  /// seller's account gains (earnings) and how much the mallow fee account
  /// gains (fee), with royalties-to-others the remainder. For an SPL bid mint
  /// these come from token-amount deltas on the associated token accounts; for
  /// a native-SOL bid mint from lamport deltas (and gas is added back to the
  /// seller side, since the seller is also the payer).
  Future<void> _simulateSettle(
    MarketPrepData prep,
    SettleSimInputs inputs,
    Emitter<MarketState> emit,
  ) async {
    Future<int> preValue(String account) => inputs.isNative
        ? _rpcService.getBalanceForAddress(account)
        : _rpcService.getTokenAccountAmount(account);

    final preSeller = await preValue(inputs.sellerAccount);
    final preFee = await preValue(inputs.feeAccount);

    final sim = await _rpcService.simulateEncodedTransaction(
      prep.transactionsBase64.first,
      inspectAccounts: [inputs.sellerAccount, inputs.feeAccount],
    );

    final post = state;
    if (post is! TxFlowReady<MarketPrepData, MarketSuccessData>) return;

    final sellerPost = inputs.isNative
        ? sim.inspectedAccountLamports[inputs.sellerAccount]
        : sim.inspectedAccountTokenAmounts[inputs.sellerAccount];
    final feePost = inputs.isNative
        ? sim.inspectedAccountLamports[inputs.feeAccount]
        : sim.inspectedAccountTokenAmounts[inputs.feeAccount];

    // The simulation ran but can't answer (failed, or no seller post balance).
    // Fall back to the arithmetic split rather than shimmering forever
    // while the user is asked to confirm an irreversible sale — the webapp
    // shows nothing else. Still never fakes a 0: with no fallback resolved the
    // amounts stay null and the shimmer + warning banner remain.
    if (!sim.success || sellerPost == null) {
      emit(
        TxFlowReady(
          post.data.copyWith(
            isSimulating: false,
            simulationResult: sim,
            settleProceeds: post.data.settleProceedsFallback,
          ),
        ),
      );
      return;
    }

    var earnings = sellerPost - preSeller;
    // The seller pays the tx fee on a native-SOL settle, so add it back to
    // report gross proceeds (the gas shows as its own "Network fee" line).
    if (inputs.isNative) earnings += prep.estimatedFeeLamports;
    final fee = (feePost ?? preFee) - preFee;
    final royalties = inputs.grossRaw - fee - earnings;

    final base =
        post.data.settleProceeds ??
        SettleProceeds(
          grossBidRaw: inputs.grossRaw,
          currencyMint: prep.settleProceeds?.currencyMint,
        );
    int nonNeg(int v) => v < 0 ? 0 : v;
    emit(
      TxFlowReady(
        post.data.copyWith(
          isSimulating: false,
          simulationResult: sim,
          settleProceeds: base.copyWith(
            sellerEarningsRaw: nonNeg(earnings),
            marketFeeRaw: nonNeg(fee),
            royaltiesToOthersRaw: nonNeg(royalties),
          ),
        ),
      ),
    );
  }
}
