import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_network_image.dart';
import 'mallow_svg_icon.dart';

/// A cached artwork thumbnail with loading/error states.
///
/// Uses cached_network_image for efficient image loading and caching.
/// Supports custom aspect ratios and placeholder behavior.
class ArtworkThumbnail extends StatelessWidget {
  const ArtworkThumbnail({
    required this.imageUrl,
    super.key,
    this.size,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.onTap,
  }) : assert(
         size != null || (width != null && height != null),
         'Either size or both width and height must be provided',
       );

  /// URL of the artwork image
  final String imageUrl;

  /// Square size (use for square thumbnails)
  final double? size;

  /// Width (use with height for non-square thumbnails)
  final double? width;

  /// Height (use with width for non-square thumbnails)
  final double? height;

  /// Border radius for rounded corners
  final BorderRadius? borderRadius;

  /// How the image should fit within its bounds
  final BoxFit fit;

  /// Optional tap callback
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final double effectiveWidth = size ?? width!;
    final double effectiveHeight = size ?? height!;
    final BorderRadius effectiveRadius =
        borderRadius ?? BorderRadius.circular(MallowTheme.radiusSm);

    final Widget image = MallowNetworkImage(
      imageUrl: imageUrl,
      logicalSize: effectiveWidth > effectiveHeight
          ? effectiveWidth
          : effectiveHeight,
      width: effectiveWidth,
      height: effectiveHeight,
      fit: fit,
      borderRadius: effectiveRadius,
      errorBuilder: (ctx) => _buildError(ctx, effectiveWidth, effectiveHeight),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: image);
    }

    return image;
  }

  Widget _buildError(BuildContext context, double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.mallowColors.divider,
        borderRadius:
            borderRadius ?? BorderRadius.circular(MallowTheme.radiusSm),
      ),
      child: Center(
        child: MallowSvgIcon(
          'assets/icons/image_off.svg',
          width: 24,
          height: 24,
          color: context.mallowColors.textTertiary,
        ),
      ),
    );
  }
}

/// A 2x2 mosaic grid for collection/curation previews.
///
/// Displays up to 4 images in a grid layout, commonly used
/// for collection thumbnails in the home screen.
class ArtworkMosaic extends StatelessWidget {
  const ArtworkMosaic({
    required this.imageUrls,
    super.key,
    this.size = 139.6,
    this.gap = 0,
    this.borderRadius,
    this.onTap,
  });

  /// URLs of the artwork images (up to 4)
  final List<String> imageUrls;

  /// Total size of the mosaic (square)
  final double size;

  /// Gap between images (default 0 for Figma design)
  final double gap;

  /// Border radius for the outer container
  final BorderRadius? borderRadius;

  /// Optional tap callback
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final BorderRadius effectiveRadius =
        borderRadius ?? BorderRadius.circular(MallowTheme.radiusPrimary);

    // If only one image, show it full size
    if (imageUrls.length == 1 && imageUrls.first.isNotEmpty) {
      final Widget singleImage = MallowNetworkImage(
        imageUrl: imageUrls.first,
        logicalSize: size,
        width: size,
        height: size,
        borderRadius: effectiveRadius,
      );

      if (onTap != null) {
        return GestureDetector(onTap: onTap, child: singleImage);
      }
      return singleImage;
    }

    // Original mosaic logic for multiple images continues below...
    final double cellSize = (size - gap) / 2;

    // Ensure we have exactly 4 URLs (pad with empty strings if needed)
    final List<String> urls = List<String>.from(imageUrls);
    while (urls.length < 4) {
      urls.add('');
    }

    final Widget mosaic = ClipRRect(
      borderRadius: effectiveRadius,
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Row(
              children: [
                _buildCell(context, urls[0], cellSize),
                if (gap > 0) SizedBox(width: gap),
                _buildCell(context, urls[1], cellSize),
              ],
            ),
            if (gap > 0) SizedBox(height: gap),
            Row(
              children: [
                _buildCell(context, urls[2], cellSize),
                if (gap > 0) SizedBox(width: gap),
                _buildCell(context, urls[3], cellSize),
              ],
            ),
          ],
        ),
      ),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: mosaic);
    }

    return mosaic;
  }

  Widget _buildCell(BuildContext context, String url, double cellSize) {
    if (url.isEmpty) {
      return Container(
        width: cellSize,
        height: cellSize,
        color: context.mallowColors.divider,
      );
    }

    return MallowNetworkImage(
      imageUrl: url,
      logicalSize: cellSize,
      width: cellSize,
      height: cellSize,
      errorIconSize: 16,
    );
  }
}
