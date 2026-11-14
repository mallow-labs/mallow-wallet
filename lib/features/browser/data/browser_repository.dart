import 'dart:convert';
import 'dart:math' show max;

import '../../../core/security/secure_storage.dart';
import '../models/browser_models.dart';

typedef BrowserMetadata = ({
  List<BrowserTab> tabs,
  List<BrowserBookmark> bookmarks,
  String? activeId,
  List<BrowserSiteInfo> sites,
});

class BrowserRepository {
  BrowserRepository(this._storage);
  final SecureWalletStorage _storage;

  /// Sites remembered for their title and icon, most recent last.
  static const siteCapacity = 100;

  Future<BrowserMetadata> load() async {
    final raw = await _storage.loadBrowserMetadata();
    if (raw == null)
      return (
        tabs: <BrowserTab>[],
        bookmarks: <BrowserBookmark>[],
        activeId: null,
        sites: <BrowserSiteInfo>[],
      );
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != 1)
      throw const FormatException('Unsupported browser data version');
    final tabs = <BrowserTab>[];
    for (final item in (data['tabs'] as List).take(20)) {
      final uri = item['url'] == null
          ? null
          : Uri.tryParse(item['url'] as String);
      if (uri != null && !isBrowserUrl(uri)) continue;
      tabs.add(
        BrowserTab(
          id: item['id'] as String,
          url: uri,
          iconUrl: _icon(item['iconUrl']),
        ),
      );
    }
    final bookmarks = <BrowserBookmark>[];
    for (final item in data['bookmarks'] as List) {
      final uri = Uri.tryParse(item['url'] as String);
      if (uri == null || !isBrowserUrl(uri)) continue;
      bookmarks.add(
        BrowserBookmark(
          url: uri,
          title: item['title'] as String,
          iconUrl: _icon(item['iconUrl']),
        ),
      );
    }
    return (
      tabs: tabs,
      bookmarks: bookmarks,
      activeId: data['activeId'] as String?,
      sites: _sites(data['sites']),
    );
  }

  /// Records written before icons existed have no `iconUrl`; a malformed or
  /// non-HTTPS value is dropped rather than failing the whole load.
  static Uri? _icon(Object? raw) =>
      raw is String ? browserIconUri(Uri.tryParse(raw)) : null;

  /// Records written before sites were remembered have no `sites`. A
  /// malformed entry is skipped: it only costs a site its remembered name.
  static List<BrowserSiteInfo> _sites(Object? raw) {
    if (raw is! List) return [];
    final sites = <String, BrowserSiteInfo>{};
    for (final item in raw.skip(max(0, raw.length - siteCapacity))) {
      if (item is! Map) continue;
      final origin = item['origin'];
      final uri = origin is String ? Uri.tryParse(origin) : null;
      if (uri == null || !isBrowserUrl(uri)) continue;
      final title = item['title'];
      final site = BrowserSiteInfo(
        origin: uri.origin,
        title: title is String ? title : '',
        iconUrl: _storableIcon(_icon(item['iconUrl'])),
        typed: item['typed'] == true,
      );
      sites.remove(site.origin);
      sites[site.origin] = site;
    }
    return sites.values.toList();
  }

  /// Same rule as the tab URL: a query or fragment may carry a session token,
  /// and the icon is re-captured on the next load.
  static Uri? _storableIcon(Uri? icon) =>
      icon != null && !icon.hasQuery && !icon.hasFragment ? icon : null;

  Future<void> save(
    List<BrowserTab> tabs,
    List<BrowserBookmark> bookmarks,
    String? activeId, {
    List<BrowserSiteInfo> sites = const [],
  }) => _storage.storeBrowserMetadata(
    jsonEncode({
      'version': 1,
      'activeId': activeId,
      'tabs': tabs
          .map(
            (tab) => {
              'id': tab.id,
              'url': tab.url == null
                  ? null
                  : browserRestoreUri(tab.url!).toString(),
              if (_storableIcon(tab.iconUrl) case final icon?)
                'iconUrl': icon.toString(),
            },
          )
          .toList(),
      'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
      'sites': [
        for (final site in sites.skip(max(0, sites.length - siteCapacity)))
          {
            'origin': site.origin,
            if (site.title.isNotEmpty) 'title': site.title,
            if (_storableIcon(site.iconUrl) case final icon?)
              'iconUrl': icon.toString(),
            if (site.typed) 'typed': true,
          },
      ],
    }),
  );
}
