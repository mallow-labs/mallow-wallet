import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart';

import '../../../core/data/mallow_market.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/services/sentry_service.dart';

/// Marketplace fees loaded from the on-chain `MarketplaceConfig` PDA:
/// the primary/secondary sale bps and the flat per-print `printFee`
/// (lamports) shown as the "mallow fee" on edition buys.
typedef MarketplaceFees = ({
  int primaryBps,
  int secondaryBps,
  int printFeeLamports,
});

/// Reads `MarketplaceConfig.feeConfig.{primaryBps,secondaryBps,printFee}`
/// from the MallowMarket program PDA.
///
/// Caching mirrors the webapp's React Query strategy
/// (`useMarketplaceConfig`):
///   - Successful fetches are cached for a bounded TTL so on-chain fee
///     updates are picked up without an app relaunch. The webapp uses the
///     React Query default `gcTime` (5 minutes); we match that here.
///   - Failures are **not** cached. The webapp's query returns `null` on
///     error and refetches on the next read; callers fall back to the
///     hardcoded defaults inline. We surface the same fallback to keep the
///     listing flow non-blocking, but leave the cache empty so the next
///     call retries the RPC instead of pinning the session to defaults.
///   - Concurrent reads coalesce onto a single in-flight fetch.
@lazySingleton
class MarketplaceConfigService {
  /// [elapsed] returns a monotonic duration since some fixed origin. It
  /// defaults to a process-lifetime [Stopwatch] so TTL math is immune to
  /// wall-clock jumps (NTP corrections, timezone changes) — a backward
  /// clock jump could otherwise make `now - cachedAt` negative and pin the
  /// cache as "fresh" indefinitely. Tests inject a controllable source.
  MarketplaceConfigService(this._rpc, {Duration Function()? elapsed})
    : _elapsed = elapsed ?? _defaultElapsed();

  /// DI entry point. Injectable builds the service through this factory so it
  /// only has to resolve the real [SolanaRpcService] dependency. The primary
  /// constructor's test-only [elapsed] seam is a bare `Duration Function()`,
  /// which injectable cannot resolve as a registerable type — routing DI
  /// through this factory keeps that seam out of the generated container.
  @factoryMethod
  factory MarketplaceConfigService.inject(SolanaRpcService rpc) =>
      MarketplaceConfigService(rpc);

  static Duration Function() _defaultElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  static const Duration cacheTtl = Duration(minutes: 5);

  final SolanaRpcService _rpc;
  final Duration Function() _elapsed;

  MarketplaceFees? _cached;
  Duration? _cachedAt;
  Future<MarketplaceFees>? _inFlight;

  Future<MarketplaceFees> get() async {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        _elapsed() - cachedAt < cacheTtl) {
      return cached;
    }

    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = _fetchAndCache();
    _inFlight = future;
    try {
      return await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<MarketplaceFees> _fetchAndCache() async {
    try {
      final fees = await _fetch();
      _cached = fees;
      _cachedAt = _elapsed();
      return fees;
    } catch (e, st) {
      await SentryService.captureException(e, stackTrace: st);
      // Swallow the error and return defaults — never rethrow. The listing
      // flow must stay non-blocking, and leaving `_cached`/`_cachedAt` null
      // means the next get() retries the RPC rather than pinning the
      // session to fallback fees. Concurrent callers that joined this same
      // in-flight future all receive the fallback for this batch; that is
      // intentional — they retry on their next call. Do NOT "fix" this by
      // rethrowing or by caching the fallback.
      return const (
        primaryBps: kDefaultPrimaryFeeBps,
        secondaryBps: kDefaultSecondaryFeeBps,
        printFeeLamports: kDefaultPrintFeeLamports,
      );
    }
  }

  Future<MarketplaceFees> _fetch() async {
    final authority = Ed25519HDPublicKey.fromBase58(
      kMallowMarketplaceAuthority,
    );
    final programId = Ed25519HDPublicKey.fromBase58(kMallowMarketProgramId);
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: [utf8.encode(kMarketplaceConfigSeed), authority.bytes],
      programId: programId,
    );
    final result = await _rpc.getAccountInfo(
      pda.toBase58(),
      encoding: Encoding.base64,
    );
    final account = result.value;
    if (account == null) {
      throw StateError('MarketplaceConfig account not found at $pda');
    }
    final data = account.data;
    if (data is! BinaryAccountData) {
      throw StateError(
        'MarketplaceConfig data not binary: ${data.runtimeType}',
      );
    }
    final bytes = Uint8List.fromList(data.data);
    final byteData = ByteData.sublistView(bytes);
    final primary = byteData.getUint16(kPrimaryBpsOffset, Endian.little);
    final secondary = byteData.getUint16(kSecondaryBpsOffset, Endian.little);
    final printFee = byteData.getUint64(kPrintFeeOffset, Endian.little);
    return (
      primaryBps: primary,
      secondaryBps: secondary,
      printFeeLamports: printFee,
    );
  }
}
