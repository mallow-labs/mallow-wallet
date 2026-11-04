import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.endsWith('/confirm')) return ResponseBody.fromString('{}', 200);
    final payload = options.path.endsWith('/prepare')
        ? {
            'quoteId': 'quote',
            'orderHash': 'order',
            'chainId': 1,
            'from': 'buyer',
            'to': 'seaport',
            'data': '0x12345678',
            'value': '123456789012345678901',
            'submitBy': '2030-01-01T00:00:00Z',
          }
        : {
            'quoteId': 'quote',
            'orderHash': 'order',
            'chainId': 1,
            'buyerAddress': 'buyer',
            'contractAddress': 'contract',
            'tokenId': '42',
            'protocolAddress': 'seaport',
            'tokenStandard': 'erc1155',
            'quantity': '1',
            'listedCopies': '8',
            'marketplace': 'opensea',
            'sellerProceedsWei': '123456789012345678901',
            'marketplaceFees': [],
            'creatorFees': [],
            'buyerPaidExtraWei': '0',
            'totalWei': '123456789012345678901',
            'estimatedGas': '100',
            'estimatedGasWei': '200',
            'expiresAt': '2030-01-01T00:00:00Z',
            'referral': {'enabled': false, 'buyerCostWei': '0'},
          };
    return ResponseBody.fromString(
      jsonEncode({'result': payload}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  test('v1 OpenSea routes serialize camelCase and retain exact wei and expiry', () async {
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final api = MallowApiClient(dio, baseUrl: 'https://api.example.com');
    final quote = (await api.quoteOpenSeaPurchase(
      const OpenSeaPurchaseQuoteRequest(artworkId: 'contract-42', buyerAddress: 'buyer'),
    )).result;
    expect(quote.totalWei, '123456789012345678901');
    expect(quote.listedCopies, '8');
    expect(quote.tokenStandard.value, 'erc1155');
    expect(quote.quantity.value, '1');
    final prepared = (await api.prepareOpenSeaPurchase(
      const OpenSeaPurchasePrepareRequest(quoteId: 'quote', buyerAddress: 'buyer'),
    )).result;
    expect(prepared.value, quote.totalWei);
    expect(prepared.submitBy, DateTime.utc(2030));
    await api.confirmOpenSeaPurchase(
      const OpenSeaPurchaseConfirmRequest(
        artworkId: 'contract-42',
        buyerAddress: 'buyer',
        transactionHash: 'hash',
      ),
    );
    expect(adapter.requests.map((r) => r.path), [
      '/v1/opensea/purchase/quote',
      '/v1/opensea/purchase/prepare',
      '/v1/opensea/purchase/confirm',
    ]);
    expect(adapter.requests[0].data, {'artworkId': 'contract-42', 'buyerAddress': 'buyer'});
    expect(adapter.requests[1].data, {'quoteId': 'quote', 'buyerAddress': 'buyer'});
    expect(adapter.requests[2].data, {
      'artworkId': 'contract-42',
      'buyerAddress': 'buyer',
      'transactionHash': 'hash',
    });
    dio.close();
  });
}
