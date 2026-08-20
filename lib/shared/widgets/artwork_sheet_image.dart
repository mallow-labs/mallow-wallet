import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/utils/mallow_image.dart';
import 'loading_indicator.dart';
import 'mallow_artwork_media.dart';
import 'mallow_image_cache_manager.dart';

/// Artwork thumbnail for transaction bottom sheets (buy / claim / offer / bid /
/// transfer / burn confirmations).
///
/// Reuses the exact CDN variant the artwork detail screen already loaded — the
/// 800-bucket `inside` image at quality 100 — whenever it's already on disk, so
/// the sheet paints from cache with no fetch. These sheets almost always open
/// on top of the detail screen, so that variant is usually cached.
///
/// Otherwise it uses the smaller 600-bucket `inside` variant the portfolio /
/// profile grids cache: lighter to download when nothing is cached yet, and
/// itself often already on disk. It probes the cache before the first paint (a
/// quick lookup masked by the sheet's present animation) so the cold path never
/// starts fetching the heavier 800 bucket only to abandon it.
class ArtworkSheetImage extends StatefulWidget {
  const ArtworkSheetImage({
    required this.imageUrl,
    super.key,
    this.height = 144,
    this.borderRadius,
    this.nsfw = false,
    this.errorIconSize = 24,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  final String imageUrl;

  /// The image's vertical cap. It renders at its native aspect ratio up to this
  /// height (and no wider than the available width), centered — so a landscape
  /// artwork extends wider than a portrait one instead of being letterboxed
  /// into a fixed square.
  final double height;

  final BorderRadius? borderRadius;
  final bool nsfw;
  final double errorIconSize;
  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  /// The detail screen's poster URL — must stay in sync with
  /// `artwork_detail_screen/artwork_image.dart` (800 / `inside` / quality 100)
  /// so the two resolve to the same disk-cache entry.
  static String _detailUrl(String raw) =>
      MallowImage.cdnUrlForSize(raw, cdnSize: 800, fit: 'inside', quality: 100);

  /// The grid tiles' URL (portfolio all-art / profile curation masonry), which
  /// render `inside` at the 600 bucket at the default quality. Also the cold
  /// fallback: lighter to download than the 800 bucket for a small thumbnail.
  static String _gridUrl(String raw) =>
      MallowImage.cdnUrlForSize(raw, cdnSize: 600, fit: 'inside');

  @override
  State<ArtworkSheetImage> createState() => _ArtworkSheetImageState();
}

class _ArtworkSheetImageState extends State<ArtworkSheetImage> {
  /// The CDN URL chosen for display; null until the cache probe resolves.
  String? _url;

  /// The artwork's native aspect ratio; null until the image dimensions
  /// resolve. Until then the preview reserves a square [ArtworkSheetImage.height]
  /// box, then settles to the real ratio (width-only, so height stays put).
  double? _aspect;
  ImageStream? _stream;
  late final ImageStreamListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final ratio = info.image.width / info.image.height;
      if (_aspect == ratio) return;
      setState(() => _aspect = ratio);
    });
    _resolve();
  }

  @override
  void didUpdateWidget(ArtworkSheetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _url = null;
      _aspect = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  /// Uses the 800 detail variant only when it's already on disk (the sheet then
  /// reuses the detail poster with no fetch); otherwise the smaller 600 grid
  /// variant, which is lighter to download on a cold miss and itself often
  /// already cached. Probing before the first paint means the cold path never
  /// starts fetching the 800 bucket only to abandon it.
  Future<void> _resolve() async {
    final raw = widget.imageUrl;
    if (raw.isEmpty) return;
    var has800 = false;
    try {
      has800 =
          await MallowImageCacheManager.instance.getFileFromCache(
            ArtworkSheetImage._detailUrl(raw),
          ) !=
          null;
    } catch (_) {
      has800 = false;
    }
    if (!mounted || widget.imageUrl != raw) return;
    final url = has800
        ? ArtworkSheetImage._detailUrl(raw)
        : ArtworkSheetImage._gridUrl(raw);
    setState(() => _url = url);
    _probeAspect(url);
  }

  void _probeAspect(String url) {
    _stream?.removeListener(_listener);
    _stream = CachedNetworkImageProvider(
      url,
      cacheManager: MallowImageCacheManager.instance,
    ).resolve(const ImageConfiguration())..addListener(_listener);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final aspect = _aspect ?? 1;
    // Largest rendered dimension → decode cap. Height for portrait/square,
    // aspect-scaled width for landscape.
    final maxDim = aspect > 1 ? widget.height * aspect : widget.height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.height),
        child: AspectRatio(
          aspectRatio: aspect,
          // An empty URL never resolves — fall through so MallowArtworkMedia
          // renders its error widget instead of a perpetual shimmer.
          child: url == null && widget.imageUrl.isNotEmpty
              ? (widget.placeholderBuilder?.call(context) ??
                    ImageShimmerGrid(borderRadius: widget.borderRadius))
              : MallowArtworkMedia(
                  imageUrl: widget.imageUrl,
                  cdnUrlOverride: url,
                  logicalSize: maxDim,
                  nsfw: widget.nsfw,
                  // Box aspect matches the image once resolved, so `contain`
                  // fills exactly; before then it letterboxes rather than crops.
                  fit: BoxFit.contain,
                  cdnFit: 'inside',
                  borderRadius: widget.borderRadius,
                  errorIconSize: widget.errorIconSize,
                  placeholderBuilder: widget.placeholderBuilder,
                  errorBuilder: widget.errorBuilder,
                ),
        ),
      ),
    );
  }
}
