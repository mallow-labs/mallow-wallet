import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import 'cast_service.dart';

/// Composes multiple per-protocol [CastService] backends behind a single
/// interface. Used on iOS to surface AirPlay + Chromecast devices in one
/// picker; could host other protocols (DLNA, Roku, etc.) the same way.
///
/// - `deviceStream` emits the union of all backends' device lists, preserving
///   the order in which backends were passed to the constructor (so AirPlay
///   stays at the top and Chromecasts append as they're discovered).
/// - `sessionStream` forwards the active backend's session events.
/// - `connectToDevice` picks the backend that emitted the device, remembers
///   it as active, and routes all subsequent media/overlay/control calls.
class MultiCastService implements CastService {
  MultiCastService(this._services) {
    debugPrint(
      '[Cast/Multi] composing ${_services.length} backend(s): '
      '${_services.map((s) => s.runtimeType).join(', ')}',
    );
    for (final svc in _services) {
      _latest[svc] = const [];
      _deviceSubs.add(
        svc.deviceStream.listen((devices) {
          _latest[svc] = devices;
          final combined = _combinedDevices();
          debugPrint(
            '[Cast/Multi] ${svc.runtimeType} → ${devices.length} device(s); '
            'combined=${combined.length}',
          );
          _deviceController.add(combined);
        }),
      );
      _sessionSubs.add(svc.sessionStream.listen(_sessionController.add));
    }
  }

  final List<CastService> _services;
  final Map<CastService, List<CastDevice>> _latest = {};
  final List<StreamSubscription<dynamic>> _deviceSubs = [];
  final List<StreamSubscription<dynamic>> _sessionSubs = [];
  final _deviceController = StreamController<List<CastDevice>>.broadcast();
  final _sessionController = StreamController<CastSessionState>.broadcast();
  // Replays the latest mirror state on subscribe — late subscribers (e.g. a
  // sheet opened after the session is established) should see the current
  // value immediately, not wait for the next event.
  late final StreamController<bool> _mirrorController =
      StreamController<bool>.broadcast(onListen: _emitLatestMirrorState);
  StreamSubscription<bool>? _mirrorSub;
  bool _mirrorLatest = true;

  CastService? _active;

  @override
  Stream<List<CastDevice>> get deviceStream => _deviceController.stream;

  @override
  Stream<CastSessionState> get sessionStream => _sessionController.stream;

  @override
  Stream<bool> get externalDisplayActiveStream => _mirrorController.stream;

  void _emitLatestMirrorState() => _mirrorController.add(_mirrorLatest);

  @override
  Future<void> startDiscovery() async {
    await Future.wait(_services.map((s) => s.startDiscovery()));
  }

  @override
  Future<void> stopDiscovery() async {
    await Future.wait(_services.map((s) => s.stopDiscovery()));
  }

  @override
  Future<void> connectToDevice(CastDevice device) async {
    final service = _serviceFor(device);
    _active = service;
    // Forward the active backend's mirror state to the combined controller.
    // Non-AirPlay backends emit `true` once and stay there; AirPlay emits
    // `false` until iOS Screen Mirroring attaches the external scene.
    await _mirrorSub?.cancel();
    _mirrorSub = service.externalDisplayActiveStream.listen((active) {
      _mirrorLatest = active;
      _mirrorController.add(active);
    });
    await service.connectToDevice(device);
  }

  @override
  Future<void> disconnect() async {
    final service = _active;
    _active = null;
    await _mirrorSub?.cancel();
    _mirrorSub = null;
    _mirrorLatest = true;
    if (service != null) await service.disconnect();
  }

  @override
  Future<void> sendMedia(
    CastQueueItem item, {
    required CastOverlayConfig overlay,
    String? resolvedUrl,
  }) async {
    await _active?.sendMedia(item, overlay: overlay, resolvedUrl: resolvedUrl);
  }

  @override
  Future<void> updateOverlay(CastOverlayConfig config) async {
    await _active?.updateOverlay(config);
  }

  @override
  Future<void> preloadItems(List<CastQueueItem> items) async {
    await _active?.preloadItems(items);
  }

  @override
  Future<void> pause() async {
    await _active?.pause();
  }

  @override
  Future<void> resume() async {
    await _active?.resume();
  }

  // --- private ---

  List<CastDevice> _combinedDevices() {
    final out = <CastDevice>[];
    for (final svc in _services) {
      out.addAll(_latest[svc] ?? const []);
    }
    return out;
  }

  /// Find the backend that emitted [device]. Falls back to matching by
  /// `device.type` if the device has been removed from the latest snapshot
  /// (e.g. a connect attempt racing with a discovery update).
  CastService _serviceFor(CastDevice device) {
    for (final svc in _services) {
      final list = _latest[svc];
      if (list != null && list.any((d) => d.id == device.id)) {
        return svc;
      }
    }
    for (final svc in _services) {
      final list = _latest[svc] ?? const <CastDevice>[];
      if (list.any((d) => d.type == device.type)) {
        return svc;
      }
    }
    throw StateError('No backend for device ${device.id} (${device.type})');
  }

  void dispose() {
    for (final sub in _deviceSubs) {
      sub.cancel();
    }
    for (final sub in _sessionSubs) {
      sub.cancel();
    }
    _mirrorSub?.cancel();
    _deviceController.close();
    _sessionController.close();
    _mirrorController.close();
  }
}
