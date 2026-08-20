import 'package:freezed_annotation/freezed_annotation.dart';

part 'live_market_state.freezed.dart';
part 'live_market_state.g.dart';

/// Live `MallowAuction` PDA snapshot. Used by `AuctionLiveRepository` to
/// keep the countdown / "Highest bid by …" line in sync with chain state
/// while an auction is running. Authoritative `currentBidder` and
/// `isSettled` flag.
@freezed
sealed class AuctionLiveState with _$AuctionLiveState {
  const factory AuctionLiveState({
    required String auctionAccount,
    required String seller,
    required String bidMint,
    required int reservePrice,
    int? currentBidAmount,
    String? currentBidder,
    @Default(0) int bidCount,
    DateTime? startsAt,
    DateTime? endsAt,
    @Default(false) bool isSettled,
  }) = _AuctionLiveState;

  factory AuctionLiveState.fromJson(Map<String, dynamic> json) => _$AuctionLiveStateFromJson(json);
}

/// Live `Rafffle` PDA snapshot. Used by `RaffleRepository` for
/// authoritative draw / claim state. Matches the v2
/// `GET /v2/raffles/:raffle_key` response (`RaffleStateResponse`).
@freezed
sealed class RaffleLiveState with _$RaffleLiveState {
  const factory RaffleLiveState({
    required String raffleAccount,
    required String creator,
    required String prizeMint,
    required String currencyMint,
    @Default(0) int ticketPrice,
    @Default(0) int supply,
    @Default(0) int sold,

    /// Per-wallet ticket cap — 0 = no limit.
    @Default(0) int ticketLimit,
    DateTime? endTime,
    String? winner,
    @Default(false) bool isPrizeClaimed,

    /// True once the entrants account is closed (creator collected
    /// proceeds).
    @Default(false) bool isClaimed,
    @Default(false) bool isExpired,

    /// Per-buyer ticket count, keyed by address.
    Map<String, int>? countByEntrant,
  }) = _RaffleLiveState;

  factory RaffleLiveState.fromJson(Map<String, dynamic> json) => _$RaffleLiveStateFromJson(json);
}

/// DAS-derived edition state. Returned by
/// `GET /v2/editions/:mint`. The backend wraps
/// `getSupplyInfoFromDigitalAsset` + `isPrintableMasterEditionFromSupplyType`
/// so the dispatcher doesn't need to re-implement token-standard-aware
/// branching in Dart. Drives `BuyEditionSheet` ↔ `BuySheet` routing and
/// the live supply progress bar.
@freezed
sealed class EditionLiveState with _$EditionLiveState {
  const factory EditionLiveState({
    /// Wire token-standard string (`nft`, `pnft`, `core`, `coreCollection`,
    /// `cnft`). Same shape as `NftDetail.tokenStandard`.
    required String tokenStandard,

    /// Authoritative master-edition flag. Use over the resolver's
    /// `supplyType` proxy.
    required bool isPrintableMasterEdition,
    required EditionSupplyInfo supplyInfo,

    /// Edition-print children only — the parent master mint.
    String? parentEdition,

    /// Edition-print children only — 1-indexed serial number.
    int? editionNumber,
  }) = _EditionLiveState;

  factory EditionLiveState.fromJson(Map<String, dynamic> json) => _$EditionLiveStateFromJson(json);
}

@freezed
sealed class EditionSupplyInfo with _$EditionSupplyInfo {
  const factory EditionSupplyInfo({
    @Default(0) int supply,

    /// Null = open edition (no cap).
    int? maxSupply,
  }) = _EditionSupplyInfo;

  factory EditionSupplyInfo.fromJson(Map<String, dynamic> json) =>
      _$EditionSupplyInfoFromJson(json);
}

/// Response body for `GET /v2/editions/:mint/buyers/:buyer`. Drives the
/// `ArtworkBuyEditionSheet` "Wallet limit reached" / "Not allowlisted"
/// disabled states.
@freezed
sealed class EditionPurchaseStats with _$EditionPurchaseStats {
  const factory EditionPurchaseStats({
    /// Editions this wallet has already purchased on this listing.
    @Default(0) int buyCount,

    /// `listing.editionsLimit` — 0 = no per-wallet cap.
    @Default(0) int walletLimit,
    EditionWhitelistConfig? whitelistConfig,

    /// Minimum RPC context slot across the on-chain reads that built this
    /// payload — "state as of at least slot X". Lets callers order the stats
    /// against a just-landed buy's slot (a view older than the buy hasn't
    /// seen it yet). Null on legacy backends.
    int? viewSlot,
  }) = _EditionPurchaseStats;

  factory EditionPurchaseStats.fromJson(Map<String, dynamic> json) =>
      _$EditionPurchaseStatsFromJson(json);
}

@freezed
sealed class EditionWhitelistConfig with _$EditionWhitelistConfig {
  const factory EditionWhitelistConfig({
    /// Base58 Merkle root — pass to
    /// `WhitelistEligibilityRepository.getEligibleRoots` to check the
    /// connected wallet against it.
    required String walletsRoot,
    @Default(0) int durationSec,

    /// True while the whitelist phase is in effect (within `durationSec`
    /// of the listing's startTime).
    @Default(false) bool isActive,
  }) = _EditionWhitelistConfig;

  factory EditionWhitelistConfig.fromJson(Map<String, dynamic> json) =>
      _$EditionWhitelistConfigFromJson(json);
}
