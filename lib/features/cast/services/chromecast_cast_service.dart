import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/cast_media_type.dart';
import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_service.dart';

/// Android Chromecast implementation of [CastService].
///
/// Communicates with the native [CastPlugin] Kotlin class via platform channels:
///   - MethodChannel: `com.mallow.wallet/cast`
///   - EventChannel:  `com.mallow.wallet/cast_events`
class ChromecastCastService implements CastService {
  ChromecastCastService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen(_onEvent);
  }

  static const _methodChannel = MethodChannel('com.mallow.wallet/cast');
  static const _eventChannel = EventChannel('com.mallow.wallet/cast_events');

  final _deviceController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSessionState>.broadcast();

  StreamSubscription<dynamic>? _eventSub;

  @override
  Stream<List<CastDevice>> get deviceStream => _deviceController.stream;

  @override
  Stream<CastSessionState> get sessionStream => _sessionController.stream;

  @override
  Stream<bool> get externalDisplayActiveStream => Stream.value(true);

  @override
  Future<void> startDiscovery() async {
    debugPrint('[Cast/Android-Chromecast] startDiscovery');
    await _methodChannel.invokeMethod<void>('startDiscovery');
  }

  @override
  Future<void> stopDiscovery() async {
    debugPrint('[Cast/Android-Chromecast] stopDiscovery');
    await _methodChannel.invokeMethod<void>('stopDiscovery');
  }

  @override
  Future<void> connectToDevice(CastDevice device) async {
    debugPrint(
      '[Cast/Android-Chromecast] connectToDevice ${device.name}(${device.id})',
    );
    try {
      await _methodChannel.invokeMethod<void>('connectToDevice', {
        'deviceId': device.id,
      });
      debugPrint('[Cast/Android-Chromecast] connectToDevice → method returned');
    } catch (e, st) {
      debugPrint('[Cast/Android-Chromecast] connectToDevice FAILED: $e\n$st');
      rethrow;
    }
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
    final mediaType = item.mediaType == CastMediaType.unknown
        ? CastMediaType.staticImage
        : item.mediaType;

    // Two URLs, both resolved here: the receiver is a browser and cannot
    // fetch the raw `ipfs://` / `ar://` sources the API returns, nor build a
    // CDN bucket itself.
    //   `imageUrl` — the small CDN poster it paints immediately.
    //   `url` (→ `mediaUrl`) — the full-resolution original it cross-fades in
    //                          once downloaded.
    final url =
        resolvedUrl ??
        ArtworkMediaResolver.originalCastUrl(
          imageUrl: item.imageUrl,
          mediaType: mediaType,
          animationUrl: item.animationUrl,
        );

    final mimeType = switch (mediaType) {
      CastMediaType.video => 'video/mp4',
      CastMediaType.animated => 'image/gif',
      _ => 'image/jpeg',
    };

    await _methodChannel.invokeMethod<void>('loadMedia', {
      'url': url,
      'mimeType': mimeType,
      'title': item.title,
      'imageUrl': ArtworkMediaResolver.posterUrl(item.imageUrl),
      'overlay': overlay.forHtmlReceiver.toJson(),
    });
  }

  @override
  Future<void> updateOverlay(CastOverlayConfig config) async {
    await _methodChannel.invokeMethod<void>('updateOverlay', {
      'overlay': config.forHtmlReceiver.toJson(),
    });
  }

  @override
  Future<void> preloadItems(List<CastQueueItem> items) async {
    if (items.isEmpty) return;
    // The HTML receiver listens for {type:'preload', urls:[...]} and warms
    // the browser image cache. Posters only: they are what removes the
    // shimmer on the next slide, and they are a few hundred KB; prefetching
    // two multi-megabyte originals onto a dongle costs bandwidth the
    // slideshow interval already covers.
    final urls = <String>[];
    for (final it in items) {
      final url = ArtworkMediaResolver.posterUrl(it.imageUrl);
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) return;
    await _methodChannel.invokeMethod<void>('preload', {'urls': urls});
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
        final rawDevices = event['devices'];
        if (rawDevices is List) {
          final devices = rawDevices
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (d) => CastDevice(
                  id: d['id']?.toString() ?? '',
                  name: d['name']?.toString() ?? '',
                  type: CastDeviceType.chromecast,
                ),
              )
              .toList();
          debugPrint(
            '[Cast/Android-Chromecast] devices=${devices.length}: '
            '${devices.map((d) => d.name).join(', ')}',
          );
          _deviceController.add(devices);
        }

      case 'session':
        final state = event['state'] as String?;
        debugPrint('[Cast/Android-Chromecast] native event: session=$state');
        final sessionState = switch (state) {
          'connecting' => CastSessionState.connecting,
          'connected' => CastSessionState.connected,
          'error' => CastSessionState.error,
          _ => CastSessionState.disconnected,
        };
        _sessionController.add(sessionState);
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _deviceController.close();
    _sessionController.close();
  }
}
