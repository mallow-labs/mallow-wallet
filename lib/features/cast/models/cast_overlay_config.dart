import 'package:freezed_annotation/freezed_annotation.dart';

import 'cast_display_type.dart';
import 'cast_media_type.dart';
import 'cast_queue.dart';

part 'cast_overlay_config.freezed.dart';
part 'cast_overlay_config.g.dart';

/// Resolved per-item overlay payload sent to the cast receiver.
///
/// Constructed from session-scoped toggles on [CastQueue] and the current
/// [CastQueueItem]. Carries everything the receiver needs to render the
/// overlay; the receiver does not look up artwork data itself.
@freezed
sealed class CastOverlayConfig with _$CastOverlayConfig {
  const factory CastOverlayConfig({
    @Default(true) bool showQr,
    @Default(true) bool showCaption,

    /// URL the QR code encodes. Null when [showQr] is false or the source
    /// item lacks a mint account.
    String? qrUrl,

    String? title,

    /// Artist name, rendered below [title] in the receiver caption.
    String? subtitle,

    /// How the receiver should fit the artwork above the bottom info bar.
    /// Carried per-render so the receiver can apply the active mode without
    /// holding session state itself.
    @Default(CastDisplayType.fillScreen) CastDisplayType displayType,

    /// Image URL of the previous queue item, used by the tile-mode
    /// carousel to render a left peek and animate slide-back transitions.
    /// Null at the start of an unwrapped queue. **Raw** as built by
    /// [CastOverlayConfigFromQueue.from] — see [CastOverlayConfigWire].
    String? prevImageUrl,

    /// Image URL of the next queue item, used by the tile-mode carousel
    /// to render a right peek and animate slide-forward transitions.
    /// Null at the end of an unwrapped queue. **Raw** as built by
    /// [CastOverlayConfigFromQueue.from] — see [CastOverlayConfigWire].
    String? nextImageUrl,
  }) = _CastOverlayConfig;

  factory CastOverlayConfig.fromJson(Map<String, dynamic> json) =>
      _$CastOverlayConfigFromJson(json);
}

extension CastOverlayConfigFromQueue on CastOverlayConfig {
  /// Build the overlay payload from session [queue] settings + current [item].
  ///
  /// Tile mode needs prev/curr/next to read as a carousel; a 1- or 2-item
  /// queue collapses the peek slots and reads as a broken layout, so the
  /// receiver renders fit-to-screen instead. The user's preference stays on
  /// [CastQueue.displayType] — adding a third item resumes tile naturally.
  static CastOverlayConfig from(CastQueue queue, CastQueueItem item) {
    final effective =
        queue.displayType == CastDisplayType.tile && queue.items.length < 3
        ? CastDisplayType.fitToScreen
        : queue.displayType;
    return CastOverlayConfig(
      showQr: queue.showQr,
      showCaption: queue.showCaption,
      qrUrl: queue.showQr
          ? 'https://mallow.art/artwork/${item.mintAccount}'
          : null,
      title: item.title,
      subtitle: item.artistName,
      displayType: effective,
      prevImageUrl: queue.previousItem?.imageUrl,
      nextImageUrl: queue.nextItem?.imageUrl,
    );
  }
}

extension CastOverlayConfigWire on CastOverlayConfig {
  /// The overlay as the **HTML (Chromecast) receiver** needs it: peek URLs
  /// rewritten to CDN posters.
  ///
  /// The browser sets those straight onto `<img src>` and cannot fetch the raw
  /// `ipfs://` / `ar://` sources the API returns. The Flutter receivers keep
  /// the raw form instead — they resolve per-render, and `_TileCarousel`'s
  /// direction detection compares these against the item's own raw `imageUrl`.
  ///
  /// Both sides of that comparison must agree, so the HTML receiver's
  /// `item.imageUrl` is the poster too (see `ChromecastCastService.sendMedia`).
  CastOverlayConfig get forHtmlReceiver => copyWith(
    prevImageUrl: _poster(prevImageUrl),
    nextImageUrl: _poster(nextImageUrl),
  );

  static String? _poster(String? url) =>
      (url == null || url.isEmpty) ? url : ArtworkMediaResolver.posterUrl(url);
}
