/// Mux stream / poster URL helpers.
///
/// mallow uploads artwork video to Mux and exposes a `playbackId` (full asset)
/// and optional `clipPlaybackId` (a short preview loop) on NFT renders. The
/// `@mux/mux-video-react` component builds these URLs internally on web; on
/// mobile we hand them straight to `video_player` (AVPlayer / ExoPlayer both
/// play HLS natively).
class Mux {
  Mux._();

  /// HLS manifest for a playback id — fed directly to `VideoPlayerController`.
  static String streamUrl(String playbackId) =>
      'https://stream.mux.com/$playbackId.m3u8';

  /// Static poster frame for a playback id. Used as the still fallback before
  /// the stream is ready when no separate image thumbnail exists.
  static String posterUrl(String playbackId) =>
      'https://image.mux.com/$playbackId/thumbnail.jpg';

  /// Preferred inline-preview id: the short clip loop when present, else the
  /// full asset. Mirrors the webapp's `clipPlaybackId ?? playbackId`.
  static String? previewId(String? playbackId, String? clipPlaybackId) {
    final clip = clipPlaybackId?.trim();
    if (clip != null && clip.isNotEmpty) return clip;
    final full = playbackId?.trim();
    if (full != null && full.isNotEmpty) return full;
    return null;
  }
}
