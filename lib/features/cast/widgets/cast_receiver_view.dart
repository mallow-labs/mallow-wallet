import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../models/cast_display_type.dart';
import '../models/cast_media_type.dart';
import '../models/cast_overlay_config.dart';
import '../models/cast_queue.dart';
import '../services/cast_bloc.dart';
import '../services/cast_service.dart';
import 'cast_animated_artwork.dart';

const double _kBarHeight = 220;

/// Renders a single [CastQueueItem] with an optional QR + caption overlay.
///
/// Self-contained: takes everything it needs as constructor args so it can
/// run inside the main app (macOS local), inside a secondary FlutterEngine
/// mounted on an external UIScreen (iOS AirPlay, Phase 5), or be mirrored
/// 1:1 by the HTML cast receiver (Chromecast, Phase 4).
class CastReceiverView extends StatelessWidget {
  const CastReceiverView({
    required this.item,
    required this.overlay,
    super.key,
  });

  final CastQueueItem item;
  final CastOverlayConfig overlay;

  bool get _showBar =>
      (overlay.showCaption &&
          (overlay.title != null || overlay.subtitle != null)) ||
      (overlay.showQr && overlay.qrUrl != null);

  @override
  Widget build(BuildContext context) {
    final media = _MediaArea(item: item, overlay: overlay);
    // Cast receiver renders on TV black background — intentional literal.
    // Subsequent black/white usages in this file inherit the same rationale.
    return ColoredBox(
      color: Colors.black,
      child: _showBar
          ? Column(
              children: [
                Expanded(child: media),
                _BottomBar(overlay: overlay),
              ],
            )
          : media,
    );
  }
}

/// Mounts [CastReceiverView] fullscreen whenever the active cast session is
/// rendering on the local device (i.e. [CastDeviceType.local]). Returns a
/// zero-size placeholder otherwise so it can sit safely in the app's root
/// [Stack].
class LocalCastReceiverOverlay extends StatelessWidget {
  const LocalCastReceiverOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CastBloc, CastState>(
      buildWhen: _shouldRebuild,
      builder: (context, state) {
        if (state is! CastActive || state.device.type != CastDeviceType.local) {
          return const SizedBox.shrink();
        }
        final item = state.queue.currentItem;
        if (item == null) return const SizedBox.shrink();

        return Positioned.fill(
          child: CastReceiverView(
            item: item,
            overlay: CastOverlayConfigFromQueue.from(state.queue, item),
          ),
        );
      },
    );
  }

  static bool _shouldRebuild(CastState prev, CastState curr) {
    if (curr is! CastActive && prev is! CastActive) return false;
    if (curr is! CastActive || prev is! CastActive) return true;
    if (curr.device.type != prev.device.type) return true;
    return curr.queue.currentItem != prev.queue.currentItem ||
        curr.queue.showQr != prev.queue.showQr ||
        curr.queue.showCaption != prev.queue.showCaption ||
        curr.queue.displayType != prev.queue.displayType;
  }
}

/// Image area above the bottom bar. Picks a renderer based on
/// [CastDisplayType] so fit/fill/tile is consistent with the HTML receiver.
class _MediaArea extends StatelessWidget {
  const _MediaArea({required this.item, required this.overlay});

  final CastQueueItem item;
  final CastOverlayConfig overlay;

  @override
  Widget build(BuildContext context) {
    // Blurred current artwork as a base layer in every mode: fills the
    // letterbox in fit-to-screen, shows through carousel gaps in tile, and
    // sits behind the cover-fit artwork in fill-screen (invisible until the
    // image loads — at which point shimmer hands off to the cover image).
    final foreground = switch (overlay.displayType) {
      CastDisplayType.fitToScreen => Center(
        child: CastAnimatedArtwork(item: item, fit: BoxFit.contain),
      ),
      CastDisplayType.fillScreen => CastAnimatedArtwork(item: item),
      CastDisplayType.tile => _TileCarousel(
        prevUrl: overlay.prevImageUrl,
        currUrl: item.imageUrl,
        nextUrl: overlay.nextImageUrl,
      ),
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        _BlurredBackground(imageUrl: item.imageUrl),
        foreground,
      ],
    );
  }
}

class _BlurredBackground extends StatelessWidget {
  const _BlurredBackground({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isEmpty) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        // TileMode.clamp made explicit: extends edge pixels into the blur
        // kernel so the visible edges don't read as a darker fade-out
        // halo against the surrounding stage.
        ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: 40,
            sigmaY: 40,
            tileMode: TileMode.clamp,
          ),
          child: MallowNetworkImage(imageUrl: imageUrl, logicalSize: 200),
        ),
        // 40% black scrim — pushes the bg back so the cover-fit image,
        // tile peeks, and captions read strongly. Matches the HTML
        // receiver's `brightness(0.6)` on `.bg` (mathematically the same
        // result over an opaque source).
        ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
      ],
    );
  }
}

/// Fully opaque black bar pinned to the bottom: caption on the left,
/// QR card on the right, both vertically centred.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.overlay});

  final CastOverlayConfig overlay;

  @override
  Widget build(BuildContext context) {
    final hasCaption =
        overlay.showCaption &&
        (overlay.title != null || overlay.subtitle != null);
    final hasQr = overlay.showQr && overlay.qrUrl != null;
    return Container(
      // Fixed height — the receiver renders on screens that range from a
      // macOS preview window to a 4K TV, and a scaling bar was producing
      // visibly different layouts across them. 220 fits the 144px QR with
      // 24px vertical padding and leaves room for two-line captions.
      height: _kBarHeight,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Row(
        children: [
          if (hasCaption)
            Expanded(
              child: _Caption(title: overlay.title, subtitle: overlay.subtitle),
            )
          else
            const Spacer(),
          if (hasQr) ...[
            const SizedBox(width: 24),
            _QrCard(url: overlay.qrUrl!),
          ],
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({this.title, this.subtitle});

  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && title!.isNotEmpty)
          Text(
            title!,
            // Editorial face for artwork titles — Newsreader italic Medium.
            // Lighter than the app-side editorialHero (w600) for a less
            // dense feel on a TV at distance.
            style: MallowTheme.editorialHero.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w500,
              fontSize: 36,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              subtitle!,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 18,
                height: 1.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({required this.url});

  final String url;

  static const double _size = 144;
  // Logo pad is sized so the icon (1.26:1 aspect, letterboxed vertically by
  // BoxFit.contain) has visible breathing room on all four sides — a tighter
  // pad reads as off-centre because the wider-than-tall icon sits flush
  // against the left and right edges.
  static const double _logoSize = 36;
  static const double _logoPadding = 4;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PrettyQrView.data(
            data: url,
            // Bumped to high so the centred logo (~24% of width) doesn't
            // exceed the QR's damage tolerance.
            errorCorrectLevel: QrErrorCorrectLevel.H,
            decoration: const PrettyQrDecoration(
              // No quiet zone: white modules sit edge-to-edge on the black bar.
              quietZone: PrettyQrQuietZone.zero,
              // Connected modules with rounded ends/turns (only exposed
              // corners are rounded; adjacent modules flow together). Mirrored
              // 1:1 by the HTML receiver's renderQr() for Chromecast.
              shape: PrettyQrSmoothSymbol(
                color: Colors.white,
                roundFactor: 0.8,
              ),
            ),
          ),
          // Black pad keeps the M legible against the surrounding white
          // QR modules — the bar behind is also black, so it visually
          // continues the bar color.
          Container(
            width: _logoSize,
            height: _logoSize,
            color: Colors.black,
            padding: const EdgeInsets.all(_logoPadding),
            child: SvgPicture.asset(
              'assets/icons/mallow_icon.svg',
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tile-mode carousel
// ---------------------------------------------------------------------------

/// Three-slide horizontal carousel with peek-of-prev / peek-of-next either
/// side of the centred current artwork. Detects forward / backward chains
/// from the URL triple changes and animates the transform with
/// [Curves.easeOutCubic] over [_duration]; non-adjacent jumps snap.
class _TileCarousel extends StatefulWidget {
  const _TileCarousel({
    required this.prevUrl,
    required this.currUrl,
    required this.nextUrl,
  });

  final String? prevUrl;
  final String currUrl;
  final String? nextUrl;

  @override
  State<_TileCarousel> createState() => _TileCarouselState();
}

class _TileCarouselState extends State<_TileCarousel>
    with SingleTickerProviderStateMixin {
  static const double _slideWidthFraction = 0.75;
  static const double _gap = 32;
  static const Duration _duration = Duration(milliseconds: 600);

  late final AnimationController _ac;
  // Slides currently rendered. 3 entries in steady state, 4 mid-animation
  // so the entering peek is in place from the start.
  late List<String?> _slides;
  // Carousel index that should be centred at the start / end of the
  // current animation. Equal during steady state.
  int _startIndex = 1;
  int _endIndex = 1;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(vsync: this, duration: _duration);
    _slides = [widget.prevUrl, widget.currUrl, widget.nextUrl];
  }

  @override
  void didUpdateWidget(_TileCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prevUrl == widget.prevUrl &&
        oldWidget.currUrl == widget.currUrl &&
        oldWidget.nextUrl == widget.nextUrl) {
      return;
    }

    String? direction;
    if (oldWidget.currUrl.isNotEmpty) {
      if (widget.currUrl == oldWidget.nextUrl) {
        direction = 'forward';
      } else if (widget.currUrl == oldWidget.prevUrl) {
        direction = 'backward';
      }
    }

    if (direction == null) {
      // Non-adjacent jump (initial, repeat-one, mode change, etc.) — snap.
      setState(() {
        _slides = [widget.prevUrl, widget.currUrl, widget.nextUrl];
        _startIndex = 1;
        _endIndex = 1;
      });
      _ac.value = 0;
      return;
    }

    if (direction == 'forward') {
      _slides = [
        oldWidget.prevUrl,
        oldWidget.currUrl,
        oldWidget.nextUrl,
        widget.nextUrl,
      ];
      _startIndex = 1;
      _endIndex = 2;
    } else {
      _slides = [
        widget.prevUrl,
        oldWidget.prevUrl,
        oldWidget.currUrl,
        oldWidget.nextUrl,
      ];
      _startIndex = 2;
      _endIndex = 1;
    }
    setState(() {});

    _ac.forward(from: 0).then((_) {
      if (!mounted) return;
      setState(() {
        _slides = [widget.prevUrl, widget.currUrl, widget.nextUrl];
        _startIndex = 1;
        _endIndex = 1;
      });
      _ac.value = 0;
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final sw = w * _slideWidthFraction;
          final step = sw + _gap;
          final startTx = w / 2 - _startIndex * step - sw / 2;
          final endTx = w / 2 - _endIndex * step - sw / 2;
          final rowWidth = _slides.length * sw + (_slides.length - 1) * _gap;

          // The slide Row (and its images) doesn't depend on the
          // animation value — only its horizontal offset does. Build it once
          // and pass it as the cached `child` so each frame rebuilds only the
          // Positioned wrapper, not every slide.
          final row = Row(
            children: [
              for (var i = 0; i < _slides.length; i++) ...[
                SizedBox(
                  // Keying by URL keeps the loaded image state
                  // pinned to the slide as the list shrinks
                  // from 4→3 after animation — without it, slots
                  // shift positionally and the image refetches /
                  // re-runs its load fade, which reads as a
                  // flicker. Nulls fall back to positional reuse.
                  key: _slides[i] != null
                      ? ValueKey<String>(_slides[i]!)
                      : null,
                  width: sw,
                  height: h * 0.92,
                  child: _SlideContent(
                    url: _slides[i],
                    isCurrent: _slides[i] == widget.currUrl,
                  ),
                ),
                if (i < _slides.length - 1) const SizedBox(width: _gap),
              ],
            ],
          );

          return AnimatedBuilder(
            animation: _ac,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_ac.value);
              final tx = startTx + (endTx - startTx) * t;
              return Stack(
                children: [
                  Positioned(
                    left: tx,
                    top: 0,
                    height: h,
                    width: rowWidth,
                    child: child!,
                  ),
                ],
              );
            },
            child: row,
          );
        },
      ),
    );
  }
}

class _SlideContent extends StatelessWidget {
  const _SlideContent({required this.url, required this.isCurrent});

  /// Raw source URL — [CastProgressiveArtwork] resolves the poster and the
  /// full-resolution original from it.
  final String? url;

  /// Whether this slide is the centred artwork. Only that one upgrades to the
  /// full-resolution original: the peeks are ~25% visible at the screen edge,
  /// where the poster is indistinguishable, and pulling three multi-megabyte
  /// originals per slide advance is bandwidth the carousel doesn't need. The
  /// HTML receiver draws the same line (`fullUrlByPoster`).
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final u = url;
    // Transparent fallback so the blurred background layer shows through
    // the slide's letterbox (BoxFit.contain) and the empty peek slots at
    // the ends of an unwrapped queue.
    if (u == null || u.isEmpty) {
      return const SizedBox.shrink();
    }
    // Slides are always stills — `_MediaArea` only routes here for the
    // carousel — so the upgrade is the image original regardless of the
    // item's media type.
    return CastProgressiveArtwork(
      imageUrl: u,
      fit: BoxFit.contain,
      fullUrl: isCurrent
          ? ArtworkMediaResolver.originalCastUrl(imageUrl: u)
          : null,
    );
  }
}
