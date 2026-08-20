import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/mallow_image.dart';
import '../../../core/utils/mux.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/mallow_image_cache_manager.dart';
import '../services/home_bloc.dart';

/// Largest rendered logical dimension of a spotlight tile. Shared between the
/// rendered [MallowNetworkImage] and the eager precache so both resolve to the
/// same CDN bucket and in-memory decode cache key.
const double _spotlightLogicalSize = 400;

class SpotlightCarousel extends StatefulWidget {
  const SpotlightCarousel({
    required this.artworks,
    this.refreshing = false,
    this.onArtworkLongPress,
    super.key,
  });

  final List<SpotlightArtwork> artworks;

  /// Whether the home feed is currently revalidating
  /// ([HomeLoaded.isRefreshing]). When a refresh returns unchanged data the
  /// bloc skips re-emitting spotlightArtworks, so the list stays identical —
  /// but this flag still edges true→false on every refresh cycle. The carousel
  /// keys its failed-tile ban reset to that edge (see
  /// [_SpotlightCarouselState.didUpdateWidget]).
  final bool refreshing;

  /// Long-press on a spotlight tile opens the artwork context menu.
  final ValueChanged<SpotlightArtwork>? onArtworkLongPress;

  @override
  State<SpotlightCarousel> createState() => _SpotlightCarouselState();
}

class _SpotlightCarouselState extends State<SpotlightCarousel> {
  late final PageController _pageController;
  int _currentPage = 0;

  /// URLs of tiles whose poster failed to load *and* that have no inline video
  /// to fall back on. Such tiles are removed from the carousel so a broken /
  /// placeholder tile is never shown. Reset on every refresh cycle and on a
  /// genuinely new artworks list (see [didUpdateWidget]) so a transient failure
  /// is not a permanent, session-long ban.
  final Set<String> _failedUrls = {};

  /// A tile keeps playing (and stays tappable) when it carries a Mux stream, so
  /// a failed *poster* must not delete it — only plain-image tiles are dropped.
  /// Mirrors [MallowArtworkMedia]'s own video gate exactly.
  static bool _isVideoBacked(SpotlightArtwork a) =>
      Mux.previewId(a.playbackId, a.clipPlaybackId) != null;

  /// Tiles that still have a usable image, in original order.
  List<SpotlightArtwork> get _visibleArtworks => widget.artworks
      .where((a) => a.imageUrl.isNotEmpty && !_failedUrls.contains(a.imageUrl))
      .toList();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  /// Drops a tile once its image fails to load. Runs post-frame because
  /// [MallowArtworkMedia.errorBuilder] fires during build, where [setState]
  /// is illegal.
  void _markFailed(String url) {
    if (url.isEmpty || _failedUrls.contains(url)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _failedUrls.contains(url)) return;
      // Index of the tile about to be removed, in the list the PageView is
      // currently showing (before it is dropped).
      final removedIndex = _visibleArtworks.indexWhere(
        (a) => a.imageUrl == url,
      );
      final previousPage = _currentPage;
      setState(() => _failedUrls.add(url));
      final maxPage = _visibleArtworks.length - 1;
      if (maxPage < 0) return;
      // Removing a tile strictly *before* the current page shifts every later
      // tile one slot toward the front. Left unadjusted, the unchanged PageView
      // index would then point at a different artwork under the user's finger —
      // and a tap would open the wrong item. Decrement so the same artwork stays
      // in view.
      if (removedIndex >= 0 && removedIndex < _currentPage) {
        _currentPage -= 1;
      }
      // Clamp when the removed tile was the (former) last page.
      if (_currentPage > maxPage) _currentPage = maxPage;
      if (_currentPage != previousPage && _pageController.hasClients) {
        _pageController.jumpToPage(_currentPage);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheAll();
  }

  @override
  void didUpdateWidget(SpotlightCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Refresh-cycle edge: HomeBloc skips re-emitting spotlightArtworks when a
    // refresh returns unchanged data (_revalidate's _sectionUnchanged guard), so
    // the list stays the *same instance* across the common pull-to-refresh. The
    // isRefreshing flag, however, flips true then false on every refresh — any
    // transition of it means a refresh cycle happened, so lift the failure ban
    // and give transiently-failed tiles another chance. Must run BEFORE the
    // identical-list early return below.
    final refreshEdge = oldWidget.refreshing != widget.refreshing;
    if (refreshEdge) _failedUrls.clear();

    // A rebuild with the same list instance and no refresh edge carries no new
    // signal — keep the current failure set so a persistently-404ing poster
    // doesn't flicker back in on every unrelated rebuild.
    if (identical(oldWidget.artworks, widget.artworks)) return;

    // A genuinely re-delivered list also lifts the ban (new data deserves a
    // clean slate). build() runs right after didUpdateWidget, so no setState is
    // needed for either clear. The within-cycle ban still holds via
    // [_markFailed], so a persistently-404ing poster doesn't flicker within a
    // delivery.
    _failedUrls.clear();

    // Only re-warm the CDN cache when the actual images changed; a same-URL
    // re-delivery already has its entries cached.
    if (!_sameImages(oldWidget.artworks, widget.artworks)) {
      _precacheAll();
    }
  }

  /// True when both lists reference the same spotlight images in the same order.
  /// Content comparison (not reference identity) so an equal-data refresh is not
  /// mistaken for a brand-new set that needs a redundant precache pass.
  static bool _sameImages(List<SpotlightArtwork> a, List<SpotlightArtwork> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].imageUrl != b[i].imageUrl) return false;
    }
    return true;
  }

  /// Eagerly fetches every spotlight image so swiping to a later page shows it
  /// instantly instead of kicking off a network fetch on demand. The provider
  /// here mirrors what [MallowNetworkImage] builds (same CDN URL, decode cap
  /// and cache manager) so the warmed entry — on disk and in memory — is the
  /// one the [PageView] tile reads back.
  void _precacheAll() {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cap = (_spotlightLogicalSize * dpr).ceil().clamp(1, 4096);
    for (final artwork in widget.artworks) {
      if (artwork.imageUrl.isEmpty) continue;
      final url = MallowImage.cdnUrl(
        artwork.imageUrl,
        logicalPx: _spotlightLogicalSize,
        dpr: dpr,
      );
      precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            cacheManager: MallowImageCacheManager.instance,
          ),
          width: cap,
        ),
        context,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artworks = _visibleArtworks;
    // No usable tiles → collapse the whole section, header included.
    if (artworks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: MallowTheme.spacing26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Text(
              'Your daily spotlight',
              style: MallowTheme.editorialQuote,
            ),
          ),
          const SizedBox(height: MallowTheme.spacing12),
          AspectRatio(
            aspectRatio: 357 / 171,
            child: PageView.builder(
              controller: _pageController,
              itemCount: artworks.length,
              onPageChanged: (index) => setState(() => _currentPage = index),
              itemBuilder: (context, index) {
                final artwork = artworks[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacing20,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      if (artwork.mintAccount.isNotEmpty) {
                        context.push(
                          AppRoutes.artworkDetailPath(artwork.mintAccount),
                        );
                      }
                    },
                    onLongPress:
                        widget.onArtworkLongPress != null &&
                            artwork.mintAccount.isNotEmpty
                        ? () => widget.onArtworkLongPress!(artwork)
                        : null,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        MallowTheme.radiusPrimary,
                      ),
                      child: MallowArtworkMedia(
                        imageUrl: artwork.imageUrl,
                        playbackId: artwork.playbackId,
                        clipPlaybackId: artwork.clipPlaybackId,
                        nsfw: artwork.nsfw,
                        logicalSize: _spotlightLogicalSize,
                        // errorBuilder fires on POSTER failure. A plain-image
                        // tile then has nothing to show, so drop it from the
                        // carousel (render blank for the single frame before
                        // removal rather than flashing a placeholder). A
                        // video-backed tile still plays its Mux stream over the
                        // poster and stays tappable, so it must be kept — the
                        // blank poster simply sits under the inline player.
                        errorBuilder: (_) {
                          if (!_isVideoBacked(artwork)) {
                            _markFailed(artwork.imageUrl);
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (artworks.length > 1) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(artworks.length, (index) {
                final isActive = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: isActive ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: isActive
                        ? context.mallowColors.textPrimary
                        : context.mallowColors.textTertiary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}
