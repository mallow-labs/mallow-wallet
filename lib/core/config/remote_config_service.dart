import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../services/sentry_service.dart';
import 'remote_config.dart';

/// In-memory cache of `GET /v2/config/mobile` — the per-`(chain, flow)` kill
/// switch and the force-upgrade fields.
///
/// Modelled on [TokenPriceService] (`ValueNotifier`, in-flight dedupe,
/// swallowed errors) with one deliberate difference: **no `Timer.periodic`**.
/// The cadence is launch + app foreground (+ opportunistic flow entry), so a
/// background timer would fetch while the app is idle for no benefit.
///
/// Semantics, in order of importance:
///
/// * **Fail-open.** Cold start is [RemoteConfig.permissive] and a backend
///   outage must not brick the app. Accepted tradeoff: a killed flow comes
///   back if the fetch fails from cold.
/// * **Last-known-good.** A *failed refresh* keeps the value we already have.
///   It must never un-kill a flow — otherwise a flapping backend re-opens a
///   path we just closed during an incident.
/// * **Bounded request rate.** Triggers are frequent (launch, foreground, every
///   gated tap and screen entry), so a fetch needs two guards, not one: the
///   [_ttl] freshness window after a success, and the [_retryGap] cooldown
///   after *any* attempt. Without the latter, a backend outage turns every
///   navigation into a doomed round trip — a per-device retry storm against a
///   backend that is trying to recover.
/// * **Nothing is persisted.** Never read from or written to disk, so a killed
///   cell can't outlive the incident on a device that never came back online.
///
/// [config] is a [ValueListenable] so gates can read the current value
/// synchronously and widgets can rebuild when a refresh lands. There is
/// deliberately no `awaitReady()`: its only window is the first second after
/// launch, and the `TransactionAuthGate` backstop catches a killed flow at
/// signing anyway.
@lazySingleton
class RemoteConfigService {
  @factoryMethod
  RemoteConfigService(MallowApiV2Client api) : this.withTtl(api, _defaultTtl);

  /// Test seam for the TTL and the clock — the staleness and cooldown windows
  /// are minutes wide, and waiting them out is not a test.
  ///
  /// [elapsed] returns a monotonic duration since some fixed origin, matching
  /// `MarketplaceConfigService`'s seam. It defaults to a process-lifetime
  /// [Stopwatch] so the windows are immune to wall-clock jumps (NTP
  /// corrections, timezone changes) — a backward jump under `DateTime.now()`
  /// could make `now - lastSuccess` negative and pin a stale config as
  /// "fresh" indefinitely, which for a kill switch means a kill that never
  /// arrives.
  @visibleForTesting
  RemoteConfigService.withTtl(
    this._api,
    this._ttl, {
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _defaultElapsed();

  static Duration Function() _defaultElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final MallowApiV2Client _api;

  static const _defaultTtl = Duration(minutes: 5);

  /// Cooldown after *any* attempt, successful or not. Caps the endpoint at
  /// ~2 req/min/device during an outage while leaving the success TTL alone
  /// (the TTL is longer, so this only ever binds after a failure).
  static const _retryGap = Duration(seconds: 30);

  final Duration _ttl;
  final Duration Function() _elapsed;

  final ValueNotifier<RemoteConfig> _config = ValueNotifier(
    RemoteConfig.permissive,
  );

  /// Completion time of the last *successful* fetch. Null until one lands,
  /// which is what makes a failed attempt retry after the short [_retryGap]
  /// instead of sitting out the full TTL.
  Duration? _lastSuccessAt;

  /// Start time of the last attempt, successful or not. Recorded in [_fetch],
  /// so it covers the launch fetch as well as [refreshIfStale] triggers.
  Duration? _lastAttemptAt;

  bool _started = false;
  Future<void>? _inFlight;

  ValueListenable<RemoteConfig> get config => _config;

  /// Kick off the launch fetch. Safe to call multiple times — subsequent
  /// calls are no-ops.
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_refresh());
  }

  /// Refresh if the cached value has gone stale. Called on foreground and,
  /// fire-and-forget, on flow entry — so a long-lived foreground session
  /// still picks up a kill within a TTL of touching a gated flow.
  ///
  /// No-ops while a fetch is in flight, while the last success is younger than
  /// the TTL, and while the last *attempt* is younger than [_retryGap]. A
  /// failed attempt leaves [_lastSuccessAt] untouched, so it retries after the
  /// cooldown rather than sitting out the full TTL — but it does set
  /// [_lastAttemptAt], so an outage costs ~2 requests a minute instead of one
  /// per tap.
  Future<void> refreshIfStale() {
    final now = _elapsed();
    final lastSuccess = _lastSuccessAt;
    final lastAttempt = _lastAttemptAt;
    final fresh = lastSuccess != null && now - lastSuccess < _ttl;
    final cooling = lastAttempt != null && now - lastAttempt < _retryGap;
    if (fresh || cooling) return Future<void>.value();
    return _refresh();
  }

  /// Single-flight wrapper: concurrent callers share one request rather than
  /// stacking round-trips on resume.
  Future<void> _refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _fetch().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _fetch() async {
    _lastAttemptAt = _elapsed();
    try {
      final response = await _api.getMobileConfig();
      _config.value = RemoteConfig.fromWire(response.result);
      _lastSuccessAt = _elapsed();
    } catch (e) {
      // Fail-open, but hold the line: keep whatever we already had rather
      // than resetting to permissive, so an intermittent backend can't
      // un-kill a flow mid-incident. _lastSuccessAt stays put so the next
      // trigger retries after _retryGap instead of waiting out the TTL.
      debugPrint('[RemoteConfigService] config fetch failed: $e');
      // Warn, don't error: a network blip is expected. But *something* has to
      // reach Sentry, because both ends of this feature fail open — if the
      // production proxy never forwards /v2/config/mobile, every device 404s
      // silently and the kill switch is dead with no symptom. Endpoint + error
      // type only; never the response body.
      unawaited(
        SentryService.captureMessage(
          'Remote config fetch failed',
          level: SentryLevel.warning,
          extras: {
            'endpoint': 'GET /v2/config/mobile',
            'errorType': e.runtimeType.toString(),
          },
        ),
      );
    }
  }

  @disposeMethod
  void dispose() {
    _config.dispose();
  }
}
