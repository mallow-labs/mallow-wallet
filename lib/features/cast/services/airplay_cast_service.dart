import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_service.dart';

/// iOS AirPlay implementation of [CastService].
///
/// Communicates with the native [AirPlayPlugin] Swift class via platform channels:
///   - MethodChannel: `com.mallow.wallet/airplay`
///   - EventChannel:  `com.mallow.wallet/airplay_events`
///
/// On iOS, device discovery is handled by the system's [AVRoutePickerView].
/// The picker sheet shows a single "AirPlay" row; tapping it opens the
/// system's device popover — no explicit device enumeration is needed.
class AirPlayCastService implements CastService {
  AirPlayCastService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen(_onEvent);
  }

  static const _methodChannel = MethodChannel('com.mallow.wallet/airplay');
  static const _eventChannel = EventChannel('com.mallow.wallet/airplay_events');

  static const _airPlayDevice = CastDevice(
    id: 'airplay',
    name: 'AirPlay',
    type: CastDeviceType.airplay,
  );

  final _deviceController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSessionState>.broadcast();
  // External-display stream replays the latest value to new subscribers via
  // `onListen` — important because the UI subscribes after the bloc has
  // already received the initial 'mirror' event from the native plugin.
  late final StreamController<bool> _mirrorController =
      StreamController<bool>.broadcast(onListen: _emitLatestMirrorState);
  bool _mirrorActive = false;

  StreamSubscription<dynamic>? _eventSub;

  @override
  Stream<List<CastDevice>> get deviceStream => _deviceController.stream;

  @override
  Stream<CastSessionState> get sessionStream => _sessionController.stream;

  @override
  Stream<bool> get externalDisplayActiveStream => _mirrorController.stream;

  void _emitLatestMirrorState() => _mirrorController.add(_mirrorActive);

  @override
  Future<void> startDiscovery() async {
    debugPrint('[Cast/AirPlay] startDiscovery');
    // Emits the virtual AirPlay device via the event channel on the native side.
    await _methodChannel.invokeMethod<void>('startDiscovery');
  }

  @override
  Future<void> stopDiscovery() async {
    debugPrint('[Cast/AirPlay] stopDiscovery');
    await _methodChannel.invokeMethod<void>('stopDiscovery');
  }

  @override
  Future<void> connectToDevice(CastDevice device) async {
    await _methodChannel.invokeMethod<void>('connectToDevice', {
      'deviceId': device.id,
    });
  }

  @override
  Future<void> disconnect() async {
    await _methodChannel.invokeMethod<void>('disconnect');
  }

  @override
  Future<void> sendMedia(
    CastQueueItem item, {
    required CastOverlayConfig overlay,
    String? resolvedUrl,
  }) async {
    // The AirPlay receiver runs a secondary Flutter engine and renders
    // CastReceiverView directly, so the full CastQueueItem flows through
    // and the receiver resolves the playable URL itself via
    // CastAnimatedArtwork. resolvedUrl is unused on iOS.
    await _methodChannel.invokeMethod<void>('loadMedia', {
      'item': item.toJson(),
      'overlay': overlay.toJson(),
    });
  }

  @override
  Future<void> updateOverlay(CastOverlayConfig config) async {
    await _methodChannel.invokeMethod<void>('updateOverlay', {
      'overlay': config.toJson(),
    });
  }

  @override
  Future<void> preloadItems(List<CastQueueItem> items) async {
    if (items.isEmpty) return;
    // Forward full items so the secondary Flutter engine can warm the
    // painting cache the same way the local receiver does. The plugin
    // delivers this on the existing receiver method channel.
    await _methodChannel.invokeMethod<void>('preload', {
      'items': items.map((it) => it.toJson()).toList(),
    });
  }

  @override
  Future<void> pause() async {
    await _methodChannel.invokeMethod<void>('pause');
  }

  @override
  Future<void> resume() async {
    await _methodChannel.invokeMethod<void>('resume');
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'devices':
        debugPrint('[Cast/AirPlay] native event: devices (virtual AirPlay)');
        // iOS emits a single virtual AirPlay device.
        _deviceController.add([_airPlayDevice]);

      case 'session':
        final state = event['state'] as String?;
        debugPrint('[Cast/AirPlay] native event: session=$state');
        final sessionState = switch (state) {
          'connecting' => CastSessionState.connecting,
          'connected' => CastSessionState.connected,
          'error' => CastSessionState.error,
          _ => CastSessionState.disconnected,
        };
        _sessionController.add(sessionState);

      case 'mirror':
        final state = event['state'] as String?;
        debugPrint('[Cast/AirPlay] native event: mirror=$state');
        _mirrorActive = state == 'active';
        _mirrorController.add(_mirrorActive);
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _deviceController.close();
    _sessionController.close();
    _mirrorController.close();
  }
}
