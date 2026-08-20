import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
// Also supplies `Uint8List` for the `HttpClientAdapter` fakes below.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_verified_token_list_service.dart';

/// Serves a canned `/tokens/v2/tag?query=verified` payload and counts fetches,
/// so the tests can prove the ~5 MB list is downloaded once and then searched
/// entirely from Drift.
class _CatalogAdapter implements HttpClientAdapter {
  _CatalogAdapter(this.tokens);

  final List<Map<String, Object?>> tokens;
  int callCount = 0;
  final List<String> queries = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    queries.add(options.queryParameters['query'] as String? ?? '');
    return ResponseBody.fromString(
      jsonEncode(tokens),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _token(
  String mint,
  String symbol,
  String name, {
  int decimals = 6,
  String? icon,
  double? buyVolume,
  double? sellVolume,
}) => {
  'id': mint,
  'symbol': symbol,
  'name': name,
  'decimals': decimals,
  'icon': icon,
  if (buyVolume != null || sellVolume != null)
    'stats24h': {'buyVolume': buyVolume, 'sellVolume': sellVolume},
};

/// The buy-side picker used to be limited to the user's balances plus ~20
/// hardcoded registry mints — any other verified token was unreachable. This
/// service is what makes the rest of Jupiter's verified set searchable, so
/// these tests pin the properties the picker depends on: the catalog populates
/// itself on first use, is not re-downloaded per keystroke, and ranks the hit
/// the user meant above the ones that merely contain their query.
void main() {
  const solMint = 'So11111111111111111111111111111111111111112';
  const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  const bonkMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';

  late MallowDatabase db;

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('populates the catalog on the first search', () async {
    final adapter = _CatalogAdapter([
      _token(usdcMint, 'USDC', 'USD Coin', icon: 'https://ex.test/usdc.png'),
    ]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // Cold cache: the search itself must trigger the fetch, otherwise the
    // user's first-ever query silently returns nothing.
    final hits = await service.search('usdc');

    expect(adapter.callCount, 1);
    expect(adapter.queries.single, 'verified');
    expect(hits, hasLength(1));
    expect(hits.single.mint, usdcMint);
    expect(hits.single.symbol, 'USDC');
    expect(hits.single.iconUrl, 'https://ex.test/usdc.png');
  });

  test('does not re-download the catalog for later searches', () async {
    final adapter = _CatalogAdapter([
      _token(usdcMint, 'USDC', 'USD Coin'),
      _token(bonkMint, 'Bonk', 'Bonk'),
    ]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    await service.search('usdc');
    await service.search('bonk');
    await service.search('us');

    // The payload is ~5 MB — a fetch per keystroke would be unusable on mobile.
    expect(adapter.callCount, 1);
  });

  test('concurrent first callers share one fetch', () async {
    final adapter = _CatalogAdapter([_token(usdcMint, 'USDC', 'USD Coin')]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // The sheet warms the cache on open while the user's first keystroke also
    // asks for it; un-coalesced that is two concurrent 5 MB downloads.
    await Future.wait([
      service.ensureCached(),
      service.search('usdc'),
      service.search('usd'),
    ]);

    expect(adapter.callCount, 1);
  });

  test(
    'ranks an exact symbol match above tokens that merely contain it',
    () async {
      final adapter = _CatalogAdapter([
        _token(
          'Mint1111111111111111111111111111111111111111',
          'JITOSOL',
          'Jito Staked SOL',
        ),
        _token(
          'Mint2222222222222222222222222222222222222222',
          'MSOL',
          'Marinade SOL',
        ),
        _token(solMint, 'SOL', 'Wrapped SOL', decimals: 9),
      ]);
      final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

      final hits = await service.search('SOL');

      // Every one of these contains "SOL"; burying the real SOL under the
      // derivatives is how a user picks the wrong mint.
      expect(hits.first.mint, solMint);
      expect(hits.map((t) => t.mint), containsAll([solMint]));
    },
  );

  test('finds a token by its exact mint address', () async {
    final adapter = _CatalogAdapter([_token(bonkMint, 'Bonk', 'Bonk')]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // Pasting a mint is how users reach a token whose symbol they don't know.
    final hits = await service.search(bonkMint);

    expect(hits.single.mint, bonkMint);
  });

  test('treats SQL wildcards in the query literally', () async {
    final adapter = _CatalogAdapter([
      _token(usdcMint, 'USDC', 'USD Coin'),
      _token(bonkMint, 'Bonk', 'Bonk'),
    ]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // Unescaped, `%` and `_` are LIKE wildcards — typing either would dump the
    // whole catalog into the picker as if everything matched.
    expect(await service.search('%'), isEmpty);
    expect(await service.search('_'), isEmpty);
    expect(await service.search('US_C'), isEmpty);
  });

  test('serves the previous catalog when a refresh fails', () async {
    final adapter = _CatalogAdapter([_token(usdcMint, 'USDC', 'USD Coin')]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);
    await service.search('usdc');

    // A later session with no network must still search what is on disk rather
    // than emptying the picker.
    final offline = JupiterVerifiedTokenListService.withAdapter(
      db,
      _ThrowingAdapter(),
    );
    final hits = await offline.search('usdc');

    expect(hits.single.mint, usdcMint);
  });

  test('a failed cold fetch degrades to empty instead of throwing', () async {
    final service = JupiterVerifiedTokenListService.withAdapter(
      db,
      _ThrowingAdapter(),
    );

    // The catalog is a supplement to the held/registry tokens — it must never
    // be able to break the picker.
    expect(await service.search('usdc'), isEmpty);
  });

  test('a database failure does not escape ensureCached', () async {
    final brokenDb = _CacheTimeThrowingDatabase();
    addTearDown(brokenDb.close);
    final service = JupiterVerifiedTokenListService.withAdapter(
      brokenDb,
      _CatalogAdapter([_token(usdcMint, 'USDC', 'USD Coin')]),
    );

    // The swap sheet warms the cache with `unawaited(ensureCached())`, so a DB
    // error escaping here is not caught by anyone — it becomes an unhandled
    // zone error and a Sentry report for a cache warm nobody was waiting on.
    await expectLater(service.ensureCached(), completes);
  });

  test('does not re-attempt a failed fetch on every later search', () async {
    final adapter = _ThrowingAdapter();
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    expect(await service.search('usdc'), isEmpty);
    expect(await service.search('usdc'), isEmpty);
    expect(await service.search('bonk'), isEmpty);

    // Each attempt costs a 15s connect / 60s receive timeout offline. Retrying
    // per keystroke leaves the user staring at the catalog spinner for minutes
    // instead of just seeing the registry + held tokens.
    expect(adapter.callCount, 1);
  });

  test('serves cached rows without waiting on a slow refresh', () async {
    // Two days old, so the 24h TTL forces a refresh on the next use.
    final staleAt =
        DateTime.now()
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch ~/
        1000;
    await db.replaceJupiterTokenList([
      CachedJupiterTokenListCompanion(
        mint: const Value(usdcMint),
        symbol: const Value('USDC'),
        name: const Value('USD Coin'),
        decimals: const Value(6),
        cachedAt: Value(staleAt),
      ),
    ]);
    final adapter = _BlockingAdapter();
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // A stale cache is still a usable cache. Awaiting the refresh would hold
    // the picker behind the full receive timeout on a slow network while the
    // row the user is typing for is already on disk.
    final hits = await service
        .search('usdc')
        .timeout(const Duration(seconds: 5));

    expect(hits.single.mint, usdcMint);
    expect(hits.single.decimals, 6);

    // The refresh still has to happen — just behind the search, not in front
    // of it, so the stale catalog is replaced before the next sheet open.
    await pumpEventQueue();
    expect(adapter.started, isTrue, reason: 'refresh should still be started');

    adapter.release();
    await pumpEventQueue();
  });

  test('skips a token whose decimals are missing or non-numeric', () async {
    final adapter = _CatalogAdapter([
      _token(usdcMint, 'USDC', 'USD Coin'),
      {'id': bonkMint, 'symbol': 'Bonk', 'name': 'Bonk'},
      {
        'id': solMint,
        'symbol': 'SOL',
        'name': 'Wrapped SOL',
        'decimals': 'nine',
      },
    ]);
    final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

    // Decimals feed the buy-side amount math, so a token cached as 0 decimals
    // quotes an amount off by 10^d — silently, and plausibly. Dropping the row
    // makes the token merely unavailable instead of wrong.
    expect(await service.search('bonk'), isEmpty);
    expect(await service.search('sol'), isEmpty);
    // ...and one malformed entry must not take the rest of the catalog with it.
    expect((await service.search('usdc')).single.decimals, 6);
  });

  test('skips a cached row whose stored decimals are null', () async {
    // `decimals` is nullable and rows written by an earlier build can hold
    // null; surfacing one as 0 is the same silent 10^d error as above.
    await db.replaceJupiterTokenList([
      CachedJupiterTokenListCompanion(
        mint: const Value(usdcMint),
        symbol: const Value('USDC'),
        name: const Value('USD Coin'),
        cachedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      ),
    ]);
    final service = JupiterVerifiedTokenListService.withAdapter(
      db,
      _CatalogAdapter([]),
    );

    expect(await service.search('usdc'), isEmpty);
  });

  group('popular', () {
    test('ranks by 24h volume, counting buys and sells together', () async {
      final adapter = _CatalogAdapter([
        _token(usdcMint, 'USDC', 'USD Coin', buyVolume: 10, sellVolume: 10),
        _token(bonkMint, 'Bonk', 'Bonk', buyVolume: 1, sellVolume: 1),
        _token(
          solMint,
          'SOL',
          'Wrapped SOL',
          decimals: 9,
          buyVolume: 100,
          sellVolume: 100,
        ),
      ]);
      final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

      final popular = await service.popular();

      // "Popular" is a claim about how much a token actually trades, and only
      // one side of the book is not that: a mint bought heavily and never sold
      // would outrank a genuinely liquid one if buys alone decided the order.
      expect(popular.map((t) => t.mint), [solMint, usdcMint, bonkMint]);
      expect(popular.first.dailyVolume, 200);
    });

    test('excludes tokens the list reports no 24h stats for', () async {
      final adapter = _CatalogAdapter([
        _token(usdcMint, 'USDC', 'USD Coin', buyVolume: 10, sellVolume: 10),
        _token(bonkMint, 'Bonk', 'Bonk'),
      ]);
      final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

      // Roughly half of Jupiter's verified set carries no stats24h block.
      // Reading that as zero volume would pad the tab with untraded tokens
      // presented as popular ones — search is where those belong.
      expect((await service.popular()).map((t) => t.mint), [usdcMint]);
      expect((await service.search('bonk')).single.mint, bonkMint);
    });

    test('honours the row limit', () async {
      final adapter = _CatalogAdapter([
        for (var i = 0; i < 5; i++)
          _token(
            'Mint$i${'1' * (43 - '$i'.length)}',
            'T$i',
            'Token $i',
            buyVolume: i.toDouble(),
          ),
      ]);
      final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

      final popular = await service.popular(limit: 2);

      // The limit has to cut the *least* traded tokens, not an arbitrary
      // window — truncating before the sort would drop the top of the list.
      expect(popular.map((t) => t.symbol), ['T4', 'T3']);
    });

    test('populates a cold catalog rather than reporting it empty', () async {
      final adapter = _CatalogAdapter([
        _token(usdcMint, 'USDC', 'USD Coin', buyVolume: 10, sellVolume: 10),
      ]);
      final service = JupiterVerifiedTokenListService.withAdapter(db, adapter);

      // The tab has no local rows to fall back on the way search does, so
      // serving [] on a cold cache reads as "there are no popular tokens".
      expect((await service.popular()).single.mint, usdcMint);
      expect(adapter.callCount, 1);
    });

    test('degrades to empty when the catalog cannot be fetched', () async {
      final service = JupiterVerifiedTokenListService.withAdapter(
        db,
        _ThrowingAdapter(),
      );

      // Offline, the picker still has to open — the tab just has nothing in it.
      expect(await service.popular(), isEmpty);
    });
  });
}

/// A database whose freshness probe fails, standing in for a locked/corrupt
/// file or the sheet being torn down (and the DB closed) mid-refresh.
class _CacheTimeThrowingDatabase extends MallowDatabase {
  _CacheTimeThrowingDatabase() : super.forTesting(NativeDatabase.memory());

  @override
  Future<DateTime?> getJupiterTokenListCacheTime() async =>
      throw StateError('database is closed');
}

/// Adapter whose fetch hangs until [release], standing in for the slow network
/// the picker must not block on when it already has rows to show.
class _BlockingAdapter implements HttpClientAdapter {
  final _gate = Completer<void>();
  bool started = false;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started = true;
    await _gate.future;
    return ResponseBody.fromString(
      '[]',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline',
    );
  }

  @override
  void close({bool force = false}) {}
}
