part of '../artwork_detail_screen.dart';

/// CDN bucket behind both the inline detail poster and the fullscreen viewer's
/// base image, doubling as their decode cap. Shared so the two resolve to one
/// image-cache entry and the Hero flies a single decoded bitmap between them.
const int _artworkPosterBucket = 800;

/// Decision 26 for video sources: a `/original/` URL that failed to initialise
/// earns exactly one retry against the asset's own gateway, appended to
/// [candidates] so the player's loop picks it up on its next pass — but only
/// after [ImageFallback.directUrlFor]'s HEAD probe confirms the image service,
/// and not a 4xx takedown verdict, is what failed. A no-op for pre-ramp gateway
/// candidates, which aren't on the image CDN and so never clear the probe.
Future<void> _appendVideoFallback(
  List<String> candidates, {
  required String raw,
  required String failedUrl,
}) async {
  final direct = await ImageFallback.directUrlFor(raw, failedUrl: failedUrl);
  if (direct != null && !candidates.contains(direct)) candidates.add(direct);
}

/// The image surfaces on this screen that each own an independent decision-26
/// fallback attempt: the 800-bucket poster (inline and, as the fullscreen
/// viewer's Hero base, there too) and the full-resolution original.
enum _FallbackSurface { poster, fullRes }

/// Decision 26's probe-once-then-swap, shared by all four surfaces on this
/// screen: a failed image-CDN load earns exactly one retry against the
/// asset's own gateway, and only once [ImageFallback.directUrlFor]'s HEAD probe
/// says the image service — not a 4xx takedown verdict — is what failed. A
/// refused probe or a failure on the fallback URL settles on the placeholder
/// instead of looping.
mixin _DirectGatewayFallback<T extends StatefulWidget> on State<T> {
  /// Surfaces whose one attempt has been spent. Marked *before* the probe
  /// resolves so an error-widget rebuild storm can't fire several.
  final Set<_FallbackSurface> _fallbackAttempted = <_FallbackSurface>{};

  /// Probes [failedUrl] for [surface] and, when a retry is allowed, hands the
  /// gateway URL to [apply] inside a [setState]. [skipWhen] is a late guard
  /// evaluated after the probe — the originals streams use it to drop a
  /// fallback whose download landed while the probe was in flight.
  Future<void> tryDirectFallback(
    _FallbackSurface surface, {
    required String rawUrl,
    required String failedUrl,
    required void Function(String direct) apply,
    bool Function()? skipWhen,
  }) async {
    if (!_fallbackAttempted.add(surface)) return;
    final direct = await ImageFallback.directUrlFor(
      rawUrl,
      failedUrl: failedUrl,
    );
    if (!mounted || direct == null || (skipWhen?.call() ?? false)) return;
    setState(() => apply(direct));
  }

  /// Gives [surface] its attempt back — a different artwork (or a re-requested
  /// original) is a new asset, not a second try at the old one.
  void resetDirectFallback(_FallbackSurface surface) =>
      _fallbackAttempted.remove(surface);
}

/// Reserves a 1:1 box up front so the sliver doesn't expand once the image
/// resolves, then animates the box to the image's true aspect ratio.
class _ArtworkImage extends StatefulWidget {
  const _ArtworkImage({required this.artwork, this.heroTag});

  final ArtworkDetails artwork;

  /// Shared-element tag threaded from the tile that opened this screen (see
  /// [ArtworkDetailScreen.heroTag]). When non-null the inline image flies in
  /// from that tile; either way it doubles as the source tag for the
  /// image → fullscreen-viewer flight. Falls back to a per-mint tag so the
  /// fullscreen flight still works when the screen was opened without a tile
  /// (deep link, push notification, search).
  final Object? heroTag;

  @override
  State<_ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<_ArtworkImage>
    with _DirectGatewayFallback<_ArtworkImage> {
  /// Tag shared by the inline image, the originating tile, and the fullscreen
  /// viewer so a single Hero drives both the tile → detail and detail →
  /// fullscreen flights. Only the *image* path is tagged — video tiles skip it.
  Object get _heroTag =>
      widget.heroTag ?? 'artwork-detail-${widget.artwork.mintAccount}';

  double? _aspectRatio;
  ImageStream? _stream;
  late final ImageStreamListener _listener;

  /// Video playback for video artworks. The detail page plays the *original*
  /// source (`animationUrl`) rather than the Mux preview stream the cards use,
  /// so the full-quality asset is shown. Muted + looping + autoplay by default,
  /// matching the webapp's inline behaviour.
  VideoPlayerController? _videoController;
  bool _videoReady = false;

  /// The viewer's own playback choices. They outlive any single controller —
  /// see [_maybeInitVideo], which re-applies them rather than resetting to
  /// muted-and-running every time a source is (re)opened.
  bool _muted = true;
  bool _playing = true;

  /// Bumped by every teardown ([_disposeVideo]). An init loop captures the
  /// value it started under and abandons the moment it changes, so a loop still
  /// walking candidates when a newer init begins cannot install its controller
  /// over the newer one's. `identical(_videoController, ...)` cannot carry this
  /// alone: the loop reassigns `_videoController` at the top of every pass, so
  /// a stale loop would pass its own identity check on the next candidate.
  int _videoGeneration = 0;

  /// True while the fullscreen video route is on screen. That route renders
  /// *this* state's controller rather than opening one of its own, so a
  /// teardown in that window would pull the player out from under it.
  bool _fullscreenOpen = false;

  /// Set when a refresh asked for a new source while [_fullscreenOpen]. The
  /// restart is deferred to the pop rather than dropped.
  bool _videoRestartPending = false;

  /// True while the fast 800-bucket poster is still resolving. Kept only to
  /// gate the aspect-ratio listener's animated-poster early-return — it no
  /// longer drives any progress bar. The 800 preload resolves near-instantly
  /// from the CDN, so surfacing a loader for it was just generic activity.
  bool _imageLoading = false;

  /// Full-resolution original, background-loaded over the 800-bucket poster and
  /// cross-faded in once decoded (2048px decode cap). Null until an expand has
  /// requested it and it resolves, or if it fails — in which case the
  /// 800-bucket poster stays. Mirrors the fullscreen viewer's sharpen-in-place
  /// upgrade.
  ImageProvider? _fullResProvider;
  ImageStream? _fullResStream;
  ImageStreamListener? _fullResListener;

  /// True while the full-resolution original is still downloading. The only
  /// thing that can surface the thin top progress bar — and only once its byte
  /// total is known (see [_fullResProgress]).
  bool _fullResLoading = false;

  /// Download progress (0..1) of the original, fed by the image stream's chunk
  /// events. Null until the first chunk with a known byte total arrives; while
  /// null the bar is suppressed entirely (no indeterminate/generic fallback).
  double? _fullResProgress;

  /// This screen's route, watched so we can tell when it starts popping.
  ModalRoute<dynamic>? _route;

  /// True once the detail route begins popping. Drops the shared-element Hero
  /// so the inline image doesn't fly back to the originating tile — the back
  /// navigation just runs the normal route transition, not an image flight.
  bool _popping = false;

  /// Mux playback id for the artwork's video, trimmed to null when blank.
  String? get _muxPlaybackId {
    final id = widget.artwork.playbackId?.trim();
    return (id == null || id.isEmpty) ? null : id;
  }

  /// The Mux HLS stream this artwork plays inline, or null when it has no
  /// transcode. Kept as a getter so the retry loop can tell that candidate
  /// apart from the gateway ones (see [_maybeInitVideo]).
  String? get _muxStreamUrl {
    final id = _muxPlaybackId;
    return id == null ? null : Mux.streamUrl(id);
  }

  /// True when the artwork is a video *and* has a playable source.
  bool get _isVideo {
    final url = widget.artwork.animationUrl;
    if (url == null || url.isEmpty) return false;
    // A playback id is the server's own verdict, reached by transcoding the
    // bytes. It outranks both heuristics below — and is the only signal for the
    // extension-less gateway URLs (bare IPFS CIDs) they both give up on.
    if (_muxPlaybackId != null) return true;
    final mime = widget.artwork.mimeType;
    if (mime != null && mime.startsWith('video/')) return true;
    return ArtworkMediaResolver.resolveSync(
          imageUrl: widget.artwork.imageUrl,
          animationUrl: url,
        ) ==
        CastMediaType.video;
  }

  /// True only while a player is actually on screen and running frames — the
  /// gate for the play/pause + mute controls. [_isVideo] is a *classification*
  /// and stays true through the init window and after every gateway has failed;
  /// offering playback controls over a still poster in either state gives dead
  /// buttons and a maximize that opens a video viewer with nothing to play.
  bool get _videoActive => _videoReady && _videoController != null;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final ratio = info.image.width / info.image.height;
        // Animated posters (GIF/APNG) emit one ImageInfo per frame for the
        // life of the stream. Once the first frame has cleared the loading
        // flag and settled the aspect ratio, later frames change nothing —
        // return early so steady-state animation doesn't rebuild the whole
        // detail media section 30×/s.
        if (!_imageLoading && _aspectRatio == ratio) return;
        setState(() {
          _aspectRatio = ratio;
          _imageLoading = false;
        });
      },
      onError: (_, _) {
        if (!mounted || !_imageLoading) return;
        setState(() => _imageLoading = false);
      },
    );
    _resolveImage();
    _maybeInitVideo();
  }

  @override
  void didUpdateWidget(covariant _ArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final imageChanged = oldWidget.artwork.imageUrl != widget.artwork.imageUrl;
    final animChanged =
        oldWidget.artwork.animationUrl != widget.artwork.animationUrl;
    // The inline player's preferred source is the Mux stream, so a transcode
    // that only lands on a later refresh has to restart it — the artwork was
    // playing the original (or nothing) until this frame.
    final videoChanged =
        animChanged ||
        oldWidget.artwork.playbackId != widget.artwork.playbackId;
    if (imageChanged) {
      _aspectRatio = null;
      _posterFallbackUrl = null;
      resetDirectFallback(_FallbackSurface.poster);
      _resolveImage();
    }
    if (videoChanged) {
      if (_fullscreenOpen) {
        _videoRestartPending = true;
      } else {
        _disposeVideo();
        _maybeInitVideo();
      }
    }
    // A different asset invalidates any original already fetched for the old
    // one; the next expand re-requests it.
    if (imageChanged || animChanged) {
      _resetFullRes();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteAnimationStatus);
    }
  }

  /// The route's primary animation runs forward on push and reverses on pop, so
  /// a reversing status means this screen is being dismissed. Dropping the Hero
  /// in that frame is early enough that the [HeroController]'s post-frame flight
  /// search finds no match on this route and skips the image flight entirely.
  void _onRouteAnimationStatus(AnimationStatus status) {
    final popping = status == AnimationStatus.reverse;
    if (popping != _popping && mounted) setState(() => _popping = popping);
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
    _stream?.removeListener(_listener);
    if (_fullResStream != null && _fullResListener != null) {
      _fullResStream!.removeListener(_fullResListener!);
    }
    _disposeVideo();
    super.dispose();
  }

  void _resolveImage() {
    _stream?.removeListener(_listener);
    _stream = null;
    _imageLoading = false;
    final url = widget.artwork.imageUrl;
    if (url.isEmpty) return;
    // The API carries the source's pixel dimensions (`assetMetadata`), so the
    // aspect ratio is already known — no probe fetch needed. Only artworks
    // indexed without them fall through to decoding the poster.
    final dimensions = widget.artwork.dimensions;
    if (dimensions != null && dimensions.height > 0) {
      _aspectRatio = dimensions.width / dimensions.height;
      return;
    }
    _imageLoading = true;
    final provider = ResizeImage(
      CachedNetworkImageProvider(
        MallowImage.cdnUrlForSize(
          url,
          cdnSize: _artworkPosterBucket,
          fit: 'inside',
          quality: 100,
        ),
        cacheManager: MallowImageCacheManager.instance,
      ),
      width: _artworkPosterBucket,
    );
    _stream = provider.resolve(const ImageConfiguration())
      ..addListener(_listener);
  }

  /// Decode-width cap for the inline full-resolution original, matching the
  /// fullscreen viewer's cap. Bounds a 4000×4000 NFT's decode to ~16 MB
  /// instead of ~64 MB while keeping the near-full-screen render sharp.
  static const int _fullResMaxDecodeWidth = 2048;

  void _resetFullRes() {
    if (_fullResStream != null && _fullResListener != null) {
      _fullResStream!.removeListener(_fullResListener!);
    }
    _fullResStream = null;
    _fullResListener = null;
    _fullResProvider = null;
    _fullResLoading = false;
    _fullResProgress = null;
    resetDirectFallback(_FallbackSurface.fullRes);
  }

  /// Background-loads the full-resolution original and cross-fades it over the
  /// fast 800-bucket poster once decoded ([_imageMedia]), sharpening in place.
  /// The thin top bar reflects this download's real byte progress and only once
  /// its byte total is known — it never appears for the 800 preload (which the
  /// CDN serves near-instantly) nor for video artworks (whose original is the
  /// video, played inline), which are skipped here entirely.
  ///
  /// Only ever started by an explicit expand interaction ([_fullscreenButton]).
  /// Merely opening the detail screen keeps the 800-bucket poster, so browsing
  /// never pulls multi-megabyte originals off the gateways.
  void _loadFullRes() {
    _resetFullRes();
    if (_isVideo) return;
    final original = MallowImage.originalUrl(widget.artwork.imageUrl);
    if (original.isEmpty) return;
    _startFullRes(original);
  }

  void _startFullRes(String url) {
    if (_fullResStream != null && _fullResListener != null) {
      _fullResStream!.removeListener(_fullResListener!);
    }
    _fullResLoading = true;
    final provider = ResizeImage(
      CachedNetworkImageProvider(
        url,
        cacheManager: MallowImageCacheManager.instance,
      ),
      width: _fullResMaxDecodeWidth,
    );
    _fullResListener = ImageStreamListener(
      (info, _) {
        if (!mounted || _fullResProvider != null) return;
        setState(() {
          _fullResProvider = provider;
          _fullResLoading = false;
          _fullResProgress = null;
        });
      },
      onChunk: (event) {
        if (!mounted || !_fullResLoading) return;
        final total = event.expectedTotalBytes;
        if (total == null || total == 0) return;
        setState(
          () => _fullResProgress = (event.cumulativeBytesLoaded / total).clamp(
            0.0,
            1.0,
          ),
        );
      },
      // Silently keep the 800-bucket poster if the original can't be fetched.
      onError: (_, _) {
        if (!mounted || !_fullResLoading) return;
        setState(() => _fullResLoading = false);
        _retryFullResDirect(url);
      },
    );
    _fullResStream = provider.resolve(const ImageConfiguration())
      ..addListener(_fullResListener!);
  }

  /// Decision 26 applied to the originals stream: re-run the download against
  /// the asset's own gateway when the image service — not the asset — is what
  /// failed. Once per artwork; on a refused fallback or a second failure the
  /// 800-bucket poster silently stays, exactly as before.
  Future<void> _retryFullResDirect(String failedUrl) => tryDirectFallback(
    _FallbackSurface.fullRes,
    rawUrl: widget.artwork.imageUrl,
    failedUrl: failedUrl,
    skipWhen: () => _fullResProvider != null,
    apply: _startFullRes,
  );

  Future<void> _maybeInitVideo() async {
    if (!_isVideo) return;
    final raw = widget.artwork.animationUrl!;
    // Mux first when the artwork has a transcode: an adaptive HLS stream starts
    // in a fraction of the time and none of the bytes, where the original is a
    // multi-megabyte gateway fetch on every open of the screen. The originals
    // stay behind it so a Mux outage still plays, and the fullscreen viewer
    // asks for them directly — the same "originals only on an explicit expand"
    // rule the still-image path follows.
    //
    // Behind Mux: canonical mode is one `/original/` URL with the images
    // service picking the gateway behind a redirect. Legacy tries each
    // reachable gateway in turn — the original arweave.net/IPFS source 403s
    // some clients, so the resolver picks a server-verified gateway and we fall
    // through to mallow's mirror before giving up. Copied so the decision-26
    // retry can be appended below.
    final generation = _videoGeneration;
    final muxUrl = _muxStreamUrl;
    final candidates = List<String>.of(
      await AssetUrl.videoSourceCandidates(
        raw,
        chain: widget.artwork.chain,
        playbackId: _muxPlaybackId,
      ),
    );
    if (!mounted || generation != _videoGeneration) return;
    // Reduce Motion suppresses autoplay — the first frame shows as a poster and
    // the existing play/pause control lets the user start it.
    final reduceMotion = context.reduceMotion;
    var fallbackTried = false;
    var index = 0;
    while (index < candidates.length) {
      // A teardown ran while the previous candidate was in flight, so a newer
      // init owns playback now. Claiming `_videoController` here would hand the
      // screen a source the current artwork no longer names.
      if (generation != _videoGeneration) return;
      final source = candidates[index++];
      final controller = VideoPlayerController.networkUrl(Uri.parse(source));
      _videoController = controller;
      try {
        await controller.initialize();
        await controller.setLooping(true);
        // Not a hardcoded mute: a viewer who unmuted the previous source keeps
        // their audio when a transcode lands mid-view and restarts playback.
        await controller.setVolume(_muted ? 0 : 1);
      } catch (_) {
        await controller.dispose();
        // Superseded mid-await — the teardown already dropped the reference.
        if (generation != _videoGeneration) return;
        _videoController = null;
        // Decision 26 probes the image service, so a failed Mux stream must not
        // spend the one attempt the `/original/` candidate behind it is owed —
        // the probe would refuse a stream.mux.com URL anyway.
        if (!fallbackTried && source != muxUrl) {
          fallbackTried = true;
          await _appendVideoFallback(candidates, raw: raw, failedUrl: source);
        }
        continue; // this gateway failed; try the next.
      }
      if (!mounted || generation != _videoGeneration) {
        await controller.dispose();
        return;
      }
      // Reduce Motion never starts a source on its own, including a replacement
      // one — a new stream is exactly the motion it exists to suppress, so the
      // control returns to "Play". Otherwise the viewer's [_playing] carries:
      // a restart resumes what was running and leaves paused what was paused,
      // rather than autoplaying under a control that still reads "Play".
      if (reduceMotion) {
        _playing = false;
      } else if (_playing) {
        await controller.play();
      }
      setState(() {
        _videoReady = true;
      });
      return;
    }
    // No gateway played — fall back to the still image (already shown).
  }

  void _disposeVideo() {
    _videoGeneration++;
    _videoController?.dispose();
    _videoController = null;
    _videoReady = false;
  }

  void _togglePlay() {
    final c = _videoController;
    if (c == null) return;
    setState(() {
      _playing = !_playing;
      _playing ? c.play() : c.pause();
    });
  }

  void _toggleMute() {
    final c = _videoController;
    if (c == null) return;
    setState(() {
      _muted = !_muted;
      c.setVolume(_muted ? 0 : 1);
    });
  }

  /// Hands the *running* player to the fullscreen route instead of opening a
  /// second one. Two things follow from that, both of them the point: playback
  /// continues from exactly where it was rather than restarting, and the source
  /// stays whatever [_maybeInitVideo] settled on — the Mux stream whenever the
  /// artwork has a transcode. Maximizing therefore never pulls a multi-megabyte
  /// original for an artwork that is already playing; only an artwork with no
  /// playback id reaches an original at all, and it did so inline.
  Future<void> _openVideoFullscreen() async {
    final controller = _videoController;
    if (controller == null) return;
    _fullscreenOpen = true;
    await _showArtworkVideoFullscreen(context, controller: controller);
    _fullscreenOpen = false;
    if (!mounted) return;
    final restart = _videoRestartPending;
    _videoRestartPending = false;
    setState(() {
      // The viewer drove the shared controller, so the row's icons follow what
      // it left running — an unmute up there carries back down here.
      _playing = controller.value.isPlaying;
      _muted = controller.value.volume == 0;
      // A refresh that renamed the source mid-view was held back so the
      // fullscreen player kept its controller. It is safe to swap now, and
      // [_maybeInitVideo] re-applies the two choices just synced above.
      if (restart) _disposeVideo();
    });
    if (restart) await _maybeInitVideo();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final hasImage = widget.artwork.imageUrl.isNotEmpty;
    // Cap the entire artwork section (including padding) at 60% of screen
    // height so tall images don't dominate the scroll view.
    final maxSectionHeight = MediaQuery.of(context).size.height * 0.6;
    const sectionPadding = MallowTheme.spacing26;
    // Double the bottom padding so the fullscreen button sits below the artwork
    // instead of overlapping it.
    const sectionBottomPadding = sectionPadding * 2;
    final section = Container(
      width: double.infinity,
      color: colors.surfaceMuted,
      padding: const EdgeInsets.fromLTRB(
        sectionPadding,
        sectionPadding,
        sectionPadding,
        sectionBottomPadding,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maxSectionHeight - sectionPadding - sectionBottomPadding,
          ),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 1, end: _aspectRatio ?? 1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, ratio, child) => AspectRatio(
              aspectRatio: ratio,
              child: hasImage
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: MallowTheme.fabShadow(context),
                      ),
                      child: child,
                    )
                  : child,
            ),
            child: _isVideo
                ? _buildVideoMedia()
                : (hasImage ? _imageMedia() : const _ArtworkImagePlaceholder()),
          ),
        ),
      ),
    );

    // Controls pinned to the bottom-right corner of the section, matching the
    // webapp's maximize control. Video adds play/pause + mute toggles to the
    // left of the fullscreen glyph — but only once a player is actually running
    // ([_videoActive]). While the stream initialises, and permanently if every
    // source failed, what is on screen is the still poster, so it gets the
    // still poster's control: maximize into the *image* viewer. The 8px padding
    // around each 24px glyph gives a comfortable tap target while keeping the
    // row visually inset by `spacing12` from the section corner.
    //
    // A video that never played leaves the poster as the subject; with no
    // poster either there is nothing to maximize, so the corner stays empty.
    if (!hasImage && !_isVideo) return section;
    final Widget? controls = _videoActive
        ? _videoControls(colors)
        : (hasImage ? _fullscreenButton(colors) : null);

    // The NSFW frost wraps the whole section (media + controls) so a blurred
    // artwork can't reach fullscreen or start video playback until revealed —
    // the fullscreen viewers themselves therefore never need their own blur.
    return NsfwObscured(
      nsfw: widget.artwork.nsfw,
      contentId: widget.artwork.mintAccount,
      child: Stack(
        children: [
          section,
          if (_fullResLoading && _fullResProgress != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              // Only ever shown for the original download, and only once its
              // byte total is known — so this is always a determinate bar.
              child: _MediaLoadingBar(progress: _fullResProgress),
            ),
          if (controls != null)
            Positioned(
              right: MallowTheme.spacing12 - 8,
              bottom: MallowTheme.spacing12 - 8,
              child: controls,
            ),
        ],
      ),
    );
  }

  /// Fast 800-bucket poster with the full-resolution original cross-fading in
  /// over it once [_loadFullRes] decodes. Mirrors the fullscreen viewer: the
  /// Hero wraps only the 800-bucket base (so the tile → detail and detail →
  /// fullscreen flights carry a stable child), and the sharp original rides as
  /// a sibling on top — dropped the instant the route starts popping so it
  /// doesn't linger over the exit while the Hero carries the poster home.
  Widget _imageMedia() {
    final base = _popping
        ? _posterImage()
        : Hero(tag: _heroTag, child: _posterImage());
    final fullRes = _fullResProvider;
    // Always host the poster inside the same Stack, whether or not the full-res
    // overlay is present yet. Returning `base` bare before the original resolves
    // and a Stack after would reparent the poster (its `DecoratedBox` child
    // changes type from Hero to Stack), tearing down the poster's
    // CachedNetworkImage element — which restarts in its loading state and
    // re-shows the shimmer placeholder just as the sharp original fades in.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        base,
        if (fullRes != null && !_popping)
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 250),
              builder: (context, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: Image(image: fullRes, fit: BoxFit.contain),
            ),
          ),
      ],
    );
  }

  /// Asset-gateway URL swapped in after the 800-bucket poster failed and the
  /// HEAD probe cleared the retry (decision 26). Null while the CDN URL is in
  /// play; set at most once per artwork, so a failure on the fallback URL lands
  /// on the placeholder instead of looping.
  String? _posterFallbackUrl;

  Future<void> _tryPosterFallback(String failedUrl) => tryDirectFallback(
    _FallbackSurface.poster,
    rawUrl: widget.artwork.imageUrl,
    failedUrl: failedUrl,
    apply: (direct) => _posterFallbackUrl = direct,
  );

  Widget _posterImage() => CachedNetworkImage(
    imageUrl:
        _posterFallbackUrl ??
        MallowImage.cdnUrlForSize(
          widget.artwork.imageUrl,
          cdnSize: _artworkPosterBucket,
          fit: 'inside',
          quality: 100,
        ),
    cacheManager: MallowImageCacheManager.instance,
    memCacheWidth: _artworkPosterBucket,
    fit: BoxFit.contain,
    placeholder: (context, url) => const ImageShimmerGrid(),
    errorWidget: (context, url, error) {
      // Ask the CDN what went wrong; if the service is what failed this swaps
      // in the asset's own gateway and the poster reloads. The placeholder is
      // what shows meanwhile, and permanently if the retry is refused or fails.
      _tryPosterFallback(url);
      return const _ArtworkImagePlaceholder();
    },
  );

  /// Still poster underneath, original-source video on top once ready.
  Widget _buildVideoMedia() {
    final controller = _videoController;
    final hasImage = widget.artwork.imageUrl.isNotEmpty;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (hasImage) _posterImage() else const _ArtworkImagePlaceholder(),
        if (_videoReady && controller != null)
          Positioned.fill(
            child: FittedBox(
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            ),
          ),
      ],
    );
  }

  Widget _fullscreenButton(MallowColors colors) => Semantics(
    button: true,
    label: 'View fullscreen',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Expanding is the explicit zoom intent: only now is the original
        // worth fetching, and the inline poster sharpens for the return trip.
        if (_fullResProvider == null && !_fullResLoading) _loadFullRes();
        _showArtworkFullscreen(
          context,
          widget.artwork.imageUrl,
          heroTag: _heroTag,
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: MallowSvgIcon(
          'assets/icons/arrows_maximize.svg',
          width: 24,
          height: 24,
          color: colors.textSecondary,
        ),
      ),
    ),
  );

  Widget _videoControls(MallowColors colors) {
    final playing = _playing;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _controlButton(
          colors: colors,
          asset: playing
              ? 'assets/icons/video_pause.svg'
              : 'assets/icons/video_play.svg',
          label: playing ? 'Pause' : 'Play',
          onTap: _togglePlay,
        ),
        _controlButton(
          colors: colors,
          asset: _muted
              ? 'assets/icons/video_mute.svg'
              : 'assets/icons/video_volume.svg',
          label: _muted ? 'Unmute' : 'Mute',
          onTap: _toggleMute,
        ),
        _controlButton(
          colors: colors,
          asset: 'assets/icons/arrows_maximize.svg',
          label: 'View fullscreen',
          onTap: _openVideoFullscreen,
        ),
      ],
    );
  }

  Widget _controlButton({
    required MallowColors colors,
    required String asset,
    required String label,
    required VoidCallback onTap,
  }) => Semantics(
    button: true,
    label: label,
    child: Tappable(
      semanticButton: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: MallowSvgIcon(
          asset,
          width: 24,
          height: 24,
          color: colors.textSecondary,
        ),
      ),
    ),
  );
}

/// Opens the artwork in a dismissible, pinch-to-zoom fullscreen viewer,
/// mirroring the webapp's fullscreen display.
void _showArtworkFullscreen(
  BuildContext context,
  String imageUrl, {
  required Object heroTag,
}) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) =>
          _ArtworkFullscreenViewer(imageUrl: imageUrl, heroTag: heroTag),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _ArtworkFullscreenViewer extends StatefulWidget {
  const _ArtworkFullscreenViewer({
    required this.imageUrl,
    required this.heroTag,
  });

  final String imageUrl;

  /// Matches the inline detail image's Hero so the fullscreen image flies in
  /// from — and, on a clean pop, back to — the inline artwork.
  final Object heroTag;

  @override
  State<_ArtworkFullscreenViewer> createState() =>
      _ArtworkFullscreenViewerState();
}

class _ArtworkFullscreenViewerState extends State<_ArtworkFullscreenViewer>
    with
        SingleTickerProviderStateMixin,
        _DirectGatewayFallback<_ArtworkFullscreenViewer> {
  /// The original, full-resolution image. Requested only once the user zooms
  /// in ([_onInteractionUpdate]) and shown over the fast CDN bucket only after
  /// it has fully decoded, so the viewer is interactive immediately and
  /// sharpens up when the original arrives. Stays null (CDN image remains)
  /// while unzoomed, or if the original fails to load.
  ImageProvider? _fullResProvider;
  ImageStream? _fullResStream;
  ImageStreamListener? _fullResListener;

  /// True while the full-resolution original is still downloading — drives the
  /// thin progress bar across the top of the screen.
  bool _fullResLoading = false;

  /// True once a zoom has asked for the original, so a failed download isn't
  /// retried on every subsequent gesture frame.
  bool _fullResRequested = false;

  /// Download progress (0..1) of the full-resolution original, fed by the image
  /// stream's chunk events. Null when the byte total is unknown — the bar falls
  /// back to indeterminate in that case.
  double? _fullResProgress;

  /// Drives drag-to-dismiss. While the image is at minimum zoom, a single-finger
  /// drag moves the artwork with the finger in any direction (fading the
  /// backdrop and tilting slightly toward the drag). Releasing with a flick in
  /// any direction — or after dragging past [_dismissDistance] — pops the
  /// viewer; otherwise the image springs back to center via [_resetController].
  /// Tracks the live zoom via [_transformController] so the drag only engages
  /// when there's nothing left to pan.
  final TransformationController _transformController =
      TransformationController();

  /// Unbounded, time-domain driver for the physics settle-back. Its value is the
  /// animated scalar distance along [_motionUnit]; the listener maps it back onto
  /// [_drag] as the image springs to center.
  late final AnimationController _resetController;
  Offset _drag = Offset.zero;

  /// Unit direction the settle-back spring rides along (the drag vector at
  /// release), so the animated scalar distance maps back onto [_drag].
  Offset _motionUnit = Offset.zero;

  /// This viewer's route, watched so we know when it starts popping.
  ModalRoute<dynamic>? _route;

  /// True once the viewer route begins popping. Drops the sharp full-res overlay
  /// so it doesn't linger and fade out over the exit; the CDN Hero underneath is
  /// left in place so the framework hands it off to the return flight without a
  /// blank frame.
  bool _popping = false;

  static const double _dismissDistance = 140;
  static const double _dismissVelocity = 800;

  /// Max tilt (radians, ~10°) applied at full horizontal drag — clockwise when
  /// dragging right, counter-clockwise when dragging left.
  static const double _maxDragRotation = 0.18;

  /// Critically damped spring (no overshoot) for the settle-back to center.
  static final SpringDescription _returnSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 500);

  @override
  void initState() {
    super.initState();
    _resetController = AnimationController.unbounded(vsync: this)
      ..addListener(_onMotionTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteAnimationStatus);
    }
  }

  /// The route's primary animation reverses on pop; the moment it does, drop the
  /// full-res overlay so it vanishes instantly instead of fading out with the
  /// route, leaving the Hero flight back to the inline artwork as the only exit
  /// motion.
  void _onRouteAnimationStatus(AnimationStatus status) {
    final popping = status == AnimationStatus.reverse;
    if (popping != _popping && mounted) setState(() => _popping = popping);
  }

  void _onMotionTick() {
    setState(() => _drag = _motionUnit * _resetController.value);
  }

  /// Decode-width cap for the full-resolution original. Without it a 4000×4000
  /// NFT decodes to ~64 MB of RGBA and can trip the iOS watchdog — the same cap
  /// [MallowNetworkImage]'s `memCacheWidth` enforces everywhere else. 2048 px
  /// keeps pinch-zoom sharp while bounding the decode to ~16 MB.
  static const int _fullResMaxDecodeWidth = 2048;

  /// Starts the original download. Called the first time the user actually
  /// pinches past 1× — opening the viewer to glance at the artwork at screen
  /// size is served by the [_artworkPosterBucket] image the Hero brought along.
  void _loadFullRes() {
    _fullResRequested = true;
    final original = MallowImage.originalUrl(widget.imageUrl);
    if (original.isEmpty) return;
    _startFullRes(original);
  }

  void _startFullRes(String url) {
    if (_fullResStream != null && _fullResListener != null) {
      _fullResStream!.removeListener(_fullResListener!);
    }
    _fullResLoading = true;
    final provider = ResizeImage(
      CachedNetworkImageProvider(
        url,
        cacheManager: MallowImageCacheManager.instance,
      ),
      width: _fullResMaxDecodeWidth,
    );
    _fullResListener = ImageStreamListener(
      (info, _) {
        if (!mounted || _fullResProvider != null) return;
        setState(() {
          _fullResProvider = provider;
          _fullResLoading = false;
          _fullResProgress = null;
        });
      },
      onChunk: (event) {
        if (!mounted || !_fullResLoading) return;
        final total = event.expectedTotalBytes;
        if (total == null || total == 0) return;
        setState(
          () => _fullResProgress = (event.cumulativeBytesLoaded / total).clamp(
            0.0,
            1.0,
          ),
        );
      },
      // Silently keep the CDN image if the original can't be fetched.
      onError: (_, _) {
        if (!mounted || !_fullResLoading) return;
        setState(() => _fullResLoading = false);
        _retryFullResDirect(url);
      },
    );
    _fullResStream = provider.resolve(const ImageConfiguration())
      ..addListener(_fullResListener!);
  }

  /// Same decision-26 retry as the inline detail image, once per viewer.
  Future<void> _retryFullResDirect(String failedUrl) => tryDirectFallback(
    _FallbackSurface.fullRes,
    rawUrl: widget.imageUrl,
    failedUrl: failedUrl,
    skipWhen: () => _fullResProvider != null,
    apply: _startFullRes,
  );

  /// Asset-gateway URL swapped in after the 800-bucket base image failed and the
  /// HEAD probe cleared the retry (decision 26) — the Hero's own copy of the
  /// same swap the inline poster does. Set at most once, so a failure on the
  /// fallback URL settles on the placeholder rather than looping.
  String? _baseFallbackUrl;

  Future<void> _tryBaseFallback(String failedUrl) => tryDirectFallback(
    _FallbackSurface.poster,
    rawUrl: widget.imageUrl,
    failedUrl: failedUrl,
    apply: (direct) => _baseFallbackUrl = direct,
  );

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
    if (_fullResStream != null && _fullResListener != null) {
      _fullResStream!.removeListener(_fullResListener!);
    }
    _transformController.dispose();
    _resetController.dispose();
    super.dispose();
  }

  double get _currentScale => _transformController.value.getMaxScaleOnAxis();

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    // Zooming past 1× is the explicit intent that earns the original; a glance
    // at screen size is served by the poster bucket the Hero flew in.
    if (!_fullResRequested && _currentScale > 1.01) setState(_loadFullRes);
    // Only single-finger drags at minimum zoom drag-to-dismiss; anything else
    // (a pinch, or a pan while zoomed in) belongs to the InteractiveViewer.
    if (details.pointerCount != 1 || _currentScale > 1.01) {
      if (_drag != Offset.zero && !_resetController.isAnimating) {
        _animateReset();
      }
      return;
    }
    _resetController.stop();
    setState(() => _drag += details.focalPointDelta);
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    // Zoomed in — the gesture was a pan/pinch, never a dismiss.
    if (_currentScale > 1.01) return;
    final velocity = details.velocity.pixelsPerSecond;
    final flung = velocity.distance > _dismissVelocity;
    if (flung || _drag.distance > _dismissDistance) {
      // Pop with the shared-element Hero intact so the image flies from wherever
      // the finger left it back to its spot in the artwork detail screen.
      Navigator.of(context).maybePop();
    } else if (_drag != Offset.zero) {
      _animateReset(velocity);
    }
  }

  void _animateReset([Offset velocity = Offset.zero]) {
    final start = _drag;
    if (start == Offset.zero) return;
    final dist = start.distance;
    _motionUnit = start / dist;
    // Project the release velocity onto the return axis so a flick keeps its
    // momentum into the spring. Motion runs along the drag vector as a single
    // spring, so the perpendicular velocity component is intentionally dropped.
    final vAlong = velocity.dx * _motionUnit.dx + velocity.dy * _motionUnit.dy;
    _resetController.animateWith(
      ScrollSpringSimulation(_returnSpring, dist, 0, vAlong),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final topInset = MediaQuery.of(context).padding.top;
    final fullRes = _fullResProvider;
    final dragProgress = (_drag.distance / _dismissDistance).clamp(0.0, 1.0);
    // Tilt toward the horizontal drag: clockwise (right) / counter-clockwise
    // (left). Positive Transform.rotate angles read clockwise on screen.
    final dragRotation = (_drag.dx / 1000).clamp(
      -_maxDragRotation,
      _maxDragRotation,
    );
    // The backdrop clears (dim + blur) as the artwork moves away from center,
    // proportional to the drag; the route's fade finishes the clear on dismiss.
    final overlayProgress = dragProgress;
    final backdropBlur = 24 * (1 - overlayProgress);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Blurred, dimmed backdrop. Taps that land outside the zoomed image
          // fall through here and dismiss the viewer (webapp click-outside
          // parity); the close button below is the guaranteed affordance.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: backdropBlur,
                  sigmaY: backdropBlur,
                ),
                child: ColoredBox(
                  // Fades out as the artwork moves toward dismissal.
                  color: colors.bgPrimary.withValues(
                    alpha: 0.5 * (1 - overlayProgress),
                  ),
                ),
              ),
            ),
          ),
          // Pinch-to-zoom + pan, matching the webapp's 1×–5× zoom range. The
          // fast 800-bucket CDN image renders first; the full-resolution
          // original is fetched on the first pinch and cross-fades in on top
          // once it finishes loading. Both use
          // BoxFit.contain within the expanded stack, so they occupy the same
          // rect and stay aligned across the swap and under zoom.
          //
          // The outer Transform follows the drag-to-dismiss gesture: when the
          // image is at minimum zoom, a single-finger drag moves the whole
          // viewer in any direction, tilts it toward the horizontal motion, and
          // scales it slightly, so the artwork tracks the finger before it's
          // released.
          Positioned.fill(
            child: Transform.translate(
              offset: _drag,
              child: Transform.rotate(
                angle: dragRotation,
                child: Transform.scale(
                  scale: 1 - 0.1 * dragProgress,
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    minScale: 1,
                    maxScale: 5,
                    onInteractionUpdate: _onInteractionUpdate,
                    onInteractionEnd: _onInteractionEnd,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Shared-element anchor: flies in from the inline
                        // detail image on open, and back to it on dismiss.
                        // A flick-to-dismiss keeps this Hero so the image
                        // transitions home rather than throwing off-screen.
                        Hero(
                          tag: widget.heroTag,
                          child: CachedNetworkImage(
                            imageUrl:
                                _baseFallbackUrl ??
                                MallowImage.cdnUrlForSize(
                                  widget.imageUrl,
                                  cdnSize: _artworkPosterBucket,
                                  fit: 'inside',
                                  quality: 100,
                                ),
                            cacheManager: MallowImageCacheManager.instance,
                            memCacheWidth: _artworkPosterBucket,
                            fit: BoxFit.contain,
                            placeholder: (context, url) =>
                                const Center(child: MallowLoadingIndicator()),
                            errorWidget: (context, url, error) {
                              // Retry on the asset's own gateway if the image
                              // service — not a takedown — is what failed.
                              _tryBaseFallback(url);
                              return const _ArtworkImagePlaceholder();
                            },
                          ),
                        ),
                        // Dropped the instant the viewer starts popping so the
                        // sharp original doesn't linger and fade out over the
                        // exit; the Hero below carries the CDN image home
                        // seamlessly, so there's no ghost and no flicker.
                        if (fullRes != null && !_popping)
                          TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 250),
                            builder: (context, opacity, child) =>
                                Opacity(opacity: opacity, child: child),
                            child: Image(image: fullRes, fit: BoxFit.contain),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Close affordance, mirroring the webapp's top-right X button.
          Positioned(
            top: topInset + MallowTheme.spacing12,
            right: MallowTheme.spacing20,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.bgPrimary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.16),
                      offset: const Offset(0, 4),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: Icon(Icons.close, size: 20, color: colors.textPrimary),
              ),
            ),
          ),
          // Thin progress bar under the status bar while the full-resolution
          // original is still downloading in the background.
          if (_fullResLoading)
            Positioned(
              top: topInset,
              left: 0,
              right: 0,
              child: _MediaLoadingBar(progress: _fullResProgress),
            ),
        ],
      ),
    );
  }
}

/// Thin bar shown across the top of the artwork surface while the
/// full-resolution original (image or video file) is loading. Shows a
/// determinate 0..100% fill when [progress] is known (image downloads report
/// byte progress) and falls back to an indeterminate looping bar otherwise
/// (e.g. video init, or a server that sent no Content-Length).
class _MediaLoadingBar extends StatelessWidget {
  const _MediaLoadingBar({this.progress});

  /// Download progress in 0..1, or null for an indeterminate bar.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final color = context.mallowColors.textPrimary;
    final value = progress;
    if (value == null) {
      return LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation(color),
      );
    }
    // Chunk events arrive in bursts; tween between them so the fill glides to
    // each new value instead of snapping.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, animated, _) => LinearProgressIndicator(
        value: animated,
        minHeight: 2,
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

class _ArtworkImagePlaceholder extends StatelessWidget {
  const _ArtworkImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      color: colors.divider,
      child: Center(
        child: MallowSvgIcon(
          'assets/icons/stamp.svg',
          width: 64,
          height: 64,
          color: colors.textTertiary,
        ),
      ),
    );
  }
}

/// Opens the artwork video in a dismissible fullscreen player, mirroring the
/// webapp's maximize control, with the same play/pause + mute controls; a
/// downward drag or a scrim tap dismisses it.
///
/// [controller] is the inline player itself, already initialised and running —
/// not a source to open. Handing it over rather than duplicating it is what
/// makes maximizing continuous: no re-buffer, no seek, no second source. The
/// caller keeps ownership; the viewer must never dispose it.
Future<void> _showArtworkVideoFullscreen(
  BuildContext context, {
  required VideoPlayerController controller,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) =>
        _ArtworkVideoFullscreenViewer(controller: controller),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

class _ArtworkVideoFullscreenViewer extends StatefulWidget {
  const _ArtworkVideoFullscreenViewer({required this.controller});

  /// The detail screen's live player, borrowed for the life of this route.
  /// Disposed by the state that owns it, never here.
  final VideoPlayerController controller;

  @override
  State<_ArtworkVideoFullscreenViewer> createState() =>
      _ArtworkVideoFullscreenViewerState();
}

class _ArtworkVideoFullscreenViewerState
    extends State<_ArtworkVideoFullscreenViewer> {
  Offset _drag = Offset.zero;

  static const double _dismissDistance = 140;
  static const double _dismissVelocity = 800;

  /// Play/pause and mute act straight on the shared controller and hold no
  /// copy of its state — [build] listens to the controller instead, so the
  /// icons here and the inline row's can never disagree about one player.
  /// Reduce Motion needs no handling either: nothing starts playback here, so
  /// a video paused inline opens paused, under a control that reads "Play".
  void _togglePlay() {
    final c = widget.controller;
    c.value.isPlaying ? c.pause() : c.play();
  }

  void _toggleMute() {
    final c = widget.controller;
    c.setVolume(c.value.volume == 0 ? 1 : 0);
  }

  void _onPanUpdate(DragUpdateDetails d) => setState(() => _drag += d.delta);

  void _onPanEnd(DragEndDetails d) {
    final flung = d.velocity.pixelsPerSecond.dy.abs() > _dismissVelocity;
    if (flung || _drag.distance > _dismissDistance) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final topInset = MediaQuery.of(context).padding.top;
    final dragProgress = (_drag.distance / _dismissDistance).clamp(0.0, 1.0);
    // The maximize control that opens this route only exists over a live
    // player, so there is nothing to load and no loading state to show: the
    // first frame here is the frame the inline player was already on.
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, video, _) => Scaffold(
        backgroundColor: colors.bgPrimary.withValues(
          alpha: 1 - 0.5 * dragProgress,
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                onVerticalDragUpdate: _onPanUpdate,
                onVerticalDragEnd: _onPanEnd,
                child: Transform.translate(
                  offset: _drag,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: video.aspectRatio,
                      child: VideoPlayer(widget.controller),
                    ),
                  ),
                ),
              ),
            ),
            // Play/pause + mute controls, centered along the bottom.
            Positioned(
              left: 0,
              right: 0,
              bottom:
                  MediaQuery.of(context).padding.bottom + MallowTheme.spacing26,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _fsControl(
                    colors: colors,
                    asset: video.isPlaying
                        ? 'assets/icons/video_pause.svg'
                        : 'assets/icons/video_play.svg',
                    label: 'Play/Pause',
                    onTap: _togglePlay,
                  ),
                  const SizedBox(width: MallowTheme.spacing12),
                  _fsControl(
                    colors: colors,
                    asset: video.volume == 0
                        ? 'assets/icons/video_mute.svg'
                        : 'assets/icons/video_volume.svg',
                    label: 'Mute/Unmute',
                    onTap: _toggleMute,
                  ),
                ],
              ),
            ),
            Positioned(
              top: topInset + MallowTheme.spacing12,
              right: MallowTheme.spacing20,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.bgPrimary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: 0.16),
                        offset: const Offset(0, 4),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Icon(Icons.close, size: 20, color: colors.textPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fsControl({
    required MallowColors colors,
    required String asset,
    required String label,
    required VoidCallback onTap,
  }) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.bgPrimary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.16),
              offset: const Offset(0, 4),
              blurRadius: 24,
            ),
          ],
        ),
        child: MallowSvgIcon(
          asset,
          width: 24,
          height: 24,
          color: colors.textPrimary,
        ),
      ),
    ),
  );
}
