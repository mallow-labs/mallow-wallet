import 'package:flutter/foundation.dart';

/// Default/uninitialized Solana pubkey (the System Program). On-chain auction /
/// listing accounts store this as the "unset" value for optional addresses
/// (e.g. `highestBidder` before any bid lands), so we normalize it to null.
const String _systemProgram = '11111111111111111111111111111111';

/// A parsed on-chain account update pushed by the backend over the
/// `/v2/ws/accounts` WebSocket (or fetched once via `GET /v2/accounts/...`).
///
/// The wire frame is the flat camelCase record the chain listener produces as
/// its `ParsedProgramAccount`:
/// `{ accountType, ...decoded fields, pubkey, program, slot, writeVersion }`.
/// The decoded fields are kept verbatim in [raw]; typed accessors are exposed
/// for the `auctionConfig` / `listing` shapes the artwork screen reconciles
/// against.
@immutable
class AccountUpdate {
  const AccountUpdate({
    required this.pubkey,
    required this.accountType,
    required this.program,
    required this.slot,
    required this.raw,
  });

  factory AccountUpdate.fromJson(Map<String, dynamic> json) {
    return AccountUpdate(
      pubkey: (json['pubkey'] as String?) ?? '',
      accountType: (json['accountType'] as String?) ?? '',
      program: json['program'] as String?,
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      raw: json,
    );
  }

  /// Synthetic "WS reconnected — you may have missed writes on [pubkey]" frame.
  /// Carries no decoded fields; consumers detect it via [isSyntheticReconnect]
  /// and re-fetch authoritative state rather than overlaying its (empty) data.
  const AccountUpdate.syntheticReconnect(this.pubkey)
    : accountType = reconnectType,
      program = null,
      slot = 0,
      raw = const {};

  /// [accountType] marker for [AccountUpdate.syntheticReconnect].
  static const String reconnectType = '__synthetic_reconnect__';

  /// The account's own on-chain address (PDA) — the key the stream is
  /// subscribed by, NOT the mint.
  final String pubkey;

  /// Self-describing discriminant: `auctionConfig`, `listing`, `offer`, …
  final String accountType;

  final String? program;

  /// Solana slot the update was observed at (0 from a REST snapshot, which
  /// carries no slot). Monotonic per account.
  final int slot;

  /// The full decoded frame, for fields without a typed accessor.
  final Map<String, dynamic> raw;

  bool get isAuctionConfig => accountType == 'auctionConfig';
  bool get isListing => accountType == 'listing';
  bool get isOffer => accountType == 'offer';
  bool get isSyntheticReconnect => accountType == reconnectType;

  /// True when the listener pushed an account-close tombstone rather than a
  /// decoded account. The closed frame is a flat `{ pubkey, program, closed:
  /// true, slot, [writeVersion] }` with NO `accountType` — emitted when a
  /// mallow market/auction PDA's lamports drain to zero (auction settled,
  /// listing sold/cancelled). Consumers match [pubkey] to the account they
  /// watch and drop it rather than keep overlaying the last live state.
  bool get isClosed => raw['closed'] == true;

  String? _addr(String key) {
    final v = raw[key];
    if (v is! String || v.isEmpty || v == _systemProgram) return null;
    return v;
  }

  /// Coerce a numeric field to int. The backend serializes u64 amounts
  /// (`price`, `highestBidAmount`, `reservePrice`, `minBidIncrement`) as
  /// **decimal strings** — full-precision values can exceed JS's 2^53 safe
  /// range — so a bare `as num` cast would throw on every real frame. Accept
  /// both shapes (the `/v2/auctions/:mint` snapshot sends plain ints).
  int? _int(String key) {
    final v = raw[key];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  bool _bool(String key) => raw[key] == true;

  /// A unix-seconds field → local [DateTime]. Null for 0/unset (e.g. an
  /// open-ended listing or an auction that never set an end).
  DateTime? _time(String key) {
    final secs = _int(key);
    if (secs == null || secs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      secs * 1000,
      isUtc: true,
    ).toLocal();
  }

  // ── auctionConfig accessors ──────────────────────────────────────────────

  /// Highest bid in raw atomic units, or null when no bid has landed
  /// (`highestBidAmount == 0`).
  int? get highestBidAmount {
    final v = _int('highestBidAmount');
    return (v == null || v == 0) ? null : v;
  }

  /// Winning bidder address, or null when there is no bid yet.
  String? get highestBidder =>
      highestBidAmount == null ? null : _addr('highestBidder');

  /// Auction end time (extends as last-second bids land).
  DateTime? get endTime => _time('endTime');

  /// Auction start time, or null when unset.
  DateTime? get startTime => _time('startTime');

  /// Auction creator/owner address.
  String? get seller => _addr('seller');

  /// Currency mint the auction takes bids in.
  String? get bidMint => _addr('bidMint');

  /// Reserve (minimum opening) bid in raw atomic units.
  int? get reservePrice => _int('reservePrice');

  /// Absolute minimum bid increment in raw atomic units (0 / unset → null).
  int? get minBidIncrement {
    final v = _int('minBidIncrement');
    return (v == null || v == 0) ? null : v;
  }

  /// Minimum bid increment expressed as basis points (alternative to the
  /// absolute [minBidIncrement]).
  int? get minBidIncrementBps => _int('minBidIncrementBps');

  /// Time-extension window in seconds (last-minute bids extend the auction).
  int? get timeExtPeriod => _int('timeExtPeriod');

  /// Seconds each in-window bid extends the auction by.
  int? get timeExtDelta => _int('timeExtDelta');

  /// Total auction duration in seconds.
  int? get auctionDuration => _int('duration');

  // ── listing accessors ────────────────────────────────────────────────────

  /// Listing price in raw atomic units.
  int? get listingPrice => _int('price');

  /// Listing end time, or null when open-ended.
  DateTime? get listingEndTime => _time('endTime');

  /// Listing start time, or null when unset.
  DateTime? get listingStartTime => _time('startTime');

  /// Currency mint the listing is priced in.
  String? get listingCurrencyMint => _addr('currencyMint');

  /// Per-wallet editions cap; 0 = list-all / no cap. A non-zero value marks a
  /// master-edition (multi-print) listing rather than a plain 1/1.
  int get listingEditionsLimit => _int('editionsLimit') ?? 0;

  /// True for buyer-sets-price (offer-style) listings — not a fixed price.
  bool get listingBuyerSetsPrice => _bool('buyerSetsPrice');

  // ── offer accessors ──────────────────────────────────────────────────────
  // Wire shape: `OfferData` in the backend's account-event payload — `{ buyer,
  // asset, currencyMint, price (decimal string), endTime, offeredAt, … }`.

  /// Offer amount in raw atomic units of [offerCurrencyMint].
  int? get offerPrice => _int('price');

  /// Currency mint the offer is denominated in.
  String? get offerCurrencyMint => _addr('currencyMint');

  /// The wallet that made the offer.
  String? get offerBuyer => _addr('buyer');

  /// Offer expiry, or null when open-ended.
  DateTime? get offerEndTime => _time('endTime');
}
