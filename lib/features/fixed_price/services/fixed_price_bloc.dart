import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_market.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/network/das_api_service.dart';
import '../../../core/realtime/market_realtime_service.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/marketplace_action_flow.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/stale_tx_tracker.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/services/tx_landed_slots.dart';
import '../../../shared/utils/artwork_mappers.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../auction/data/rewards_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../../sale/services/direct_proceeds.dart';
import '../../sale/services/marketplace_config_service.dart';
import '../../sale/services/proceeds_calculator.dart';
import '../data/fixed_price_repository.dart';

export '../../../core/services/transaction_flow_state.dart';

part 'fixed_price_bloc.freezed.dart';

// Sentinel for FixedPriceState.copyWith — lets callers pass explicit null on
// nullable fields without conflating "leave unchanged" with "set to null".
const Object _sentinel = Object();

/// The user-facing steps of the fixed-price listing flow. Indexed for the
/// progress bar — see [FixedPriceState.progressFraction].
enum FixedPriceStep { selectArtwork, pricing, additionalOptions, review }

/// Domain-specific result payload carried by [TxFlowSuccess] for fixed-price
/// listing flows.
class FixedPriceSuccessData extends Equatable {
  const FixedPriceSuccessData({this.indexed});

  /// Indexer-ack flag for the just-broadcast listing. `null` while the
  /// background poll is running (success sheet shows optimistically); flips
  /// to `true` once the indexer acks (or `false` after retries exhaust — UI
  /// treats them the same: enable "View listing" CTAs).
  final bool? indexed;

  FixedPriceSuccessData copyWith({Object? indexed = _sentinel}) =>
      FixedPriceSuccessData(
        indexed: identical(indexed, _sentinel)
            ? this.indexed
            : indexed as bool?,
      );

  @override
  List<Object?> get props => [indexed];
}

/// Generic alias for the unified flow state with fixed-price-specific payloads.
/// TPrep is void — the flow runs end-to-end with no confirm sheet.
typedef FixedPriceFlowState = TransactionFlowState<void, FixedPriceSuccessData>;

@freezed
sealed class FixedPriceEvent with _$FixedPriceEvent {
  /// Hydrate user pubkey + (optional) preselected artwork. When
  /// [mintAccount] is supplied the select-artwork step is skipped.
  const factory FixedPriceEvent.started({
    String? mintAccount,
    PortfolioArtwork? artwork,
  }) = FixedPriceStarted;

  // --- Navigation ---
  const factory FixedPriceEvent.next() = FixedPriceNext;
  const factory FixedPriceEvent.back() = FixedPriceBack;
  const factory FixedPriceEvent.gotoStep(FixedPriceStep step) =
      FixedPriceGotoStep;
  const factory FixedPriceEvent.selectArtwork(PortfolioArtwork artwork) =
      FixedPriceSelectArtwork;

  // --- Pricing step ---
  const factory FixedPriceEvent.setPrice(int rawAmount) = FixedPriceSetPrice;
  const factory FixedPriceEvent.setCurrencyMint(String? mint) =
      FixedPriceSetCurrencyMint;
  const factory FixedPriceEvent.setEditionsLimit(int value) =
      FixedPriceSetEditionsLimit;

  /// Review step — "Direct all proceeds to creators" toggle.
  const factory FixedPriceEvent.setDisablePrimarySplit(bool value) =
      FixedPriceSetDisablePrimarySplit;

  // --- Additional options step ---
  const factory FixedPriceEvent.setIncludePhysical(bool value) =
      FixedPriceSetIncludePhysical;
  const factory FixedPriceEvent.setPhysical(PhysicalDetailsPayload value) =
      FixedPriceSetPhysical;
  const factory FixedPriceEvent.setIncludeRewards(bool value) =
      FixedPriceSetIncludeRewards;
  const factory FixedPriceEvent.setRewardsDescription(String value) =
      FixedPriceSetRewardsDescription;
  const factory FixedPriceEvent.setAskForShippingAddress(bool value) =
      FixedPriceSetAskForShippingAddress;

  // --- Pipeline ---
  const factory FixedPriceEvent.requestList() = FixedPriceRequestList;
  const factory FixedPriceEvent.dismissError() = FixedPriceDismissError;
  const factory FixedPriceEvent.reset() = FixedPriceReset;

  /// Internal — emitted by the background `_runCheckTx` poll once the
  /// indexer acks the listing tx. Drives [FixedPriceState.successIndexed].
  const factory FixedPriceEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = FixedPriceIndexedAck;
}

class FixedPriceState extends Equatable {
  const FixedPriceState({
    this.step = FixedPriceStep.selectArtwork,
    this.userPubkey = '',
    this.entryFromArtworkDetail = false,
    this.isSecondaryMarket = false,
    this.showVerifiedSellerOptions = false,
    this.selectedArtwork,
    this.updateAuthority,
    this.price = 0,
    this.currencyMint,
    this.editionsLimit = 0,
    this.includePhysical = false,
    this.physical,
    this.includeRewards = false,
    this.rewardsDescription = '',
    this.askForShippingAddress = false,
    this.royaltyShares = const <ArtworkRoyaltySplit>[],
    this.royaltyBps = 0,
    this.primaryFeeBps = 500,
    this.secondaryFeeBps = 250,
    this.disablePrimarySplit = false,
    this.flow = const TxFlowIdle(),
  });

  final FixedPriceStep step;

  // Wallet / context
  final String userPubkey;

  /// True when entered from the artwork detail screen with a preselected
  /// mint — the select-artwork step is skipped and the progress bar
  /// reflects the smaller flow.
  final bool entryFromArtworkDetail;

  /// True when the listing is on the secondary market (the user is not
  /// the verified update authority). Drives the proceeds split logic and
  /// hides the verified-seller-only options.
  final bool isSecondaryMarket;

  /// Webapp parity: `(onChainAsset != null && !isSecondaryMarket(...)) ||
  /// isApprovedCreator(user)` (`ListingContext`). For now we
  /// derive only the non-secondary-market arm via DAS creator info.
  final bool showVerifiedSellerOptions;

  final PortfolioArtwork? selectedArtwork;

  /// On-chain update authority for the selected mint, populated from the
  /// DAS asset lookup. Used as the review-step fallback label when the
  /// artist has no mallow username.
  final String? updateAuthority;

  // Pricing
  final int price;
  final String? currencyMint;

  /// Optional per-buyer-wallet purchase cap for master-edition
  /// listings — the on-chain `u16` editionsLimit field on `ListArgs`.
  /// `0` means "no per-wallet cap" (any single wallet can buy all
  /// available editions); otherwise it caps how many copies one wallet
  /// can purchase from this listing. Only meaningful when
  /// [isMasterEdition] is true; ignored on the `listNft` branch.
  final int editionsLimit;

  // Additional options
  final bool includePhysical;
  final PhysicalDetailsPayload? physical;
  final bool includeRewards;
  final String rewardsDescription;
  final bool askForShippingAddress;

  // Royalty + fee data, populated on `started`. Defaults match webapp's
  // `DEFAULT_PRIMARY_BPS` / `DEFAULT_SECONDARY_BPS`.
  final List<ArtworkRoyaltySplit> royaltyShares;
  final int royaltyBps;
  final int primaryFeeBps;
  final int secondaryFeeBps;

  /// Seller opt-in for the webapp's "Direct all proceeds to creators" toggle.
  /// When true, a primary sale is split like a secondary one: creators get
  /// only their royalty %, the remainder goes to the seller. Mirrors
  /// `ListingContext`'s `listNftArgs.disablePrimarySplit` (default false).
  /// Only surfaced when [showDirectProceedsOption] is true.
  final bool disablePrimarySplit;

  /// Unified transaction-flow state. Replaces the former
  /// `pipelineStatus`/`pipelineStage`/`pipelineError`/`successSignature`/
  /// `successIndexed` cluster.
  final FixedPriceFlowState flow;

  FixedPriceState copyWith({
    FixedPriceStep? step,
    String? userPubkey,
    bool? entryFromArtworkDetail,
    bool? isSecondaryMarket,
    bool? showVerifiedSellerOptions,
    Object? selectedArtwork = _sentinel,
    Object? updateAuthority = _sentinel,
    int? price,
    Object? currencyMint = _sentinel,
    int? editionsLimit,
    bool? includePhysical,
    Object? physical = _sentinel,
    bool? includeRewards,
    String? rewardsDescription,
    bool? askForShippingAddress,
    List<ArtworkRoyaltySplit>? royaltyShares,
    int? royaltyBps,
    int? primaryFeeBps,
    int? secondaryFeeBps,
    bool? disablePrimarySplit,
    FixedPriceFlowState? flow,
  }) => FixedPriceState(
    step: step ?? this.step,
    userPubkey: userPubkey ?? this.userPubkey,
    entryFromArtworkDetail:
        entryFromArtworkDetail ?? this.entryFromArtworkDetail,
    isSecondaryMarket: isSecondaryMarket ?? this.isSecondaryMarket,
    showVerifiedSellerOptions:
        showVerifiedSellerOptions ?? this.showVerifiedSellerOptions,
    selectedArtwork: identical(selectedArtwork, _sentinel)
        ? this.selectedArtwork
        : selectedArtwork as PortfolioArtwork?,
    updateAuthority: identical(updateAuthority, _sentinel)
        ? this.updateAuthority
        : updateAuthority as String?,
    price: price ?? this.price,
    currencyMint: identical(currencyMint, _sentinel)
        ? this.currencyMint
        : currencyMint as String?,
    editionsLimit: editionsLimit ?? this.editionsLimit,
    includePhysical: includePhysical ?? this.includePhysical,
    physical: identical(physical, _sentinel)
        ? this.physical
        : physical as PhysicalDetailsPayload?,
    includeRewards: includeRewards ?? this.includeRewards,
    rewardsDescription: rewardsDescription ?? this.rewardsDescription,
    askForShippingAddress: askForShippingAddress ?? this.askForShippingAddress,
    royaltyShares: royaltyShares ?? this.royaltyShares,
    royaltyBps: royaltyBps ?? this.royaltyBps,
    primaryFeeBps: primaryFeeBps ?? this.primaryFeeBps,
    secondaryFeeBps: secondaryFeeBps ?? this.secondaryFeeBps,
    disablePrimarySplit: disablePrimarySplit ?? this.disablePrimarySplit,
    flow: flow ?? this.flow,
  );

  @override
  List<Object?> get props => [
    step,
    userPubkey,
    entryFromArtworkDetail,
    isSecondaryMarket,
    showVerifiedSellerOptions,
    selectedArtwork,
    updateAuthority,
    price,
    currencyMint,
    editionsLimit,
    includePhysical,
    physical,
    includeRewards,
    rewardsDescription,
    askForShippingAddress,
    royaltyShares,
    royaltyBps,
    primaryFeeBps,
    secondaryFeeBps,
    disablePrimarySplit,
    flow,
  ];

  /// Steps visible in this flow. The select-artwork step is dropped when
  /// the flow was entered from the artwork detail screen. The
  /// additional-options step is dropped when the seller can't use the
  /// physical/rewards features (secondary-market sales) — there'd be nothing
  /// to show, so we skip it rather than render an empty state.
  List<FixedPriceStep> get visibleSteps => FixedPriceStep.values
      .where(
        (s) => s != FixedPriceStep.selectArtwork || !entryFromArtworkDetail,
      )
      .where(
        (s) =>
            s != FixedPriceStep.additionalOptions || showVerifiedSellerOptions,
      )
      .toList(growable: false);

  /// 0..1 progress fraction. Matches `AuctionState.progressFraction` —
  /// `(visibleIndex + 2) / (visible.length + 2)`. The +2 reserves slot 1
  /// for the upstream sell-type chooser and the final slot for success.
  double get progressFraction {
    if (flow is TxFlowSuccess) return 1.0;
    final visible = visibleSteps;
    final idx = visible.indexOf(step);
    if (idx < 0) return 0;
    return (idx + 2) / (visible.length + 2);
  }

  bool get canGoNext => switch (step) {
    FixedPriceStep.selectArtwork => selectedArtwork != null,
    FixedPriceStep.pricing => _pricingValid,
    FixedPriceStep.additionalOptions => _additionalValid,
    FixedPriceStep.review => true,
  };

  /// True when the selected artwork is a master edition that the seller
  /// can mint copies from (LimitedEdition or OpenEdition supply types).
  /// The backend uses this same shape (via DAS) to decide whether to call
  /// `mallowMarket.listEditions` instead of `listNft`.
  bool get isMasterEdition {
    final a = selectedArtwork;
    if (a == null) return false;
    if (a.parentEdition != null) return false; // edition print, not master
    final maxSupply = a.maxSupply ?? 0;
    final supply = a.supply ?? 0;
    // LimitedEdition: maxSupply > 1. OpenEdition: maxSupply == 0/null but
    // supply > 0. Either way, this seller can list more copies.
    return maxSupply > 1 || (maxSupply <= 0 && supply > 0);
  }

  /// Remaining supply for a master edition (informational), or null when
  /// the asset is open-edition / not a master.
  int? get editionsAvailable {
    if (!isMasterEdition) return null;
    final maxSupply = selectedArtwork?.maxSupply ?? 0;
    if (maxSupply <= 0) return null; // open edition — no upper cap
    final supply = selectedArtwork?.supply ?? 0;
    return (maxSupply - supply).clamp(0, maxSupply);
  }

  /// Validation error for the pricing step, surfaced on the review step
  /// when non-null. Mirrors the auction's `pricingError` shape.
  ///
  /// `editionsLimit` is intentionally not required: it's a per-buyer-wallet
  /// purchase cap, not a total-supply cap. `0` means "no cap" and is a
  /// valid choice. We do clamp it to the on-chain `u16` range when set.
  String? get pricingError {
    if (price <= 0) return 'Price is required';
    final token = tokenByMint(currencyMint) ?? defaultBidToken;
    if (price < token.minListingPrice) {
      return 'Minimum price is ${token.minListingDisplay} ${token.symbol}';
    }
    if (isMasterEdition && editionsLimit > 0xFFFF) {
      return 'Per-wallet cap exceeds maximum (65535)';
    }
    return null;
  }

  bool get _pricingValid => pricingError == null;

  bool get _additionalValid {
    if (includeRewards && rewardsDescription.trim().isEmpty) return false;
    if (includePhysical && (physical?.description.trim().isEmpty ?? true)) {
      return false;
    }
    return true;
  }

  /// Whether to show the "Direct all proceeds to creators" toggle. Mirrors
  /// webapp `ProceedsInfo`'s `showDirectProceedsOption`: only on a primary
  /// sale with creator shares where the seller isn't the first creator (the
  /// split is a no-op otherwise).
  bool get showDirectProceedsOption => showDirectProceedsOptionOf(
    isSecondary: isSecondaryMarket,
    seller: userPubkey,
    shares: royaltyShares,
  );

  /// Pre-computed proceeds rows for the review step. Empty when no seller
  /// is set (i.e. before the bloc has hydrated).
  List<ProceedsSplit> get proceedsSplits {
    if (userPubkey.isEmpty) return const [];
    return computeProceedsSplits(
      seller: userPubkey,
      priceRaw: price,
      isSecondary: isSecondaryMarket,
      royaltyShares: royaltyShares,
      royaltyBps: royaltyBps,
      primaryFeeBps: primaryFeeBps,
      secondaryFeeBps: secondaryFeeBps,
      disablePrimarySplit: disablePrimarySplit,
    );
  }

  /// Build the `getCreateBuyNowTx` request from the current form fields.
  /// `editionsLimit` is only sent for master-edition listings; the backend
  /// branches between `mallowMarket.listNft` and `listEditions` based on
  /// the asset's supply type derived server-side from DAS. Caller supplies
  /// the priority fee from the injected [FeeConfig] — the state class has
  /// no DI access.
  CreateFixedPriceTxRequest toRequest({
    required int priorityFeeLamports,
    String? memo,
  }) {
    return CreateFixedPriceTxRequest(
      asset: selectedArtwork!.mintAccount,
      seller: userPubkey,
      price: price,
      currencyMint: currencyMint,
      editionsLimit: isMasterEdition ? editionsLimit : null,
      enablePrimarySplit: !disablePrimarySplit,
      memo: memo,
      targetPriorityFeeLamports: priorityFeeLamports,
    );
  }

  RewardsDescriptionPayload? toRewardsPayload() {
    if (!includeRewards && !includePhysical) return null;
    return RewardsDescriptionPayload(
      rewardsDescription: includeRewards && rewardsDescription.trim().isNotEmpty
          ? rewardsDescription.trim()
          : null,
      includesPhysical: includePhysical,
      physicalDetails: includePhysical ? physical : null,
      askForShippingAddress: askForShippingAddress,
    );
  }
}

@injectable
class FixedPriceBloc extends Bloc<FixedPriceEvent, FixedPriceState> {
  FixedPriceBloc(
    this._fixedPriceRepo,
    this._rewardsRepo,
    this._walletManager,
    this._dasApi,
    this._artworkRepo,
    this._marketplaceConfig,
    this._realtime,
    this._flow,
    this._feeConfig,
    this._txLandedSlots,
  ) : super(const FixedPriceState()) {
    on<FixedPriceStarted>(_onStarted);
    on<FixedPriceNext>(_onNext);
    on<FixedPriceBack>(_onBack);
    on<FixedPriceGotoStep>((e, emit) => emit(state.copyWith(step: e.step)));
    on<FixedPriceSelectArtwork>(_onSelectArtwork);

    on<FixedPriceSetPrice>(
      (e, emit) => emit(state.copyWith(price: e.rawAmount)),
    );
    on<FixedPriceSetCurrencyMint>((e, emit) {
      // Clear the price on currency change so a stale raw amount in the
      // old token's decimals can't slip through.
      emit(state.copyWith(currencyMint: e.mint, price: 0));
    });
    on<FixedPriceSetEditionsLimit>(
      (e, emit) => emit(state.copyWith(editionsLimit: e.value)),
    );
    on<FixedPriceSetDisablePrimarySplit>(
      (e, emit) => emit(state.copyWith(disablePrimarySplit: e.value)),
    );

    on<FixedPriceSetIncludePhysical>(
      (e, emit) => emit(state.copyWith(includePhysical: e.value)),
    );
    on<FixedPriceSetPhysical>(
      (e, emit) => emit(state.copyWith(physical: e.value)),
    );
    on<FixedPriceSetIncludeRewards>(
      (e, emit) => emit(state.copyWith(includeRewards: e.value)),
    );
    on<FixedPriceSetRewardsDescription>(
      (e, emit) => emit(state.copyWith(rewardsDescription: e.value)),
    );
    on<FixedPriceSetAskForShippingAddress>(
      (e, emit) => emit(state.copyWith(askForShippingAddress: e.value)),
    );

    on<FixedPriceRequestList>(_onRequestList);
    on<FixedPriceIndexedAck>(_onIndexedAck);
    on<FixedPriceDismissError>(
      (e, emit) => emit(state.copyWith(flow: const TxFlowIdle())),
    );
    on<FixedPriceReset>((e, emit) {
      _txTracker.clear();
      emit(const FixedPriceState());
    });
  }

  final FixedPriceRepository _fixedPriceRepo;
  final RewardsRepository _rewardsRepo;
  final WalletManager _walletManager;
  final DasApiService _dasApi;
  final ArtworkRepository _artworkRepo;
  final MarketplaceConfigService _marketplaceConfig;
  final MarketRealtimeService _realtime;
  final TxLandedSlots _txLandedSlots;
  final MarketplaceActionFlow _flow;
  final FeeConfig _feeConfig;

  final _txTracker = StaleTxTracker<List<String>>();

  Future<void> _onStarted(
    FixedPriceStarted event,
    Emitter<FixedPriceState> emit,
  ) async {
    final pubkey = await _walletManager.getAddress();
    final entryFromDetail = event.mintAccount != null || event.artwork != null;

    emit(
      state.copyWith(
        userPubkey: pubkey,
        entryFromArtworkDetail: entryFromDetail,
        selectedArtwork: event.artwork ?? state.selectedArtwork,
        step: entryFromDetail
            ? FixedPriceStep.pricing
            : FixedPriceStep.selectArtwork,
      ),
    );

    final mint = event.mintAccount ?? event.artwork?.mintAccount;
    if (mint == null) return;

    await _hydrateForMint(mint: mint, pubkey: pubkey, emit: emit);
  }

  /// Picker path: selecting an artwork with no preselected mint
  /// must run the same hydration `_onStarted` does, otherwise the review step
  /// keeps the empty defaults and the proceeds breakdown / toggle are wrong.
  /// The selection emits immediately; hydration follows asynchronously.
  Future<void> _onSelectArtwork(
    FixedPriceSelectArtwork event,
    Emitter<FixedPriceState> emit,
  ) async {
    emit(state.copyWith(selectedArtwork: event.artwork));
    await _hydrateForMint(
      mint: event.artwork.mintAccount,
      pubkey: state.userPubkey,
      emit: emit,
      guardSelection: true,
    );
  }

  /// Shared royalty/fee/secondary-market resolution for both the `started`
  /// and select-artwork paths. When [guardSelection] is set, a newer picker
  /// selection that landed while the network round-trip was in flight cancels
  /// this stale emit.
  Future<void> _hydrateForMint({
    required String mint,
    required String pubkey,
    required Emitter<FixedPriceState> emit,
    bool guardSelection = false,
  }) async {
    final ctx = await resolveListingContext(
      mint: mint,
      sellerPubkey: pubkey,
      dasApi: _dasApi,
      artworkRepo: _artworkRepo,
      marketplaceConfig: _marketplaceConfig,
    );

    // Drop a stale hydration whose selection has since been replaced.
    if (guardSelection && state.selectedArtwork?.mintAccount != mint) return;

    emit(
      state.copyWith(
        isSecondaryMarket: ctx.isSecondaryMarket,
        showVerifiedSellerOptions: ctx.isVerifiedSeller,
        royaltyShares: ctx.royaltyShares,
        royaltyBps: ctx.royaltyBps,
        primaryFeeBps: ctx.primaryFeeBps,
        secondaryFeeBps: ctx.secondaryFeeBps,
        selectedArtwork:
            state.selectedArtwork ?? ctx.detail?.toPortfolioArtwork(),
        updateAuthority: ctx.updateAuthority,
      ),
    );
  }

  void _onNext(FixedPriceNext event, Emitter<FixedPriceState> emit) {
    if (!state.canGoNext) return;
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx < 0 || idx + 1 >= visible.length) return;
    emit(state.copyWith(step: visible[idx + 1]));
  }

  void _onBack(FixedPriceBack event, Emitter<FixedPriceState> emit) {
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx <= 0) return;
    emit(state.copyWith(step: visible[idx - 1]));
  }

  Future<void> _onRequestList(
    FixedPriceRequestList event,
    Emitter<FixedPriceState> emit,
  ) async {
    if (state.selectedArtwork == null) return;
    if (state.pricingError != null) {
      // Form validation problem, not a tx failure — classify as
      // `validation` and surface the raw message without the
      // "Listing failed:" prefix that `prefixedWith` adds.
      emit(
        state.copyWith(
          flow: TxFlowFailure(AppFailure.validation(state.pricingError!)),
        ),
      );
      return;
    }

    final sink = txFlowSink<void, FixedPriceSuccessData>(
      (flow) => emit(state.copyWith(flow: flow)),
    );

    // 1. Persist rewards/physical metadata up-front (once per list attempt) and
    // fold its id into the listing memo. This must NOT live inside the `prepare`
    // build closure below: `StaleTxTracker` replays that closure on a
    // stale-blockhash refresh, and `postRewardsDescription` is non-idempotent,
    // so a replay would persist a duplicate record and orphan the first. Doing
    // it here means a refresh only rebuilds the (idempotent) listing tx around
    // the same memo. A fresh retry re-runs this handler and re-persists, which
    // matches the pre-migration behaviour.
    final rewardsResult = await Result.guard(() async {
      final rewardsPayload = state.toRewardsPayload();
      if (rewardsPayload == null) return null;
      final id = await _rewardsRepo.postRewardsDescription(rewardsPayload);
      return 'rewards:$id';
    });
    final String? memo;
    switch (rewardsResult) {
      case ResultSuccess(:final value):
        memo = value;
      case ResultFailure(:final error):
        sink.onFailure(error.prefixedWith('Listing failed'));
        return;
    }

    // 2. Prepare: build the listing tx (plus an optional LUT setup tx for
    // non-Core master editions) and track it for stale-blockhash replay. Seller
    // pubkey is already on `state.userPubkey`, so `requireWallet` is false. The
    // batch order is `[setupTx, listingTx]` — the executor chains them in order
    // and stops on the first failure.
    List<String>? builtBatch;
    await _flow.prepare<void, FixedPriceSuccessData>(
      sink: sink,
      tracker: _txTracker,
      requireWallet: false,
      build: (_) async {
        final response = await _fixedPriceRepo.getCreateBuyNowTx(
          state.toRequest(
            memo: memo,
            priorityFeeLamports: _feeConfig.priorityFeeLamports,
          ),
        );
        return builtBatch = [?response.result.setupTx, response.result.tx];
      },
      // No confirmation sheet — the flow runs end-to-end without a
      // user-facing confirm step (TPrep is void, onReady is transient).
      toPrep: (_, _) {},
      errorPrefix: 'Listing failed',
    );

    // Bail on prepare failure (sink already emitted TxFlowFailure).
    final txs = builtBatch;
    if (txs == null ||
        state.flow is! TxFlowReady<void, FixedPriceSuccessData>) {
      return;
    }

    // Local-key wallets sign without a user-facing approval prompt — surface
    // the local signing copy instead of the misleading wallet prompt.
    final isLocal = await _walletManager.isLocalSigner();

    // 3. Execute: sign + broadcast the batch. For the two-step (setup + listing)
    // flow, `stageFor` carries the step count in the signing copy so the user
    // knows a second prompt is coming. The executor chains the txs in order and
    // runs the indexer poll on the last (listing) signature.
    await _flow.execute(
      sink: sink,
      tracker: _txTracker,
      txsBase64: txs,
      usdValue: 0.0,
      flow: const FlowKey.solana(AppFlow.fixedPriceCreate),
      stageFor: (index, total, ledger) {
        if (ledger) return kLedgerSigningStage;
        if (isLocal) return kLocalSigningLabel;
        if (total > 1) {
          return '$kExternalSigningLabel (${index + 1} of $total)';
        }
        return kExternalSigningLabel;
      },
      toSuccess: (_) => const FixedPriceSuccessData(),
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(FixedPriceEvent.indexedAck(signature: sig, ok: ok)),
      // Listing state on the artwork screen is read off `/byMint`, which
      // only reflects the listing once its marketplace entry is indexed
      // (strictly later than the tx-level `checkTx` ack). Gate on the
      // entry so the post-list refresh reads the new listing, not stale
      // pre-listing state.
      requireEntry: true,
      failurePrefix: 'Listing failed',
      emptyTxMessage: 'No listing transaction',
    );
  }

  void _onIndexedAck(
    FixedPriceIndexedAck event,
    Emitter<FixedPriceState> emit,
  ) {
    final flow = state.flow;
    if (flow is! TxFlowSuccess<void, FixedPriceSuccessData>) return;
    if (flow.signature != event.signature) return;
    emit(
      state.copyWith(
        flow: TxFlowSuccess(
          signature: flow.signature,
          result: flow.result.copyWith(indexed: event.ok),
        ),
      ),
    );

    // Drive every screen subscribed to this mint (artwork detail, portfolio,
    // home) the moment the indexer confirms. Fire even on a non-ok poll: a
    // timed-out `checkTx` doesn't mean the listing failed (the indexer may
    // still be catching up), and refetching is harmless — it just re-pulls
    // whatever the true server state is.
    final mint = state.selectedArtwork?.mintAccount;
    debugPrint(
      '[LIST-DEBUG] FixedPrice indexedAck ok=${event.ok} mint=$mint '
      '@${DateTime.now().toIso8601String()}',
    );
    if (mint != null) {
      _realtime.publishLocal(
        mintAccount: mint,
        signature: event.signature,
        programs: const [kMallowMarketProgramId],
        // Landed slot (recorded at confirmation) — lets the artwork screen
        // raise its chain floor so a lagging RPC read can't clear the fresh
        // listing.
        slot: _txLandedSlots.slotFor(event.signature) ?? 0,
      );
      // The listing price and badge are what every browse/list tile renders
      // for this mint — home rails, collection + curation grids, profile
      // grids. `publishLocal` only reaches the detail screen's account
      // subscriptions, so without this they keep serving the pre-listing
      // price.
      notifyArtworkEdited(mint);
    }
    // Listing an artwork changes its My Art card (listed badge + price), so
    // refetch the portfolio now that the listing entry is indexed.
    notifyPortfolioRefresh();
  }
}
