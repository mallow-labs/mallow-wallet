import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_domain_policy.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_site_tile.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_image_cache_manager.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';

void main() {
  setUpAll(BrowserDomainPolicy.initialize);
  Future<void> pump(WidgetTester tester, Widget child, {ThemeData? theme}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: theme ?? MallowTheme.lightTheme,
          home: Scaffold(body: Center(child: child)),
        ),
      );

  BoxDecoration monogramBox(WidgetTester tester) => tester
      .widgetList<Container>(find.byType(Container))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.borderRadius != null);

  test('monogram names skip product subdomains and public suffixes', () {
    expect(browserSiteName('jup.ag'), 'jup');
    expect(browserSiteName('www.orca.so'), 'orca');
    expect(browserSiteName('app.kamino.finance'), 'kamino');
    expect(browserSiteName('gacha.collectorcrypt.com'), 'collectorcrypt');
    expect(browserSiteName('shop.example.co.uk'), 'example');
    expect(browserSiteName('localhost'), 'localhost');
    expect(browserSiteName(''), '');
  });

  testWidgets('without an icon the tile is a monogram of the site', (
    tester,
  ) async {
    await pump(
      tester,
      const BrowserSiteTile(host: 'app.kamino.finance', size: 60),
    );
    expect(find.text('K'), findsOneWidget);
    expect(find.byType(MallowNetworkImage), findsNothing);
    expect(monogramBox(tester).borderRadius, BorderRadius.circular(18));
  });

  testWidgets('mallow.art is always the lower-case accent monogram', (
    tester,
  ) async {
    for (final theme in [MallowTheme.lightTheme, MallowTheme.darkTheme]) {
      await pump(
        tester,
        const BrowserSiteTile(host: 'mallow.art', size: 40),
        theme: theme,
      );
      // Let the light-to-dark theme animation finish.
      await tester.pumpAndSettle();
      final colors = theme.extension<MallowColors>()!;
      expect(find.text('m'), findsOneWidget);
      expect(monogramBox(tester).color, colors.accent);
      expect(
        tester.widget<Text>(find.text('m')).style?.color,
        colors.textOnAccent,
      );
    }
  });

  testWidgets('the same host always gets the same tint', (tester) async {
    await pump(tester, const BrowserSiteTile(host: 'www.orca.so', size: 40));
    final first = monogramBox(tester);
    await pump(tester, const BrowserSiteTile(host: 'orca.so', size: 40));
    expect(monogramBox(tester).color, first.color);
  });

  testWidgets('an icon loads through MallowNetworkImage with the raw URL', (
    tester,
  ) async {
    final icon = Uri.parse('https://jup.ag/apple-touch-icon.png');
    await pump(
      tester,
      BrowserSiteTile(host: 'jup.ag', iconUrl: icon, size: 60),
    );
    final image = tester.widget<MallowNetworkImage>(
      find.byType(MallowNetworkImage),
    );
    expect(image.imageUrl, icon.toString());
    expect(image.logicalSize, 60);
    expect(image.cdnFit, 'cover');
    // The browser's own disk cache, which "Clear browsing data" empties: the
    // shared image cache would keep the visited site's icon URL.
    expect(image.cacheManager, same(MallowImageCacheManager.browserSiteIcons));
    // Loading (and any failure) shows the monogram, not a grey box.
    expect(find.text('J'), findsOneWidget);
  });

  testWidgets('connected draws the positive dot and labels the tile', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      const BrowserSiteTile(
        host: 'jup.ag',
        size: 20,
        connected: true,
        semanticLabel: 'jup.ag, connected',
      ),
    );
    final dot = tester.widget<Container>(
      find.byKey(const Key('site-tile-connected')),
    );
    final decoration = dot.decoration! as BoxDecoration;
    expect(decoration.color, MallowColors.light.positive);
    expect(decoration.border!.top.color, MallowColors.light.bgSurface);
    expect(find.bySemanticsLabel('jup.ag, connected'), findsOneWidget);
    handle.dispose();
  });
}
