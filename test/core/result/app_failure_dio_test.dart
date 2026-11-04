import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';

DioException badRequest(Object? data) {
  final request = RequestOptions(path: '/tx/auctions/bid');
  return DioException.badResponse(
    statusCode: 400,
    requestOptions: request,
    response: Response<Object?>(
      requestOptions: request,
      statusCode: 400,
      data: data,
    ),
  );
}

void main() {
  const bidMinimum =
      'bidAmount must be at least 890880 for this auction currency';

  group('AppFailure.from — HTTP error messages', () {
    test(
      'preserves a nested backend refusal through guard and prefix',
      () async {
        final error = badRequest({
          'error': {'message': bidMinimum},
        });

        final result = await Result.guard<void>(() async => throw error);
        final failure = result.errorOrNull!.prefixedWith(
          'Failed to prepare bid',
        );

        expect(failure.kind, AppFailureKind.network);
        expect(failure.message, 'Failed to prepare bid: $bidMinimum');
        expect(failure.cause, same(error));
      },
    );

    final messages = <String, (Object?, String)>{
      'flat message': ({'message': 'Listing not found'}, 'Listing not found'),
      'flat error': ({'error': 'Invalid proof'}, 'Invalid proof'),
      'nested error before top-level message': (
        {
          'message': 'Top-level refusal',
          'error': {'message': 'Nested refusal'},
        },
        'Nested refusal',
      ),
      'plain text': ('Gateway unavailable', 'Gateway unavailable'),
      'empty nested message': (
        {
          'error': {'message': ''},
        },
        'Request failed (400)',
      ),
      'non-string nested message': (
        {
          'error': {'message': 123},
        },
        'Request failed (400)',
      ),
      'missing nested message': (
        {
          'error': {'code': 'invalid_bid'},
        },
        'Request failed (400)',
      ),
      'null error': ({'error': null}, 'Request failed (400)'),
      'non-map body': (['Invalid proof'], 'Request failed (400)'),
      'missing body': (null, 'Request failed (400)'),
    };

    for (final entry in messages.entries) {
      test('handles ${entry.key}', () {
        final (body, expectedMessage) = entry.value;
        final error = badRequest(body);

        final failure = AppFailure.from(error);

        expect(failure.kind, AppFailureKind.network);
        expect(failure.message, expectedMessage);
        expect(failure.cause, same(error));
      });
    }
  });
}
