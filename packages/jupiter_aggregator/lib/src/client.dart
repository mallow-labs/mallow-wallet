import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:retrofit/retrofit.dart';

part 'client.g.dart';

const _defaultSwapApiUrl = 'https://api.jup.ag/ultra/v1';
const _defaultPriceApiUrl = 'https://api.jup.ag/';

/// Jupiter Ultra swap API (`/ultra/v1`) — managed order → execute flow.
/// For docs head to https://dev.jup.ag/docs/ultra-api
@RestApi()
abstract class JupiterAggregatorClient {
  factory JupiterAggregatorClient({String? baseUrl, String? apiKey}) => _JupiterAggregatorClient(
    Dio()
      ..interceptors.addAll([
        if (apiKey != null)
          InterceptorsWrapper(
            onRequest: (options, handler) {
              options.headers['x-api-key'] = apiKey;
              handler.next(options);
            },
          ),
      ]),
    baseUrl:
        baseUrl ?? const String.fromEnvironment('QUOTE_API_BASE', defaultValue: _defaultSwapApiUrl),
  );

  /// Quote + unsigned transaction (when `taker` is set) for a swap.
  @GET('/order')
  Future<UltraOrderResponseDto> getOrder(@Queries() UltraOrderRequestDto orderRequestDto);

  /// Submit the signed order transaction — Jupiter broadcasts and confirms.
  @POST('/execute')
  Future<UltraExecuteResponseDto> executeOrder(@Body() UltraExecuteRequestDto executeRequestDto);
}

/// For docs head to https://dev.jup.ag/docs/price-api
@RestApi()
abstract class JupiterPriceClient {
  factory JupiterPriceClient({String? baseUrl, String? apiKey}) => _JupiterPriceClient(
    Dio()
      ..interceptors.addAll([
        InterceptorsWrapper(
          onResponse: (response, handler) {
            final content = response.data;
            if (content is String) response.data = json.decode(content);
            handler.next(response);
          },
        ),
        if (apiKey != null)
          InterceptorsWrapper(
            onRequest: (options, handler) {
              options.headers['x-api-key'] = apiKey;
              handler.next(options);
            },
          ),
      ]),
    baseUrl: baseUrl ?? _defaultPriceApiUrl,
  );

  /// Current USD prices for the requested mints, keyed by mint.
  ///
  /// Price **v3** answers with a flat map — mint → price object — and omits a
  /// mint it has no price for, so a missing key is the "unpriced" case. There
  /// is no `data` envelope; v2, which had one, is retired and now 404s.
  @GET('/price/v3')
  Future<Map<String, PriceDto>> getPrice(@Queries() PriceRequestDto priceRequestDto);
}
