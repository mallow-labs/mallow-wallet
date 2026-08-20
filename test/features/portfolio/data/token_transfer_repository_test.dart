import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/data/address_scope_key.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/token_transfer_repository.dart';

const _addr = '8M9bV1Rjs1R4w4uX4qzPCsBkLs1ehrhRrUkkPwbAddrz';
const _siblingAddr = '9N1cW2Sktu2S5x5vY5razQDtCmLt2fisSsVllQxcBees';
const _mint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

Map<String, dynamic> _activityJson(String id) => {
  'id': id,
  'type': 'send',
  'timestamp': 1700000000,
  'signature': 'sig-$id',
  'status': 'finalized',
  'data': <String, dynamic>{},
};

/// Serves one canned body and records the request the repository built.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
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

  setUp(() {
    Config.debugOverrides['API_V2_BASE_URL'] = 'http://test.local:8090/v2';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  TokenTransferRepository build(_RecordingAdapter adapter) =>
      TokenTransferRepository(db, Dio()..httpClientAdapter = adapter);

  group('fetchTransfers', () {
    // 🛑 Regression: `GET /v2/transfers` wraps its ActivityListResponse in the
    // shared v2 `{"result": ...}` envelope, so the rows live at
    // `result.result` — NOT at `result` like `/v2/activity`, which returns the
    // response bare. Reading the outer key as the row list cast a Map to a
    // List, the throw was swallowed by the bloc's cache fallback, and the
    // History tab was empty for every token on every account.
    test(
      'reads rows and the cursor from inside the ApiResponse envelope',
      () async {
        final adapter = _RecordingAdapter({
          'result': {
            'result': [_activityJson('a'), _activityJson('b')],
            'pagination': {
              'page': 0,
              'limit': 50,
              'hasMore': true,
              'lastSignature': 'cursor-2',
            },
          },
        });

        final page = await build(
          adapter,
        ).fetchTransfers(addresses: [_addr], mint: _mint);

        expect(page.activities.map((a) => a.id), ['a', 'b']);
        expect(page.paginationToken, 'cursor-2');
        expect(page.hasMore, isTrue);
      },
    );

    test(
      'reports no more pages when the envelope omits lastSignature',
      () async {
        final adapter = _RecordingAdapter({
          'result': {
            'result': [_activityJson('a')],
            'pagination': {'page': 0, 'limit': 50, 'hasMore': false},
          },
        });

        final page = await build(
          adapter,
        ).fetchTransfers(addresses: [_addr], mint: _mint);

        expect(page.activities, hasLength(1));
        expect(page.hasMore, isFalse);
      },
    );

    // The Rust handler splits a single `addresses` param on commas; a repeated
    // key would not deserialize server-side.
    test('sends the whole scope comma-joined in one addresses param', () async {
      final adapter = _RecordingAdapter({
        'result': {
          'result': <dynamic>[],
          'pagination': {'page': 0, 'limit': 50, 'hasMore': false},
        },
      });

      await build(
        adapter,
      ).fetchTransfers(addresses: [_addr, _siblingAddr], mint: _mint);

      final query = adapter.requests.single.queryParameters;
      expect(query['addresses'], '$_addr,$_siblingAddr');
      expect(query['mint'], _mint);
    });

    // The handler fails soft on the first Helius error, so an empty scope must
    // not become a request at all — `addresses=` returns an empty page that
    // would then be cached over real history.
    test('makes no request for an empty scope', () async {
      final adapter = _RecordingAdapter(const {});

      final page = await build(
        adapter,
      ).fetchTransfers(addresses: const [], mint: _mint);

      expect(page.activities, isEmpty);
      expect(adapter.requests, isEmpty);
    });

    // The fetch aggregates across the scope, so the cache must be keyed by the
    // whole scope. Keying it by one wallet let a second session wallet's rows
    // overwrite the first's under the same key.
    test('caches the page under the scope key, readable back by it', () async {
      final adapter = _RecordingAdapter({
        'result': {
          'result': [_activityJson('a')],
          'pagination': {'page': 0, 'limit': 50, 'hasMore': false},
        },
      });
      final repository = build(adapter);
      final scope = [_siblingAddr, _addr];

      await repository.fetchTransfers(addresses: scope, mint: _mint);

      final cached = await repository.getCachedActivities(
        cacheKey: addressScopeKey(scope),
        mint: _mint,
      );
      expect(cached.map((a) => a.id), ['a']);
    });
  });
}
