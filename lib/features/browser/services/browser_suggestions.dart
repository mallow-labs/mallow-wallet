import '../models/browser_models.dart';
import 'browser_services.dart';
import 'browser_session.dart';

/// Where an address-bar suggestion came from. The order is the tie-break:
/// the user's own sites come before the catalog's.
enum BrowserSuggestionSource { bookmark, typed, catalog }

class BrowserSuggestion {
  const BrowserSuggestion({
    required this.url,
    required this.name,
    required this.source,
    this.iconUrl,
  });

  final Uri url;

  /// A bookmark's title, a catalog site's name, or a typed site's last page
  /// title. Shown under the host, never in place of it: a typed site's title
  /// is the page's own claim.
  final String name;
  final BrowserSuggestionSource source;
  final Uri? iconUrl;
}

/// The most suggestions the address bar shows at once.
const browserSuggestionLimit = 5;

/// Sites for [input] from the user's [bookmarks], the sites they typed their
/// way to ([typedSites], most recent first) and [catalog] (see
/// [browserSuggestionCatalog]).
///
/// A site matches on its address: the host, without `www.`, from its start
/// or from any label but the last (`drift` finds `app.drift.trade`, `trade`
/// does not). Bookmark titles, which the user wrote, and catalog names
/// match too; a typed site's page title does not, so a page cannot claim a
/// name it would then be suggested for.
List<BrowserSuggestion> browserSuggestions(
  String input, {
  required List<BrowserBookmark> bookmarks,
  required List<BrowserSiteInfo> typedSites,
  required List<BrowserPopularSite> catalog,
  BrowserSiteInfo? Function(Uri url)? site,
  int limit = browserSuggestionLimit,
}) {
  final query = browserSuggestionQuery(input);
  if (query.isEmpty) return const [];
  final ranked = <({int rank, int order, BrowserSuggestion suggestion})>[];
  void add(BrowserSuggestion suggestion, {required bool matchName}) {
    final rank = _rank(
      query,
      suggestion.url,
      matchName ? suggestion.name : null,
    );
    if (rank == null) return;
    ranked.add((rank: rank, order: ranked.length, suggestion: suggestion));
  }

  for (final bookmark in bookmarks) {
    if (!isBrowserUrl(bookmark.url)) continue;
    add(
      BrowserSuggestion(
        url: bookmark.url,
        name: bookmark.title,
        source: BrowserSuggestionSource.bookmark,
        iconUrl: bookmark.iconUrl ?? site?.call(bookmark.url)?.iconUrl,
      ),
      matchName: true,
    );
  }
  for (final typed in typedSites) {
    final url = Uri.tryParse(typed.origin);
    if (url == null || !isBrowserUrl(url)) continue;
    add(
      BrowserSuggestion(
        url: url,
        name: typed.title,
        source: BrowserSuggestionSource.typed,
        iconUrl: typed.iconUrl,
      ),
      matchName: false,
    );
  }
  for (final entry in catalog) {
    final url = entry.uri;
    add(
      BrowserSuggestion(
        url: url,
        name: entry.name,
        source: BrowserSuggestionSource.catalog,
        iconUrl: entry.iconUri ?? site?.call(url)?.iconUrl,
      ),
      matchName: true,
    );
  }

  ranked.sort(
    (a, b) => a.rank != b.rank
        ? a.rank.compareTo(b.rank)
        : a.suggestion.source != b.suggestion.source
        ? a.suggestion.source.index.compareTo(b.suggestion.source.index)
        : a.order.compareTo(b.order),
  );
  final seen = <String>{};
  return [
    for (final entry in ranked)
      if (seen.add(_address(entry.suggestion.url))) entry.suggestion,
  ].take(limit).toList();
}

/// [input] as the matcher compares it: lower case, without a leading
/// `https://`, `http://` or `www.`.
String browserSuggestionQuery(String input) {
  var query = input.trim().toLowerCase();
  for (final prefix in const ['https://', 'http://', 'www.']) {
    if (query.startsWith(prefix)) query = query.substring(prefix.length);
  }
  return query;
}

String _bareHost(String host) {
  final lower = host.toLowerCase();
  return lower.startsWith('www.') ? lower.substring(4) : lower;
}

/// Host without `www.` plus path without its trailing slash: what a
/// suggestion is matched and de-duplicated on.
String _address(Uri url) {
  var path = url.path.toLowerCase();
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '${_bareHost(url.host)}$path';
}

final _wordBreak = RegExp(r'[\s._-]+');

/// 0 for an address that starts with [query], 1 for a later host label or a
/// name that starts with it, 2 for a later word of the name; null otherwise.
int? _rank(String query, Uri url, String? name) {
  if ('${_address(url)}/'.startsWith(query)) return 0;
  final labels = _bareHost(url.host).split('.');
  for (var i = 1; i < labels.length - 1; i++) {
    if (labels.skip(i).join('.').startsWith(query)) return 1;
  }
  final lower = name?.trim().toLowerCase() ?? '';
  if (lower.isEmpty) return null;
  if (lower.startsWith(query)) return 1;
  if (lower.split(_wordBreak).any((word) => word.startsWith(query))) return 2;
  return null;
}

/// The well-known sites to suggest: the loaded site list ([browserSites]),
/// then the start page's compiled-in popular sites, which are suggested even
/// before a list has loaded. Duplicates collapse in [browserSuggestions].
List<BrowserPopularSite> browserSuggestionCatalog() => [
  ...browserSites.sites,
  ...browserPopularSites,
  ...browserPopularEthereumSites,
  ...browserPopularTezosSites,
];

extension BrowserSessionSuggestions on BrowserSession {
  /// The address bar's suggestions for [input] from this session's
  /// bookmarks and typed sites, and [catalog] (by default
  /// [browserSuggestionCatalog]).
  List<BrowserSuggestion> suggestions(
    String input, {
    List<BrowserPopularSite>? catalog,
  }) => browserSuggestions(
    input,
    bookmarks: bookmarks,
    typedSites: typedSites,
    catalog: catalog ?? browserSuggestionCatalog(),
    site: site,
  );
}
