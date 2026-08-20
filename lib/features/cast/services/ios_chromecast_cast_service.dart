import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/config/environment.dart';
import '../models/cast_media_type.dart';
import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_service.dart';

/// iOS Chromecast implementation of [CastService] via the Google Cast SDK.
///
/// Communicates with the native [IosChromecastPlugin] Swift class via:
///   - MethodChannel: `com.mallow.wallet/cast_ios`
///   - EventChannel:  `com.mallow.wallet/cast_ios_events`
///
/// Wire format matches the Android [ChromecastCastService] so the single
/// HTML receiver registered on the Cast developer console serves both
/// platforms. The plugin lazily initialises the Cast SDK on the first
/// `startDiscovery` call so iOS's local-network permission prompt fires in
/// context (when the user taps Cast) rather than at app startup.
class IosChromecastCastService implements CastService {
  IosChromecastCastService() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen(_onEvent);
  }

  static const _methodChannel = MethodChannel('com.mallow.wallet/cast_ios');
  static const _eventChannel = EventChannel(
    'com.mallow.wallet/cast_ios_events',
  );

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
    debugPrint('[Cast/iOS-Chromecast] startDiscovery');
    // The receiver id rides on this call rather than a separate `configure`
    // one: `ensureInitialized` runs here and nowhere else, so there is no
    // window in which the plugin could initialise without having been told
    // which receiver to launch.
    await _methodChannel.invokeMethod<void>('startDiscovery', {
      'appId': Config.castReceiverAppId,
    });
  }

  @override
  Future<void> stopDiscovery() async {
    debugPrint('[Cast/iOS-Chromecast] stopDiscovery');
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
    final mediaType = item.mediaType == CastMediaType.unknown
        ? CastMediaType.staticImage
        : item.mediaType;

    // `mediaUrl` is the full-resolution upgrade, `imageUrl` the poster the
    // receiver paints first — see ChromecastCastService.sendMedia for why
    // both must be resolved here rather than in the browser.
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
      'item': {
        'mediaUrl': url,
        'imageUrl': ArtworkMediaResolver.posterUrl(item.imageUrl),
        'mimeType': mimeType,
        'title': item.title,
      },
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
    // Posters only. They are what removes the shimmer on the next slide, and
    // they are a few hundred KB; prefetching two multi-megabyte originals
    // onto a dongle costs bandwidth the slideshow interval already covers.
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
            '[Cast/iOS-Chromecast] native event: devices=${devices.length} '
            '[${devices.map((d) => '${d.name}(${d.id})').join(', ')}]',
          );
          _deviceController.add(devices);
        }

      case 'session':
        final state = event['state'] as String?;
        debugPrint('[Cast/iOS-Chromecast] native event: session=$state');
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
