import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';

DioException _http(int status, Object? body) {
  final options = RequestOptions(path: '/v2/tx/fixed-price/buy');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: body,
    ),
  );
}

/// A refused request has to tell the user why. The backend says why in
/// `{ "error": { "message": "…" } }`, and a classifier that reads only a
/// top-level string turns every one of those into `Request failed (403)`.
void main() {
  const restricted = 'Marketplace actions are disabled for this account';

  group('AppFailure.from — server message', () {
    test('reads the message out of the backend error envelope', () {
      final failure = AppFailure.from(
        _http(403, {
          'error': {'message': restricted},
        }),
      );

      expect(failure.kind, AppFailureKind.network);
      expect(failure.message, restricted);
    });

    test('reads it whatever the status, not only for a 403', () {
      for (final status in [400, 401, 404, 409, 422, 429, 500, 503]) {
        final failure = AppFailure.from(
          _http(status, {
            'error': {'message': 'Listing not found'},
          }),
        );

        expect(failure.message, 'Listing not found', reason: 'status $status');
      }
    });

    test('ignores the fields that travel beside the message', () {
      final failure = AppFailure.from(
        _http(429, {
          'error': {
            'message': 'Rate limit exceeded. Retry after reset.',
            'code': 'RATE_LIMITED',
          },
        }),
      );

      expect(failure.message, 'Rate limit exceeded. Retry after reset.');
    });

    test('reads the older envelope', () {
      final failure = AppFailure.from(
        _http(400, {
          'err': {'message': 'Invalid signature'},
        }),
      );

      expect(failure.message, 'Invalid signature');
    });

    test('still reads a flat message or a flat error string', () {
      expect(
        AppFailure.from(_http(400, {'message': 'Bad amount'})).message,
        'Bad amount',
      );
      expect(
        AppFailure.from(_http(400, {'error': 'Bad amount'})).message,
        'Bad amount',
      );
    });

    test('prefers the envelope over a flat message beside it', () {
      final failure = AppFailure.from(
        _http(403, {
          'message': 'Forbidden',
          'error': {'message': restricted},
        }),
      );

      expect(failure.message, restricted);
    });

    test('falls back to the status when the body names no reason', () {
      for (final body in <Object?>[
        null,
        <String, Object?>{},
        {'error': <String, Object?>{}},
        {
          'error': {'message': ''},
        },
        {
          'error': {'message': '   '},
        },
        {
          'error': {'message': 42},
        },
        {'result': false},
      ]) {
        expect(
          AppFailure.from(_http(403, body)).message,
          'Request failed (403)',
          reason: 'body $body',
        );
      }
    });

    test('keeps a short plain-text body, and not a long one', () {
      expect(AppFailure.from(_http(502, 'Bad Gateway')).message, 'Bad Gateway');
      expect(
        AppFailure.from(_http(502, '<html>${'x' * 300}</html>')).message,
        'Request failed (502)',
      );
    });

    test('a phase prefix keeps the reason it wraps', () {
      final failure = AppFailure.from(
        _http(403, {
          'error': {'message': restricted},
        }),
      );

      expect(
        failure.prefixedWith('Listing failed').message,
        'Listing failed: $restricted',
      );
    });

    test('Result.guard carries the reason to the caller', () async {
      final result = await Result.guard<void>(
        () async => throw _http(403, {
          'error': {'message': 'Trading with this account is disabled'},
        }),
      );

      expect(result, isA<ResultFailure<void, AppFailure>>());
      expect(
        (result as ResultFailure<void, AppFailure>).error.message,
        'Trading with this account is disabled',
      );
    });
  });
}
