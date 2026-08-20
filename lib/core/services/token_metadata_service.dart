import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';

import '../../shared/utils/chain.dart';
import '../data/mallow_tokens.dart';
import '../database/database.dart';
import '../network/das_api_service.dart';
import 'preferences_service.dart';

/// Whether a price surface can render an amount in a given currency yet.
enum TokenMetadataStatus {
  /// Symbol and decimals are known right now — static registry hit, or a
  /// cached DAS read. Rendering and signing are both safe.
  resolved,

  /// A DAS lookup is running (or has not been kicked off yet). The amount is
  /// unknown, so it renders as a shimmer and the CTA stays disabled.
  resolving,

  /// The DAS read failed or returned no usable `token_info`. Renders
  /// "Unknown token"; the CTA stays disabled. Reverts to [resolving] once
  /// [TokenMetadataService.failureTtl] passes, so a transient failure is
  /// retryable rather than terminal for the process.
  unresolved,
}

/// Resolves symbol / decimals / logo for tokens the static [tokenByMint]
/// registry doesn't key — listing currencies, and the legs of a swap the
/// activity feed reports by mint alone.
///
/// Seven memecoin currencies (WEN, SILLY, GUAC, FWOG, VALUE, PXLPSHR, ART)
/// were deliberately dropped from `mallow_tokens.dart` — see its header. That
/// left their listings unrenderable: a price with no decimals is either blank
/// or, where a `chain` was passed, silently reformatted as the chain's native
/// token (a 5,000 WEN sale rendered "0.5 SOL"). This service is the
/// replacement for static registration, resolving cheapest source first:
/// **static registry**, then this device's own caches (the persisted blob
/// below, then the cached Jupiter verified-token list), then a DAS `getAsset`
/// whose result is cached like any other.
///
/// Resolved entries are published into the registry overlay
/// ([registerResolvedToken]) so every existing `tokenByMint` consumer — price
/// formatting, balance checks, proceeds breakdowns, confirmation sheets —
/// becomes correct the moment metadata lands, with no per-call-site rewiring.
///
/// The invariant the buy/bid CTAs are gated on: **never signable for an amount
/// that was never displayed.** [statusOf] is the single source for both.
@lazySingleton
class TokenMetadataService {
  TokenMetadataService(this._das, this._prefs, this._database) {
    _hydrate();
  }

  /// Symbol and logo churn; decimals are immutable. The TTL exists only for
  /// the former, which is why a stale entry stays *usable* while it refreshes.
  static const Duration cacheTtl = Duration(days: 30);

  /// How long a failed lookup is remembered.
  ///
  /// Bounded because most failures are network blips: the marker used to be
  /// permanent, which pinned the mint to [TokenMetadataStatus.unresolved] for
  /// the whole process — one timeout left "Unknown token" on screen and the
  /// buy / bid CTA disabled until the app was restarted. Short enough that a
  /// user who pulls to refresh gets a real retry, long enough that a mint DAS
  /// genuinely can't resolve doesn't cost a request per row per rebuild.
  static const Duration failureTtl = Duration(seconds: 30);

  /// Injected clock so TTL expiry is testable without waiting 30 days.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  final DasApiService _das;
  final PreferencesService _prefs;
  final MallowDatabase _database;

  final Map<String, _CachedToken> _cache = {};
  final Map<String, Future<MallowToken?>> _inFlight = {};

  /// When each failed lookup failed, for the [failureTtl] window. Never
  /// persisted — a failure must not survive the process it happened in.
  final Map<String, DateTime> _failedAt = {};

  /// Whether [mint] has to go through DAS before it can be rendered.
  ///
  /// False for registry mints (nothing to look up) and for non-Solana chains:
  /// DAS only indexes Solana, so there is no lookup to run. An unkeyed
  /// EVM/Tezos currency therefore renders as [kUnknownTokenLabel] — resolving
  /// those needs a non-DAS source, not a guess at the chain's base token.
  /// A null/unknown `chain` is treated as Solana — that is what the
  /// overwhelming majority of unkeyed marketplace currencies are.
  bool needsLookup(String? mint, {String? chain}) {
    if (mint == null || mint.isEmpty) return false;
    if (isRegistryMint(mint)) return false;
    final parsed = Chain.tryParse(chain);
    return parsed == null || parsed == Chain.solana;
  }

  /// Synchronous render/gating state for [mint]. Registry mints and warm
  /// cache entries return [TokenMetadataStatus.resolved] with no I/O, so
  /// registered-token surfaces behave exactly as they did before this service
  /// existed — no shimmer, no gating delay.
  TokenMetadataStatus statusOf(String? mint, {String? chain}) {
    if (!needsLookup(mint, chain: chain)) return TokenMetadataStatus.resolved;
    // A stale entry still resolves: decimals can't change, so the figure is
    // right even when the symbol is a month old.
    if (_cache.containsKey(mint)) return TokenMetadataStatus.resolved;
    if (_isFailed(mint!)) return TokenMetadataStatus.unresolved;
    return TokenMetadataStatus.resolving;
  }

  /// Whether [mint]'s last failure is still inside [failureTtl]. Past it the
  /// mint is treated as never-tried again, so the next [resolve] re-requests.
  bool _isFailed(String mint) {
    final at = _failedAt[mint];
    if (at == null) return false;
    if (clock().difference(at) < failureTtl) return true;
    _failedAt.remove(mint);
    return false;
  }

  /// The token [mint] should render in, or null when it can't be resolved.
  /// Never performs I/O — [resolve] is the async door.
  ///
  /// An absent mint means the chain's native currency; a present but unkeyed
  /// mint resolves to null rather than to that native currency, matching
  /// `PriceFormatter._token`. Rendering an unkeyed mint as the chain's base
  /// token is a wrong number under a wrong ticker, which is what this service
  /// exists to eliminate.
  MallowToken? tokenFor(String? mint, {String? chain}) =>
      (mint == null || mint.isEmpty)
      ? baseTokenForChain(chain)
      : tokenByMint(mint);

  /// Logo URI from the DAS read, for the token glyph next to a price. Raw
  /// upstream URL — callers hand it to `MallowNetworkImage`, which does the
  /// CDN wrapping.
  String? imageUrlFor(String? mint) =>
      mint == null ? null : _cache[mint]?.imageUrl;

  /// Resolve [mint], hitting DAS only when [needsLookup] says so.
  ///
  /// Concurrent calls for the same mint share one request. A cached entry
  /// inside the TTL short-circuits; past the TTL the cached value is returned
  /// immediately (decimals are immutable) while a refresh runs in the
  /// background.
  Future<MallowToken?> resolve(String? mint, {String? chain}) {
    if (!needsLookup(mint, chain: chain)) {
      return Future.value(tokenFor(mint, chain: chain));
    }
    final m = mint!;
    final cached = _cache[m];
    if (cached != null && !cached.isStale(clock())) {
      return Future.value(cached.toToken(m));
    }
    if (_isFailed(m)) {
      // Inside the failure window: don't re-request on every rebuild. A stale
      // cached entry is still usable, so hand that back when there is one.
      return Future.value(cached?.toToken(m));
    }
    final pending = _inFlight[m] ?? (_inFlight[m] = _fetch(m));
    // A stale-but-present entry is usable now; don't make the UI wait on the
    // refresh (and don't let a failed refresh blank a price that was fine).
    return cached != null ? Future.value(cached.toToken(m)) : pending;
  }

  Future<MallowToken?> _fetch(String mint) async {
    try {
      // Local first: the verified list is already on disk for most fungibles
      // the user can have traded, and it carries the same three fields DAS
      // would be asked for.
      final entry =
          await _fromVerifiedList(mint) ?? _parse(await _das.getAssetRaw(mint));
      if (entry == null) {
        _failedAt[mint] = clock();
        return null;
      }
      _failedAt.remove(mint);
      _cache[mint] = entry;
      registerResolvedToken(entry.toToken(mint));
      await _persist();
      return entry.toToken(mint);
    } catch (_) {
      // Negative-cached for [failureTtl] only: a failure is usually a network
      // blip, and once the window passes the next render of this surface is
      // free to try again. Callers memoize the future per widget, so a failed
      // mint costs at most one request per window.
      _failedAt[mint] = clock();
      return _cache[mint]?.toToken(mint);
    } finally {
      unawaited(_inFlight.remove(mint)?.then<void>((_) {}));
    }
  }

  /// [mint]'s row in the cached Jupiter verified-token list, or null.
  ///
  /// The catalog (`CachedJupiterTokenList`, refreshed 24-hourly by the swap
  /// picker) already holds symbol, decimals and icon for ~4k verified mints,
  /// so a hit answers the whole question from disk. A miss is the normal case
  /// on a device that has never opened the swap sheet, not an error — and a
  /// database failure must never be why a token can't be named, so both fall
  /// through to DAS.
  Future<_CachedToken?> _fromVerifiedList(String mint) async {
    try {
      final row = await _database.getJupiterTokenListEntry(mint);
      if (row == null) return null;
      final symbol = row.symbol?.trim();
      final decimals = row.decimals;
      if (symbol == null || symbol.isEmpty || decimals == null) return null;
      return _CachedToken(
        symbol: symbol,
        decimals: decimals,
        imageUrl: row.iconUrl,
        fetchedAt: clock(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Extract the fungible-token fields from a DAS `getAsset` result.
  ///
  /// `token_info.decimals` is the load-bearing one — without it there is no
  /// way to scale the amount, so a response missing it is a failure, not a
  /// partial success. The symbol falls back through the metadata block
  /// because some mints only populate one of the two.
  _CachedToken? _parse(Map<String, dynamic> json) {
    final tokenInfo = json['token_info'] as Map<String, dynamic>?;
    final decimals = (tokenInfo?['decimals'] as num?)?.toInt();
    if (decimals == null || decimals < 0 || decimals > 18) return null;

    final content = (json['content'] as Map<String, dynamic>?) ?? const {};
    final metadata = (content['metadata'] as Map<String, dynamic>?) ?? const {};
    final symbol = _firstNonEmpty([
      tokenInfo?['symbol'] as String?,
      metadata['symbol'] as String?,
      metadata['name'] as String?,
    ]);
    if (symbol == null) return null;

    return _CachedToken(
      symbol: symbol,
      decimals: decimals,
      imageUrl: _imageUri(content),
      fetchedAt: clock(),
    );
  }

  static String? _imageUri(Map<String, dynamic> content) {
    final links = content['links'] as Map<String, dynamic>?;
    final fromLinks = _firstNonEmpty([links?['image'] as String?]);
    if (fromLinks != null) return fromLinks;
    for (final file in (content['files'] as List<dynamic>?) ?? const []) {
      if (file is! Map<String, dynamic>) continue;
      final uri = _firstNonEmpty([
        file['cdn_uri'] as String?,
        file['uri'] as String?,
      ]);
      if (uri != null) return uri;
    }
    return null;
  }

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final c in candidates) {
      final trimmed = c?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Load the persisted map and publish it into the registry overlay, so a
  /// warm start renders known currencies synchronously (no shimmer) even
  /// before any lookup runs. Expired entries are kept and re-fetched on use.
  void _hydrate() {
    final raw = _prefs.tokenMetadataCache;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((mint, value) {
        if (value is! Map<String, dynamic>) return;
        final entry = _CachedToken.fromJson(value);
        if (entry == null) return;
        _cache[mint] = entry;
        registerResolvedToken(entry.toToken(mint));
      });
    } catch (_) {
      // Corrupt cache is a cache miss, never a startup failure.
    }
  }

  Future<void> _persist() => _prefs.setTokenMetadataCache(
    jsonEncode({for (final e in _cache.entries) e.key: e.value.toJson()}),
  );
}

class _CachedToken {
  const _CachedToken({
    required this.symbol,
    required this.decimals,
    required this.imageUrl,
    required this.fetchedAt,
  });

  static _CachedToken? fromJson(Map<String, dynamic> json) {
    final symbol = (json['symbol'] as String?)?.trim();
    final decimals = (json['decimals'] as num?)?.toInt();
    final fetchedAt = (json['fetchedAt'] as num?)?.toInt();
    if (symbol == null || symbol.isEmpty || decimals == null) return null;
    return _CachedToken(
      symbol: symbol,
      decimals: decimals,
      imageUrl: json['imageUrl'] as String?,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        (fetchedAt ?? 0) * 1000,
        isUtc: true,
      ),
    );
  }

  final String symbol;
  final int decimals;
  final String? imageUrl;
  final DateTime fetchedAt;

  bool isStale(DateTime now) =>
      fetchedAt.isBefore(now.subtract(TokenMetadataService.cacheTtl));

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'decimals': decimals,
    if (imageUrl != null) 'imageUrl': imageUrl,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch ~/ 1000,
  };

  /// `inputDecimals` is the registry's *display* precision, hand-tuned per
  /// token (SOL 9→3, USDC 6→2, BONK 5→0). There is nothing to tune against
  /// for a mint we just met, so cap at 4: enough that no real listing price
  /// truncates to "0", few enough that a 9-decimal token doesn't render a
  /// wall of digits. `minListingPrice` is 0 because these tokens are never
  /// offered in the seller's currency picker — the overlay is read-only for
  /// rendering, and `pickableBidTokens` only ever walks the static table.
  MallowToken toToken(String mint) => MallowToken(
    symbol: symbol,
    mint: mint,
    decimals: decimals,
    inputDecimals: decimals < 4 ? decimals : 4,
    minListingPrice: 0,
    disablePrice: true,
    disableSwap: true,
  );
}
