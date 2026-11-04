import 'package:dio/dio.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  const quoteJson = {
    'orderId': 'order',
    'revision': 12,
    'mintAccount': 'mint',
    'seller': 'seller',
    'currencyMint': 'currency',
    'currencySymbol': 'TOKEN',
    'currencyDecimals': 6,
    'sellerPrice': '18446744073709551615',
    'creatorRoyalty': '10',
    'magicEdenFee': '20',
    'mallowFeeLamports': '30',
    'networkFeeLamports': '40',
    'rentLamports': '50',
    'totalPaymentAmount': '18446744073709551645',
    'totalSolDebitLamports': '120',
    'expiresAt': '2030-01-01T00:00:00Z',
    'buyerPaymentBalance': '18446744073709551645',
    'buyerSolBalanceLamports': '120',
  };
  test('quote and transaction parse exact amounts and confirmation window', () {
    final body = MagicEdenBuyTxResponse.fromJson({
      'tx': 'base64',
      'quote': quoteJson,
      'lastValidBlockHeight': 500000000,
    });
    expect(body.quote.totalPaymentAmount, '18446744073709551645');
    expect(body.quote.buyerPaymentBalance, '18446744073709551645');
    expect(body.quote.expiresAt, DateTime.utc(2030));
    expect(body.lastValidBlockHeight, 500000000);
  });
  test('unavailable orders need no quote', () {
    final result = MagicEdenBuyQuoteResponse.fromJson({
      'available': false,
      'reason': 'Order changed',
    });
    expect(result.quote, isNull);
    expect(result.reason, 'Order changed');
  });
  test('client uses v2 paths, query keys, and both debit ceilings', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'result': request.method == 'GET'
                      ? {'available': true, 'quote': quoteJson}
                      : {'tx': 'base64', 'quote': quoteJson, 'lastValidBlockHeight': 500000000},
                },
              ),
            );
          },
        ),
      );
    final client = MallowApiV2Client(dio, baseUrl: 'https://api.example.com/v2');
    final response = await client.quoteMagicEdenBuy('mint', 'buyer');
    expect(response.result.quote!.sellerPrice, '18446744073709551615');
    expect(requests.first.uri.path, '/v2/magic-eden/quote');
    expect(requests.first.queryParameters, {'mintAccount': 'mint', 'buyer': 'buyer'});
    await client.buyMagicEdenTx(
      const MagicEdenBuyTxRequest(
        buyer: 'buyer',
        orderId: 'order',
        revision: 12,
        paymentMint: 'currency',
        maxPaymentAmount: '18446744073709551645',
        maxSolDebitLamports: '120',
      ),
    );
    expect(requests.last.uri.path, '/v2/tx/magic-eden/buy');
    expect(requests.last.data, {
      'buyer': 'buyer',
      'orderId': 'order',
      'revision': 12,
      'paymentMint': 'currency',
      'maxPaymentAmount': '18446744073709551645',
      'maxSolDebitLamports': '120',
    });
    dio.close();
  });
}
