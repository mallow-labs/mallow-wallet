import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/features/browser/services/browser_domain_policy.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_host_text.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await BrowserDomainPolicy.initialize();
  });
  tearDown(Config.debugOverrides.clear);
  final page = Uri.parse('https://example.com/app');
  const fallback = 'https://example.com/favicon.ico';
  Map<String, String> link(String href, String rel, [String sizes = '']) => {
    'href': href,
    'rel': rel,
    'sizes': sizes,
  };

  test('prefers the largest declared raster icon', () {
    expect(
      pickBrowserFavicon(page, [
        link('https://example.com/favicon.ico', 'icon'),
        link('https://example.com/32.png', 'icon', '32x32'),
        link('https://example.com/192.png', 'icon', '16x16 192x192'),
        link('https://example.com/touch.png', 'apple-touch-icon'),
        link('https://example.com/logo.svg', 'icon', 'any'),
      ]).toString(),
      'https://example.com/192.png',
    );
  });

  test('apple-touch-icon beats an equal or undeclared icon', () {
    expect(
      pickBrowserFavicon(page, [
        link('https://example.com/a.png', 'icon', '180x180'),
        link('https://example.com/touch.png', 'apple-touch-icon'),
      ]).toString(),
      'https://example.com/touch.png',
    );
  });

  test('rejects non-HTTPS, credentialed and malformed entries', () {
    expect(
      pickBrowserFavicon(page, [
        link('http://example.com/a.png', 'icon', '512x512'),
        link('https://u:p@example.com/b.png', 'icon', '512x512'),
        link('javascript:alert(1)', 'icon'),
        {'href': 42, 'rel': 'icon'},
        'not a map',
      ]).toString(),
      fallback,
    );
    expect(pickBrowserFavicon(page, null).toString(), fallback);
    expect(pickBrowserFavicon(page, '{not json').toString(), fallback);
  });

  test('a page that declares no icon gets its origin\'s favicon.ico', () {
    expect(pickBrowserFavicon(page, const []).toString(), fallback);
    expect(
      pickBrowserFavicon(
        Uri.parse('https://shop.example.com:8443/a?b=c#d'),
        const [],
      ).toString(),
      'https://shop.example.com:8443/favicon.ico',
    );
    expect(pickBrowserFavicon(Uri.parse('http://example.com/'), []), isNull);
  });

  test('SVG is used only when the image CDN can rasterise it', () {
    final links = [
      link('https://example.com/favicon.ico', 'icon'),
      link('https://example.com/logo.svg', 'icon', '32x32'),
    ];
    expect(pickBrowserFavicon(page, links).toString(), fallback);
    Config.debugOverrides['IMAGE_CDN_BASE_URL'] = 'https://images.example';
    expect(
      pickBrowserFavicon(page, links).toString(),
      'https://example.com/logo.svg',
    );
    // A large declared raster still wins over the vector mark.
    expect(
      pickBrowserFavicon(page, [
        ...links,
        link('https://example.com/touch.png', 'apple-touch-icon'),
      ]).toString(),
      'https://example.com/touch.png',
    );
  });

  test('accepts the JSON string form Android returns and same-site hosts', () {
    expect(browserRegistrableDomain('cdn.example.com'), 'example.com');
    expect(browserRegistrableDomain('example.com'), 'example.com');
    expect(
      pickBrowserFavicon(
        page,
        '[{"href":"https://cdn.example.com/icon.png","rel":"icon","sizes":"64x64"}]',
      ).toString(),
      'https://cdn.example.com/icon.png',
    );
  });

  test('another site\'s icon is refused for the page\'s own', () {
    expect(
      pickBrowserFavicon(page, [
        link('https://mallow.art/apple-touch-icon.png', 'apple-touch-icon'),
        link('https://example.com.evil.xyz/icon.png', 'icon', '512x512'),
      ]).toString(),
      fallback,
    );
    expect(
      pickBrowserFavicon(Uri.parse('https://shop.example.co.uk/'), [
        link('https://example.co.uk/icon.png', 'icon', '64x64'),
        link('https://other.co.uk/big.png', 'icon', '512x512'),
      ]).toString(),
      'https://example.co.uk/icon.png',
    );
  });

  test('private suffix tenants cannot borrow one another\'s icon', () {
    expect(
      pickBrowserFavicon(Uri.parse('https://alice.github.io/'), [
        link('https://bob.github.io/icon.png', 'icon', '512x512'),
      ]).toString(),
      'https://alice.github.io/favicon.ico',
    );
  });

  group('web app manifest', () {
    Map<String, String> icon(
      String href, {
      String sizes = '',
      String type = '',
      String purpose = '',
    }) => {'href': href, 'sizes': sizes, 'type': type, 'purpose': purpose};

    test('finds a same-site HTTPS manifest and never ranks it as an icon', () {
      final links = [
        link('https://example.com/manifest.json', 'manifest'),
        link('https://example.com/favicon.ico', 'icon'),
      ];
      expect(
        browserManifestUrl(page, links).toString(),
        'https://example.com/manifest.json',
      );
      expect(pickBrowserFavicon(page, links).toString(), fallback);
      expect(
        browserManifestUrl(page, [
          link('http://example.com/manifest.json', 'manifest'),
          link('https://evil.xyz/manifest.json', 'manifest'),
        ]),
        isNull,
      );
      expect(browserManifestUrl(page, '[not json'), isNull);
    });

    test('a larger manifest icon beats the declared links', () {
      expect(
        pickBrowserFavicon(
          page,
          [link('https://example.com/touch.png', 'apple-touch-icon')],
          manifestIcons: [
            icon('https://example.com/192.png', sizes: '192x192'),
            icon('https://example.com/512.png', sizes: '512x512'),
          ],
        ).toString(),
        'https://example.com/512.png',
      );
    });

    test('accepts the JSON string form the page hands back', () {
      expect(
        pickBrowserFavicon(
          page,
          const [],
          manifestIcons:
              '[{"href":"https://example.com/m.png","sizes":"256x256"}]',
        ).toString(),
        'https://example.com/m.png',
      );
      expect(
        pickBrowserFavicon(page, const [], manifestIcons: '').toString(),
        fallback,
      );
    });

    test('skips monochrome masks and ranks maskable below any', () {
      expect(
        pickBrowserFavicon(
          page,
          const [],
          manifestIcons: [
            icon(
              'https://example.com/mono.png',
              sizes: '1024x1024',
              purpose: 'monochrome',
            ),
            icon(
              'https://example.com/mask.png',
              sizes: '512x512',
              purpose: 'maskable',
            ),
            icon(
              'https://example.com/any.png',
              sizes: '512x512',
              purpose: 'any maskable',
            ),
          ],
        ).toString(),
        'https://example.com/any.png',
      );
      expect(
        pickBrowserFavicon(
          page,
          const [],
          manifestIcons: [
            icon(
              'https://example.com/mask.png',
              sizes: '512x512',
              purpose: 'maskable',
            ),
          ],
        ).toString(),
        'https://example.com/mask.png',
      );
    });

    test('holds manifest icons to the same site and scheme rules', () {
      expect(
        pickBrowserFavicon(
          page,
          const [],
          manifestIcons: [
            icon('https://cdn.evil.xyz/512.png', sizes: '512x512'),
            icon('http://example.com/512.png', sizes: '512x512'),
            {'href': 7},
          ],
        ).toString(),
        fallback,
      );
    });

    test('an SVG manifest icon needs the image CDN, even without .svg', () {
      final icons = [icon('https://example.com/icon', type: 'image/svg+xml')];
      expect(
        pickBrowserFavicon(page, const [], manifestIcons: icons).toString(),
        fallback,
      );
      Config.debugOverrides['IMAGE_CDN_BASE_URL'] = 'https://images.example';
      expect(
        pickBrowserFavicon(page, const [], manifestIcons: icons).toString(),
        'https://example.com/icon',
      );
    });
  });
}
