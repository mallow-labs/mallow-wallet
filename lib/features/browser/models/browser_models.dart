/// Where the address bar sends text that is not a website.
enum BrowserSearchEngine {
  duckDuckGo('DuckDuckGo'),
  google('Google');

  const BrowserSearchEngine(this.label);
  final String label;

  Uri search(String query) => switch (this) {
    duckDuckGo => Uri.https('duckduckgo.com', '/', {'q': query}),
    google => Uri.https('www.google.com', '/search', {'q': query}),
  };
}

/// Parses addresses without allowing credentials or executable URL schemes;
/// anything else is a search on [engine].
Uri browserInputUri(
  String input, {
  BrowserSearchEngine engine = BrowserSearchEngine.duckDuckGo,
}) {
  final value = input.trim();
  if (value.isEmpty) throw const FormatException('Enter a website or search');
  return browserAddressUri(value) ?? engine.search(value);
}

/// The website [input] names, or null when it is a search (or empty). Throws
/// like [browserInputUri] on an explicit scheme the browser will not open.
Uri? browserAddressUri(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  final explicit = Uri.tryParse(value);
  if (explicit?.hasScheme == true) {
    if (!isBrowserUrl(explicit!)) {
      throw const FormatException(
        'Only HTTPS websites without credentials are supported',
      );
    }
    return explicit;
  }
  if (!value.contains(RegExp(r'\s')) && value.contains('.')) {
    final uri = Uri.tryParse('https://$value');
    if (uri != null && isBrowserUrl(uri)) return uri;
  }
  return null;
}

bool isBrowserUrl(Uri uri) =>
    uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;

/// Automatic restoration never persists query/fragment credentials or page text.
Uri browserRestoreUri(Uri uri) => uri.hasQuery || uri.hasFragment
    ? Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      )
    : uri;

/// A site icon is only kept when it is itself a browser-safe HTTPS URL.
Uri? browserIconUri(Uri? uri) => uri != null && isBrowserUrl(uri) ? uri : null;

class BrowserTab {
  BrowserTab({required this.id, this.url, this.title = '', Uri? iconUrl})
    : iconUrl = browserIconUri(iconUrl);
  final String id;
  final Uri? url;
  final String title;

  /// Page-declared icon, captured after load. Never shown as identity: the
  /// origin always comes from [url] / the committed navigation.
  final Uri? iconUrl;

  /// A new host drops the previous site's icon unless one is supplied, so a
  /// tab never shows one site's icon beside another site's address.
  BrowserTab copyWith({Uri? url, String? title, Uri? iconUrl}) => BrowserTab(
    id: id,
    url: url ?? this.url,
    title: title ?? this.title,
    iconUrl:
        iconUrl ??
        (url != null && url.host != this.url?.host ? null : this.iconUrl),
  );
}

/// What the browser last saw of a site: its page title and declared icon, so
/// a return visit shows both as soon as the document commits instead of
/// after the page reports them. Keyed by origin, and decoration only, like
/// the tab's own title and icon.
class BrowserSiteInfo {
  BrowserSiteInfo({
    required this.origin,
    String title = '',
    Uri? iconUrl,
    this.typed = false,
  }) : title = browserSiteTitle(title),
       iconUrl = browserIconUri(iconUrl);
  final String origin;
  final String title;
  final Uri? iconUrl;

  /// The user reached this site by typing its address (or picking it from
  /// the address bar's suggestions) and it loaded, so the address bar offers
  /// it again. A site only ever followed to by a link is not offered.
  final bool typed;
}

/// The longest page title kept for a site.
const browserSiteTitleLength = 200;

String browserSiteTitle(String title) {
  final trimmed = title.trim();
  return trimmed.length <= browserSiteTitleLength
      ? trimmed
      : trimmed.substring(0, browserSiteTitleLength);
}

class BrowserBookmark {
  BrowserBookmark({required this.url, required this.title, Uri? iconUrl})
    : iconUrl = browserIconUri(iconUrl);
  final Uri url;
  final String title;
  final Uri? iconUrl;
  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'title': title,
    if (iconUrl != null) 'iconUrl': iconUrl.toString(),
  };
}

/// A curated start-page site. [iconUrl] is a verified high-resolution icon
/// (apple-touch-icon or large PNG) loaded through the image CDN; null falls
/// back to a monogram tile.
class BrowserPopularSite {
  const BrowserPopularSite({
    required this.name,
    required this.url,
    this.iconUrl,
  });
  final String name;
  final String url;
  final String? iconUrl;

  Uri get uri => Uri.parse(url);
  Uri? get iconUri => iconUrl == null ? null : Uri.parse(iconUrl!);
}

const browserPopularSites = <BrowserPopularSite>[
  BrowserPopularSite(
    name: 'mallow.art',
    url: 'https://mallow.art',
    iconUrl: 'https://mallow.art/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'Jupiter',
    url: 'https://jup.ag',
    iconUrl: 'https://jup.ag/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'Orca',
    url: 'https://www.orca.so/pools',
    iconUrl: 'https://www.orca.so/android-chrome-384x384.png',
  ),
  BrowserPopularSite(
    name: 'Meteora',
    url: 'https://www.meteora.ag',
    iconUrl: 'https://www.meteora.ag/apple/apple-icon-180x180.png',
  ),
  BrowserPopularSite(
    name: 'Raydium',
    url: 'https://raydium.io',
    iconUrl: 'https://raydium.io/logo.png',
  ),
  // The app host redirects to kamino.com, which serves the icon.
  BrowserPopularSite(
    name: 'Kamino',
    url: 'https://app.kamino.finance',
    iconUrl: 'https://kamino.com/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'pump.fun',
    url: 'https://pump.fun',
    iconUrl: 'https://pump.fun/icon2.png',
  ),
  // Titan publishes only a 180 px ICO; the image CDN transcodes it.
  BrowserPopularSite(
    name: 'Titan',
    url: 'https://titan.exchange',
    iconUrl: 'https://titan.exchange/favicon.ico',
  ),
  BrowserPopularSite(
    name: 'Collector Crypt',
    url: 'https://gacha.collectorcrypt.com',
    iconUrl: 'https://gacha.collectorcrypt.com/apple-touch-icon.png',
  ),
  // famousfoxes.com publishes only a 48 px ICO; the image CDN transcodes it.
  BrowserPopularSite(
    name: 'Famous Foxes',
    url: 'https://famousfoxes.com',
    iconUrl: 'https://famousfoxes.com/favicon.ico',
  ),
  BrowserPopularSite(
    name: 'World',
    url: 'https://world.xyz',
    iconUrl: 'https://world.xyz/assets/favicon.png?v=2',
  ),
  BrowserPopularSite(
    name: 'Sol Incinerator',
    url: 'https://sol-incinerator.com',
    iconUrl: 'https://sol-incinerator.com/apple-touch-icon.png',
  ),
];

const browserPopularEthereumSites = <BrowserPopularSite>[
  BrowserPopularSite(
    name: 'OpenSea',
    url: 'https://opensea.io',
    iconUrl: 'https://opensea.io/icons/icon-192x192.png',
  ),
  BrowserPopularSite(
    name: 'SuperRare',
    url: 'https://superrare.com',
    iconUrl: 'https://superrare.com/assets/pwa/apple-icon-180.png',
  ),
  BrowserPopularSite(
    name: 'Verse',
    url: 'https://verse.works',
    iconUrl: 'https://verse.works/apple-icon.png',
  ),
  BrowserPopularSite(
    name: 'Uniswap',
    url: 'https://app.uniswap.org',
    iconUrl: 'https://cdn.app.uniswap.org/images/192x192_App_Icon.png',
  ),
  BrowserPopularSite(
    name: 'Aave',
    url: 'https://app.aave.com',
    iconUrl: 'https://app.aave.com/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'Lido',
    url: 'https://stake.lido.fi',
    iconUrl: 'https://stake.lido.fi/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'Curve',
    url: 'https://www.curve.finance',
    iconUrl: 'https://www.curve.finance/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: '1inch',
    url: 'https://1inch.com',
    iconUrl: 'https://1inch.com/favicon/apple-touch-icon.png',
  ),
];

const browserPopularTezosSites = <BrowserPopularSite>[
  BrowserPopularSite(
    name: 'objkt',
    url: 'https://objkt.com',
    iconUrl: 'https://objkt.com/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'Teia',
    url: 'https://teia.art',
    iconUrl: 'https://teia.art/icons/apple-touch-icon.png?v=1',
  ),
  BrowserPopularSite(
    name: 'Tezos Domains',
    url: 'https://app.tezos.domains',
    iconUrl: 'https://app.tezos.domains/assets/icons/apple-touch-icon.png',
  ),
  BrowserPopularSite(
    name: 'akaSwap',
    url: 'https://akaswap.com',
    iconUrl: 'https://akaswap.com/logo/apple-icon-180x180.png',
  ),
  BrowserPopularSite(
    name: '3Route',
    url: 'https://3route.io',
    iconUrl: 'https://3route.io/favicon.png',
  ),
  BrowserPopularSite(
    name: 'QuipuSwap',
    url: 'https://quipuswap.com',
    iconUrl: 'https://quipuswap.com/favicon.ico',
  ),
  BrowserPopularSite(
    name: 'youves',
    url: 'https://app.youves.com',
    iconUrl: 'https://icons.llamao.fi/icons/protocols/youves.png',
  ),
  BrowserPopularSite(
    name: 'Etherlink',
    url: 'https://bridge.etherlink.com',
    iconUrl: 'https://icons.llamao.fi/icons/chains/rsz_etherlink.jpg',
  ),
];
