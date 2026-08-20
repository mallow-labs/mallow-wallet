import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/services/rewards_store_service.dart';

/// Records every URL the service actually puts on the wire, so a test can
/// assert that no request happened at all — not merely that the result was
/// null, which a swallowed transport failure also produces.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> requests = [];
  final Map<String, ResponseBody Function()> routes = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    final route = routes[url];
    if (route == null) return ResponseBody.fromString('', 404);
    return route();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object json) => ResponseBody.fromString(
  jsonEncode(json),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  late _RecordingAdapter adapter;
  late RewardsStoreService service;

  setUp(() {
    adapter = _RecordingAdapter();
    // The same shared client the app injects: base URL is the API host and the
    // interceptors that stamp build credentials hang off it.
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = adapter;
    service = RewardsStoreService(dio);
  });

  tearDown(Config.debugOverrides.clear);

  test('fetches SKU metadata from the configured store CDN', () async {
    Config.debugOverrides['ASSET_CDN_BASE_URL'] = 'https://cdn.example.com';
    adapter.routes['https://cdn.example.com/store/merch.shirt.foo.json'] = () =>
        _json({'name': 'Foo Shirt', 'image': 'https://img/foo.png'});

    final product = await service.getBySku('merch.shirt.foo');

    expect(product?.name, 'Foo Shirt');
    expect(adapter.requests, [
      'https://cdn.example.com/store/merch.shirt.foo.json',
    ]);
  });

  // An unset asset CDN empties Config.storeCdnBaseUrl, which used to leave the
  // relative path `/{sku}.json`. Dio resolves that against the API host, so
  // every rewards row in an activity list sent a credentialed GET — client-id,
  // api key, app version — to a backend route that does not exist. "No CDN
  // configured" must mean no store metadata, not a request somewhere else.
  test('issues no request at all when no store CDN is configured', () async {
    Config.debugOverrides['ASSET_CDN_BASE_URL'] = '';

    final product = await service.getBySku('merch.shirt.foo');

    expect(product, isNull);
    expect(adapter.requests, isEmpty);
  });
}
