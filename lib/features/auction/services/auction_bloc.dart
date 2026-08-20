import 'package:equatable/equatable.dart';
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
import '../../../core/services/fee_config.dart'
    show kDefaultPriorityFeeLamports;
import '../../../core/services/marketplace_action_flow.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../core/services/tx_landed_slots.dart';
import '../../../shared/utils/artwork_mappers.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';
import '../../sale/services/direct_proceeds.dart';
import '../../sale/services/marketplace_config_service.dart';
import '../../sale/services/proceeds_calculator.dart';
import '../data/auction_repository.dart';
import '../data/rewards_repository.dart';

export '../../../core/services/transaction_flow_state.dart';

part 'auction_bloc.freezed.dart';

// Sentinel for AuctionState.copyWith — lets callers explicitly pass null on
// nullable fields without conflating "leave unchanged" with "set to null".
const Object _sentinel = Object();

/// The user-facing steps of the auction-listing flow. Indexed for the
/// progress bar — see [AuctionState.progressFraction].
enum AuctionStep { selectArtwork, pricing, timing, additionalOptions, review }

/// Domain-specific result payload carried by [TxFlowSuccess] for auction flows.
class AuctionSuccessData extends Equatable {
  const AuctionSuccessData({this.indexed});

  /// Indexer-ack flag for the just-broadcast listing. `null` while the
  /// background `checkTx` poll is running (success sheet shows
  /// optimistically); flips to `true` once the indexer acks (or `false`
  /// after retries exhaust — UI treats them the same: enable
  /// "View listing" CTAs).
  final bool? indexed;

  AuctionSuccessData copyWith({Object? indexed = _sentinel}) =>
      AuctionSuccessData(
        indexed: identical(indexed, _sentinel)
            ? this.indexed
            : indexed as bool?,
      );

  @override
  List<Object?> get props => [indexed];
}

/// Generic alias for the unified flow state with auction-specific payloads.
/// TPrep is void — auction has no confirm sheet; the flow runs end-to-end.
typedef AuctionFlowState = TransactionFlowState<void, AuctionSuccessData>;

@freezed
sealed class AuctionEvent with _$AuctionEvent {
  /// Hydrate user pubkey + (optional) preselected artwork. When
  /// [mintAccount] is supplied the select-artwork step is skipped.
  const factory AuctionEvent.started({
    String? mintAccount,
    PortfolioArtwork? artwork,
  }) = AuctionStarted;

  // --- Navigation ---
  const factory AuctionEvent.next() = AuctionNext;
  const factory AuctionEvent.back() = AuctionBack;
  const factory AuctionEvent.gotoStep(AuctionStep step) = AuctionGotoStep;
  const factory AuctionEvent.selectArtwork(PortfolioArtwork artwork) =
      AuctionSelectArtwork;

  // --- Pricing step ---
  const factory AuctionEvent.setReservePrice(int rawAmount) =
      AuctionSetReservePrice;
  const factory AuctionEvent.setBidMint(String? mint) = AuctionSetBidMint;
  const factory AuctionEvent.setMinBidIncrement({
    required int value,
    required bool absolute,
  }) = AuctionSetMinBidIncrement;

  /// Review step — "Direct all proceeds to creators" toggle.
  const factory AuctionEvent.setDisablePrimarySplit(bool value) =
      AuctionSetDisablePrimarySplit;

  // --- Timing step ---
  const factory AuctionEvent.setStartTime(int value) = AuctionSetStartTime;
  const factory AuctionEvent.setDuration(int seconds) = AuctionSetDuration;
  const factory AuctionEvent.setTimeExtPeriod(int seconds) =
      AuctionSetTimeExtPeriod;

  // --- Additional options step ---
  const factory AuctionEvent.setIncludePhysical(bool value) =
      AuctionSetIncludePhysical;
  const factory AuctionEvent.setPhysical(PhysicalDetailsPayload value) =
      AuctionSetPhysical;
  const factory AuctionEvent.setIncludeRewards(bool value) =
      AuctionSetIncludeRewards;
  const factory AuctionEvent.setRewardsDescription(String value) =
      AuctionSetRewardsDescription;
  const factory AuctionEvent.setAskForShippingAddress(bool value) =
      AuctionSetAskForShippingAddress;

  // --- Pipeline ---
  const factory AuctionEvent.requestList() = AuctionRequestList;
  const factory AuctionEvent.dismissError() = AuctionDismissError;
  const factory AuctionEvent.reset() = AuctionReset;

  /// Internal — emitted by the background `_runCheckTx` poll once the
  /// indexer acks the listing tx (or gives up). Drives [AuctionSuccessData.indexed].
  const factory AuctionEvent.indexedAck({
    required String signature,
    required bool ok,
  }) = AuctionIndexedAck;
}

class AuctionState extends Equatable {
  const AuctionState({
    this.step = AuctionStep.selectArtwork,
    this.userPubkey = '',
    this.entryFromArtworkDetail = false,
    this.isSecondaryMarket = false,
    this.showVerifiedSellerOptions = false,
    this.selectedArtwork,
    this.updateAuthority,
    this.royaltyShares = const <ArtworkRoyaltySplit>[],
    this.royaltyBps = 0,
    this.primaryFeeBps = 500,
    this.secondaryFeeBps = 250,
    this.disablePrimarySplit = false,
    this.reservePrice = 0,
    this.minBidIncrement = 500,
    this.absoluteIncrement = false,
    this.bidMint,
    this.startTime = 0,
    this.duration = 86400,
    this.timeExtPeriod = 900,
    this.timeExtDelta = 900,
    this.includePhysical = false,
    this.physical,
    this.includeRewards = false,
    this.rewardsDescription = '',
    this.askForShippingAddress = false,
    this.flow = const TxFlowIdle(),
  });

  final AuctionStep step;

  // Wallet / context
  final String userPubkey;

  /// True when entered from the artwork detail screen with a preselected
  /// mint — the select-artwork step is skipped and the progress bar
  /// reflects the smaller flow.
  final bool entryFromArtworkDetail;

  /// True when the listing is on the secondary market (the user is not the
  /// verified update authority). Drives the proceeds split logic.
  final bool isSecondaryMarket;

  /// Webapp parity: `(onChainAsset != null && !isSecondaryMarket(...)) ||
  /// isApprovedCreator(user)` (`ListingContext`). For now we
  /// derive only the non-secondary-market arm via DAS creator info; the
  /// approved-creator role isn't surfaced in the Flutter user model yet.
  final bool showVerifiedSellerOptions;

  final PortfolioArtwork? selectedArtwork;

  /// On-chain update authority for the selected mint, populated from the
  /// DAS asset lookup. Used as the review-step fallback label when the
  /// artist has no mallow username.
  final String? updateAuthority;

  // Royalty + fee data, populated on `started`. Defaults match webapp's
  // `DEFAULT_PRIMARY_BPS` / `DEFAULT_SECONDARY_BPS`.
  final List<ArtworkRoyaltySplit> royaltyShares;
  final int royaltyBps;
  final int primaryFeeBps;
  final int secondaryFeeBps;

  /// Seller opt-in for the webapp's "Direct all proceeds to creators" toggle.
  /// When true, a primary sale is split like a secondary one: creators get
  /// only their royalty %, the remainder goes to the seller. Mirrors
  /// `ListingContext`'s `createAuctionArgs.disablePrimarySplit` (default
  /// false). Only surfaced when [showDirectProceedsOption] is true.
  final bool disablePrimarySplit;

  // Pricing — defaults match `ListingContext`.
  final int reservePrice;
  final int minBidIncrement;
  final bool absoluteIncrement;
  final String? bidMint;

  // Timing
  final int startTime;
  final int duration;
  final int timeExtPeriod;
  final int timeExtDelta;

  // Additional options
  final bool includePhysical;
  final PhysicalDetailsPayload? physical;
  final bool includeRewards;
  final String rewardsDescription;
  final bool askForShippingAddress;

  /// Unified transaction-flow state. Replaces the former
  /// `pipelineStatus`/`pipelineStage`/`pipelineError`/`successSignature`/
  /// `successIndexed` cluster.
  final AuctionFlowState flow;

  AuctionState copyWith({
    AuctionStep? step,
    String? userPubkey,
    bool? entryFromArtworkDetail,
    bool? isSecondaryMarket,
    bool? showVerifiedSellerOptions,
    Object? selectedArtwork = _sentinel,
    Object? updateAuthority = _sentinel,
    List<ArtworkRoyaltySplit>? royaltyShares,
    int? royaltyBps,
    int? primaryFeeBps,
    int? secondaryFeeBps,
    bool? disablePrimarySplit,
    int? reservePrice,
    int? minBidIncrement,
    bool? absoluteIncrement,
    Object? bidMint = _sentinel,
    int? startTime,
    int? duration,
    int? timeExtPeriod,
    int? timeExtDelta,
    bool? includePhysical,
    Object? physical = _sentinel,
    bool? includeRewards,
    String? rewardsDescription,
    bool? askForShippingAddress,
    AuctionFlowState? flow,
  }) => AuctionState(
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
    royaltyShares: royaltyShares ?? this.royaltyShares,
    royaltyBps: royaltyBps ?? this.royaltyBps,
    primaryFeeBps: primaryFeeBps ?? this.primaryFeeBps,
    secondaryFeeBps: secondaryFeeBps ?? this.secondaryFeeBps,
    disablePrimarySplit: disablePrimarySplit ?? this.disablePrimarySplit,
    reservePrice: reservePrice ?? this.reservePrice,
    minBidIncrement: minBidIncrement ?? this.minBidIncrement,
    absoluteIncrement: absoluteIncrement ?? this.absoluteIncrement,
    bidMint: identical(bidMint, _sentinel) ? this.bidMint : bidMint as String?,
    startTime: startTime ?? this.startTime,
    duration: duration ?? this.duration,
    timeExtPeriod: timeExtPeriod ?? this.timeExtPeriod,
    timeExtDelta: timeExtDelta ?? this.timeExtDelta,
    includePhysical: includePhysical ?? this.includePhysical,
    physical: identical(physical, _sentinel)
        ? this.physical
        : physical as PhysicalDetailsPayload?,
    includeRewards: includeRewards ?? this.includeRewards,
    rewardsDescription: rewardsDescription ?? this.rewardsDescription,
    askForShippingAddress: askForShippingAddress ?? this.askForShippingAddress,
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
    royaltyShares,
    royaltyBps,
    primaryFeeBps,
    secondaryFeeBps,
    disablePrimarySplit,
    reservePrice,
    minBidIncrement,
    absoluteIncrement,
    bidMint,
    startTime,
    duration,
    timeExtPeriod,
    timeExtDelta,
    includePhysical,
    physical,
    includeRewards,
    rewardsDescription,
    askForShippingAddress,
    flow,
  ];

  /// Steps visible in this flow. The select-artwork step is dropped when
  /// the flow was entered from the artwork detail screen. The
  /// additional-options step is dropped when the seller can't use the
  /// physical/rewards features (secondary-market sales) — there'd be nothing
  /// to show, so we skip it rather than render an empty state.
  List<AuctionStep> get visibleSteps => AuctionStep.values
      .where((s) => s != AuctionStep.selectArtwork || !entryFromArtworkDetail)
      .where(
        (s) => s != AuctionStep.additionalOptions || showVerifiedSellerOptions,
      )
      .toList(growable: false);

  /// 0..1 progress fraction. Mirrors [MintState.progressFraction] —
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
    AuctionStep.selectArtwork => selectedArtwork != null,
    AuctionStep.pricing => _pricingValid,
    AuctionStep.timing => duration > 0,
    AuctionStep.additionalOptions => _additionalValid,
    AuctionStep.review => true,
  };

  /// Validation errors mirroring `ListingContext`. Returned as a
  /// human-readable message so the review step can surface it; null when
  /// valid.
  String? get pricingError {
    if (reservePrice <= 0) return 'Reserve starting bid is required';
    final token = tokenByMint(bidMint) ?? defaultBidToken;
    if (reservePrice < token.minListingPrice) {
      return 'Minimum reserve price is ${token.minListingDisplay} ${token.symbol}';
    }
    if (absoluteIncrement) {
      if (minBidIncrement < token.minListingPrice) {
        return 'Minimum bid increment must be at least '
            '${token.minListingDisplay} ${token.symbol}';
      }
    } else {
      // 10 = 0.1% in the bps*100 storage format used by the program.
      if (minBidIncrement < 10) {
        return 'Minimum bid increment must be at least 0.1%';
      }
    }
    return null;
  }

  bool get _pricingValid => pricingError == null;

  /// Whether to show the "Direct all proceeds to creators" toggle. Mirrors
  /// webapp `ProceedsInfo`'s `showDirectProceedsOption`: only on a primary
  /// sale with creator shares where the seller isn't the first creator (the
  /// split is a no-op otherwise).
  bool get showDirectProceedsOption => showDirectProceedsOptionOf(
    isSecondary: isSecondaryMarket,
    seller: userPubkey,
    shares: royaltyShares,
  );

  /// Pre-computed proceeds rows for the review step. Empty before the bloc has
  /// hydrated a seller. Auctions always show percentages (no fixed sale price
  /// at listing time), so the amount column is driven by [reservePrice].
  List<ProceedsSplit> get proceedsSplits {
    if (userPubkey.isEmpty) return const [];
    return computeProceedsSplits(
      seller: userPubkey,
      priceRaw: reservePrice,
      isSecondary: isSecondaryMarket,
      royaltyShares: royaltyShares,
      royaltyBps: royaltyBps,
      primaryFeeBps: primaryFeeBps,
      secondaryFeeBps: secondaryFeeBps,
      disablePrimarySplit: disablePrimarySplit,
    );
  }

  bool get _additionalValid {
    if (includeRewards && rewardsDescription.trim().isEmpty) return false;
    if (includePhysical && (physical?.description.trim().isEmpty ?? true)) {
      return false;
    }
    return true;
  }

  /// Build the `getCreateAuctionTx` request from the current form fields.
  /// Caller supplies the optional rewards `memo`.
  CreateAuctionTxRequest toRequest({String? memo}) {
    return CreateAuctionTxRequest(
      asset: selectedArtwork!.mintAccount,
      seller: userPubkey,
      reservePrice: reservePrice,
      duration: duration,
      minBidIncrement: minBidIncrement,
      absoluteIncrement: absoluteIncrement,
      startTime: startTime,
      timeExtPeriod: timeExtPeriod,
      timeExtDelta: timeExtDelta,
      bidMint: bidMint,
      enablePrimarySplit: !disablePrimarySplit,
      memo: memo,
      // Backend's `createTransactionWithOptionalSwap` only falls back to the
      // default when this is `undefined`; passing `null` would leave a
      // 0-fee compute budget. See parity notes in the listing-flow plan.
      targetPriorityFeeLamports: kDefaultPriorityFeeLamports,
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
class AuctionBloc extends Bloc<AuctionEvent, AuctionState> {
  AuctionBloc(
    this._auctionRepo,
    this._rewardsRepo,
    this._walletManager,
    this._dasApi,
    this._artworkRepo,
    this._flow,
    this._realtime,
    this._txLandedSlots,
    this._marketplaceConfig,
  ) : super(const AuctionState()) {
    on<AuctionStarted>(_onStarted);
    on<AuctionNext>(_onNext);
    on<AuctionBack>(_onBack);
    on<AuctionGotoStep>((e, emit) => emit(state.copyWith(step: e.step)));
    on<AuctionSelectArtwork>(_onSelectArtwork);

    on<AuctionSetReservePrice>(
      (e, emit) => emit(state.copyWith(reservePrice: e.rawAmount)),
    );
    on<AuctionSetBidMint>((e, emit) {
      // Clearing the increment on token change matches
      // `AuctionListingDetails`.
      emit(state.copyWith(bidMint: e.mint, minBidIncrement: 0));
    });
    on<AuctionSetDisablePrimarySplit>(
      (e, emit) => emit(state.copyWith(disablePrimarySplit: e.value)),
    );

    on<AuctionSetMinBidIncrement>(
      (e, emit) => emit(
        state.copyWith(minBidIncrement: e.value, absoluteIncrement: e.absolute),
      ),
    );

    on<AuctionSetStartTime>(
      (e, emit) => emit(state.copyWith(startTime: e.value)),
    );
    on<AuctionSetDuration>(
      (e, emit) => emit(state.copyWith(duration: e.seconds)),
    );
    on<AuctionSetTimeExtPeriod>(
      (e, emit) => emit(
        // Webapp parity: setting the period also sets the delta to the same
        // value (`AuctionListingDetails`).
        state.copyWith(timeExtPeriod: e.seconds, timeExtDelta: e.seconds),
      ),
    );

    on<AuctionSetIncludePhysical>(
      (e, emit) => emit(state.copyWith(includePhysical: e.value)),
    );
    on<AuctionSetPhysical>(
      (e, emit) => emit(state.copyWith(physical: e.value)),
    );
    on<AuctionSetIncludeRewards>(
      (e, emit) => emit(state.copyWith(includeRewards: e.value)),
    );
    on<AuctionSetRewardsDescription>(
      (e, emit) => emit(state.copyWith(rewardsDescription: e.value)),
    );
    on<AuctionSetAskForShippingAddress>(
      (e, emit) => emit(state.copyWith(askForShippingAddress: e.value)),
    );

    on<AuctionRequestList>(_onRequestList);
    on<AuctionIndexedAck>(_onIndexedAck);
    on<AuctionDismissError>(
      (e, emit) => emit(state.copyWith(flow: const TxFlowIdle())),
    );
    on<AuctionReset>((e, emit) => emit(const AuctionState()));
  }

  final AuctionRepository _auctionRepo;
  final RewardsRepository _rewardsRepo;
  final WalletManager _walletManager;
  final DasApiService _dasApi;
  final ArtworkRepository _artworkRepo;
  final MarketplaceActionFlow _flow;
  final MarketRealtimeService _realtime;
  final TxLandedSlots _txLandedSlots;
  final MarketplaceConfigService _marketplaceConfig;

  Future<void> _onStarted(
    AuctionStarted event,
    Emitter<AuctionState> emit,
  ) async {
    final pubkey = await _walletManager.getAddress();
    final entryFromDetail = event.mintAccount != null || event.artwork != null;

    emit(
      state.copyWith(
        userPubkey: pubkey,
        entryFromArtworkDetail: entryFromDetail,
        selectedArtwork: event.artwork ?? state.selectedArtwork,
        step: entryFromDetail ? AuctionStep.pricing : AuctionStep.selectArtwork,
      ),
    );

    // Always resolve the on-chain asset + artwork detail (even when
    // preselected) so the review-step proceeds breakdown and the
    // secondary-market gate have real data. When entered via the sell chooser
    // with no mint, the picker's select-artwork handler runs the same
    // resolution once the seller picks something.
    final mint = event.mintAccount ?? event.artwork?.mintAccount;
    if (mint == null) return;

    await _hydrateForMint(mint: mint, pubkey: pubkey, emit: emit);
  }

  /// Picker path: selecting an artwork with no preselected mint
  /// must run the same hydration `_onStarted` does, otherwise the review step
  /// keeps the empty defaults (`royaltyShares=[]`, `isSecondaryMarket=false`,
  /// `primaryFeeBps=500`) and the toggle can never render / the breakdown is
  /// wrong. The selection emits immediately; hydration follows asynchronously.
  Future<void> _onSelectArtwork(
    AuctionSelectArtwork event,
    Emitter<AuctionState> emit,
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
    required Emitter<AuctionState> emit,
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

  void _onNext(AuctionNext event, Emitter<AuctionState> emit) {
    if (!state.canGoNext) return;
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx < 0 || idx + 1 >= visible.length) return;
    emit(state.copyWith(step: visible[idx + 1]));
  }

  void _onBack(AuctionBack event, Emitter<AuctionState> emit) {
    final visible = state.visibleSteps;
    final idx = visible.indexOf(state.step);
    if (idx <= 0) return;
    emit(state.copyWith(step: visible[idx - 1]));
  }

  Future<void> _onRequestList(
    AuctionRequestList event,
    Emitter<AuctionState> emit,
  ) async {
    if (state.selectedArtwork == null) return;
    if (state.pricingError != null) {
      // Form validation problem, not a tx failure — classify as
      // `validation` and surface the raw message without the
      // "Listing failed:" prefix that `prefixedWith` adds for real failures.
      emit(
        state.copyWith(
          flow: TxFlowFailure(AppFailure.validation(state.pricingError!)),
        ),
      );
      return;
    }

    emit(state.copyWith(flow: const TxFlowPreparing()));

    // 1. Persist rewards/physical metadata and fold its id into the memo.
    // 2. Ask the backend to build the unsigned createAuction tx.
    final buildResult = await Result.guard(() async {
      final rewardsPayload = state.toRewardsPayload();
      String? memo;
      if (rewardsPayload != null) {
        final id = await _rewardsRepo.postRewardsDescription(rewardsPayload);
        memo = 'rewards:$id';
      }
      return _auctionRepo.getCreateAuctionTx(state.toRequest(memo: memo));
    });

    final String unsignedTxBase64;
    switch (buildResult) {
      case ResultSuccess(:final value):
        unsignedTxBase64 = value;
      case ResultFailure(:final error):
        emit(
          state.copyWith(
            flow: TxFlowFailure(error.prefixedWith('Listing failed')),
          ),
        );
        return;
    }

    // 3. Sign + broadcast + confirm via [MarketplaceActionFlow].
    // Local-key wallets skip the user-facing approval prompt — surface
    // the local signing copy instead. Listing creation transfers the NFT into
    // escrow but does not move any SOL/token value out of the wallet
    // beyond ~5k lamports of network fee — well below the gate threshold.
    final isLocal = await _walletManager.isLocalSigner();
    String approvalCopy(bool ledger) => ledger
        ? kLedgerSigningStage
        : (isLocal ? kLocalSigningLabel : kExternalSigningLabel);

    await _flow.execute(
      sink: txFlowSink<void, AuctionSuccessData>(
        (flow) => emit(state.copyWith(flow: flow)),
      ),
      txsBase64: [unsignedTxBase64],
      usdValue: 0.0,
      flow: const FlowKey.solana(AppFlow.auctionCreate),
      stageFor: (_, _, ledger) => approvalCopy(ledger),
      toSuccess: (_) => const AuctionSuccessData(),
      isClosed: () => isClosed,
      onIndexedAck: (sig, ok) =>
          add(AuctionEvent.indexedAck(signature: sig, ok: ok)),
      // Creating an auction writes a `list` marketplace entry that the
      // artwork screen reads off `/byMint` (strictly later than the
      // tx-level `checkTx` ack). Gate on the entry so the post-list refresh
      // reads the live auction, not stale pre-listing state.
      requireEntry: true,
      failurePrefix: 'Listing failed',
    );
  }

  void _onIndexedAck(AuctionIndexedAck event, Emitter<AuctionState> emit) {
    final flow = state.flow;
    if (flow is! TxFlowSuccess<void, AuctionSuccessData>) return;
    if (flow.signature != event.signature) return;
    emit(
      state.copyWith(
        flow: TxFlowSuccess(
          signature: flow.signature,
          result: flow.result.copyWith(indexed: event.ok),
        ),
      ),
    );
    // Deterministically refresh every screen subscribed to this mint the moment
    // the auction entry indexes — parity with FixedPriceBloc's
    // publishLocal. The server invalidation and this self-trigger now agree
    // rather than racing, so a newly-created auction reliably surfaces on the
    // detail screen. Fire even on a non-ok poll: a timed-out checkTx doesn't
    // mean the listing failed, and a refetch just re-pulls true server state.
    final mint = state.selectedArtwork?.mintAccount;
    if (mint != null) {
      _realtime.publishLocal(
        mintAccount: mint,
        signature: event.signature,
        programs: const [kMallowAuctionProgramId],
        // Landed slot (recorded at confirmation) — lets the artwork screen
        // raise its chain floor so a lagging RPC read can't clear the fresh
        // auction.
        slot: _txLandedSlots.slotFor(event.signature) ?? 0,
      );
      // Same reasoning as the portfolio refresh below, for the surfaces the
      // portfolio signal doesn't cover: home rails, collection + curation
      // grids and profile grids render this mint's auction badge + price and
      // are not subscribed to the detail screen's refetch.
      notifyArtworkEdited(mint);
    }
    // Listing an artwork for auction changes its My Art card (auction badge +
    // price), so refetch the portfolio now that the entry is indexed.
    notifyPortfolioRefresh();
  }
}
