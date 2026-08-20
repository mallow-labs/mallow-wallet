import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/environment.dart';

/// Builds a `WebSocketChannel` for the given URL. Production uses
/// `WebSocketChannel.connect`; tests inject a stub so the WS layer can be
/// driven from in-process streams.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// A routed event: the typed payload [event] plus the string [key] it belongs
/// to (a mint, an account pubkey, …), so [RealtimeSocket.watch] can fan out a
/// single connection to per-key streams.
typedef KeyedEvent<T> = ({String key, T event});

/// Shared machinery for the backend's realtime WebSockets.
///
/// Owns a single multiplexed WebSocket to `<api-v2-base><wsPathSuffix>` (scheme
/// swapped to `wss://`/`ws://`), refcounts per-key subscriptions across
/// consumers, and reconnects with exponential backoff on transient drops.
/// Subclasses bind it to a concrete endpoint by supplying the path suffix, the
/// `subscribe`/`unsubscribe` key field name, and a frame parser.
///
/// Behavior contract:
/// * [watch] returns a broadcast stream of [T] events scoped to one key. The
///   WS opens on the first watcher; an `unsubscribe` is sent and the channel is
///   torn down after the last watcher cancels and a short grace period elapses
///   (to survive screen-to-screen navigation).
/// * On reconnect, `subscribe` is re-sent for every still-watched key and (if
///   [syntheticReconnectEvent] is non-null) a synthetic event is emitted on
///   each — so consumers refetch and close any gap that opened during the
///   outage.
/// * On `AppLifecycleState.paused` the WS is closed (refcounts retained); on
///   `resumed` the connection is rebuilt if any key is still watched.
abstract class RealtimeSocket<T> with WidgetsBindingObserver {
  RealtimeSocket({
    WebSocketChannelFactory? channelFactory,
    String Function()? wsUrlOverride,
    Random? random,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect,
       _wsUrlOverride = wsUrlOverride,
       _random = random ?? Random() {
    WidgetsBinding.instance.addObserver(this);
  }

  // ── Subclass contract ──────────────────────────────────────────────────

  /// Path appended to [Config.apiV2BaseUrl], e.g. `/ws/invalidations`.
  String get wsPathSuffix;

  /// JSON field carrying the key list in `subscribe`/`unsubscribe` messages,
  /// e.g. `mints` or `keys`.
  String get subscribeKeyField;

  /// A short label used only in debug logs to disambiguate sockets.
  String get debugLabel => runtimeType.toString();

  /// Parse a decoded data frame into a routed event, or null to ignore it.
  /// `type: ack`/`error` frames are handled by the base and never reach here.
  /// May throw on a malformed frame — the base catches and drops it.
  KeyedEvent<T>? parseFrame(Map<String, dynamic> json);

  /// Optional synthetic event emitted for each still-watched [key] on
  /// reconnect, so consumers refetch the gap. Null disables it.
  T? syntheticReconnectEvent(String key) => null;

  // ── State ──────────────────────────────────────────────────────────────

  static const _gracePeriod = Duration(seconds: 5);
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _maxReconnectDelay = Duration(seconds: 300);

  final WebSocketChannelFactory _channelFactory;
  final String Function()? _wsUrlOverride;
  final Random _random;

  // Lifetime matches the singleton; closed in `dispose()`.
  // ignore: close_sinks
  final StreamController<KeyedEvent<T>> _events =
      StreamController<KeyedEvent<T>>.broadcast();

  /// Key → number of active [watch] subscribers.
  final Map<String, int> _refcounts = {};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  bool _channelReady = false;
  Timer? _idleCloseTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _paused = false;

  // ── Public API ─────────────────────────────────────────────────────────

  /// Subscribe to events for [key]. The first subscriber opens (or reuses) the
  /// WS connection; the last cancellation tears it down after [_gracePeriod].
  Stream<T> watch(String key) {
    if (_disposed) {
      return const Stream.empty();
    }

    late StreamController<T> controller;
    StreamSubscription<KeyedEvent<T>>? upstream;

    void onListen() {
      _retain(key);
      upstream = _events.stream
          .where((e) => e.key == key)
          .listen((e) => controller.add(e.event));
    }

    Future<void> onCancel() async {
      await upstream?.cancel();
      upstream = null;
      _release(key);
      await controller.close();
    }

    controller = StreamController<T>.broadcast(
      onListen: onListen,
      onCancel: onCancel,
    );
    return controller.stream;
  }

  /// Inject a synthetic event for [key] into the same stream [watch] exposes —
  /// used by transaction pipelines to drive a refresh the moment our own
  /// `checkTx` poll confirms, without waiting for the backend's WS push.
  void publishLocalRaw(String key, T event) {
    if (_disposed) return;
    _events.add((key: key, event: event));
  }

  // ── Connection management ────────────────────────────────────────────────

  void _retain(String key) {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;

    final next = (_refcounts[key] ?? 0) + 1;
    _refcounts[key] = next;

    if (_paused) return;

    if (_channel == null) {
      _ensureConnection();
    } else if (next == 1 && _channelReady) {
      _send({
        'action': 'subscribe',
        subscribeKeyField: [key],
      });
    }
  }

  void _release(String key) {
    final current = _refcounts[key] ?? 0;
    if (current <= 1) {
      _refcounts.remove(key);
      if (_channelReady) {
        _send({
          'action': 'unsubscribe',
          subscribeKeyField: [key],
        });
      }
    } else {
      _refcounts[key] = current - 1;
    }

    if (_refcounts.isEmpty) {
      _idleCloseTimer?.cancel();
      _idleCloseTimer = Timer(_gracePeriod, () {
        if (_refcounts.isEmpty) _teardown();
      });
    }
  }

  void _ensureConnection() {
    if (_disposed || _paused) return;
    if (_channel != null) return;

    final uri = Uri.parse(_resolveWsUrl());
    debugPrint('[$debugLabel] connecting to $uri');

    final WebSocketChannel channel;
    try {
      channel = _channelFactory(uri);
    } catch (e, st) {
      debugPrint('[$debugLabel] connect failed: $e\n$st');
      _scheduleReconnect();
      return;
    }

    _channel = channel;
    _channelReady = true;

    // Resubscribe everything we're still watching, and emit synthetic events
    // so consumers refetch any state that may have changed while down.
    if (_refcounts.isNotEmpty) {
      _send({
        'action': 'subscribe',
        subscribeKeyField: _refcounts.keys.toList(growable: false),
      });
      for (final key in _refcounts.keys) {
        final synthetic = syntheticReconnectEvent(key);
        if (synthetic != null) {
          _events.add((key: key, event: synthetic));
        }
      }
    }

    _channelSub = channel.stream.listen(
      _handleFrame,
      onError: (Object error, StackTrace st) {
        debugPrint('[$debugLabel] socket error: $error');
        _onChannelClosed();
      },
      onDone: () {
        debugPrint('[$debugLabel] socket closed (code=${channel.closeCode})');
        _onChannelClosed();
      },
      cancelOnError: true,
    );
  }

  void _onChannelClosed() {
    _channelReady = false;
    _channelSub?.cancel();
    _channelSub = null;
    _channel = null;
    if (_disposed || _paused) return;
    if (_refcounts.isEmpty) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final exp = pow(2, min(_reconnectAttempt, 10)).toInt();
    final base = _baseReconnectDelay * exp;
    final capped = base > _maxReconnectDelay ? _maxReconnectDelay : base;
    // ±20% jitter to avoid coordinated reconnect storms when the backend
    // restarts.
    final jitter = 1.0 + (_random.nextDouble() * 0.4 - 0.2);
    final delay = Duration(
      milliseconds: (capped.inMilliseconds * jitter).round(),
    );
    _reconnectAttempt++;
    debugPrint(
      '[$debugLabel] reconnecting in ${delay.inMilliseconds}ms '
      '(attempt $_reconnectAttempt)',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _ensureConnection();
    });
  }

  void _handleFrame(dynamic frame) {
    final String text;
    if (frame is String) {
      text = frame;
    } else if (frame is List<int>) {
      text = utf8.decode(frame);
    } else {
      return;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      debugPrint('[$debugLabel] bad JSON frame: $text');
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    final type = decoded['type'];
    if (type == 'ack') {
      // First successful frame after a (re)connect resets the backoff.
      _reconnectAttempt = 0;
      return;
    }
    if (type == 'error') {
      debugPrint('[$debugLabel] server error: ${decoded['message']}');
      return;
    }

    try {
      final parsed = parseFrame(decoded);
      if (parsed == null) return;
      _reconnectAttempt = 0;
      _events.add(parsed);
    } catch (e) {
      debugPrint('[$debugLabel] malformed frame: $decoded');
    }
  }

  void _send(Map<String, dynamic> message) {
    final ch = _channel;
    if (ch == null || !_channelReady) return;
    try {
      ch.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint('[$debugLabel] send failed: $e');
    }
  }

  void _teardown() {
    _idleCloseTimer?.cancel();
    _idleCloseTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channelSub?.cancel();
    _channelSub = null;
    final ch = _channel;
    _channel = null;
    _channelReady = false;
    _reconnectAttempt = 0;
    if (ch != null) {
      try {
        ch.sink.close();
      } catch (_) {
        /* ignore */
      }
    }
  }

  String _resolveWsUrl() {
    if (_wsUrlOverride != null) return _wsUrlOverride();
    final base = Config.apiV2BaseUrl;
    final wsBase = base.startsWith('https://')
        ? 'wss://${base.substring('https://'.length)}'
        : base.startsWith('http://')
        ? 'ws://${base.substring('http://'.length)}'
        : base;
    return '$wsBase$wsPathSuffix';
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _paused = true;
        _teardown();
      case AppLifecycleState.resumed:
        _paused = false;
        if (_refcounts.isNotEmpty) _ensureConnection();
      case AppLifecycleState.inactive:
        // Transient — don't churn the connection.
        break;
    }
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    _events.close();
    _refcounts.clear();
  }
}
