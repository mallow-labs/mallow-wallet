import 'dart:async';

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
    // the next slide renders without a fetch. Local rendering uses Flutter's
    // ImageProvider chain, so resolving NetworkImage seeds PaintingBinding's
    // imageCache transparently.
    for (final item in items) {
      unawaited(
        ArtworkMediaResolver.resolveAsync(
          imageUrl: item.imageUrl,
          animationUrl: item.animationUrl,
        ),
      );
      if (item.imageUrl.isNotEmpty) {
        NetworkImage(item.imageUrl).resolve(ImageConfiguration.empty);
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
