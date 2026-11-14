import 'dart:convert';

import '../services/browser_domain_policy.dart';
import 'browser_models.dart';

/// The sites the address bar suggests before the user has typed them: a
/// published list of well-known dApps on the wallet's chains, so a site can
/// be added or dropped without an app release.
///
/// ```json
/// {"version": 1, "sites": [{"name": "Jupiter", "url": "https://jup.ag",
///   "chain": "solana", "iconUrl": "https://jup.ag/apple-touch-icon.png"}]}
/// ```
///
/// `chain` (`solana`, `ethereum` or `tezos`) groups the list for whoever
/// maintains it; the app does not read it. `iconUrl` is optional: a site
/// without one shows a monogram until it has been visited. Spell `url` as
/// the site lands (the host it redirects to, not the one that redirects), so
/// a pick opens without a hop and matches the address the browser commits.
///
/// The app bundles a copy of the list ([browserSitesAsset]) and fetches the
/// published one over it, so a build with no list configured, or offline on
/// first launch, still suggests the bundled sites.
const browserSitesAsset = 'assets/data/browser_sites.json';

/// Bounds on one payload. Far above the real list; they only stop a broken
/// publish from filling preferences or the suggestions.
const _maxSites = 1000;
const _maxNameLength = 40;

/// Letters, digits, space and the punctuation real site names use
/// ("ether.fi", "Revoke.cash", "Sol Incinerator"). No look-alike letters and
/// no bidi controls: a name sits under its host in a suggestion and must not
/// be able to pass for another one.
final _plainName = RegExp(r"^[A-Za-z0-9 .\-_()/&+':!]+$");

/// The sites the start page compiles in. A published entry may not take one
/// of their names for a site on another domain: the list is not signed, so it
/// is trusted no further than its publish path, and "Jupiter" pointing
/// anywhere but Jupiter is the entry a compromised list would most like to add.
///
/// Built per parse, not once: the domain rules load at startup, and a map
/// built before them would compare whole hosts.
Map<String, String> _reservedNames() => {
  for (final site in [
    ...browserPopularSites,
    ...browserPopularEthereumSites,
    ...browserPopularTezosSites,
  ])
    _nameKey(site.name): _siteDomain(site.uri.host),
};

/// A name with case, spacing and punctuation folded away.
String _nameKey(String name) =>
    name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

String _siteDomain(String host) {
  final domain = BrowserDomainPolicy.registrableDomain(host);
  return domain.startsWith('www.') ? domain.substring(4) : domain;
}

/// The sites in a published payload, or null when it is not a version-1
/// list. Each entry that fails a check is dropped on its own, and the first
/// entry for an address wins.
List<BrowserPopularSite>? parseBrowserSites(Object? data) {
  if (data is String) {
    try {
      data = jsonDecode(data);
    } on FormatException {
      return null;
    }
  }
  if (data is! Map<String, dynamic> || data['version'] != 1) return null;
  final sites = data['sites'];
  if (sites is! List) return null;
  final reservedNames = _reservedNames();
  final result = <BrowserPopularSite>[];
  final seen = <String>{};
  for (final entry in sites.take(_maxSites)) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'], url = entry['url'], icon = entry['iconUrl'];
    if (name is! String || url is! String) continue;
    final trimmed = name.trim().replaceAll(RegExp(' +'), ' ');
    if (trimmed.isEmpty ||
        trimmed.length > _maxNameLength ||
        !_plainName.hasMatch(trimmed)) {
      continue;
    }
    final uri = Uri.tryParse(url);
    // A site, not a page state: no query or fragment, no explicit port.
    if (uri == null ||
        !isBrowserUrl(uri) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort) {
      continue;
    }
    final reserved = reservedNames[_nameKey(trimmed)];
    if (reserved != null && reserved != _siteDomain(uri.host)) continue;
    String? iconUrl;
    if (icon is String) {
      final iconUri = Uri.tryParse(icon);
      if (iconUri != null && isBrowserUrl(iconUri)) iconUrl = icon;
    }
    if (!seen.add(uri.toString())) continue;
    result.add(
      BrowserPopularSite(name: trimmed, url: uri.toString(), iconUrl: iconUrl),
    );
  }
  return result;
}

/// [sites] as a version-1 payload, for the cache.
Map<String, Object?> browserSitesPayload(List<BrowserPopularSite> sites) => {
  'version': 1,
  'sites': [
    for (final site in sites)
      {
        'name': site.name,
        'url': site.url,
        if (site.iconUrl != null) 'iconUrl': site.iconUrl,
      },
  ],
};
