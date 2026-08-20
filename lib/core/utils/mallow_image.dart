/// Image optimization utilities for mallow.
///
/// Transforms raw image URLs into resize URLs on the configured image CDN
/// ([Config.imageCdnBaseUrl]), matching the web client's own thumbnail rule.
///
/// With no CDN configured every entry point returns the resolved source URL
/// unchanged, so a build without one still renders — at full size, straight
/// from the asset's own origin.
///
/// Usage:
///   final url = MallowImage.cdnUrl(rawUrl, logicalPx: 140);
///   // Returns: `<cdn>/350x350/cover/{encoded}?quality=50`
library;

import '../config/environment.dart';
import 'asset_url.dart';
import 'canonical_asset_url.dart';

class MallowImage {
  MallowImage._();

  /// Origin of the resize service, without a trailing slash. Empty when this
  /// build has no image CDN — see [_buildUrl].
  static String get _cdnBase {
    final base = Config.imageCdnBaseUrl;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// Pixel density assumed when the caller has no [MediaQuery] to read a real
  /// one from (non-widget code paths). Matches the standard Retina screen the
  /// buckets were originally sized for.
  static const double defaultPixelRatio = 2;

  // Supported CDN sizes (px) — keep in sync with the web client's thumbnail
  // size set.
  // These are the only buckets the backend pre-warms, so cdnUrl must never emit
  // a size outside this set (cdnUrlForSize should also stick to these).
  static const List<int> _cdnSizes = [50, 100, 350, 600, 800];

  /// Picks the smallest CDN size that covers [logicalPx] at [dpr] pixel
  /// density, clamped to the largest bucket.
  static int _pickSize(double logicalPx, double dpr) {
    final needed = (logicalPx * dpr).ceil();
    for (final s in _cdnSizes) {
      if (s >= needed) return s;
    }
    return _cdnSizes.last;
  }

  /// The source URL embedded in a CDN resize path.
  ///
  /// With [Config.canonicalAssetUrls] on, that is the canonical form
  /// (`ipfs://<CID>` / `ar://<TXID>`, verbatim https otherwise) so every arrival
  /// shape of one asset collapses onto a single Cloudflare edge key and a single
  /// R2 object (original-serving spec). Off, it keeps the legacy behaviour of
  /// handing the CDN a resolved gateway URL — see [Config.canonicalAssetUrls]
  /// for why Flutter trails the rollout.
  static String _cdnSource(String url) =>
      Config.canonicalAssetUrls ? canonicalizeAssetUrl(url) : _resolveIpfs(url);

  /// Normalises an IPFS URL to an HTTPS gateway URL, deferring to [AssetUrl] so
  /// the CDN is handed the same gateway the app prefers for direct fetches
  /// ([Config.ipfsGatewayUrl]) rather than a second, separately-chosen one.
  static String _resolveIpfs(String url) {
    if (url.startsWith('ipfs://')) {
      return AssetUrl.primaryGatewayUrl(url);
    }
    return url;
  }

  /// Returns a CDN-optimised URL sized for [logicalPx] at [dpr] pixel density.
  ///
  /// Pass the largest rendered dimension in logical pixels (device-independent
  /// points) and the screen's `devicePixelRatio` — a 3× device otherwise gets a
  /// bucket sized for 2× and decodes an upscaled image. [dpr] defaults to
  /// [defaultPixelRatio] for callers with no [BuildContext].
  ///
  /// [fit] controls the resize strategy:
  ///   - `'cover'` (default) — crops to fill the square
  ///   - `'inside'` — fits the whole image without cropping
  static String cdnUrl(
    String imageUrl, {
    required double logicalPx,
    double dpr = defaultPixelRatio,
    String fit = 'cover',
    int quality = 50,
  }) {
    if (imageUrl.isEmpty) return imageUrl;
    final size = _pickSize(logicalPx, dpr);
    return _buildUrl(imageUrl, size: size, fit: fit, quality: quality);
  }

  /// Returns a CDN-optimised URL at an explicit [cdnSize].
  ///
  /// Prefer [cdnUrl] for automatic size selection. Use this when you need a
  /// specific bucket (e.g. full-screen artwork → 800).
  static String cdnUrlForSize(
    String imageUrl, {
    required int cdnSize,
    String fit = 'cover',
    int quality = 50,
  }) {
    if (imageUrl.isEmpty) return imageUrl;
    return _buildUrl(imageUrl, size: cdnSize, fit: fit, quality: quality);
  }

  /// Returns the full-resolution original — NOT routed through the CDN resizer.
  /// Use for fullscreen zoom, where the native resolution matters and a resized
  /// bucket would look soft when magnified.
  ///
  /// The image CDN's `/original/` route when one is configured: it
  /// serves mint-time bytes from R2 when stored — far faster than the public
  /// gateways, which is the whole reason originals are cached — and redirects
  /// to the best live gateway when not. Not gated on
  /// [Config.canonicalAssetUrls]; that flag
  /// only decides the form of the *resize* path. A failed load still falls back
  /// to the asset's own gateway via `ImageFallback.directUrlFor`.
  static String originalUrl(String imageUrl) {
    if (imageUrl.isEmpty) return imageUrl;
    return getOriginalAssetUrl(imageUrl);
  }

  static String _buildUrl(
    String imageUrl, {
    required int size,
    required String fit,
    required int quality,
  }) {
    final resolved = _cdnSource(imageUrl);
    final base = _cdnBase;
    // No resizer configured: hand back the resolved source. Callers treat the
    // result as "the URL to load", and an unresized image is a slower correct
    // answer where a CDN-shaped path pointing nowhere is a broken one.
    //
    // With the canonical flag on, [_cdnSource] emits `ipfs://` / `ar://` — a
    // cache key for the resize path, not something an image loader can fetch.
    // Nothing cross-gates the two settings, so a build that sets the flag with
    // no CDN would hand every content-addressed image an unfetchable scheme and
    // render the error fallback. Map it back to a gateway, as the originals
    // route already does in the same situation.
    if (base.isEmpty) {
      return Config.canonicalAssetUrls ? toDirectUrl(resolved) : resolved;
    }
    final encoded = Uri.encodeComponent(resolved);
    return '$base/${size}x$size/$fit/$encoded?quality=$quality';
  }
}
