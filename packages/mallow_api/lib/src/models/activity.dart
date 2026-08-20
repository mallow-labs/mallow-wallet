import 'package:freezed_annotation/freezed_annotation.dart';

part 'activity.freezed.dart';
part 'activity.g.dart';

/// Activity types returned by the API.
enum ActivityType {
  @JsonValue('sale')
  sale,
  @JsonValue('buy')
  buy,
  @JsonValue('list')
  list,
  @JsonValue('delist')
  delist,
  @JsonValue('offer')
  offer,
  @JsonValue('offer-received')
  offerReceived,
  @JsonValue('mint')
  mint,
  @JsonValue('swap')
  swap,
  @JsonValue('send')
  send,
  @JsonValue('receive')
  receive,
  @JsonValue('gumball-create')
  gumballCreate,
  @JsonValue('gumball-update')
  gumballUpdate,
  @JsonValue('alt-create')
  altCreate,

  /// Native Solana stake-program actions. `stake` delegates a freshly funded
  /// stake account, `unstake` deactivates one (nothing moves until it is
  /// claimed), `stakeWithdraw` claims a deactivated account back to the wallet.
  @JsonValue('stake')
  stake,
  @JsonValue('unstake')
  unstake,
  @JsonValue('stake-withdraw')
  stakeWithdraw,
  @JsonValue('unknown')
  unknown,
}

/// Activity status.
enum ActivityStatus {
  @JsonValue('confirmed')
  confirmed,
  @JsonValue('finalized')
  finalized,
  @JsonValue('failed')
  failed,
}

/// Token information for swap and transfer activities.
@freezed
sealed class TokenInfo with _$TokenInfo {
  const factory TokenInfo({
    required String mint,
    required String symbol,
    required double amount,
    required int decimals,
    String? logoUrl,
  }) = _TokenInfo;

  factory TokenInfo.fromJson(Map<String, dynamic> json) => _$TokenInfoFromJson(json);
}

/// Counterparty information (buyer/seller/sender/recipient).
@freezed
sealed class Counterparty with _$Counterparty {
  const factory Counterparty({required String address, String? username, String? avatarUrl}) =
      _Counterparty;

  factory Counterparty.fromJson(Map<String, dynamic> json) => _$CounterpartyFromJson(json);
}

/// Artwork information for marketplace activities.
@freezed
sealed class ActivityArtwork with _$ActivityArtwork {
  const factory ActivityArtwork({
    required String mintAccount,
    required String name,
    required String imageUrl,
    String? artistName,
    String? collectionName,
    int? editionNumber,
    String? updateAuth,

    /// Sensitive-content flag off the indexed `Nft` row. Feeds render this
    /// artwork's thumbnail, so the row has to blur it behind the viewer's
    /// show-NSFW setting exactly as the grids do. Absent (→ false) on rows
    /// whose mint the indexer has never seen.
    @Default(false) bool nsfw,
  }) = _ActivityArtwork;

  factory ActivityArtwork.fromJson(Map<String, dynamic> json) => _$ActivityArtworkFromJson(json);
}

/// Data for marketplace activities (sale, buy, list, delist, offer, mint).
@freezed
sealed class MarketActivityData with _$MarketActivityData {
  const factory MarketActivityData({
    required ActivityArtwork artwork,
    required double price,
    required String currencyMint,
    String? currencySymbol,
    Counterparty? counterparty,
    double? usdPrice,
    double? fee,
  }) = _MarketActivityData;

  factory MarketActivityData.fromJson(Map<String, dynamic> json) =>
      _$MarketActivityDataFromJson(json);
}

/// Data for swap activities.
@freezed
sealed class SwapActivityData with _$SwapActivityData {
  const factory SwapActivityData({
    required TokenInfo inputToken,
    required TokenInfo outputToken,
    double? priceImpact,
    String? route,
  }) = _SwapActivityData;

  factory SwapActivityData.fromJson(Map<String, dynamic> json) => _$SwapActivityDataFromJson(json);
}

/// Counterparty for transfer (simpler than market counterparty).
@freezed
sealed class TransferCounterparty with _$TransferCounterparty {
  const factory TransferCounterparty({required String address, String? username}) =
      _TransferCounterparty;

  factory TransferCounterparty.fromJson(Map<String, dynamic> json) =>
      _$TransferCounterpartyFromJson(json);
}

/// Data for transfer activities (send, receive).
@freezed
sealed class TransferActivityData with _$TransferActivityData {
  const factory TransferActivityData({
    required TokenInfo token,
    required TransferCounterparty counterparty,
    required bool isNft,
    double? usdPrice,
    String? transferDirection,

    /// Artwork name for NFT transfers, resolved server-side from the indexed
    /// `Nft` table. Null when the mint isn't indexed (the client falls back to
    /// the counterparty / truncated mint). The NFT's image arrives via
    /// [token]'s `logoUrl`.
    String? nftName,

    /// Edition number for NFT transfers, so the client can render
    /// "Name #edition" like the marketplace rows. Null for non-edition NFTs.
    int? nftEditionNumber,

    /// Sensitive-content flag for NFT transfers. These rows render the artwork
    /// from [token]'s `logoUrl`, so they need the same blur the marketplace
    /// rows get from `artwork.nsfw`.
    @Default(false) bool nftNsfw,

    /// Network fee (SOL) the viewer paid — present only when the viewer was the
    /// fee payer (i.e. their own sends). Drives the row's "cost to transfer"
    /// amount and the detail "Network fee" row; absent on receives.
    double? fee,
  }) = _TransferActivityData;

  factory TransferActivityData.fromJson(Map<String, dynamic> json) =>
      _$TransferActivityDataFromJson(json);
}

/// Data for native staking activities (stake, unstake, stake-withdraw).
@freezed
sealed class StakeActivityData with _$StakeActivityData {
  const factory StakeActivityData({
    /// Always SOL. The amount is what the stake account holds — the stake plus
    /// the rent reserve the wallet funded — for `stake`/`unstake`, and the
    /// lamports withdrawn for `stakeWithdraw`.
    required TokenInfo token,

    /// Vote account of the validator the stake was delegated to. Only a `stake`
    /// row carries one: deactivating and withdrawing never name the validator
    /// on chain.
    String? validator,
    double? usdPrice,

    /// Network fee (SOL) — present only when the viewer paid it, which for a
    /// staking transaction they always did.
    double? fee,
  }) = _StakeActivityData;

  factory StakeActivityData.fromJson(Map<String, dynamic> json) =>
      _$StakeActivityDataFromJson(json);
}

/// Data for unknown activities.
@freezed
sealed class UnknownActivityData with _$UnknownActivityData {
  const factory UnknownActivityData({required List<String> programIds, required double fee}) =
      _UnknownActivityData;

  factory UnknownActivityData.fromJson(Map<String, dynamic> json) =>
      _$UnknownActivityDataFromJson(json);
}

/// A single activity item.
@freezed
sealed class Activity with _$Activity {
  const Activity._();

  const factory Activity({
    required String id,

    /// A wire value this build doesn't know degrades to [ActivityType.unknown]
    /// rather than throwing. Without the fallback a single row of a type the
    /// backend shipped after this build fails the whole page decode — not just
    /// that row — so a deploy would black out the feed for every client that
    /// hasn't updated yet.
    @JsonKey(unknownEnumValue: ActivityType.unknown) required ActivityType type,
    required int timestamp,
    required String signature,
    required ActivityStatus status,
    required Map<String, dynamic> data,
    String? displayLabel,
  }) = _Activity;

  factory Activity.fromJson(Map<String, dynamic> json) => _$ActivityFromJson(json);

  /// Parse data as MarketActivityData (for sale, buy, list, delist, offer, offer_received, mint).
  MarketActivityData? get marketData {
    if (_isMarketType) {
      try {
        return MarketActivityData.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Parse data as SwapActivityData.
  SwapActivityData? get swapData {
    if (type == ActivityType.swap) {
      try {
        return SwapActivityData.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Parse data as TransferActivityData (for send, receive, and mint).
  ///
  /// `mint` is included because the Tezos feed emits mints with a transfer-
  /// shaped payload (token/counterparty/isNft) rather than the marketplace
  /// payload the Solana feed uses. A Solana `mint` carries market data, so
  /// [TransferActivityData.fromJson] throws there and this returns null —
  /// callers must keep checking [marketData] first.
  TransferActivityData? get transferData {
    if (type == ActivityType.send || type == ActivityType.receive || type == ActivityType.mint) {
      try {
        return TransferActivityData.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Parse data as StakeActivityData (for stake, unstake, stakeWithdraw).
  StakeActivityData? get stakeData {
    if (type == ActivityType.stake ||
        type == ActivityType.unstake ||
        type == ActivityType.stakeWithdraw) {
      try {
        return StakeActivityData.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Parse data as UnknownActivityData.
  UnknownActivityData? get unknownData {
    if (type == ActivityType.unknown) {
      try {
        return UnknownActivityData.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  bool get _isMarketType =>
      type == ActivityType.sale ||
      type == ActivityType.buy ||
      type == ActivityType.list ||
      type == ActivityType.delist ||
      type == ActivityType.offer ||
      type == ActivityType.offerReceived ||
      type == ActivityType.mint;

  /// Get DateTime from timestamp.
  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

  /// URL to view this transaction on Orb Markets explorer.
  String get explorerUrl => 'https://orbmarkets.io/tx/$signature';
}

/// Pagination info for activity list.
@freezed
sealed class ActivityPagination with _$ActivityPagination {
  const factory ActivityPagination({
    required int page,
    required int limit,
    required bool hasMore,
    String? lastSignature,
  }) = _ActivityPagination;

  factory ActivityPagination.fromJson(Map<String, dynamic> json) =>
      _$ActivityPaginationFromJson(json);
}

/// Response from the activity endpoint.
@freezed
sealed class ActivityListResponse with _$ActivityListResponse {
  const factory ActivityListResponse({
    required List<Activity> result,
    required ActivityPagination pagination,
  }) = _ActivityListResponse;

  factory ActivityListResponse.fromJson(Map<String, dynamic> json) =>
      _$ActivityListResponseFromJson(json);
}
