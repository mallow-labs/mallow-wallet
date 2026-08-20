import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/utils/mux.dart';
import '../../core/utils/reduce_motion.dart';
import 'mallow_network_image.dart';
import 'nsfw_obscured.dart';
import 'video_playback_coordinator.dart';

/// The single artwork-tile widget for the app.
///
/// Drop-in replacement for [MallowNetworkImage] on any surface that shows an
/// NFT thumbnail. When the artwork carries a Mux playback id it streams a
/// muted, looping preview inline (matching the webapp's autoplay cards);
/// otherwise it renders exactly as [MallowNetworkImage] would, preserving the
/// CDN sizing and decode-cap behaviour.
///
/// The still image is always rendered underneath as the poster, so there is no
/// blank frame while the stream loads and no flash when playback is evicted by
/// [VideoPlaybackCoordinator]. Playback is gated on visibility: a tile only
/// plays while it is at least [_playThreshold] visible, and frees its decoder
/// as soon as it scrolls off — keeping a dense grid within the concurrent-player
/// budget.
/// Builds the shared-element ([Hero]) tag for an artwork tile.
///
/// The same artwork can appear on several surfaces of one screen (home
/// sections, search, profile tabs), so [source] disambiguates them and keeps
/// every tag unique per route — a duplicate tag on a single route crashes the
/// Hero flight. Callers that open the detail screen must pass the identical
/// string as the route's `extra` so the detail image registers the matching
/// Hero.
String artworkHeroTag(String source, String mintAccount) =>
    'artwork-$source-$mintAccount';

/// Flight shuttle for the tile → detail artwork Hero.
///
/// The tile renders a small CDN bucket; the detail image renders a much larger
/// one under a different URL, so it is usually still loading during the flight.
/// The default shuttle would show that destination widget — and flash its
/// shimmer placeholder mid-air. Instead, keep the *tile's* already-cached image
/// on screen for the entire flight (the `from` hero on push, the `to` hero on
/// pop — both the tile poster), then let the detail image resolve its bucket
/// after the flight lands.
Widget _artworkHeroFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final heroContext = direction == HeroFlightDirection.push
      ? fromHeroContext
      : toHeroContext;
  return (heroContext.widget as Hero).child;
}

class MallowArtworkMedia extends StatelessWidget {
  const MallowArtworkMedia({
    required this.imageUrl,
    required this.logicalSize,
    super.key,
    this.playbackId,
    this.clipPlaybackId,
    this.fit = BoxFit.cover,
    this.cdnFit = 'cover',
    this.cdnUrlOverride,
    this.width,
    this.height,
    this.borderRadius,
    this.errorIconSize = 24,
    this.placeholderBuilder,
    this.errorBuilder,
    this.heroTag,
    this.nsfw = false,
  });

  final String imageUrl;
  final double logicalSize;

  /// Opt-in shared-element tag. When non-null *and* the tile renders as a still
  /// image, the poster is wrapped in a [Hero] so it flies to the artwork detail
  /// image. Left off by default; video-backed tiles (Mux inline playback) skip
  /// the Hero entirely — a preview stream can't take part in a still-image
  /// flight and the detail screen plays a different source. Build the tag with
  /// [artworkHeroTag].
  final Object? heroTag;

  /// Full-asset Mux playback id. When present (or [clipPlaybackId] is), the
  /// tile streams inline; when both are null it behaves as a plain image.
  final String? playbackId;

  /// Short preview-loop playback id, preferred over [playbackId] for inline
  /// autoplay (mirrors the webapp).
  final String? clipPlaybackId;

  /// Moderation flag: when true the tile is wrapped in [NsfwObscured], which
  /// blurs it (and absorbs taps) until the viewer's show-NSFW setting is on
  /// or they reveal it.
  final bool nsfw;

  final BoxFit fit;
  final String cdnFit;

  /// Forwarded to [MallowNetworkImage.cdnUrlOverride]: when set (non-empty),
  /// the still poster fetches this exact URL instead of a bucket derived from
  /// [logicalSize]/[cdnFit].
  final String? cdnUrlOverride;

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final double errorIconSize;
  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  Widget _poster() => MallowNetworkImage(
    imageUrl: imageUrl,
    logicalSize: logicalSize,
    fit: fit,
    cdnFit: cdnFit,
    cdnUrlOverride: cdnUrlOverride,
    width: width,
    height: height,
    borderRadius: borderRadius,
    errorIconSize: errorIconSize,
    placeholderBuilder: placeholderBuilder,
    errorBuilder: errorBuilder,
  );

  /// Wraps the finished tile in the NSFW frost when the artwork is flagged.
  /// Applied outside the Hero so the overlay never takes part in a flight.
  Widget _withNsfw(Widget media) => NsfwObscured(
    nsfw: nsfw,
    // The image URL is the stable per-artwork identity available here;
    // it lets the overlay re-blur when a recycled grid slot swaps in a
    // different artwork (so a prior reveal can't leak onto it).
    contentId: imageUrl,
    borderRadius: borderRadius,
    child: media,
  );

  @override
  Widget build(BuildContext context) {
    final previewId = Mux.previewId(playbackId, clipPlaybackId);
    if (previewId == null) {
      final poster = _poster();
      // Still-image tile: opt into the shared-element flight when a tag is set.
      if (heroTag == null) return _withNsfw(poster);
      return _withNsfw(
        Hero(
          tag: heroTag!,
          flightShuttleBuilder: _artworkHeroFlightShuttle,
          child: poster,
        ),
      );
    }

    // Video-backed tile: no Hero. The detail screen plays a different source and
    // a preview stream can't fly, so the tile just renders its inline player.
    return _withNsfw(
      _InlineArtworkVideo(
        previewId: previewId,
        poster: _poster(),
        fit: fit,
        width: width,
        height: height,
        borderRadius: borderRadius,
        // Under Reduce Motion the tile never auto-plays; the poster stays put and
        // the viewer taps to start playback.
        reduceMotion: context.reduceMotion,
      ),
    );
  }
}

/// Fraction of the tile that must be visible before it starts playing. The
/// tile only tears playback down once it is fully off-screen, so the gap
/// between the two thresholds gives hysteresis that avoids init/dispose thrash
/// mid-scroll.
const double _playThreshold = 0.6;

class _InlineArtworkVideo extends StatefulWidget {
  const _InlineArtworkVideo({
    required this.previewId,
    required this.poster,
    required this.fit,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.reduceMotion,
  });

  final String previewId;
  final Widget poster;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  /// When true, visibility does not auto-start playback; the tile plays only on
  /// an explicit tap.
  final bool reduceMotion;

  @override
  State<_InlineArtworkVideo> createState() => _InlineArtworkVideoState();
}

class _InlineArtworkVideoState extends State<_InlineArtworkVideo> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _wantsPlay = false;

  /// Set when [_start] fails to initialize the stream. Under Reduce Motion this
  /// unmounts the tap-to-play detector so a permanently-failed tile stops eating
  /// taps and lets them fall through to the ancestor (navigation). Cleared when
  /// the previewId changes (a genuinely different source is worth retrying).
  bool _playFailed = false;

  @override
  void didUpdateWidget(_InlineArtworkVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewId != widget.previewId) {
      _playFailed = false;
      _teardown();
    }
  }

  @override
  void dispose() {
    VideoPlaybackCoordinator.instance.release(this);
    _controller?.dispose();
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    // Off-screen teardown must run even under Reduce Motion: a manually-started
    // video would otherwise keep playing and hold a coordinator slot after
    // scrolling away. Only the *autoplay* branch below is suppressed.
    if (info.visibleFraction == 0 && _wantsPlay) {
      _wantsPlay = false;
      VideoPlaybackCoordinator.instance.release(this);
      _teardown();
      return;
    }
    // Reduce Motion suppresses autoplay entirely — the tile waits for a tap.
    if (widget.reduceMotion) return;
    final visible = info.visibleFraction >= _playThreshold;
    if (visible && !_wantsPlay) {
      _wantsPlay = true;
      VideoPlaybackCoordinator.instance.acquire(this, _evict);
      _start();
    }
  }

  /// Explicit tap-to-play used when autoplay is suppressed by Reduce Motion.
  void _manualPlay() {
    if (_wantsPlay) return;
    _wantsPlay = true;
    VideoPlaybackCoordinator.instance.acquire(this, _evict);
    _start();
  }

  /// Called by the coordinator when another tile needs this one's slot.
  void _evict() {
    _wantsPlay = false;
    _teardown();
  }

  Future<void> _start() async {
    if (_controller != null) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(Mux.streamUrl(widget.previewId)),
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
    } catch (_) {
      // Stream failed — keep the poster, drop the slot. Reset _wantsPlay so a
      // stuck true doesn't make _manualPlay early-return forever, and flag the
      // failure so the (Reduce-Motion) tap-to-play detector unmounts and taps
      // fall through to the ancestor (navigation) instead of being swallowed.
      VideoPlaybackCoordinator.instance.release(this);
      await controller.dispose();
      if (identical(_controller, controller)) _controller = null;
      _wantsPlay = false;
      if (mounted) {
        setState(() => _playFailed = true);
      } else {
        _playFailed = true;
      }
      return;
    }
    // Evicted or scrolled away while initializing.
    if (!mounted || !_wantsPlay || !identical(_controller, controller)) {
      await controller.dispose();
      if (identical(_controller, controller)) _controller = null;
      return;
    }
    await controller.play();
    setState(() => _ready = true);
  }

  void _teardown() {
    final controller = _controller;
    _controller = null;
    if (_ready) setState(() => _ready = false);
    controller?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final showVideo = _ready && controller != null;

    Widget content = Stack(
      fit: StackFit.passthrough,
      children: [
        widget.poster,
        if (showVideo)
          Positioned.fill(
            // Fade the first frame in over the poster so the swap isn't a hard cut.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 200),
              builder: (_, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: _CoveredVideo(controller: controller, fit: widget.fit),
            ),
          ),
      ],
    );

    if (widget.borderRadius != null) {
      content = ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }

    // With autoplay suppressed, let a tap on the poster start playback — unless
    // init already failed, in which case the detector must stay unmounted so
    // taps fall through to the ancestor (navigation).
    if (widget.reduceMotion && !showVideo && !_playFailed) {
      content = GestureDetector(
        onTap: _manualPlay,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }

    return VisibilityDetector(
      key: Key('artwork-video-${widget.previewId}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: content,
      ),
    );
  }
}

/// Scales the video to fill (or fit) its box while preserving aspect ratio,
/// the same way [BoxFit.cover] treats an image.
class _CoveredVideo extends StatelessWidget {
  const _CoveredVideo({required this.controller, required this.fit});

  final VideoPlayerController controller;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}
