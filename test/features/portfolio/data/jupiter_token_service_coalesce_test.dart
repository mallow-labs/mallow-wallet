import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_token_service.dart';

/// A fake [HttpClientAdapter] that counts `/tokens/v2/search` calls and gates
/// each one behind a [Completer], so a test can hold a request "in flight"
/// while it fires concurrent callers — then release them all at once.
///
/// Every call records the `query` it was asked for and returns a Jupiter-shaped
/// array echoing each requested mint, so the service caches a row per mint.
class _GatedSearchAdapter implements HttpClientAdapter {
  _GatedSearchAdapter({this.gated = false});

  /// When true, [fetch] blocks on [release] before responding.
  final bool gated;
  final Completer<void> _release = Completer<void>();

  int callCount = 0;
  final List<List<String>> queriedMints = [];

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    final query = options.queryParameters['query'] as String? ?? '';
    final mints = query.isEmpty ? <String>[] : query.split(',');
    queriedMints.add(mints);

    if (gated) await _release.future;

    final payload = [
      for (final mint in mints)
        {
          'id': mint,
          'usdPrice': 1.5,
          'stats24h': {'priceChange': 2.0},
          'tags': ['verified'],
          'name': 'Token $mint',
          'symbol': 'TKN',
          'icon': 'https://example.test/$mint.png',
        },
    ];

    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late MallowDatabase db;

  setUp(() => db = MallowDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const m1 = 'Mint1111111111111111111111111111111111111111';
  const m2 = 'Mint2222222222222222222222222222222222222222';
  const m3 = 'Mint3333333333333333333333333333333333333333';

  test(
    'concurrent overlapping getMarketInfo calls coalesce into one request',
    () async {
      // Gated: the first request is held in flight while the siblings start, so
      // they must find the in-flight future rather than racing their own
      // cache-cold fetch. This is exactly the app-open / wallet-switch burst.
      final adapter = _GatedSearchAdapter(gated: true);
      final service = JupiterTokenService.withAdapter(db, adapter);

      // Three callers with overlapping mint sets, all started before any
      // resolves — mirrors several blocs fetching different wallets at once.
      final fA = service.getMarketInfo([m1, m2]);
      final fB = service.getMarketInfo([m2, m3]);
      final fC = service.getMarketInfo([m1, m2, m3]);

      // Let every caller progress past its cache read to its in-flight check.
      await pumpEventQueue();

      // Only now release the network. If coalescing works, the later callers
      // already attached to the first fetch's in-flight futures.
      adapter.release();

      final results = await Future.wait([fA, fB, fC]);

      // The whole burst touches each unique mint exactly once. Without
      // coalescing every caller would have fired its own request for the
      // shared mints (m2 three times, m1/m3 twice) — the stampede that the
      // proxy answers with 429.
      final allQueried = adapter.queriedMints.expand((e) => e).toList();
      expect(allQueried.toSet(), {m1, m2, m3});
      expect(
        allQueried.length,
        3,
        reason: 'each unique mint fetched once across the burst, no duplicates',
      );

      // Every caller still gets complete data for the mints it asked for.
      expect(results[0].keys.toSet(), {m1, m2});
      expect(results[1].keys.toSet(), {m2, m3});
      expect(results[2].keys.toSet(), {m1, m2, m3});
      expect(results[2][m2]?.usdPrice, 1.5);
      expect(results[2][m2]?.isVerified, isTrue);
    },
  );

  test('a fresh cache hit issues no request at all', () async {
    final adapter = _GatedSearchAdapter();
    final service = JupiterTokenService.withAdapter(db, adapter);

    // First call populates the 15-minute market cache.
    await service.getMarketInfo([m1]);
    expect(adapter.callCount, 1);

    // A second call moments later is served entirely from cache.
    final cached = await service.getMarketInfo([m1]);
    expect(adapter.callCount, 1);
    expect(cached[m1]?.usdPrice, 1.5);
  });
}
