import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../services/preferences_service.dart';
import 'environment.dart';
import 'system_status.dart';

/// Scheduled-maintenance feed: a static object on [Config.assetCdnBaseUrl],
/// the same one the web client reads — deliberately not a new endpoint and not
/// the `/v2/config/mobile` payload: operators already publish here, and a
/// second source of truth for the same announcement is how the two clients end
/// up telling users different things.
///
/// Empty when no asset CDN is configured, which disables the poll — the banner
/// already fails safe when a feed does not answer.
String get kStatusFeedUrl {
  final base = Config.assetCdnBaseUrl;
  return base.isEmpty ? '' : '$base/status.json';
}

/// Operator-broadcast feed, the same object the web client reads.
String get kNoticeFeedUrl {
  final base = Config.assetCdnBaseUrl;
  return base.isEmpty ? '' : '$base/notification-v2.json';
}

/// Polls the two static status feeds and exposes the banner that should
/// currently be showing.
///
/// Shaped like [RemoteConfigService]: `ValueNotifier`, single-flight, launch +
/// foreground cadence, failures swallowed. The differences are deliberate:
///
/// * **Fail-quiet, and hold the line.** A *missing or malformed* feed announces
///   nothing — that is the steady state. An *unreachable* one keeps whatever
///   the last good fetch said, exactly as [RemoteConfigService] does: a CDN
///   blip during the very outage being announced must not clear the live
///   banner. There is no state here that can block a user, so a failure needs
///   no telemetry escalation — unlike the kill switch, a silently dead status
///   feed costs an explanation, not a safety property.
/// * **Dismissals are persisted and value-scoped.** The key is the window's
///   `startsAt` / the notice's `id`, so dismissing today's announcement does
///   not suppress next week's, and a re-published notice re-shows.
/// * **A 5-minute TTL, no periodic timer.** The whole point of the feed is
///   two days' notice, so polling harder buys nothing.
@lazySingleton
class SystemStatusService {
  @factoryMethod
  SystemStatusService(PreferencesService prefs) : this.withSeams(prefs);

  /// Test seam for the HTTP client and the clock. Both windows here are
  /// day- and minute-wide, so waiting them out is not a test.
  ///
  /// Split from the injectable constructor because `injectable` cannot resolve
  /// a bare function type in a constructor parameter.
  @visibleForTesting
  SystemStatusService.withSeams(
    this._prefs, {
    Dio? dio,
    DateTime Function()? now,
  }) : _dio = dio ?? Dio(),
       _now = now ?? DateTime.now;

  final PreferencesService _prefs;
  final Dio _dio;
  final DateTime Function() _now;

  static const _ttl = Duration(minutes: 5);

  final ValueNotifier<SystemBanner?> _banner = ValueNotifier(null);

  SystemStatus _status = SystemStatus.empty;
  DateTime? _lastFetchAt;
  bool _started = false;
  Future<void>? _inFlight;

  /// The banner to render, or null for none. Recomputed on every fetch and on
  /// every dismissal.
  ValueListenable<SystemBanner?> get banner => _banner;

  @visibleForTesting
  SystemStatus get status => _status;

  void start() {
    if (_started) return;
    _started = true;
    // Recompute first so a still-valid, still-undismissed announcement from a
    // previous run isn't invisible for the length of the first round trip.
    _recompute();
    unawaited(_refresh());
  }

  Future<void> refreshIfStale() {
    final last = _lastFetchAt;
    if (last != null && _now().difference(last) < _ttl) {
      // Still recompute: the banner is time-dependent, so a resume after the
      // window opened (or the notice expired) has to re-evaluate even when the
      // feed itself is fresh.
      _recompute();
      return Future<void>.value();
    }
    return _refresh();
  }

  /// Hide the current banner for good — the key it was resolved under is
  /// stored, so only a *different* window or notice will show again.
  Future<void> dismiss(SystemBanner banner) async {
    switch (banner) {
      case MaintenanceBanner():
        await _prefs.setDismissedMaintenance(banner.dismissKey);
      case NoticeBanner():
        await _prefs.setDismissedNotice(banner.dismissKey);
    }
    _recompute();
  }

  /// False when no asset CDN is configured, which is the documented way to run
  /// with the banner off and the default for a build that has no feed of its
  /// own. Both URLs come from the same base, so they go empty together.
  bool get _feedsConfigured =>
      kStatusFeedUrl.isNotEmpty && kNoticeFeedUrl.isNotEmpty;

  Future<void> _refresh() {
    // Off means silent. Fetching an empty URL only throws, and a round that
    // never succeeds never stamps `_lastFetchAt` — so nothing throttles the
    // next attempt and every launch and every foreground would pay two doomed
    // requests and two error logs, forever. There is nothing to announce
    // without a feed, and `_status` already says so.
    if (!_feedsConfigured) return Future<void>.value();
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _fetch().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _fetch() async {
    final results = await Future.wait([
      _getJson(kStatusFeedUrl),
      _getJson(kNoticeFeedUrl),
    ]);
    final (status, notice) = (results[0], results[1]);
    // A feed we couldn't reach keeps its last-good value: overwriting it with
    // the empty parse would pull a live maintenance banner down mid-outage,
    // which is when the CDN is least likely to answer. Only a feed that
    // actually answered gets to say "nothing to announce".
    _status = SystemStatus(
      maintenance: status.ok
          ? MaintenanceWindow.fromJson(status.data)
          : _status.maintenance,
      notice: notice.ok ? OperatorNotice.fromJson(notice.data) : _status.notice,
    );
    // Only a fully successful round stamps the TTL, so a failed attempt is
    // retried on the next foreground rather than sitting out five minutes.
    if (status.ok && notice.ok) _lastFetchAt = _now();
    _recompute();
  }

  /// Never throws. `ok` separates the two cases the caller must not conflate:
  /// the CDN answered (`ok`) — with an object, with something malformed, or
  /// with a 404 because the operator unpublished the feed, all of which mean
  /// "nothing to announce" — versus the CDN did not answer (`!ok`), which says
  /// nothing at all about what is announced. A 4xx is an answer; a timeout,
  /// a DNS failure or a 5xx is not.
  Future<({bool ok, Map<String, dynamic>? data})> _getJson(String url) async {
    try {
      final response = await _dio.get<dynamic>(
        url,
        options: Options(responseType: ResponseType.json),
      );
      final data = response.data;
      return (ok: true, data: data is Map<String, dynamic> ? data : null);
    } catch (e) {
      debugPrint('[SystemStatusService] feed fetch failed ($url): $e');
      final status = e is DioException ? e.response?.statusCode : null;
      final answered = status != null && status >= 400 && status < 500;
      return (ok: answered, data: null);
    }
  }

  void _recompute() {
    _banner.value = resolveSystemBanner(
      status: _status,
      now: _now(),
      dismissedMaintenanceKey: _prefs.dismissedMaintenance,
      dismissedNoticeKey: _prefs.dismissedNotice,
    );
  }

  @disposeMethod
  void dispose() {
    _banner.dispose();
  }
}
