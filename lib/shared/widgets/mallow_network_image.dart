import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/observability/app_logger.dart';
import '../../core/utils/image_fallback.dart';
import '../../core/utils/mallow_image.dart';
import '../theme/mallow_theme.dart';
import 'loading_indicator.dart';
import 'mallow_image_cache_manager.dart';
import 'mallow_svg_icon.dart';

/// Cached network image with a hard decode-size cap.
///
/// The single image widget for the app — use this in place of
/// [CachedNetworkImage] or [Image.network] for any non-decorative remote
/// image. The artwork detail screen is the only intentional exception
/// (it serves a deliberately large 800-bucket image).
///
/// Two layers of memory protection:
///   1. Routes the URL through [MallowImage.cdnUrl] so the CDN serves the
///      smallest bucket that covers [logicalSize] at the screen's real pixel
///      density. Works for artwork, avatars, token logos, banners — anything;
///      the CDN proxies arbitrary upstream URLs.
///   2. Sets `memCacheWidth` from `logicalSize × devicePixelRatio` so Flutter
///      decodes at the rendered size — a 4000×4000 NFT no longer occupies
///      ~64 MB of RGBA memory for a 60×60 thumbnail.
///
/// `memCacheHeight` is intentionally omitted so the original aspect ratio is
/// preserved (important for masonry / variable-height layouts). For square
/// tiles, a square [logicalSize] plus [BoxFit.cover] is enough.
///
/// Use [cdnFit] = `'inside'` for layouts that show the native aspect ratio
/// (e.g. masonry, the artwork detail page); the default `'cover'` is correct
/// for fixed squares and rectangles.
///
/// For circular avatars, pass `borderRadius: BorderRadius.circular(size / 2)`.
///
/// When the CDN itself fails, the image retries once against the asset's own
/// gateway — but only after [ImageFallback.directUrlFor] confirms the failure
/// was the service and not a takedown. See that helper for the verdict table.
class MallowNetworkImage extends StatefulWidget {
  const MallowNetworkImage({
    required this.imageUrl,
    required this.logicalSize,
    super.key,
    this.fit = BoxFit.cover,
    this.cdnFit = 'cover',
    this.cdnUrlOverride,
    this.width,
    this.height,
    this.borderRadius,
    this.errorIconSize = 24,
    this.placeholderBuilder,
    this.errorBuilder,
    this.semanticLabel,
  });

  final String imageUrl;

  /// Largest rendered logical dimension in dp. Drives both the CDN bucket
  /// and the in-memory decode cap.
  final double logicalSize;

  final BoxFit fit;
  final String cdnFit;

  /// Pre-resolved CDN URL to fetch verbatim, bypassing [MallowImage.cdnUrl]
  /// bucket selection (and so [cdnFit]). [logicalSize] still drives the decode
  /// cap. Set by callers that must reuse a specific already-cached bucket (e.g.
  /// [ArtworkSheetImage]); leave null for normal automatic sizing. An empty
  /// string is treated as unset.
  final String? cdnUrlOverride;

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final double errorIconSize;

  /// Optional override for the placeholder shown while loading. When null,
  /// renders a divider-coloured box at [width] × [height].
  final WidgetBuilder? placeholderBuilder;

  /// Optional override for the error widget. When null, renders a
  /// divider-coloured box with an `image_not_supported` icon.
  final WidgetBuilder? errorBuilder;

  /// Screen-reader description of the image. When null the image is treated as
  /// decorative and excluded from the semantics tree (VoiceOver skips it);
  /// pass a label for meaningful images (e.g. an NFT title or avatar owner).
  final String? semanticLabel;

  @override
  State<MallowNetworkImage> createState() => _MallowNetworkImageState();
}

class _MallowNetworkImageState extends State<MallowNetworkImage> {
  static const String _tag = 'MallowNetworkImage';

  /// The asset's own gateway URL, swapped in after the CDN URL failed AND the
  /// HEAD probe cleared the retry. Null while the CDN URL is in play.
  String? _fallbackUrl;

  /// True once the probe has run for the current asset. Set *before* the probe
  /// resolves so a rebuild storm can't fire several, and left set afterwards so
  /// a failure on the fallback URL falls through to the error widget rather than
  /// looping — decision 26's "exactly once, then placeholder".
  bool _fallbackAttempted = false;

  @override
  void didUpdateWidget(MallowNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.cdnUrlOverride != widget.cdnUrlOverride) {
      _fallbackUrl = null;
      _fallbackAttempted = false;
    }
  }

  Future<void> _tryFallback(String failedUrl) async {
    if (_fallbackAttempted) return;
    _fallbackAttempted = true;
    final direct = await ImageFallback.directUrlFor(
      widget.imageUrl,
      failedUrl: failedUrl,
    );
    // A 4xx verdict (or a healthy CDN) returns null — keep the error widget.
    if (direct == null) {
      AppLogger.debug(_tag, 'giving up on ${widget.imageUrl} → placeholder');
      return;
    }
    if (!mounted) return;
    setState(() => _fallbackUrl = direct);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cap = (widget.logicalSize * dpr).ceil().clamp(1, 4096);
    final override = widget.cdnUrlOverride;
    final cdnUrl = (override != null && override.isNotEmpty)
        ? override
        : MallowImage.cdnUrl(
            widget.imageUrl,
            logicalPx: widget.logicalSize,
            dpr: dpr,
            fit: widget.cdnFit,
          );
    final url = _fallbackUrl ?? cdnUrl;

    Widget image = CachedNetworkImage(
      imageUrl: url,
      cacheManager: MallowImageCacheManager.instance,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheWidth: cap,
      // CachedNetworkImage's 500 ms default fade makes a freshly-loaded tile
      // feel slow to appear even once its bytes have landed; a short fade keeps
      // the pop-in snappy without a hard cut.
      fadeInDuration: const Duration(milliseconds: 100),
      fadeOutDuration: const Duration(milliseconds: 100),
      placeholder: (ctx, _) =>
          widget.placeholderBuilder?.call(ctx) ?? _defaultPlaceholder(ctx),
      errorWidget: (ctx, failedUrl, error) {
        // Which attempt failed matters more than the error text: a CDN failure
        // is about to be probed and retried, a fallback failure is terminal.
        // The Android ImageDecoder also throws "unimplemented" deep in the
        // engine with no URL attached, so the URLs are logged explicitly.
        AppLogger.debug(
          _tag,
          '${_fallbackUrl == null ? 'cdn' : 'fallback'} attempt failed\n'
          '  source: ${widget.imageUrl}\n'
          '  requested: $failedUrl\n'
          '  error: $error',
        );
        // Ask the CDN what went wrong; if it's the service (unreachable/5xx)
        // this swaps in the asset's own gateway and the image reloads. The
        // error widget below is what the user sees meanwhile, and permanently
        // if the fallback is refused or itself fails.
        _tryFallback(failedUrl);
        return widget.errorBuilder?.call(ctx) ?? _defaultError(ctx);
      },
    );

    if (widget.borderRadius != null) {
      image = ClipRRect(borderRadius: widget.borderRadius!, child: image);
    }

    // CachedNetworkImage exposes no semantic hooks, so annotate here: label it
    // as an image for screen readers, or exclude it entirely when decorative.
    return widget.semanticLabel != null
        ? Semantics(image: true, label: widget.semanticLabel, child: image)
        : ExcludeSemantics(child: image);
  }

  Widget _defaultPlaceholder(BuildContext context) {
    return ImageShimmerGrid(width: widget.width, height: widget.height);
  }

  Widget _defaultError(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: context.mallowColors.divider,
      alignment: Alignment.center,
      child: MallowSvgIcon(
        'assets/icons/image_off.svg',
        width: widget.errorIconSize,
        height: widget.errorIconSize,
        color: context.mallowColors.textTertiary,
      ),
    );
  }
}
