import 'package:dio/dio.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  test('deposit discovery and close use the v2 routes and response envelopes', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'result': request.method == 'GET' ? {'claims': []} : {'tx': 'UNSIGNED'},
              },
            ),
          );
        },
      ),
    );
    final client = MallowApiV2Client(dio, baseUrl: 'https://example.com/v2');
    final deposits = await client.getBidRefundClaims('PAYER');
    final close = await client.closeBidRefundClaimTx(
      const CloseBidRefundClaimTxRequest(
        rentPayer: 'PAYER',
        claim: 'CLAIM',
        targetPriorityFeeLamports: 5000,
      ),
    );
    expect(deposits.result.claims, isEmpty);
    expect(close.result.tx, 'UNSIGNED');
    expect(requests[0].method, 'GET');
    expect(requests[0].uri.path, '/v2/auctions/bid-refund-claims/PAYER');
    expect(requests[1].method, 'POST');
    expect(requests[1].uri.path, '/v2/tx/auctions/close-bid-refund-claim');
    expect(requests[1].data, containsPair('rentPayer', 'PAYER'));
    expect(requests[1].data, containsPair('claim', 'CLAIM'));
  });
  test('SOL release uses its v2 route and the payer signs for the recorded bidder', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'result': {'tx': 'UNSIGNED'},
              },
            ),
          );
        },
      ),
    );
    final client = MallowApiV2Client(dio, baseUrl: 'https://example.com/v2');
    final result = await client.pushSolBidRefundTx(
      const PushSolBidRefundTxRequest(
        payer: 'PAYER',
        bidder: 'BIDDER',
        targetPriorityFeeLamports: 5000,
      ),
    );
    expect(result.result.tx, 'UNSIGNED');
    expect(requests.single.method, 'POST');
    expect(requests.single.uri.path, '/v2/tx/auctions/push-sol-bid-refund');
    expect(requests.single.data, containsPair('payer', 'PAYER'));
    expect(requests.single.data, containsPair('bidder', 'BIDDER'));
    expect(requests.single.data, containsPair('targetPriorityFeeLamports', 5000));
    expect(requests.single.data, isNot(contains('rentPayer')));
    expect(requests.single.data, isNot(contains('destination')));
    expect(requests.single.data, isNot(contains('target_priority_fee_lamports')));
  });
  for (final destination in [null, 'ALTERNATIVE']) {
    test('token release forwards destination $destination with the recorded bidder', () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'result': {'tx': 'UNSIGNED'},
                },
              ),
            );
          },
        ),
      );
      final client = MallowApiV2Client(dio, baseUrl: 'https://example.com/v2');
      final result = await client.pushBidRefundTx(
        PushBidRefundTxRequest(
          payer: 'PAYER',
          bidder: 'BIDDER',
          mint: 'TOKEN_MINT',
          destination: destination,
          targetPriorityFeeLamports: 5000,
        ),
      );
      expect(result.result.tx, 'UNSIGNED');
      expect(requests.single.method, 'POST');
      expect(requests.single.uri.path, '/v2/tx/auctions/push-bid-refund');
      expect(requests.single.data, containsPair('payer', 'PAYER'));
      expect(requests.single.data, containsPair('bidder', 'BIDDER'));
      expect(requests.single.data, containsPair('mint', 'TOKEN_MINT'));
      expect(requests.single.data, containsPair('targetPriorityFeeLamports', 5000));
      expect(requests.single.data, isNot(contains('rentPayer')));
      if (destination == null) {
        expect(requests.single.data, isNot(contains('destination')));
      } else {
        expect(requests.single.data, containsPair('destination', destination));
      }
      expect(requests.single.data, isNot(contains('target_priority_fee_lamports')));
    });
  }
}
