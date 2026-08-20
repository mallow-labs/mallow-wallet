import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/cache_freshness.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_token_info_service.dart';

/// Fake adapter that counts `/tokens/v2/search` calls and returns a
/// Jupiter-shaped single-mint payload, so the test can assert how many times
/// the service actually hit the network behind its cache.
class _CountingSearchAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    final mint = options.queryParameters['query'] as String? ?? '';
    final payload = [
      {
        'id': mint,
        'name': 'Token $mint',
        'symbol': 'TKN',
        'decimals': 6,
        'usdPrice': 1.5,
        'mcap': 1000000,
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
  late _CountingSearchAdapter adapter;
  late JupiterTokenInfoService service;

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    adapter = _CountingSearchAdapter();
    service = JupiterTokenInfoService.withAdapter(db, adapter);
  });
  tearDown(() => db.close());

  const mint = 'Mint1111111111111111111111111111111111111111';

  test('a second call within the TTL is served from cache, no request', () async {
    final first = await service.getTokenInfo(mint);
    expect(first?.symbol, 'TKN');
    expect(adapter.callCount, 1);

    // Reopening the same token detail moments later must not re-hit the proxy —
    // this is the repeated single-mint storm the cache exists to kill.
    final second = await service.getTokenInfo(mint);
    expect(second?.symbol, 'TKN');
    expect(second?.decimals, 6);
    expect(adapter.callCount, 1);
  });

  test('a call after the TTL expires re-fetches', () async {
    await service.getTokenInfo(mint);
    expect(adapter.callCount, 1);

    // Age the cached row past the 5-minute TTL by backdating cachedAt.
    final stale =
        CacheFreshness.nowEpochSeconds() - const Duration(minutes: 6).inSeconds;
    await db.upsertTokenInfoCache(
      CachedJupiterTokenInfoCompanion(
        mint: const Value(mint),
        jsonData: Value(jsonEncode({'mint': mint, 'symbol': 'OLD'})),
        cachedAt: Value(stale),
      ),
    );

    final refreshed = await service.getTokenInfo(mint);
    // Stale row triggered a network refresh, which overwrote 'OLD' with 'TKN'.
    expect(adapter.callCount, 2);
    expect(refreshed?.symbol, 'TKN');
  });
}
