import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../config/environment.dart';
import '../services/preferences_service.dart';
import '../services/sentry_service.dart';
import 'analytics_events.dart';

/// Fire-and-forget product analytics.
///
/// Forwards events to the backend `POST /v1/analytics`, which enriches them and
/// uploads to the analytics provider. The client never talks to that provider
/// directly.
///
/// Design guarantees:
/// - Never throws into a user flow (all sends are best-effort).
/// - Gated on the build flag + the user's Settings opt-out.
/// - Client-stamps `time` + `$insert_id` and queues offline, so events survive
///   a dropped connection and Mixpanel dedups retries.
@lazySingleton
class AnalyticsService {
  AnalyticsService(this._dio, this._prefs, this._secureStorage);

  final Dio _dio;
  final PreferencesService _prefs;
  final FlutterSecureStorage _secureStorage;

  static const _endpoint = '/v1/analytics';
  static const _deviceIdKey = 'mallow_analytics_device_id';

  /// New session after this much inactivity (or since last background).
  static const _sessionTimeout = Duration(minutes: 30);

  /// Minimum gap between two `Logged In` events. Independent of
  /// [_sessionTimeout] despite the matching value — see [trackLogin].
  static const loginThrottle = Duration(minutes: 30);

  /// Offline-queue bounds: stay under Mixpanel's ~5-day
  /// `/import` staleness limit and cap local storage.
  static const _maxQueueAge = Duration(days: 3);
  static const _maxQueueSize = 500;

  final _uuid = const Uuid();

  bool _initialized = false;
  String? _deviceId;
  String? _sessionId;
  DateTime? _lastActivity;

  /// Context props stamped on every event (resolved once in [init]).
  Map<String, Object?> _context = const {};

  /// In-memory mirror of the persisted offline queue. Each entry is a full
  /// `{event: {event, properties}}` envelope ready to POST.
  final List<Map<String, dynamic>> _queue = [];

  bool get _enabled => Config.analyticsEnabled && !_prefs.analyticsOptOut;

  String get _network => Config.isDevnet ? 'devnet' : 'mainnet';

  /// Resolve device id, app/device context, restore the queue, and open a
  /// session. Safe to call more than once. Best-effort — any failure leaves
  /// analytics disabled rather than crashing boot.
  Future<void> init() async {
    if (_initialized) return;
    try {
      _deviceId = await _resolveDeviceId();
      _context = await _resolveContext();
      _restoreQueue();
      _startSession();
      _initialized = true;
      unawaited(_flush());
    } catch (e) {
      debugPrint('[Analytics] init failed, analytics disabled: $e');
    }
  }

  /// Emit an event. Fire-and-forget: safe to `unawaited`.
  ///
  /// [entryPoint]/[isOnchainTx] are the conditional globals; [properties] are
  /// event-specific. `null` values are preserved (e.g. `usd_value: null` when a
  /// price isn't cached) rather than stripped.
  Future<void> track(
    String event, {
    Map<String, Object?> properties = const {},
    EntryPoint? entryPoint,
    bool isOnchainTx = false,
  }) async {
    // Check init first: an unregistered/uninitialized service (e.g. in widget
    // tests) must no-op before touching Config.
    if (!_initialized || !_enabled) return;
    _touchSession();

    final props = <String, Object?>{
      ..._context,
      AnalyticsProp.network: _network,
      AnalyticsProp.sessionId: _sessionId,
      'time': DateTime.now().millisecondsSinceEpoch,
      r'$insert_id': _uuid.v4(),
      if (entryPoint != null) AnalyticsProp.entryPoint: entryPoint.wire,
      if (isOnchainTx) AnalyticsProp.isOnchainTx: true,
      ...properties,
    };

    _enqueue({
      'event': {'event': event, 'properties': props},
    });
    await _flush();
  }

  /// Emit a transaction event.
  ///
  /// The single entry point for the transaction family — [txType] is required
  /// and [signature] is stamped alongside it, so no transaction can be recorded
  /// without saying what it was and (once broadcast) which on-chain tx it was.
  /// Pass `signature: null` only where the flow failed before broadcast.
  Future<void> trackTransaction(
    String event, {
    required TxType txType,
    String? signature,
    Map<String, Object?> properties = const {},
    EntryPoint? entryPoint,
    bool isOnchainTx = true,
  }) => track(
    event,
    properties: {
      AnalyticsProp.txType: txType.wire,
      AnalyticsProp.signature: signature,
      ...properties,
    },
    entryPoint: entryPoint,
    isOnchainTx: isOnchainTx,
  );

  /// Emit `Logged In`, at most once per [loginThrottle].
  ///
  /// `/v0/login` runs on every cold start, wallet switch and session refresh,
  /// so the raw call is a plumbing signal, not a user action — tracking it
  /// unthrottled produced runs of identical events. The last-sent stamp is
  /// persisted, so a force-quit-and-relaunch inside the window stays silent.
  Future<void> trackLogin() async {
    if (!_initialized || !_enabled) return;
    final last = _prefs.lastLoggedInTrackedAt;
    final now = DateTime.now();
    if (last != null && now.difference(last).abs() < loginThrottle) return;
    await _prefs.setLastLoggedInTrackedAt(now);
    await track(AnalyticsEvent.loggedIn);
  }

  // ── Session ────────────────────────────────────────────────────────────────

  void _startSession() {
    _sessionId = _uuid.v4();
    _lastActivity = DateTime.now();
  }

  /// Roll the session if 30+ min elapsed since the last activity; otherwise
  /// extend it. Call on resume and before every event.
  void _touchSession() {
    final now = DateTime.now();
    final last = _lastActivity;
    if (_sessionId == null ||
        last == null ||
        now.difference(last) >= _sessionTimeout) {
      _startSession();
    } else {
      _lastActivity = now;
    }
  }

  /// Called from the app lifecycle observer on resume — refresh the session
  /// boundary and drain any events queued while offline/backgrounded.
  Future<void> onForegrounded() async {
    if (!_initialized) return;
    _touchSession();
    await _flush();
  }

  // ── Offline queue ────────────────────────────────────────────────────────

  void _enqueue(Map<String, dynamic> envelope) {
    _queue.add(envelope);
    _pruneQueue();
    _persistQueue();
  }

  /// Drop stale events (> [_maxQueueAge]) and cap the queue (oldest-out).
  void _pruneQueue() {
    final cutoff = DateTime.now().subtract(_maxQueueAge).millisecondsSinceEpoch;
    _queue.removeWhere((e) {
      final t = (e['event']?['properties']?['time']) as int?;
      return t != null && t < cutoff;
    });
    if (_queue.length > _maxQueueSize) {
      _queue.removeRange(0, _queue.length - _maxQueueSize);
    }
  }

  /// Send queued events oldest-first. Stops at the first failure so ordering is
  /// preserved and a dropped connection just retries later.
  Future<void> _flush() async {
    if (_queue.isEmpty) return;
    while (_queue.isNotEmpty) {
      final envelope = _queue.first;
      try {
        await _dio.post<void>(
          _endpoint,
          data: envelope,
          options: Options(
            headers: {
              if (_deviceId != null) 'Device-Id': _deviceId,
              'app-version':
                  '${_context[AnalyticsProp.appVersion]}+${_context[AnalyticsProp.buildNumber]}',
            },
          ),
        );
        _queue.removeAt(0);
        _persistQueue();
      } catch (_) {
        // Network/backend hiccup — keep the queue for the next flush attempt.
        break;
      }
    }
  }

  /// Drop every buffered event **without** sending it.
  ///
  /// PRIVACY: called when the user opts out. Anything still queued was
  /// recorded under the old consent and must not leave the device, so this is
  /// deliberately not a flush — a reviewer watching the network after toggling
  /// the switch off must see nothing go out.
  Future<void> discardQueue() async {
    _queue.clear();
    await _prefs.setAnalyticsQueue(jsonEncode(_queue));
  }

  /// Single entry point for flipping telemetry consent. One switch governs
  /// both pipelines — this queue and the Sentry hub — and both must stop
  /// within this session, not on next launch. Any future writer of the
  /// opt-out pref must go through here: flipping the pref directly leaves the
  /// buffered queue and the Sentry hub out of sync with consent.
  Future<void> setConsent({required bool enabled}) async {
    if (!enabled) {
      // The backlog was recorded under the old consent and must never leave
      // the device — drop it *before* the final event below, so the flush
      // inside `track` sends exactly that one event rather than draining the
      // whole queue first.
      await discardQueue();
      // One final event before the gate flips, so the opt-out is measurable.
      await track(
        AnalyticsEvent.analyticsDisabled,
        properties: {AnalyticsProp.optOut: true},
      );
    }
    await _prefs.setAnalyticsOptOut(!enabled);
    if (!enabled) {
      // If the final event's POST failed it is still buffered — drop it too;
      // nothing may leave the device after the switch flips.
      await discardQueue();
    }
    // Close or re-open the Sentry hub to match. It reads the pref, so this
    // must run after setAnalyticsOptOut.
    await SentryService.applyAnalyticsPreference();
  }

  void _restoreQueue() {
    try {
      final raw = _prefs.analyticsQueue;
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      _queue
        ..clear()
        ..addAll(decoded.cast<Map<String, dynamic>>());
      _pruneQueue();
    } catch (e) {
      debugPrint('[Analytics] failed to restore queue: $e');
    }
  }

  void _persistQueue() {
    // Best-effort; never block the caller on disk.
    unawaited(_prefs.setAnalyticsQueue(jsonEncode(_queue)));
  }

  // ── Device identity & context ──────────────────────────────────────────────

  /// Context props stamped on every event. Each field degrades to `'unknown'`
  /// on its own if a platform channel is unavailable, rather than disabling
  /// analytics entirely.
  Future<Map<String, Object?>> _resolveContext() async {
    var version = 'unknown';
    var build = 'unknown';
    try {
      final pkg = await PackageInfo.fromPlatform();
      version = pkg.version;
      build = pkg.buildNumber;
    } catch (e) {
      debugPrint('[Analytics] package info unavailable: $e');
    }
    return {
      AnalyticsProp.platform: Platform.isIOS ? 'ios' : 'android',
      AnalyticsProp.osVersion: await _resolveOsVersion(),
      AnalyticsProp.appVersion: version,
      AnalyticsProp.buildNumber: build,
      AnalyticsProp.deviceModel: await _resolveDeviceModel(),
    };
  }

  /// Persistent device id in secure storage — the unique-user key. Stable
  /// across reinstall on iOS (keychain survives); resets on Android uninstall.
  Future<String> _resolveDeviceId() async {
    final existing = await _secureStorage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4();
    await _secureStorage.write(key: _deviceIdKey, value: id);
    return id;
  }

  Future<String> _resolveOsVersion() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isIOS) return (await info.iosInfo).systemVersion;
      if (Platform.isAndroid) return (await info.androidInfo).version.release;
    } catch (e) {
      debugPrint('[Analytics] os version unavailable: $e');
    }
    return 'unknown';
  }

  Future<String> _resolveDeviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isIOS) return (await info.iosInfo).utsname.machine;
      if (Platform.isAndroid) return (await info.androidInfo).model;
    } catch (e) {
      debugPrint('[Analytics] device model unavailable: $e');
    }
    return 'unknown';
  }
}
