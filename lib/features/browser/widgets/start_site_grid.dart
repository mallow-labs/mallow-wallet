import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tappable.dart';
import '../models/browser_models.dart';
import 'browser_site_tile.dart';

/// Popular sites: a home-screen style grid of site tiles in catalog
/// order. Four columns, dropping to three and then two as the text grows so
/// labels wrap between words instead of inside them.
class StartSiteGrid extends StatelessWidget {
  const StartSiteGrid({required this.sites, required this.onOpen, super.key});
  final List<BrowserPopularSite> sites;
  final ValueChanged<BrowserPopularSite> onOpen;

  static const _tile = 60.0;
  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final label = MediaQuery.textScalerOf(context).scale(12);
    final largeText = label > 16;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = label > 20 ? 2 : (largeText ? 3 : 4);
        final width = (constraints.maxWidth - _gap * (columns - 1)) / columns;
        return Wrap(
          spacing: _gap,
          runSpacing: 16,
          children: [
            for (final site in sites)
              SizedBox(
                width: width,
                child: _SiteCell(
                  site: site,
                  twoLineLabel: largeText,
                  onTap: () => onOpen(site),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SiteCell extends StatelessWidget {
  const _SiteCell({
    required this.site,
    required this.twoLineLabel,
    required this.onTap,
  });
  final BrowserPopularSite site;
  final bool twoLineLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      button: true,
      label: 'Open ${site.name}',
      excludeSemantics: true,
      child: Tappable(
        onTap: onTap,
        semanticButton: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrowserSiteTile(
              host: site.uri.host,
              iconUrl: site.iconUri,
              size: StartSiteGrid._tile,
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              site.name,
              maxLines: twoLineLabel ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: MallowTheme.uiLabel.copyWith(
                fontSize: 12,
                height: 16 / 12,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
