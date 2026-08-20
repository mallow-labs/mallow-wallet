import 'dart:io' show Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Shared [CacheManager] for every remote image in the app.
///
/// Exists instead of [DefaultCacheManager] for two reasons:
///
///   1. **HTTP/2 transport.** The default cache manager fetches over dart:io's
///      HTTP/1.1 client — one connection per host, with the download queue
///      capped at 10 — so a screen full of NFT tiles drains in serialized
///      waves. Routing through the platform networking stack (NSURLSession on
///      iOS, Cronet on Android) gives HTTP/2 multiplexing: dozens of tiles
///      stream in parallel over a single connection to the image CDN,
///      matching the webapp's native `<img>` behaviour. [_concurrentFetches]
///      is raised to let the queue actually feed that connection.
///
///   2. **Bigger disk cache.** [_maxCacheObjects] (default is 200) keeps more
///      buckets on disk so scroll-back on a large portfolio hits the disk
///      instead of re-fetching over the network.
///
/// Every image surface — [MallowNetworkImage] and the [ArtworkSheetImage] cache
/// probe — MUST use this one instance so a file warmed by one is visible to the
/// others.
class MallowImageCacheManager {
  MallowImageCacheManager._();

  static const _key = 'mallowImageCache';

  /// Parallel downloads the cache-manager queue will start. Well above the
  /// default 10 because HTTP/2 multiplexes them cheaply over one connection.
  static const _concurrentFetches = 32;

  /// Disk-cache object budget (default is 200). Eviction stays LRU past this.
  static const _maxCacheObjects = 1000;

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      maxNrOfCacheObjects: _maxCacheObjects,
      stalePeriod: const Duration(days: 30),
      fileService: HttpFileService(httpClient: _client())
        ..concurrentFetches = _concurrentFetches,
    ),
  );

  /// Platform-native HTTP/2 client. Falls back to the dart:io client on
  /// platforms without a native adapter — and if native init ever throws, so a
  /// networking-stack quirk degrades to HTTP/1.1 rather than breaking images.
  static http.Client _client() {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        // Ephemeral: NSURLSession keeps no on-disk cache of its own (that is
        // flutter_cache_manager's job), while still reusing the HTTP/2
        // connection for the session's lifetime.
        return CupertinoClient.fromSessionConfiguration(
          URLSessionConfiguration.ephemeralSessionConfiguration(),
        );
      }
      if (Platform.isAndroid) {
        // Cronet handles the disk cache; disable its own so the bytes aren't
        // stored twice. HTTP/2 is on by default but set explicitly.
        //
        // Brotli is intentionally NOT enabled: advertising `Accept-Encoding: br`
        // lets the CDN return brotli-encoded image bodies, which land on disk
        // still compressed and fail to decode ("Invalid image data" /
        // ImageDecoder "unimplemented"). Gzip (on by default) covers text
        // assets; raster formats gain ~nothing from brotli anyway.
        final engine = CronetEngine.build(
          cacheMode: CacheMode.disabled,
          enableHttp2: true,
        );
        return CronetClient.fromCronetEngine(engine, closeEngine: true);
      }
    } catch (e, s) {
      debugPrint('[MallowImageCacheManager] native client init failed: $e\n$s');
    }
    return IOClient();
  }
}
