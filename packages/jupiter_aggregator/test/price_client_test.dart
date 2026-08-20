import 'dart:io';

import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:test/test.dart';

const _sol = 'So11111111111111111111111111111111111111112';
const _usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const _unpriced = 'NotAMintAddress111111111111111111111111111';

/// Captured live from `GET /price/v3?ids=$_sol,$_usdc,$_unpriced` on
/// 2026-08-14, verbatim. Two properties of it are the point of these tests:
/// the body is a FLAT map keyed by mint (v2 nested its entries under `data`),
/// `usdPrice` is a JSON number (v2's `price` was a string), and a mint Jupiter
/// cannot price is simply missing rather than present-and-null.
const _v3Body =
    '{"$_usdc":{"createdAt":"2024-06-05T08:55:25.527Z",'
    '"liquidity":366301759.87436855,"usdPrice":0.9995676897815599,'
    '"blockId":439211368,"decimals":6,"priceChange24h":0.0038771166339592288},'
    '"$_sol":{"createdAt":"2024-06-05T08:55:25.527Z",'
    '"liquidity":666265821.7822826,"usdPrice":75.34131397160515,'
    '"blockId":439211370,"decimals":9,"priceChange24h":-0.438896049576193}}';

void main() {
  late HttpServer server;
  late List<Uri> requests;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(_v3Body);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  JupiterPriceClient client() =>
      JupiterPriceClient(baseUrl: 'http://${server.address.address}:${server.port}/');

  test('requests /price/v3 with the ids comma-joined', () async {
    await client().getPrice(const PriceRequestDto(ids: [_sol, _usdc]));

    // Pinned deliberately: Jupiter retired Price v2 and `/price/v2` now 404s on
    // api.jup.ag, lite-api.jup.ag and the proxy alike, so a revert to it is a
    // silent loss of every Jupiter-sourced price.
    expect(requests.single.path, '/price/v3');
    expect(requests.single.queryParameters['ids'], '$_sol,$_usdc');
  });

  test('parses the flat mint-keyed map with a numeric usdPrice', () async {
    final prices = await client().getPrice(const PriceRequestDto(ids: [_sol, _usdc]));

    expect(prices.keys, unorderedEquals(<String>[_sol, _usdc]));
    expect(prices[_sol]!.usdPrice, closeTo(75.34131397160515, 1e-12));
    expect(prices[_usdc]!.usdPrice, closeTo(0.9995676897815599, 1e-12));
  });

  test('a mint Jupiter cannot price is absent from the map', () async {
    final prices = await client().getPrice(const PriceRequestDto(ids: [_sol, _usdc, _unpriced]));

    expect(prices.containsKey(_unpriced), isFalse);
    expect(prices[_unpriced], isNull);
  });
}
