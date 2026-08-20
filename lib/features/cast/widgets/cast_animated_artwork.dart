import 'package:chewie/chewie.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../models/cast_media_type.dart';
import '../models/cast_queue.dart';

/// Displays a [CastQueueItem]'s media content, handling static images,
/// animated GIF/WebP, and video with a unified API.
///
/// - Static images and animated GIF/WebP are rendered via [ExtendedImage].
/// - Videos are rendered via [Chewie] (wraps [VideoPlayerController]).
///
/// Every mode paints the CDN poster first and upgrades in place — see
/// [CastProgressiveArtwork]. Resolves the [CastMediaType] asynchronously when
/// [item.mediaType] is [CastMediaType.unknown], using [ArtworkMediaResolver];
/// the poster is already on screen while that resolves.
class CastAnimatedArtwork extends StatefulWidget {
  const CastAnimatedArtwork({
    required this.item,
    this.fit = BoxFit.cover,
    super.key,
  });

  final CastQueueItem item;
  final BoxFit fit;

  @override
  State<CastAnimatedArtwork> createState() => _CastAnimatedArtworkState();
}

class _CastAnimatedArtworkState extends State<CastAnimatedArtwork> {
  CastMediaType? _resolvedType;
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _videoInitialized = false;

  @override
  void initState() {
    super.initState();
    _resolveMediaType();
  }

  @override
  void didUpdateWidget(CastAnimatedArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.mintAccount != widget.item.mintAccount) {
      _disposeVideo();
      _resolvedType = null;
      _videoInitialized = false;
      _resolveMediaType();
    }
  }

  Future<void> _resolveMediaType() async {
    final knownType = widget.item.mediaType;
    if (knownType != CastMediaType.unknown) {
      if (!mounted) return;
      setState(() => _resolvedType = knownType);
      if (knownType == CastMediaType.video) _initVideo().ignore();
      return;
    }

    final resolved = await ArtworkMediaResolver.resolveAsync(
      imageUrl: widget.item.imageUrl,
      animationUrl: widget.item.animationUrl,
    );
    if (!mounted) return;
    setState(() => _resolvedType = resolved);
    if (resolved == CastMediaType.video) _initVideo().ignore();
  }

  Future<void> _initVideo() async {
    // The `/original/` route rather than the raw source: `video_player` cannot
    // open an `ipfs://` URI, and the R2-cached original beats the gateways.
    final url = ArtworkMediaResolver.originalCastUrl(
      imageUrl: widget.item.imageUrl,
      mediaType: CastMediaType.video,
      animationUrl: widget.item.animationUrl,
    );
    if (url.isEmpty) return;

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
    await _videoController!.initialize();

    if (!mounted) {
      _disposeVideo();
      return;
    }

    // Reduce Motion freezes the artwork on its first frame instead of looping.
    final autoPlay = !context.reduceMotion;
    _chewieController = ChewieController(
      videoPlayerController: _videoController!,
      autoPlay: autoPlay,
      looping: true,
      showControls: false,
      aspectRatio: _videoController!.value.aspectRatio,
    );

    setState(() => _videoInitialized = true);
  }

  void _disposeVideo() {
    _chewieController?.dispose();
    _videoController?.dispose();
    _chewieController = null;
    _videoController = null;
    _videoInitialized = false;
  }

  @override
  void dispose() {
    _disposeVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = _resolvedType;

    // Video is the one mode whose upgrade is not an image: the poster carries
    // the screen while the player buffers, then Chewie fades in over it.
    if (type == CastMediaType.video) {
      return CastProgressiveArtwork(
        imageUrl: widget.item.imageUrl,
        fit: widget.fit,
        upgrade: _videoInitialized && _chewieController != null
            ? Chewie(controller: _chewieController!)
            : null,
      );
    }

    // `null` (type still resolving) renders the poster with no upgrade layer;
    // the resolve completes long before a multi-megabyte original would have,
    // and rebuilding with the real type just adds the upgrade underneath.
    return CastProgressiveArtwork(
      imageUrl: widget.item.imageUrl,
      fit: widget.fit,
      fullUrl: type == null
          ? null
          : ArtworkMediaResolver.originalCastUrl(
              imageUrl: widget.item.imageUrl,
              mediaType: type,
              animationUrl: widget.item.animationUrl,
            ),
    );
  }
}

/// Two-phase artwork renderer shared by every receiver surface.
///
/// Paints `ArtworkMediaResolver.posterUrl(imageUrl)` — a small, CDN-warm,
/// scheme-resolved bucket that is usually already cached — as soon as it
/// decodes, then cross-fades the full-resolution original (or [upgrade], for
/// video) over it when *that* finishes downloading. The shimmer therefore only
/// ever covers the poster fetch, never the multi-megabyte original.
///
/// A failure on either layer is silent and non-blocking: a failed poster
/// leaves the blurred background until the original lands, and a failed
/// original leaves the poster as the final frame. Neither strands the shimmer
/// on screen — a receiver stuck shimmering forever is the exact regression
/// this widget replaced.
class CastProgressiveArtwork extends StatelessWidget {
  const CastProgressiveArtwork({
    required this.imageUrl,
    required this.fit,
    this.fullUrl,
    this.upgrade,
    super.key,
  });

  /// Raw source URL, resolved to a poster internally.
  final String imageUrl;

  final BoxFit fit;

  /// Resolved full-resolution URL to layer over the poster. Null/empty leaves
  /// the poster as the final frame. Ignored when [upgrade] is set.
  final String? fullUrl;

  /// Non-image upgrade layer (the video player). Takes precedence over
  /// [fullUrl]; null while the player is still initialising.
  final Widget? upgrade;

  /// Decode-width cap for the full-resolution layer, matching the artwork
  /// detail screen's cap. Bounds a 4000×4000 original to ~16 MB of RGBA
  /// instead of ~64 MB — the AirPlay receiver runs in a secondary engine that
  /// cannot afford the latter.
  static const int _fullResMaxDecodeWidth = 2048;

  @override
  Widget build(BuildContext context) {
    final full = fullUrl;
    final hasUpgrade = upgrade != null || (full != null && full.isNotEmpty);

    // A video-only or animation-only NFT carries no still image, so an empty
    // poster is not the same as nothing to draw — bailing to the shimmer here
    // strands the receiver on it forever with the player already initialised.
    if (imageUrl.isEmpty && !hasUpgrade) return const CastShimmerSurface();

    return Stack(
      fit: StackFit.expand,
      children: [
        if (imageUrl.isNotEmpty)
          _CastImageLayer(
            url: ArtworkMediaResolver.posterUrl(imageUrl),
            fit: fit,
            whileLoading: const CastShimmerSurface(),
          )
        else
          // No poster to cover the upgrade's fetch; the shimmer is the base
          // layer instead, and the upgrade fades in over it.
          const CastShimmerSurface(),
        if (upgrade != null)
          _FadeInOnce(child: upgrade!)
        else if (full != null && full.isNotEmpty)
          _CastImageLayer(
            url: full,
            fit: fit,
            cacheWidth: _fullResMaxDecodeWidth,
            fadeIn: true,
          ),
      ],
    );
  }
}

/// One [ExtendedImage] layer of [CastProgressiveArtwork].
class _CastImageLayer extends StatelessWidget {
  const _CastImageLayer({
    required this.url,
    required this.fit,
    this.cacheWidth,
    this.fadeIn = false,
    this.whileLoading = const SizedBox.shrink(),
  });

  final String url;
  final BoxFit fit;
  final int? cacheWidth;
  final bool fadeIn;
  final Widget whileLoading;

  @override
  Widget build(BuildContext context) {
    return ExtendedImage.network(
      url,
      fit: fit,
      cacheWidth: cacheWidth,
      loadStateChanged: (state) => switch (state.extendedImageLoadState) {
        LoadState.loading => whileLoading,
        // Transparent, never the shimmer: this layer is stacked, so whatever
        // is behind it (the poster, or the blurred background) is the answer.
        LoadState.failed => const SizedBox.shrink(),
        LoadState.completed =>
          fadeIn ? _FadeInOnce(child: state.completedWidget) : null,
      },
    );
  }
}

/// Fades its child in once, on first build, so the full-resolution original
/// sharpens in over the poster rather than hard-cutting.
class _FadeInOnce extends StatefulWidget {
  const _FadeInOnce({required this.child});

  final Widget child;

  @override
  State<_FadeInOnce> createState() => _FadeInOnceState();
}

class _FadeInOnceState extends State<_FadeInOnce> {
  static const _duration = Duration(milliseconds: 250);

  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Post-frame rather than a synchronous flip: the child is built with
    // opacity 0 first so the tween has a frame to animate from.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: _duration,
      child: widget.child,
    );
  }
}

/// Ripple-grid shimmer used as the loading placeholder for cast art. Full-size
/// so it slots cleanly into Stack / Expanded contexts in the receiver view.
/// Forces a dark theme locally because the cast surface is always black,
/// regardless of the host app's theme.
class CastShimmerSurface extends StatelessWidget {
  const CastShimmerSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(data: ThemeData.dark(), child: const ImageShimmerGrid());
  }
}
