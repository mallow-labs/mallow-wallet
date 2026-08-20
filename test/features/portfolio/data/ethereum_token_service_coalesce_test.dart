import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/data/ethereum_token_service.dart';
import 'package:mallow_wallet/features/portfolio/data/uniswap_token_list_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockUniswapList extends Mock implements UniswapTokenListService {}

/// Fake EVM-balances adapter that counts requests and returns an empty wallet
/// so the balance flow completes without needing price/metadata.
class _CountingEvmAdapter implements HttpClientAdapter {
  int getCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    getCount++;
    return ResponseBody.fromString(
      jsonEncode({'result': <dynamic>[]}),
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
  late _MockUniswapList uniswap;
  late _CountingEvmAdapter adapter;
  late EthereumTokenService service;

  setUp(() {
    // EthereumTokenService builds its URL from Config.apiV2BaseUrl; pin it to a
    // test host so the adapter sees the request the assertions count.
    Config.debugOverrides['API_V2_BASE_URL'] = 'http://test.local:8090/v2';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    uniswap = _MockUniswapList();
    when(() => uniswap.verifiedContracts()).thenAnswer((_) async => <String>{});
    adapter = _CountingEvmAdapter();
    service = EthereumTokenService(
      db,
      uniswap,
      Dio()..httpClientAdapter = adapter,
    );
  });
  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  const address = '0x535B938D9BABDdE2ad618D313d87ef98A4a91b8e';

  // Regression: the in-flight-coalescing whenComplete callback must NOT return
  // the very future it is attached to. An arrow body (`() => _inFlight.remove`)
  // returns that future, so whenComplete waits on itself and getTokenBalances
  // never completes — the tokens portfolio then spins its loader forever.
  // A timeout here is the failure signal for that deadlock.
  test('getTokenBalances completes (no self-referential whenComplete '
      'deadlock)', () async {
    final result = await service
        .getTokenBalances(address)
        .timeout(const Duration(seconds: 2));
    expect(result, isEmpty);
    expect(adapter.getCount, 1);
  });

  test('coalescing is in-flight only — a later call re-fetches', () async {
    // If the in-flight entry never cleared (because the future deadlocked),
    // this second call would return the same stuck future and time out.
    await service.getTokenBalances(address).timeout(const Duration(seconds: 2));
    await service.getTokenBalances(address).timeout(const Duration(seconds: 2));
    expect(adapter.getCount, 2);
  });
}
