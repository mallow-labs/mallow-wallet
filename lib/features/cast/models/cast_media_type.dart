import 'dart:io';

import '../../../core/config/environment.dart';
import '../../../core/utils/mallow_image.dart';

/// The media type of a castable artwork.
enum CastMediaType {
  /// Static image (JPEG, PNG, etc.)
  staticImage,

  /// Animated GIF or WebP
  animated,

  /// Video (MP4, MOV, WebM)
  video,

  /// Type not yet determined
  unknown,
}

/// Resolves the [CastMediaType] for an artwork URL.
///
/// Uses a two-tier strategy:
///   1. URL extension heuristic (synchronous, no network).
///   2. HTTP HEAD probe with Content-Type header (async, cached) for URLs
///      where the extension is absent or ambiguous (e.g. IPFS CIDs).
class ArtworkMediaResolver {
  ArtworkMediaResolver._();

  /// Origin of the image CDN whose resize prefix [_stripCdn] removes. Empty
  /// when this build has no CDN, which makes the strip a no-op — nothing was
  /// rewritten, so there is nothing to undo.
  static String get _cdnBase => Config.imageCdnBaseUrl;

  static const _videoExtensions = {'mp4', 'mov', 'webm', 'm4v', 'ogv', 'avi'};
  static const _animatedExtensions = {'gif', 'webp'};

  /// In-memory cache: URL → resolved type. Populated by [resolveAsync].
  static final Map<String, CastMediaType> _cache = {};

  /// Synchronously classify a URL by its file extension.
  ///
  /// Prefers [animationUrl] over [imageUrl]. Strips the image-CDN prefix
  /// from [imageUrl] before inspecting the extension, since CDN-resized URLs
  /// lose the original extension.
  ///
  /// Returns [CastMediaType.unknown] when the extension is absent or
  /// unrecognised — call [resolveAsync] to probe via HTTP HEAD in that case.
  static CastMediaType resolveSync({
    required String imageUrl,
    String? animationUrl,
  }) {
    // Prefer animationUrl — it's the original media file.
    if (animationUrl != null && animationUrl.isNotEmpty) {
      final type = _classifyByExtension(animationUrl);
      if (type != CastMediaType.unknown) return type;
    }

    // Strip CDN prefix to recover the original URL before extension check.
    final rawImageUrl = _stripCdn(imageUrl);
    return _classifyByExtension(rawImageUrl);
  }

  /// Asynchronously resolve the media type by firing an HTTP HEAD request.
  ///
  /// Results are cached in [_cache]. If the type is already cached, returns
  /// immediately without a network call. Falls back to [resolveSync] first and
  /// only performs the HEAD probe when that returns [CastMediaType.unknown].
  static Future<CastMediaType> resolveAsync({
    required String imageUrl,
    String? animationUrl,
  }) async {
    // Sync fast-path.
    final quick = resolveSync(imageUrl: imageUrl, animationUrl: animationUrl);
    if (quick != CastMediaType.unknown) return quick;

    // Prefer animationUrl for the probe; fall back to imageUrl.
    final probeUrl = (animationUrl != null && animationUrl.isNotEmpty)
        ? animationUrl
        : imageUrl;

    if (probeUrl.isEmpty) return CastMediaType.staticImage;

    if (_cache.containsKey(probeUrl)) return _cache[probeUrl]!;

    try {
      final client = HttpClient();
      final request = await client.headUrl(Uri.parse(probeUrl));
      final response = await request.close();
      final contentType = response.headers.contentType?.mimeType ?? '';
      client.close();

      final result = _classifyByMimeType(contentType);
      _cache[probeUrl] = result;
      return result;
    } catch (_) {
      _cache[probeUrl] = CastMediaType.staticImage;
      return CastMediaType.staticImage;
    }
  }

  /// Returns the artwork's own source URL for [mediaType] — [animationUrl] for
  /// video/animated (it is the original media file), [imageUrl] otherwise.
  ///
  /// This is the **raw** URL as the API returned it, which is frequently an
  /// `ipfs://` / `ar://` URI. Nothing can fetch that directly: pass the result
  /// through [posterUrl] or [originalCastUrl] before handing it to an image
  /// widget, a `<img src>`, or a video player.
  static String bestCastUrl({
    required String imageUrl,
    CastMediaType mediaType = CastMediaType.staticImage,
    String? animationUrl,
  }) {
    if (mediaType != CastMediaType.staticImage &&
        animationUrl != null &&
        animationUrl.isNotEmpty) {
      return animationUrl;
    }
    return imageUrl;
  }

  /// CDN bucket used for the receiver poster. The largest warm bucket, so it
  /// stands on its own on a 4K panel if the original never arrives.
  static const int posterCdnSize = 800;

  /// The instantly-loadable poster for [imageUrl] — the largest warm CDN
  /// bucket, `fit: 'inside'` so the receiver's own `BoxFit` does the cropping.
  ///
  /// This is the first thing every receiver paints. It resolves the raw
  /// `ipfs://` / `ar://` sources the API returns (which no receiver can fetch
  /// itself), and it is a few hundred KB rather than the multi-megabyte
  /// original. The size/fit/quality triple deliberately matches
  /// `ArtworkSheetImage`'s so both hit the same warm Cloudflare edge object —
  /// the local disk caches are separate (`extended_image` keeps its own, apart
  /// from `MallowImageCacheManager`), so the edge hit is the whole win.
  static String posterUrl(String imageUrl) {
    if (imageUrl.isEmpty) return imageUrl;
    return MallowImage.cdnUrlForSize(
      imageUrl,
      cdnSize: posterCdnSize,
      fit: 'inside',
      quality: 100,
    );
  }

  /// The full-resolution source the receiver upgrades to once it has finished
  /// downloading, layered over [posterUrl].
  ///
  /// Always the images service's `/original/` route: it resolves `ipfs://` /
  /// `ar://` the same way [posterUrl] does and serves mint-time bytes from R2
  /// ahead of the public gateways. Empty when there is nothing to upgrade to,
  /// in which case the poster is the final frame.
  static String originalCastUrl({
    required String imageUrl,
    CastMediaType mediaType = CastMediaType.staticImage,
    String? animationUrl,
  }) {
    final source = bestCastUrl(
      imageUrl: imageUrl,
      mediaType: mediaType,
      animationUrl: animationUrl,
    );
    return MallowImage.originalUrl(source);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static CastMediaType _classifyByExtension(String url) {
    if (url.isEmpty) return CastMediaType.unknown;

    // Strip query string and fragment before extracting extension.
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return CastMediaType.unknown;

    final ext = path.substring(dot + 1).toLowerCase();
    if (_videoExtensions.contains(ext)) return CastMediaType.video;
    if (_animatedExtensions.contains(ext)) return CastMediaType.animated;

    // Known static extensions.
    const staticExts = {'jpg', 'jpeg', 'png', 'avif', 'svg', 'bmp', 'tiff'};
    if (staticExts.contains(ext)) return CastMediaType.staticImage;

    return CastMediaType.unknown;
  }

  static CastMediaType _classifyByMimeType(String mimeType) {
    if (mimeType.startsWith('video/')) return CastMediaType.video;
    if (mimeType == 'image/gif') return CastMediaType.animated;
    if (mimeType == 'image/webp') return CastMediaType.animated;
    if (mimeType.startsWith('image/')) return CastMediaType.staticImage;
    return CastMediaType.staticImage;
  }

  /// Removes the image-CDN prefix from a URL, returning the original URL.
  static String _stripCdn(String url) {
    final base = _cdnBase;
    if (base.isEmpty || !url.startsWith(base)) return url;
    // CDN URL format: <cdn>/{size}x{size}/{fit}/{encodedUrl}
    final afterBase = url.substring(base.length);
    // afterBase starts with '/{size}x{size}/{fit}/'
    final parts = afterBase.split('/');
    // parts[0] is '', [1] is '{size}x{size}', [2] is fit, [3..] is the encoded URL
    if (parts.length < 4) return url;
    final encoded = parts.sublist(3).join('/').split('?').first;
    return Uri.decodeComponent(encoded);
  }
}
