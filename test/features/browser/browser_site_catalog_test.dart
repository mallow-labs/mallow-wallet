import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/browser_models.dart';
import 'package:mallow_wallet/features/browser/models/browser_site_catalog.dart';
import 'package:mallow_wallet/features/browser/services/browser_site_catalog_service.dart';

Map<String, Object?> _site(String name, String url, {String? iconUrl}) => {
  'name': name,
  'url': url,
  'iconUrl': ?iconUrl,
};

String _list(List<Object?> sites) => jsonEncode({'version': 1, 'sites': sites});

/// Answers every GET with [body], or fails it when [body] is null.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  String? body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final body = this.body;
    if (body == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('parseBrowserSites', () {
    test('keeps plain HTTPS sites and drops each entry it cannot trust', () {
      final sites = parseBrowserSites(
        _list([
          _site('Tensor', 'https://www.tensor.trade'),
          _site(
            'Orca',
            'https://www.orca.so/pools',
            iconUrl: 'http://insecure.example/icon.png',
          ),
          _site('Plain http', 'http://site.example'),
          _site('Credentials', 'https://user:pass@site.example'),
          _site('Query', 'https://site.example/?ref=1'),
          _site('Port', 'https://site.example:8443'),
          _site('Ｔensor', 'https://lookalike.example'),
          _site('', 'https://empty.example'),
          _site('x' * 41, 'https://long.example'),
          _site('Duplicate', 'https://www.tensor.trade'),
          {'name': 7, 'url': 'https://number.example'},
          'not a site',
        ]),
      )!;
      expect(sites.map((s) => '${s.name} ${s.url} ${s.iconUrl}'), [
        'Tensor https://www.tensor.trade null',
        'Orca https://www.orca.so/pools null',
      ]);
    });

    test('a compiled-in popular name cannot point at another domain', () {
      final sites = parseBrowserSites(
        _list([
          _site('Jupiter', 'https://jup-claim.example'),
          _site('jupiter!', 'https://jupiter.example'),
          _site('Jupiter', 'https://www.jup.ag'),
        ]),
      )!;
      expect(sites.map((s) => s.url), ['https://www.jup.ag']);
    });

    test('only a version-1 list is read', () {
      expect(parseBrowserSites('{"version": 2, "sites": []}'), isNull);
      expect(parseBrowserSites('{"sites": []}'), isNull);
      expect(parseBrowserSites('not json'), isNull);
      expect(parseBrowserSites(null), isNull);
    });

    test('the bundled list reads in full, once per address', () {
      final raw = File(browserSitesAsset).readAsStringSync();
      final entries =
          (jsonDecode(raw) as Map<String, dynamic>)['sites'] as List;
      final sites = parseBrowserSites(raw)!;
      expect(sites, hasLength(entries.length));
      for (final entry in entries.cast<Map<String, dynamic>>()) {
        expect(['solana', 'ethereum', 'tezos'], contains(entry['chain']));
      }
      // Every popular grid site is in it, so the list is the whole catalog.
      final urls = sites.map((s) => s.url).toSet();
      for (final site in [
        ...browserPopularSites,
        ...browserPopularEthereumSites,
        ...browserPopularTezosSites,
      ]) {
        expect(urls, contains(site.url));
      }
    });
  });

  group('BrowserSiteCatalog', () {
    final now = DateTime(2026, 11, 9, 12);
    final bundled = _list([_site('Bundled', 'https://bundled.example')]);
    final published = _list([_site('Published', 'https://published.example')]);

    String cache(DateTime fetchedAt, String list) => jsonEncode({
      'fetchedAt': fetchedAt.millisecondsSinceEpoch,
      'list': jsonDecode(list),
    });

    ({BrowserSiteCatalog catalog, _Adapter adapter, List<String> writes})
    catalog({String? cached, String? body, String url = 'https://list/'}) {
      final adapter = _Adapter(body);
      final writes = <String>[];
      return (
        catalog: BrowserSiteCatalog(
          dio: Dio()..httpClientAdapter = adapter,
          now: () => now,
          url: () => url,
          readCache: () => cached,
          writeCache: (json) async => writes.add(json),
          loadBundled: () async => bundled,
        ),
        adapter: adapter,
        writes: writes,
      );
    }

    List<String> names(BrowserSiteCatalog c) => [
      for (final s in c.sites) s.name,
    ];

    test('fetches over the bundled list and caches what it read', () async {
      final c = catalog(body: published);
      await c.catalog.start();
      expect(names(c.catalog), ['Published']);
      final written = jsonDecode(c.writes.single) as Map<String, dynamic>;
      expect(written['fetchedAt'], now.millisecondsSinceEpoch);
      expect(parseBrowserSites(written['list'])!.single.name, 'Published');
    });

    test('a fresh cache makes no request', () async {
      final c = catalog(
        cached: cache(now.subtract(const Duration(hours: 2)), published),
        body: _list([_site('Newer', 'https://newer.example')]),
      );
      await c.catalog.start();
      expect(names(c.catalog), ['Published']);
      expect(c.adapter.requests, 0);
    });

    test('a stale cache is refetched', () async {
      final c = catalog(
        cached: cache(now.subtract(const Duration(days: 2)), published),
        body: _list([_site('Newer', 'https://newer.example')]),
      );
      await c.catalog.start();
      expect(names(c.catalog), ['Newer']);
    });

    test('offline or malformed keeps what was loaded', () async {
      final offline = catalog();
      await offline.catalog.start();
      expect(names(offline.catalog), ['Bundled']);
      expect(offline.writes, isEmpty);

      final malformed = catalog(
        cached: cache(now.subtract(const Duration(days: 2)), published),
        body: '{"version": 9}',
      );
      await malformed.catalog.start();
      expect(names(malformed.catalog), ['Published']);
      expect(malformed.writes, isEmpty);
    });

    test('with no list configured only the bundled list loads', () async {
      final c = catalog(body: published, url: '');
      await c.catalog.start();
      expect(names(c.catalog), ['Bundled']);
      expect(c.adapter.requests, 0);
    });

    test('starts once', () async {
      final c = catalog(body: published);
      await Future.wait([c.catalog.start(), c.catalog.start()]);
      await c.catalog.start();
      expect(c.adapter.requests, 1);
    });
  });
}
