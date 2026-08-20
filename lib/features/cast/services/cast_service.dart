import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';

/// A discovered cast-capable device.
class CastDevice {
  const CastDevice({required this.id, required this.name, required this.type});

  final String id;
  final String name;
  final CastDeviceType type;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is CastDevice && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

/// The hardware/protocol type of a cast device.
enum CastDeviceType {
  chromecast,
  airplay,

  /// In-app local slideshow (phone screen).
  local,
}

/// Current state of the cast session.
enum CastSessionState { disconnected, connecting, connected, error }

/// Platform-agnostic interface for sending art to a display device.
///
/// Implementations:
///   - [LocalCastService]   — in-app slideshow (dev/testing)
///   - [ChromecastCastService] — Android Chromecast via platform channel
///   - [AirPlayCastService]    — iOS AirPlay via AVPlayer platform channel
abstract interface class CastService {
  /// Stream of available devices. Emits a new list whenever discovery updates.
  Stream<List<CastDevice>> get deviceStream;

  /// Stream of session state changes.
  Stream<CastSessionState> get sessionStream;

  /// Whether the external display infrastructure backing this session is
  /// currently live.
  ///
  /// For AirPlay this is `false` until iOS Screen Mirroring is enabled and
  /// the external display scene attaches — the bloc can be in
  /// [CastActive] (session connected from the app's perspective) while
  /// mirror is still inactive. UI keyed on this stream gates an "open
  /// Control Center → Screen Mirroring" prompt.
  ///
  /// For Chromecast/local backends the concept doesn't apply — once
  /// connected, content flows. Those implementations emit `true` once and
  /// stay there.
  ///
  /// Emits the current value on subscribe and on every change.
  Stream<bool> get externalDisplayActiveStream;

  /// Start scanning for nearby cast devices.
  Future<void> startDiscovery();

  /// Stop scanning and release discovery resources.
  Future<void> stopDiscovery();

  /// Connect to [device] and prepare it for media playback.
  Future<void> connectToDevice(CastDevice device);

  /// Disconnect from the currently connected device.
  Future<void> disconnect();

  /// Send [item] to the connected device for playback with the given [overlay]
  /// rendered on the first frame.
  ///
  /// [resolvedUrl] overrides the default URL selection (useful when the caller
  /// has already performed an HTTP HEAD probe to determine the real media URL).
  Future<void> sendMedia(
    CastQueueItem item, {
    required CastOverlayConfig overlay,
    String? resolvedUrl,
  });

  /// Push a new overlay [config] to the receiver without re-loading media.
  /// Used when the user toggles QR/caption mid-slide.
  Future<void> updateOverlay(CastOverlayConfig config);

  /// Hint to the connected device that [items] are likely to play next, so
  /// it can warm caches (decode images, fetch bytes) ahead of the next
  /// `sendMedia` call. Best-effort — never throws.
  Future<void> preloadItems(List<CastQueueItem> items);

  /// Pause playback on the connected device.
  Future<void> pause();

  /// Resume playback on the connected device.
  Future<void> resume();
}
