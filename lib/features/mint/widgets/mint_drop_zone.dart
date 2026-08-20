import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../models/picked_mint_asset.dart';

/// 1:1 media drop zone used in the Upload and Review steps.
///
/// Empty state: shows an upload glyph and "Tap to upload your media"
/// beneath a dashed accent border.
///
/// Populated state: shows the asset preview. Image bytes render via
/// `Image.memory`; non-image assets fall back to a filename chip.
/// When [asset] is null and [existingUrl] is provided (edit mode), the
/// existing IPFS asset is fetched and shown as the placeholder so the
/// user sees what they're editing.
class MintDropZone extends StatelessWidget {
  const MintDropZone({
    required this.onTap,
    super.key,
    this.asset,
    this.existingUrl,
    this.existingKind = ExistingAssetKind.image,
    this.emptyHint = 'Tap to upload your media',
    this.interactive = true,
    this.loading = false,
    this.height,
    this.imageAspectRatio,
    this.imageFit = BoxFit.contain,
    this.imagePadding = const EdgeInsets.all(MallowTheme.spacing20),
  });

  final PickedMintAsset? asset;

  /// IPFS URL of the asset that's already on-chain (edit flow). Rendered
  /// when [asset] is null. Ignored when [asset] is set — the freshly
  /// picked file wins.
  final String? existingUrl;

  /// How to render [existingUrl]. Image URLs render via [MallowNetworkImage];
  /// video URLs render as a labeled placeholder (no network video
  /// playback to keep this widget cheap).
  final ExistingAssetKind existingKind;

  final VoidCallback onTap;
  final String emptyHint;

  /// When false, disables the `GestureDetector` — used on the Review step
  /// where the drop zone becomes a pure preview.
  final bool interactive;

  /// When true, replaces the body with a shimmer placeholder — used in
  /// the edit flow while the prefill is in flight so the user sees the
  /// dropzone hydrating rather than staring at an empty hint.
  final bool loading;

  /// Fixed height override. When null, the drop zone is square (1:1).
  final double? height;

  /// Aspect ratio for the populated image area. When non-null, the picked
  /// image fills an [AspectRatio] of this value (no padding) using [imageFit].
  /// When null, the image is rendered with the default 20px padding.
  final double? imageAspectRatio;

  /// Fit applied to the populated image. Only used when [imageAspectRatio]
  /// is non-null; the default ([BoxFit.contain]) preserves prior behavior.
  final BoxFit imageFit;

  /// Padding around the populated image/existing-asset preview. Defaults to
  /// 20px; callers that want the image to sit closer to the box edges (e.g.
  /// the physical-artwork photo zone) can override it.
  final EdgeInsetsGeometry imagePadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final Widget body;
    if (loading) {
      body = const _LoadingContents();
    } else if (asset != null) {
      body = _PopulatedContents(
        asset: asset!,
        imageAspectRatio: imageAspectRatio,
        imageFit: imageFit,
        imagePadding: imagePadding,
      );
    } else if (existingUrl != null && existingUrl!.isNotEmpty) {
      body = _ExistingAssetContents(
        url: existingUrl!,
        kind: existingKind,
        imageAspectRatio: imageAspectRatio,
        imageFit: imageFit,
        imagePadding: imagePadding,
      );
    } else {
      body = _EmptyContents(hint: emptyHint);
    }
    final inner = CustomPaint(
      // Foreground (not background) so the dashed stroke draws on top of the
      // opaque `surfaceMuted` fill — a background painter is fully covered by
      // the child and only leaks through on sub-pixel edges.
      foregroundPainter: DashedBorderPainter(color: colors.accent),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        child: Container(
          color: colors.surfaceMuted,
          alignment: Alignment.center,
          child: body,
        ),
      ),
    );
    final content = height != null
        ? SizedBox(height: height, width: double.infinity, child: inner)
        : AspectRatio(aspectRatio: 1, child: inner);

    if (!interactive) return content;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

/// Kind of asset behind an existing-URL placeholder, used to pick the
/// right render path (image vs. labeled-video chip).
enum ExistingAssetKind { image, video }

/// Renders an already-uploaded asset by URL — used in the edit flow so
/// the user sees their current image/video without having to re-pick.
/// Tapping the drop zone still fires `onTap`, letting them swap in a
/// fresh file.
class _ExistingAssetContents extends StatelessWidget {
  const _ExistingAssetContents({
    required this.url,
    required this.kind,
    this.imageAspectRatio,
    this.imageFit = BoxFit.contain,
    this.imagePadding = const EdgeInsets.all(MallowTheme.spacing20),
  });

  final String url;
  final ExistingAssetKind kind;
  final double? imageAspectRatio;
  final BoxFit imageFit;
  final EdgeInsetsGeometry imagePadding;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case ExistingAssetKind.image:
        final fit = imageAspectRatio != null ? imageFit : BoxFit.contain;
        // The drop zone is either a full-width square or a fixed-height box,
        // so the rendered size is only known from the incoming constraints —
        // measure it rather than guessing a `logicalSize`.
        final image = LayoutBuilder(
          builder: (context, constraints) {
            final longest = constraints.biggest.longestSide;
            return MallowNetworkImage(
              // RAW url — MallowNetworkImage does the CDN wrapping itself.
              imageUrl: url,
              logicalSize: longest.isFinite && longest > 0
                  ? longest
                  : MediaQuery.sizeOf(context).width,
              fit: fit,
              cdnFit: fit == BoxFit.cover ? 'cover' : 'inside',
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_) => const _ExistingAssetFallback(),
            );
          },
        );
        return Padding(
          padding: imagePadding,
          child: imageAspectRatio != null
              ? AspectRatio(aspectRatio: imageAspectRatio!, child: image)
              : image,
        );
      case ExistingAssetKind.video:
        return Padding(
          padding: const EdgeInsets.all(MallowTheme.spacing20),
          child: _NetworkVideoPreview(key: ValueKey(url), url: url),
        );
    }
  }
}

class _ExistingAssetFallback extends StatelessWidget {
  const _ExistingAssetFallback();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MallowSvgIcon(
          'assets/icons/page.svg',
          width: 32,
          height: 32,
          color: colors.textSecondary,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          'Existing asset',
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          'Tap to replace',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// Shimmer fill rendered inside the dropzone while the edit prefill is
/// loading. Sized to the parent so it inherits the 1:1 (or fixed-height)
/// frame from [MintDropZone].
class _LoadingContents extends StatelessWidget {
  const _LoadingContents();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      child: ShimmerBox(
        width: double.infinity,
        height: double.infinity,
        borderRadius: BorderRadius.circular(MallowTheme.radiusSm),
      ),
    );
  }
}

class _EmptyContents extends StatelessWidget {
  const _EmptyContents({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MallowSvgIcon(
          'assets/icons/upload_square.svg',
          width: 32,
          height: 32,
          color: colors.textSecondary,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          hint,
          style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _PopulatedContents extends StatelessWidget {
  const _PopulatedContents({
    required this.asset,
    this.imageAspectRatio,
    this.imageFit = BoxFit.contain,
    this.imagePadding = const EdgeInsets.all(MallowTheme.spacing20),
  });

  final PickedMintAsset asset;
  final double? imageAspectRatio;
  final BoxFit imageFit;
  final EdgeInsetsGeometry imagePadding;

  @override
  Widget build(BuildContext context) {
    if (asset.isImage) {
      final fit = imageAspectRatio != null ? imageFit : BoxFit.contain;
      final image = asset.isSvg
          ? SvgPicture.memory(
              asset.bytes,
              fit: fit,
              width: double.infinity,
              height: double.infinity,
              placeholderBuilder: (_) => _FileChip(asset: asset),
            )
          // Picked bytes decode at full native resolution unless capped — a
          // 48 MP camera still is ~50 MB of RGBA held for the life of the
          // preview. The drop zone is either a full-width square or a
          // fixed-height box, so measure it from the incoming constraints
          // exactly as the existing-asset path above does.
          : LayoutBuilder(
              builder: (context, constraints) {
                final longest = constraints.biggest.longestSide;
                final logicalWidth = longest.isFinite && longest > 0
                    ? longest
                    : MediaQuery.sizeOf(context).width;
                return Image.memory(
                  asset.bytes,
                  fit: fit,
                  width: double.infinity,
                  height: double.infinity,
                  // Width only: `cacheHeight` too would resize to exact dims
                  // and squash the aspect ratio, changing how `fit` crops.
                  cacheWidth:
                      (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(1, 4096),
                  gaplessPlayback: true,
                  // Not every mintable still has a Flutter decoder — AVIF and
                  // APNG in particular depend on the engine build. The file is
                  // valid and uploads fine, so degrade to the filename chip
                  // instead of the framework's grey error box.
                  errorBuilder: (_, _, _) => _FileChip(asset: asset),
                );
              },
            );
      return Padding(
        padding: imagePadding,
        child: imageAspectRatio != null
            ? AspectRatio(aspectRatio: imageAspectRatio!, child: image)
            : image,
      );
    }
    if (asset.isVideo) {
      return Padding(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: _VideoPreview(
          key: ValueKey('${asset.fileName}:${asset.sizeBytes}'),
          asset: asset,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      child: _FileChip(asset: asset),
    );
  }
}

/// Name + mime placeholder for an asset the drop zone can't render inline —
/// a `.glb`, `.html` or `.pdf` main artwork, or a still whose format the
/// engine has no decoder for.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.asset});

  final PickedMintAsset asset;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MallowSvgIcon(
          'assets/icons/page.svg',
          width: 32,
          height: 32,
          color: colors.textSecondary,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          asset.fileName,
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          asset.mimeType,
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// Autoplay, muted, looping preview of a user-picked video.
///
/// The file picker gives us bytes, but [VideoPlayerController.file] needs a
/// path — so we stage the bytes in the temp dir, initialize the controller,
/// and clean both up on dispose.
class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.asset, super.key});

  final PickedMintAsset asset;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  File? _tempFile;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = await getTemporaryDirectory();
      final safeName = widget.asset.fileName.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final file = File(
        '${dir.path}/mint_video_preview_'
        '${DateTime.now().microsecondsSinceEpoch}_$safeName',
      );
      await file.writeAsBytes(widget.asset.bytes, flush: true);
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        await _safeDelete(file);
        return;
      }
      // Reduce Motion holds the first frame instead of auto-looping.
      final reduceMotion = context.reduceMotion;
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!reduceMotion) await controller.play();
      setState(() {
        _controller = controller;
        _tempFile = file;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup; OS will reclaim the temp file eventually.
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    final file = _tempFile;
    _controller = null;
    _tempFile = null;
    controller?.dispose();
    if (file != null) _safeDelete(file);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed) return _VideoFallback(asset: widget.asset);
    if (controller == null || !controller.value.isInitialized) {
      final colors = context.mallowColors;
      return Center(child: MallowLoader(size: 24, color: colors.textSecondary));
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}

/// Autoplay, muted, looping preview of a network-hosted video — used in
/// the edit flow to show the existing process-video or video main asset
/// without first downloading it for the file picker.
class _NetworkVideoPreview extends StatefulWidget {
  const _NetworkVideoPreview({required this.url, super.key});

  final String url;

  @override
  State<_NetworkVideoPreview> createState() => _NetworkVideoPreviewState();
}

class _NetworkVideoPreviewState extends State<_NetworkVideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // Reduce Motion holds the first frame instead of auto-looping.
      final reduceMotion = context.reduceMotion;
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!reduceMotion) await controller.play();
      setState(() => _controller = controller);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed) return const _NetworkVideoFallback();
    if (controller == null || !controller.value.isInitialized) {
      final colors = context.mallowColors;
      return Center(child: MallowLoader(size: 24, color: colors.textSecondary));
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}

class _NetworkVideoFallback extends StatelessWidget {
  const _NetworkVideoFallback();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MallowSvgIcon(
          'assets/icons/video.svg',
          width: 32,
          height: 32,
          color: colors.textSecondary,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          'Existing video',
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          'Tap to replace',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _VideoFallback extends StatelessWidget {
  const _VideoFallback({required this.asset});

  final PickedMintAsset asset;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MallowSvgIcon(
          'assets/icons/video.svg',
          width: 32,
          height: 32,
          color: colors.textSecondary,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        Text(
          asset.fileName,
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
      ],
    );
  }
}

/// Paints a dashed rounded rectangle around the child. Used by
/// [MintDropZone] and anywhere else we need a dashed border in the mint
/// flow (the review preview reuses it).
class DashedBorderPainter extends CustomPainter {
  DashedBorderPainter({
    required this.color,
    this.strokeWidth = 1,
    this.dashLength = 6,
    this.gapLength = 4,
    this.radius = 4,
  });

  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;

    // Inset by half the stroke so the entire stroke stays within the widget
    // bounds — otherwise the half-pixel overflow is clipped by scrolling
    // ancestors (e.g. the review step's ListView).
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final path = Path()..addRRect(rrect);

    _drawDashedPath(canvas, path, paint);
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      final totalLength = metric.length;
      while (distance < totalLength) {
        final end = (distance + dashLength).clamp(0, totalLength);
        final segment = metric.extractPath(distance, end.toDouble());
        canvas.drawPath(segment, paint);
        distance = end + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.gapLength != gapLength ||
        oldDelegate.radius != radius;
  }
}
