import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/jupiter_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockPriceClient extends Mock implements JupiterPriceClient {}

class _MockJupiterTokenService extends Mock implements JupiterTokenService {}

/// Fake Helius adapter that counts `searchAssets` POSTs and (optionally) holds
/// each request in flight behind [release], so the test can fire concurrent
/// callers before any resolves. Returns an empty wallet so the balance flow
/// completes without needing price/enrich data.
class _GatedHeliusAdapter implements HttpClientAdapter {
  _GatedHeliusAdapter({this.gated = false});

  final bool gated;
  final Completer<void> _release = Completer<void>();
  int postCount = 0;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    postCount++;
    if (gated) await _release.future;
    return ResponseBody.fromString(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'mallow-wallet',
        'result': {
          'items': <dynamic>[],
          'nativeBalance': {'lamports': 0},
        },
      }),
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
  late _MockPriceClient priceClient;
  late _MockJupiterTokenService jupiter;

  setUpAll(() => registerFallbackValue(<String>[]));

  setUp(() {
    // Point the RPC proxy at an unroutable host so any unstubbed call fails
    // fast instead of reaching the real rpc.example.com default.
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.test';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    priceClient = _MockPriceClient();
    jupiter = _MockJupiterTokenService();
    when(() => jupiter.getMarketInfo(any())).thenAnswer((_) async => {});
  });
  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  const wallet = 'Wallet11111111111111111111111111111111111111';
  const other = 'Wallet22222222222222222222222222222222222222';

  test('concurrent getTokenBalances for one wallet coalesce into a single '
      'searchAssets round', () async {
    final adapter = _GatedHeliusAdapter(gated: true);
    final repo = TokenRepository.withAdapter(priceClient, db, jupiter, adapter);

    // Mirrors the app-start / wallet-switch burst: several factory
    // TokenBalanceBlocs (tokens tab, swap, send, …) plus the drawer all
    // loading the active wallet at once.
    final calls = [
      repo.getTokenBalances(wallet),
      repo.getTokenBalances(wallet),
      repo.getTokenBalances(wallet),
    ];
    await pumpEventQueue();
    adapter.release();
    await Future.wait(calls);

    // Without coalescing this would have been three full rounds (three
    // searchAssets POSTs + three Jupiter enrich calls) — the duplicate
    // traffic that drove the 429s.
    expect(adapter.postCount, 1);
  });

  test('coalescing is in-flight only — a later call re-fetches', () async {
    final adapter = _GatedHeliusAdapter();
    final repo = TokenRepository.withAdapter(priceClient, db, jupiter, adapter);

    await repo.getTokenBalances(wallet);
    // The first round has settled and cleared the in-flight entry, so this is
    // a fresh fetch (freshness is the short balance cache's job, not this map).
    await repo.getTokenBalances(wallet);

    expect(adapter.postCount, 2);
  });

  test('distinct wallets are not collapsed together', () async {
    final adapter = _GatedHeliusAdapter(gated: true);
    final repo = TokenRepository.withAdapter(priceClient, db, jupiter, adapter);

    final calls = [repo.getTokenBalances(wallet), repo.getTokenBalances(other)];
    await pumpEventQueue();
    adapter.release();
    await Future.wait(calls);

    expect(adapter.postCount, 2);
  });
}
