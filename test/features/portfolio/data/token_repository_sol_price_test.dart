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
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mocktail/mocktail.dart';

class _MockPriceClient extends Mock implements JupiterPriceClient {}

class _MockJupiterTokenService extends Mock implements JupiterTokenService {}

/// Helius adapter for a wallet holding 2 SOL and nothing else, deliberately
/// **without** `price_per_sol`: that omission is the only path that falls back
/// to Jupiter for the SOL/USD rate, which is what these tests exercise.
class _NativeSolHeliusAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 'mallow-wallet',
        'result': {
          'items': <dynamic>[],
          'nativeBalance': {'lamports': 2000000000},
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

/// A Jupiter Price **v3** body, shaped as the live API answers: a flat map
/// keyed by mint with a numeric `usdPrice`. Decoded here the way the generated
/// client decodes it, so this test fails if the repository ever goes back to
/// expecting v2's `data` envelope with its string `price`.
const _v3Body =
    '{"So11111111111111111111111111111111111111112":'
    '{"createdAt":"2024-06-05T08:55:25.527Z","liquidity":666265821.7822826,'
    '"usdPrice":190.5,"blockId":439211370,"decimals":9,'
    '"priceChange24h":-0.438896049576193}}';

Map<String, PriceDto> _decodeV3(String body) =>
    (jsonDecode(body) as Map<String, dynamic>).map(
      (mint, entry) =>
          MapEntry(mint, PriceDto.fromJson(entry as Map<String, dynamic>)),
    );

void main() {
  late MallowDatabase db;
  late _MockPriceClient priceClient;
  late _MockJupiterTokenService jupiter;

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(const PriceRequestDto(ids: <String>[]));
  });

  setUp(() {
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.test';
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    priceClient = _MockPriceClient();
    jupiter = _MockJupiterTokenService();
    when(() => jupiter.getMarketInfo(any())).thenAnswer((_) async => {});
    when(
      () => priceClient.getPrice(any()),
    ).thenAnswer((_) async => _decodeV3(_v3Body));
  });

  tearDown(() {
    Config.debugOverrides.clear();
    return db.close();
  });

  const wallet = 'Wallet11111111111111111111111111111111111111';

  test(
    'prices native SOL from the flat v3 map when Helius omits the rate',
    () async {
      final repo = TokenRepository.withAdapter(
        priceClient,
        db,
        jupiter,
        _NativeSolHeliusAdapter(),
      );

      final balances = await repo.getTokenBalances(wallet);

      final sol = balances.singleWhere((t) => t.mint == TokenBalance.solMint);
      expect(sol.pricePerToken, 190.5);
      expect(sol.totalUsdValue, 381.0);
    },
  );

  test('asks Jupiter for the SOL mint only', () async {
    final repo = TokenRepository.withAdapter(
      priceClient,
      db,
      jupiter,
      _NativeSolHeliusAdapter(),
    );

    await repo.getTokenBalances(wallet);

    final request =
        verify(() => priceClient.getPrice(captureAny())).captured.single
            as PriceRequestDto;
    expect(request.ids, [TokenBalance.solMint]);
  });
}
