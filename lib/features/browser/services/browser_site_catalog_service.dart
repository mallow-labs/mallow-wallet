import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../models/browser_models.dart';
import '../models/browser_site_catalog.dart';

/// The list of well-known sites the address bar suggests: the published one
/// at [Config.browserSitesUrl] when it has been fetched, else the copy
/// bundled with the app ([browserSitesAsset]).
///
/// Started by the browser, not at launch, so a user who never opens it never
/// fetches the list. Fetches only when the cached copy is missing or older
/// than [ttl]: the list moves on the scale of weeks. Never throws. A failed
/// or malformed fetch keeps what is loaded, and the next launch tries again.
class BrowserSiteCatalog extends ChangeNotifier {
  BrowserSiteCatalog({
    Dio? dio,
    DateTime Function()? now,
    String Function()? url,
    String? Function()? readCache,
    Future<void> Function(String json)? writeCache,
    Future<String> Function()? loadBundled,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 15),
             ),
           ),
       _now = now ?? DateTime.now,
       _url = url ?? (() => Config.browserSitesUrl),
       _readCache = readCache ?? _prefsCache,
       _writeCache = writeCache ?? _prefsWrite,
       _loadBundled =
           loadBundled ?? (() => rootBundle.loadString(browserSitesAsset));

  static const ttl = Duration(days: 1);

  final Dio _dio;
  final DateTime Function() _now;
  final String Function() _url;
  final String? Function() _readCache;
  final Future<void> Function(String json) _writeCache;
  final Future<String> Function() _loadBundled;

  List<BrowserPopularSite> _sites = const [];
  Future<void>? _started;

  /// The sites, in list order. Empty until [start] has read a list.
  List<BrowserPopularSite> get sites => _sites;

  /// Loads the cached or bundled list, then fetches the published one if the
  /// cache is missing or stale. Runs once; later calls return the same
  /// future.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    final cachedAt = _loadCache();
    if (cachedAt == null) await _loadBundledList();
    if (cachedAt != null && _now().difference(cachedAt) < ttl) return;
    final url = _url();
    if (url.isEmpty) return;
    await _fetch(url);
  }

  /// The cache's timestamp, or null when there is no readable cache.
  DateTime? _loadCache() {
    try {
      final raw = _readCache();
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final sites = parseBrowserSites(json['list']);
      if (sites == null) return null;
      _set(sites);
      return DateTime.fromMillisecondsSinceEpoch(json['fetchedAt'] as int);
    } catch (e) {
      debugPrint('[BrowserSiteCatalog] ignoring unreadable cache: $e');
      return null;
    }
  }

  Future<void> _loadBundledList() async {
    try {
      final sites = parseBrowserSites(await _loadBundled());
      if (sites != null) _set(sites);
    } catch (e) {
      debugPrint('[BrowserSiteCatalog] bundled list unreadable: $e');
    }
  }

  Future<void> _fetch(String url) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        url,
        options: Options(responseType: ResponseType.json),
      );
    } catch (e) {
      debugPrint('[BrowserSiteCatalog] site list fetch failed: $e');
      return;
    }
    final sites = parseBrowserSites(response.data);
    if (sites == null) {
      debugPrint('[BrowserSiteCatalog] ignoring malformed site list');
      return;
    }
    _set(sites);
    try {
      await _writeCache(
        jsonEncode({
          'fetchedAt': _now().millisecondsSinceEpoch,
          'list': browserSitesPayload(sites),
        }),
      );
    } catch (e) {
      // The list is live for this session; only the next launch's head start
      // is lost.
      debugPrint('[BrowserSiteCatalog] could not cache site list: $e');
    }
  }

  void _set(List<BrowserPopularSite> sites) {
    _sites = List.unmodifiable(sites);
    notifyListeners();
  }

  static String? _prefsCache() => sl.isRegistered<PreferencesService>()
      ? sl<PreferencesService>().browserSitesCache
      : null;

  static Future<void> _prefsWrite(String json) async {
    if (sl.isRegistered<PreferencesService>()) {
      await sl<PreferencesService>().setBrowserSitesCache(json);
    }
  }
}
