import 'dart:async';

// `extended_image` only to warm the cache `CastProgressiveArtwork` reads —
// the same narrow receiver-side exception `cast_receiver_app.dart` takes for
// the AirPlay engine. Nothing here renders.
import 'package:extended_image/extended_image.dart';
import 'package:flutter/painting.dart';

import '../models/cast_media_type.dart';
import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_service.dart';

/// Local (in-app) cast service implementation.
///
/// Drives a fullscreen on-device slideshow — no external hardware required.
/// Used in development, on simulators, and as the fallback on devices without
/// Chromecast/AirPlay support.
///
/// Registered in [RegisterModule.castService] so Phase 5/6 can swap to
/// Chromecast/AirPlay implementations without touching annotations.
class LocalCastService implements CastService {
  final _deviceController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSessionState>.broadcast();

  static const _localDevice = CastDevice(
    id: 'local',
    name: 'This device',
    type: CastDeviceType.local,
  );

  @override
  Stream<List<CastDevice>> get deviceStream => _deviceController.stream;

  @override
  Stream<CastSessionState> get sessionStream => _sessionController.stream;

  @override
  Stream<bool> get externalDisplayActiveStream => Stream.value(true);

  @override
  Future<void> startDiscovery() async {
    // Immediately emit the local device — always available.
    _deviceController.add([_localDevice]);
  }

  @override
  Future<void> stopDiscovery() async {
    _deviceController.add([]);
  }

  @override
  Future<void> connectToDevice(CastDevice device) async {
    _sessionController.add(CastSessionState.connecting);
    // Simulate a brief connection delay.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _sessionController.add(CastSessionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _sessionController.add(CastSessionState.disconnected);
  }

  @override
  Future<void> sendMedia(
    CastQueueItem item, {
    required CastOverlayConfig overlay,
    String? resolvedUrl,
  }) async {
    // Local rendering is driven directly by CastBloc state via
    // LocalCastReceiverOverlay — no service-side push needed.
  }

  @override
  Future<void> updateOverlay(CastOverlayConfig config) async {
    // See sendMedia above — overlay state lives in CastBloc; the receiver
    // widget rebuilds automatically.
  }

  @override
  Future<void> preloadItems(List<CastQueueItem> items) async {
    // Warm both the media-type probe cache and the painting image cache so
    // the next slide renders without a fetch.
    for (final item in items) {
      unawaited(
        ArtworkMediaResolver.resolveAsync(
          imageUrl: item.imageUrl,
          animationUrl: item.animationUrl,
        ),
      );
      if (item.imageUrl.isNotEmpty) {
        // 🛑 Every field the renderer's provider is built with has to match
        // here, because `ExtendedNetworkImageProvider` puts them all in its
        // `operator ==` / `hashCode` and returns *itself* from `obtainKey` —
        // so any difference warms a cache entry the renderer will never look
        // up, which is a preload that silently does nothing.
        //   * the *poster* URL, not the raw source: the raw one is usually an
        //     unfetchable `ipfs://` URI, and it is not what gets rendered.
        //   * `cache: true`, because `ExtendedImage.network` defaults to true
        //     while this constructor defaults to **false**.
        // Keep this in step with `_CastImageLayer` in cast_animated_artwork.dart.
        ExtendedNetworkImageProvider(
          ArtworkMediaResolver.posterUrl(item.imageUrl),
          cache: true,
        ).resolve(ImageConfiguration.empty);
      }
    }
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  void dispose() {
    _deviceController.close();
    _sessionController.close();
  }
}
