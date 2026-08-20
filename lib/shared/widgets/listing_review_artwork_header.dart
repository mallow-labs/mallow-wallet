import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/utils/mallow_image.dart';
import '../theme/mallow_theme.dart';
import 'mallow_image_cache_manager.dart';
import 'mallow_network_image.dart';

/// Artwork preview + `TITLE / @artist` headline shared by the auction and
/// fixed-price review steps. Layout per the Figma spec:
///
/// - 185.95 / 104.45 aspect-ratio preview, full-width within the parent's
///   content area, with a `surfaceMuted` fill, 4px corner radius, and 20px
///   padding around the contained image. The image renders at its native
///   aspect with a soft drop shadow (`0 4 24 rgba(102,102,110,0.16)`).
/// - 24px gap, then the headline aligned to the section's left edge — title
///   in [MallowTheme.editorialSubhead], a Geist " / " separator, and the
///   artist label in [MallowTheme.uiCaption] / `textSecondary`. The caller
///   formats the label (e.g. `@username` or a truncated address).
class ListingReviewArtworkHeader extends StatefulWidget {
  const ListingReviewArtworkHeader({
    required this.imageUrl,
    required this.title,
    required this.artistDisplay,
    super.key,
  });

  final String imageUrl;
  final String title;
  final String artistDisplay;

  @override
  State<ListingReviewArtworkHeader> createState() =>
      _ListingReviewArtworkHeaderState();
}

class _ListingReviewArtworkHeaderState
    extends State<ListingReviewArtworkHeader> {
  static const _containerAspect = 185.95 / 104.45;

  /// CDN bucket the aspect probe reads, doubling as its decode cap — the probe
  /// only needs the source's proportions, never its pixels.
  static const int _probeBucket = 600;

  double? _imageAspect;
  ImageStream? _stream;
  late final ImageStreamListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final ratio = info.image.width / info.image.height;
      if (_imageAspect == ratio) return;
      setState(() => _imageAspect = ratio);
    });
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant ListingReviewArtworkHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _imageAspect = null;
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  void _resolveImage() {
    _stream?.removeListener(_listener);
    _stream = null;
    if (widget.imageUrl.isEmpty) return;
    final provider = ResizeImage(
      CachedNetworkImageProvider(
        MallowImage.cdnUrlForSize(
          widget.imageUrl,
          cdnSize: _probeBucket,
          fit: 'inside',
        ),
        cacheManager: MallowImageCacheManager.instance,
      ),
      width: _probeBucket,
    );
    _stream = provider.resolve(const ImageConfiguration())
      ..addListener(_listener);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
          child: AspectRatio(
            aspectRatio: _containerAspect,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(4),
              ),
              child: widget.imageUrl.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.all(MallowTheme.spacing20),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _imageAspect ?? _containerAspect,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Color.fromRGBO(102, 102, 110, 0.16),
                                  offset: Offset(0, 4),
                                  blurRadius: 24,
                                ),
                              ],
                            ),
                            child: MallowNetworkImage(
                              imageUrl: widget.imageUrl,
                              logicalSize:
                                  MediaQuery.sizeOf(context).width -
                                  MallowTheme.spacing20 * 4,
                              cdnFit: 'inside',
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            children: [
              TextSpan(
                text: widget.title,
                style: MallowTheme.editorialSubhead.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              TextSpan(
                text: ' / ',
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
              TextSpan(
                text: widget.artistDisplay,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
