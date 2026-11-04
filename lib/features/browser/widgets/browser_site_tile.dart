import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_image_cache_manager.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../services/browser_site_icons.dart';
import 'browser_host_text.dart';

/// A site's squircle icon: the icon the page drew for itself when this
/// session has one ([BrowserSiteIcons]), else its HTTPS icon through the image
/// CDN when known, otherwise (and while loading or after an error) a
/// Newsreader monogram on a tint picked deterministically from [host].
///
/// Decoration only. The tile is never proof of identity: pair it with the
/// natively committed origin text wherever the user makes a trust decision.
class BrowserSiteTile extends StatelessWidget {
  const BrowserSiteTile({
    required this.host,
    required this.size,
    this.iconUrl,
    this.connected = false,
    this.semanticLabel,
    super.key,
  });

  final String host;
  final Uri? iconUrl;

  /// Edge length in logical pixels; the corner radius and monogram scale with it.
  final double size;

  /// Draws the positive "connected" dot on the bottom-right corner.
  final bool connected;

  /// Read by screen readers; the tile is decorative when null.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.3);
    final monogram = _Monogram(host: host, size: size, radius: radius);
    final icon = iconUrl;
    Widget tile = icon == null
        ? monogram
        : ListenableBuilder(
            listenable: BrowserSiteIcons.instance,
            builder: (context, _) {
              final drawn = BrowserSiteIcons.instance[icon];
              if (drawn != null) {
                return ClipRRect(
                  borderRadius: radius,
                  child: Image.memory(
                    drawn,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => monogram,
                  ),
                );
              }
              return MallowNetworkImage(
                imageUrl: icon.toString(),
                // Its own cache, so clearing browsing data can erase it.
                cacheManager: MallowImageCacheManager.browserSiteIcons,
                logicalSize: size,
                width: size,
                height: size,
                borderRadius: radius,
                placeholderBuilder: (_) => monogram,
                errorBuilder: (_) => monogram,
              );
            },
          );
    if (connected) {
      final dot = (size * 0.3).clamp(9.0, 16.0);
      final ring = dot >= 12 ? 2.5 : 2.0;
      final colors = context.mallowColors;
      tile = Stack(
        clipBehavior: Clip.none,
        children: [
          tile,
          Positioned(
            right: -dot / 3,
            bottom: -dot / 3,
            child: Container(
              key: const Key('site-tile-connected'),
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: colors.positive,
                shape: BoxShape.circle,
                border: Border.all(color: colors.bgSurface, width: ring),
              ),
            ),
          ),
        ],
      );
    }
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: true,
      child: SizedBox.square(dimension: size, child: tile),
    );
  }
}

/// The registrable name of [host] without its public suffix: `jup` for
/// `jup.ag`, `collectorcrypt` for `gacha.collectorcrypt.com`.
@visibleForTesting
String browserSiteName(String host) {
  final labels = browserRegistrableDomain(host).split('.')
    ..removeWhere((label) => label.isEmpty);
  return labels.firstOrNull ?? '';
}

bool _isMallow(String host) {
  final lower = host.toLowerCase();
  return lower == 'mallow.art' || lower.endsWith('.mallow.art');
}

class _Monogram extends StatelessWidget {
  const _Monogram({
    required this.host,
    required this.size,
    required this.radius,
  });

  final String host;
  final double size;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final name = browserSiteName(host);
    final mallow = _isMallow(host);
    final letter = name.isEmpty
        ? '·'
        // The brand is always written lower-case.
        : mallow
        ? name.characters.first
        : name.characters.first.toUpperCase();
    final (fill, ink, border) = mallow
        ? (colors.accent, colors.textOnAccent, null)
        : switch (name.codeUnits.fold(0, (sum, unit) => sum + unit) % 3) {
            0 => (colors.textPrimary, colors.bgSurface, null),
            1 => (colors.surfaceMuted, colors.textPrimary, null),
            _ => (colors.bgSurface, colors.textPrimary, colors.dividerLight),
          };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        letter,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: MallowTheme.editorialHero.copyWith(
          fontSize: size * 0.5,
          height: 1,
          letterSpacing: 0,
          color: ink,
        ),
      ),
    );
  }
}
