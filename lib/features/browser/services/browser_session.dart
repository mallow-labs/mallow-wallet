import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:uuid/uuid.dart';

import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../data/browser_repository.dart';
import '../models/browser_models.dart';
import 'browser_domain_policy.dart';
import 'browser_site_icons.dart';

/// Device-wide metadata. Only the selected tab has a live platform WebView.
class BrowserSession extends ChangeNotifier {
  BrowserSession(this.repository);
  static BrowserSession? _instance;
  static BrowserSession get instance => _instance ??= BrowserSession(
    BrowserRepository(sl<SecureWalletStorage>()),
  );

  /// The session if the browser has been used, without creating one: for
  /// app-wide hooks such as the lock, which must not start the browser.
  static BrowserSession? get existing => _instance;

  /// Retires the process-wide session without constructing it when the browser
  /// has not been used. The retired instance stays installed until its writes
  /// drain, so browser callbacks cannot create a replacement during a reset.
  static Future<void> resetForAppWipe() async {
    final session = _instance;
    if (session == null) return;
    try {
      await session.retireForAppWipe();
    } finally {
      if (identical(_instance, session)) _instance = null;
    }
  }

  final BrowserRepository repository;
  final List<BrowserTab> _tabs = [];
  final List<BrowserBookmark> _bookmarks = [];
  final Map<String, Uri> _pendingUrls = {};

  /// Each origin's last title and icon, oldest first. Device-wide like the
  /// bookmarks: closing tabs keeps it, and "Clear browsing data" drops it.
  /// Which of them the user typed is not device-wide: [clear] forgets it.
  final Map<String, BrowserSiteInfo> _sites = {};

  /// The address the user just typed, until the next document commits. Only
  /// the active tab has a WebView, so that commit is the typed navigation,
  /// or, when it failed, a later one that [_sameSite] turns away.
  Uri? _typedPending;

  /// Page screenshots for the tab switcher. Memory only, by design: they can
  /// show balances or addresses, so they are never written to storage and are
  /// dropped with their tab, on "Clear browsing data" and on app reset.
  final Map<String, Uint8List> _thumbnails = {};
  String? _activeId;
  Future<void>? _loading;
  Future<void> _writeTail = Future.value();
  Future<void> _lastWrite = Future.value();
  int _generation = 0;
  bool _retired = false;
  String? error;
  bool isLoaded = false;
  bool? _clearWhileLoading;
  bool _forgetSitesWhileLoading = false;
  bool _forgetTypedWhileLoading = false;
  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  List<BrowserBookmark> get bookmarks => List.unmodifiable(_bookmarks);
  String? get activeId => _activeId;
  BrowserTab? get activeTab =>
      _tabs.where((t) => t.id == _activeId).firstOrNull;
  Uri? pendingUrl(String id) => _pendingUrls[id];

  /// What the browser last saw of [url]'s origin, or null.
  BrowserSiteInfo? site(Uri url) =>
      isBrowserUrl(url) ? _sites[url.origin] : null;

  /// Sites the user typed their way to, most recent first.
  List<BrowserSiteInfo> get typedSites => [
    for (final site in _sites.values.toList().reversed)
      if (site.typed) site,
  ];

  /// Records that the user typed [url] (or picked it from the suggestions),
  /// just before the browser navigates to it. The site is remembered as typed
  /// only once a document on the same site commits, so an address that never
  /// loads is never offered again.
  void noteTyped(Uri url) {
    if (_retired || !isBrowserUrl(url)) return;
    _typedPending = url;
  }

  /// One site for typing purposes: the address typed and the one it settled
  /// on share a registrable domain (`jup.ag` landing on `www.jup.ag`).
  static bool _sameSite(Uri typed, Uri committed) {
    String site(Uri uri) {
      final domain = BrowserDomainPolicy.registrableDomain(uri.host);
      return domain.startsWith('www.') ? domain.substring(4) : domain;
    }

    return site(typed) == site(committed);
  }

  Future<void> load() {
    if (_retired) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    try {
      final data = await repository.load();
      if (_retired || generation != _generation) return;
      if (!_forgetSitesWhileLoading) {
        for (final site in data.sites) {
          _sites[site.origin] = site;
        }
        if (_forgetTypedWhileLoading) _forgetTyped();
      }
      // The start page and tab switcher show these icons first; read the
      // stored drawings before they appear rather than just after.
      if (_clearWhileLoading == null) {
        await BrowserSiteIcons.instance.preload([
          ...data.tabs.map((t) => t.iconUrl),
          ...data.bookmarks.map((b) => _withRememberedIcon(b).iconUrl),
        ]);
        if (_retired || generation != _generation) return;
      }
      if (_clearWhileLoading == null) {
        // Tab titles are not stored with the tab; a restored tab takes its
        // site's remembered one until the page reports its own.
        _tabs.addAll(data.tabs.map(_withRememberedSite));
        _activeId = data.activeId;
        if (activeTab == null) _activeId = _tabs.firstOrNull?.id;
      }
      if (_clearWhileLoading != false) {
        _bookmarks.addAll(data.bookmarks.map(_withRememberedIcon));
      }
    } catch (_) {
      if (_retired || generation != _generation) return;
      error =
          'Browsing data could not be loaded. Clear browsing data to start again.';
    }
    if (_retired || generation != _generation) return;
    isLoaded = true;
    _forgetSitesWhileLoading = false;
    _forgetTypedWhileLoading = false;
    if (_clearWhileLoading != null) {
      _clearWhileLoading = null;
      _changed();
    } else {
      notifyListeners();
    }
  }

  void _changed() {
    if (_retired) return;
    notifyListeners();
    final tabs = List<BrowserTab>.of(_tabs);
    final bookmarks = List<BrowserBookmark>.of(_bookmarks);
    final activeId = _activeId;
    final sites = List<BrowserSiteInfo>.of(_sites.values);
    final write = _writeTail.then(
      (_) => repository.save(tabs, bookmarks, activeId, sites: sites),
    );
    _lastWrite = write;
    _writeTail = write.then<void>(
      (_) {
        if (_retired) return;
        error = null;
        notifyListeners();
      },
      onError: (Object _, StackTrace _) {
        if (_retired) return;
        error = 'Browsing data could not be saved.';
        notifyListeners();
      },
    );
  }

  void open(Uri? url) {
    if (_retired) throw StateError('The browser session was reset.');
    if (!isLoaded) throw StateError('Browser is starting. Please try again.');
    if (_tabs.length >= 20)
      throw StateError('Close a tab before opening another (20 maximum).');
    final tab = BrowserTab(id: const Uuid().v4(), url: url);
    _tabs.add(tab);
    _activeId = tab.id;
    _changed();
  }

  /// Opens a tab with a URL that is shown only after its document commits.
  void openPending(Uri url) {
    if (_retired) throw StateError('The browser session was reset.');
    if (!isLoaded) throw StateError('Browser is starting. Please try again.');
    if (_tabs.length >= 20)
      throw StateError('Close a tab before opening another (20 maximum).');
    final tab = BrowserTab(id: const Uuid().v4());
    _tabs.add(tab);
    _pendingUrls[tab.id] = url;
    _activeId = tab.id;
    _changed();
  }

  /// Starts a URL in a blank tab without claiming that it has loaded.
  void navigatePending(String id, Uri url) {
    if (_retired || !_tabs.any((tab) => tab.id == id)) return;
    _pendingUrls[id] = url;
    notifyListeners();
  }

  void select(String id) {
    if (_retired) return;
    if (!_tabs.any((t) => t.id == id)) return;
    _activeId = id;
    _changed();
  }

  /// A non-HTTPS [iconUrl] is ignored. Changing [url] to another host drops
  /// the tab's icon unless a new one is supplied in the same call.
  void update(String id, {Uri? url, String? title, Uri? iconUrl}) {
    if (_retired) return;
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    if (url != null) {
      _pendingUrls.remove(id);
      final typed = _typedPending;
      _typedPending = null;
      if (typed != null && isBrowserUrl(url) && _sameSite(typed, url)) {
        _markTyped(url);
      }
    }
    final tab = _tabs[index] = _tabs[index].copyWith(
      url: url,
      title: title,
      iconUrl: browserIconUri(iconUrl),
    );
    if (title != null || iconUrl != null) _remember(tab);
    if (iconUrl != null) _refreshBookmarkIcons(tab);
    _changed();
  }

  /// Gives the saved pages on [tab]'s origin the icon the tab just reported.
  /// A bookmark keeps the icon it was saved with otherwise, which is none if
  /// it was saved before the page reported one.
  void _refreshBookmarkIcons(BrowserTab tab) {
    final url = tab.url, icon = tab.iconUrl;
    if (url == null || icon == null || !isBrowserUrl(url)) return;
    for (final (index, bookmark) in _bookmarks.indexed) {
      if (bookmark.url.origin != url.origin || bookmark.iconUrl == icon) {
        continue;
      }
      _bookmarks[index] = BrowserBookmark(
        url: bookmark.url,
        title: bookmark.title,
        iconUrl: icon,
      );
    }
  }

  /// A bookmark saved without an icon takes its site's remembered one.
  BrowserBookmark _withRememberedIcon(BrowserBookmark bookmark) {
    if (bookmark.iconUrl != null) return bookmark;
    final icon = site(bookmark.url)?.iconUrl;
    if (icon == null) return bookmark;
    return BrowserBookmark(
      url: bookmark.url,
      title: bookmark.title,
      iconUrl: icon,
    );
  }

  /// Records [tab]'s title and icon for its origin. The host stands in for a
  /// title until the page reports one, so it never replaces a real one.
  void _remember(BrowserTab tab) {
    final url = tab.url;
    if (url == null || !isBrowserUrl(url)) return;
    final previous = _sites.remove(url.origin);
    final title = tab.title.trim();
    _sites[url.origin] = BrowserSiteInfo(
      origin: url.origin,
      title: title.isEmpty || title == url.host ? previous?.title ?? '' : title,
      iconUrl: tab.iconUrl ?? previous?.iconUrl,
      typed: previous?.typed ?? false,
    );
    _trimSites();
  }

  void _markTyped(Uri url) {
    final previous = _sites.remove(url.origin);
    _sites[url.origin] = BrowserSiteInfo(
      origin: url.origin,
      title: previous?.title ?? '',
      iconUrl: previous?.iconUrl,
      typed: true,
    );
    _trimSites();
  }

  /// Forgets which sites were typed, keeping each one's title and icon: a
  /// bookmark that stays may still be drawn with them.
  void _forgetTyped() {
    _typedPending = null;
    for (final site in _sites.values.toList()) {
      if (!site.typed) continue;
      _sites[site.origin] = BrowserSiteInfo(
        origin: site.origin,
        title: site.title,
        iconUrl: site.iconUrl,
      );
    }
  }

  /// Forgets the oldest site past capacity, sparing typed sites while any
  /// other is left: they are what the address bar suggests.
  void _trimSites() {
    while (_sites.length > BrowserRepository.siteCapacity) {
      final oldest = _sites.values.firstWhere(
        (site) => !site.typed,
        orElse: () => _sites.values.first,
      );
      _sites.remove(oldest.origin);
    }
  }

  BrowserTab _withRememberedSite(BrowserTab tab) {
    final site = tab.url == null ? null : this.site(tab.url!);
    if (site == null) return tab;
    return tab.copyWith(
      title: site.title,
      iconUrl: tab.iconUrl ?? site.iconUrl,
    );
  }

  /// The tab's last in-memory screenshot, or null.
  Uint8List? thumbnail(String tabId) => _thumbnails[tabId];

  /// Stores an encoded PNG/JPEG screenshot for an open tab. Never persisted.
  void setThumbnail(String tabId, Uint8List bytes) {
    if (_retired || !_tabs.any((t) => t.id == tabId)) return;
    final previous = _thumbnails[tabId];
    _thumbnails[tabId] = bytes;
    if (previous != null && !identical(previous, bytes)) _evict(previous);
    notifyListeners();
  }

  void removeThumbnail(String tabId) {
    final removed = _thumbnails.remove(tabId);
    if (removed == null) return;
    _evict(removed);
    if (!_retired) notifyListeners();
  }

  /// Drops every screenshot, e.g. when the app locks.
  void clearThumbnails() {
    if (_thumbnails.isEmpty) return;
    _dropThumbnails();
    if (!_retired) notifyListeners();
  }

  void _dropThumbnails() {
    _thumbnails.values.forEach(_evict);
    _thumbnails.clear();
  }

  /// Drops the decoded screenshot too, not just its bytes: the switcher shows
  /// it through a plain [MemoryImage], which the image cache would otherwise
  /// keep after a lock or a closed tab.
  static void _evict(Uint8List bytes) {
    try {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
    } catch (_) {
      // No painting binding (pure unit tests): nothing was decoded.
    }
  }

  BrowserTab? close(String id) {
    if (_retired) return null;
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return null;
    final removed = _tabs.removeAt(index);
    _pendingUrls.remove(id);
    final thumbnail = _thumbnails.remove(id);
    if (thumbnail != null) _evict(thumbnail);
    if (_activeId == id)
      _activeId = _tabs.isEmpty
          ? null
          : _tabs[index.clamp(0, _tabs.length - 1)].id;
    _changed();
    return removed;
  }

  void restore(BrowserTab tab) {
    if (_retired) return;
    if (_tabs.length >= 20 || _tabs.any((t) => t.id == tab.id)) return;
    _tabs.add(tab);
    _activeId = tab.id;
    _changed();
  }

  void bookmark(BrowserBookmark bookmark, {Uri? replacing}) {
    if (_retired) return;
    final index = _bookmarks.indexWhere(
      (b) => b.url == (replacing ?? bookmark.url),
    );
    _bookmarks.removeWhere((b) => b.url == (replacing ?? bookmark.url));
    _bookmarks.removeWhere((b) => b.url == bookmark.url);
    _bookmarks.insert(
      index < 0 ? _bookmarks.length : index.clamp(0, _bookmarks.length),
      bookmark,
    );
    _changed();
  }

  /// Removes the saved page at [url]. Returns it with the position it held,
  /// for [restoreBookmark], or null if there was none.
  ({BrowserBookmark bookmark, int index})? removeBookmark(Uri url) {
    if (_retired) return null;
    final index = _bookmarks.indexWhere((b) => b.url == url);
    if (index < 0) return null;
    final bookmark = _bookmarks.removeAt(index);
    _changed();
    return (bookmark: bookmark, index: index);
  }

  /// Puts back a page [removeBookmark] took out, where it was, unless the
  /// page has been saved again since.
  void restoreBookmark(({BrowserBookmark bookmark, int index}) removed) {
    if (_retired) return;
    final bookmark = removed.bookmark;
    if (_bookmarks.any((b) => b.url == bookmark.url)) return;
    _bookmarks.insert(removed.index.clamp(0, _bookmarks.length), bookmark);
    _changed();
  }

  /// Moves a saved page to [target]'s position, preserving all other pages.
  void moveBookmark(Uri url, Uri target) {
    if (_retired) return;
    final from = _bookmarks.indexWhere((b) => b.url == url);
    final to = _bookmarks.indexWhere((b) => b.url == target);
    if (from < 0 || to < 0 || from == to) return;
    _bookmarks.insert(to, _bookmarks.removeAt(from));
    _changed();
  }

  /// Closes every tab and forgets which sites were typed. The browser is
  /// cleared when it passes to another Account or Profile, and the address
  /// bar must not offer the next one the addresses the last one typed.
  /// [forgetSites] also drops the remembered site titles and icons, as
  /// "Clear browsing data" does.
  void clear({required bool keepBookmarks, bool forgetSites = false}) {
    if (_retired) return;
    if (!isLoaded) {
      _clearWhileLoading = (_clearWhileLoading ?? true) && keepBookmarks;
      _forgetSitesWhileLoading |= forgetSites;
      _forgetTypedWhileLoading = true;
    }
    _tabs.clear();
    if (forgetSites) {
      _sites.clear();
      _typedPending = null;
    } else {
      _forgetTyped();
    }
    _pendingUrls.clear();
    _dropThumbnails();
    unawaited(BrowserSiteIcons.instance.clear(stored: forgetSites));
    _activeId = null;
    if (!keepBookmarks) _bookmarks.clear();
    error = null;
    _changed();
  }

  Future<void> clearAndFlush({required bool keepBookmarks}) async {
    if (!isLoaded) await load();
    if (_retired) throw StateError('The browser session was reset.');
    clear(keepBookmarks: keepBookmarks, forgetSites: true);
    await Future.wait([flush(), BrowserSiteIcons.instance.settled]);
  }

  Future<void> flush() => _lastWrite;

  /// Invalidates pending loads, blocks later mutations, and replaces any
  /// queued persistence with an empty snapshot.
  Future<void> retireForAppWipe() async {
    _beginRetiring();
    await _drainAndClearPersistence();
  }

  void _beginRetiring() {
    if (_retired) return;
    _retired = true;
    _generation++;
    _tabs.clear();
    _pendingUrls.clear();
    _dropThumbnails();
    unawaited(BrowserSiteIcons.instance.clear(stored: true));
    _bookmarks.clear();
    _sites.clear();
    _typedPending = null;
    _activeId = null;
    error = null;
    isLoaded = false;
    _clearWhileLoading = null;
    _forgetSitesWhileLoading = false;
    _forgetTypedWhileLoading = false;
    notifyListeners();
  }

  Future<void> _drainAndClearPersistence() async {
    await _writeTail;
    await repository.save(const [], const [], null);
    await BrowserSiteIcons.instance.settled;
  }
}
